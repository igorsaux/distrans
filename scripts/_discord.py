"""Minimal Discord REST client for refreshing expired CDN URLs in ``importguild.py``.

Discord attachment CDN URLs carry a signed query string (``ex``/``is``/``hm``)
that expires after roughly a day, so a dump older than that cannot be
downloaded as-is. This client re-signs the affected URLs over the REST API; it
never downloads media itself.

The fast path is ``POST /attachments/refresh-urls`` (up to 50 URLs per call),
which is exactly what Discord offers for expiring attachment links. Only
URLs that endpoint cannot refresh are looked up message-by-message. Both paths
handle 429 rate limits; a 403/404 (no access / deleted message) yields ``None``
so the caller can skip it.
"""
import time
import urllib.parse

import httpx

API_BASE = "https://discord.com/api/v10"
REFRESH_BATCH = 50


class DiscordError(Exception):
    pass


def signed_url_expired(url, now=None, margin_s=300):
    """True when ``url`` carries no usable signed URL.

    Discord attachment links are signed with a hex ``ex`` (expiry, seconds
    since epoch); a link without ``ex`` or with an expired one must be
    refreshed before it can be downloaded. ``margin_s`` refreshes slightly
    early to avoid racing the expiry.
    """
    if not isinstance(url, str) or not url:
        return True

    query = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    values = query.get("ex")

    if not values:
        return True

    try:
        expires_at = int(values[0], 16)
    except (TypeError, ValueError):
        return True

    if now is None:
        now = time.time()

    return expires_at - margin_s <= now


class Discord:
    """A bot-authenticated Discord REST client (Get/POST, no media)."""

    def __init__(self, token, timeout=30.0):
        self.token = token
        self._client = httpx.Client(
            base_url=API_BASE,
            headers={
                "Authorization": f"Bot {token}",
                "User-Agent": "distrans-importguild/1.0",
            },
            timeout=timeout,
        )

    def close(self):
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()

    def _request(self, method, path, params=None, json=None, attempts=6):
        for attempt in range(attempts):
            response = self._client.request(method, path, params=params, json=json)

            if response.status_code == 429:
                try:
                    retry_after = float(response.json().get("retry_after", 1.0))
                except (ValueError, TypeError):
                    retry_after = 1.0

                time.sleep(min(60.0, retry_after) + 0.1)

                continue

            if response.status_code in (401, 403, 404):
                return None

            if response.status_code >= 500 and attempt + 1 < attempts:
                time.sleep(2**attempt)

                continue

            response.raise_for_status()

            return response.json()

        raise DiscordError(f"{method} {path} kept failing after {attempts} attempts")

    def get_message(self, channel_id, message_id):
        return self._request("GET", f"/channels/{channel_id}/messages/{message_id}")

    def refresh_attachment_urls(self, urls):
        """Re-sign up to 50 attachment URLs via ``POST /attachments/refresh-urls``.

        Returns ``{old_url: new_url}`` for the URLs Discord could re-sign; the
        endpoint is bot-token only and refreshes the signed query string in one
        round trip.
        """
        mapping = {}

        for start in range(0, len(urls), REFRESH_BATCH):
            batch = urls[start : start + REFRESH_BATCH]
            payload = self._request(
                "POST", "/attachments/refresh-urls", json={"attachment_urls": batch}
            )

            if not payload:
                continue

            for item in payload.get("refreshed_urls") or []:
                original = item.get("original")
                refreshed = item.get("refreshed")

                if original and refreshed:
                    mapping[original] = refreshed

        return mapping


def fresh_attachment_urls(message):
    """Map attachment id -> fresh CDN URL from a REST message payload."""
    urls = {}

    for attachment in message.get("attachments") or []:
        attachment_id = attachment.get("id")
        url = attachment.get("url")

        if attachment_id is None or not url:
            continue

        urls[int(attachment_id)] = url

    return urls
