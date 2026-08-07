"""Minimal AWS Signature V4 S3 client used by ``importguild.py``.

The server uploads files with libcurl's ``CURLAUTH_AWS_SIGV4`` against the
endpoint/region/keys in ``files.s3`` (see ``src/services/files.zig``), storing
objects at the path-style key ``files/<hash>``. This module reproduces just
enough of that signing to ``PUT`` an object from the importer without pulling in
``boto3``: the same canonical request, region and service (``s3``), the payload
``x-amz-content-sha256``, and a single ``PUT`` per object.

Only ``put`` is implemented; the importer never deletes or lists.
"""
import datetime
import hashlib
import hmac
import urllib.error
import urllib.parse
import urllib.request

_ALGORITHM = "AWS4-HMAC-SHA256"
_SERVICE = "s3"


class S3Error(Exception):
    """A signed S3 request failed or the config has no usable S3 section."""


def _hmac(key, message):
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret_key, date, region, service):
    k_date = _hmac(("AWS4" + secret_key).encode("utf-8"), date)
    k_region = hmac.new(k_date, region.encode("utf-8"), hashlib.sha256).digest()
    k_service = hmac.new(k_region, service.encode("utf-8"), hashlib.sha256).digest()

    return hmac.new(k_service, b"aws4_request", hashlib.sha256).digest()


class S3:
    """A configured S3 endpoint. ``available()`` is False without a config."""

    def __init__(self, endpoint, region, access_key, secret_key, public_base_url=None):
        self.endpoint = endpoint.rstrip("/")
        self.region = region
        self.access_key = access_key
        self.secret_key = secret_key
        self.public_base_url = (public_base_url or "").rstrip("/")

    @classmethod
    def from_config(cls, config):
        files = config.get("files") if isinstance(config, dict) else None

        if not isinstance(files, dict) or files.get("type") != "s3":
            return None

        s3 = files.get("s3")

        if not isinstance(s3, dict):
            return None

        endpoint = s3.get("endpoint")
        region = s3.get("region")
        access_key = s3.get("access_key")
        secret_key = s3.get("secret_key")

        for name, value in (
            ("files.s3.endpoint", endpoint),
            ("files.s3.region", region),
            ("files.s3.access_key", access_key),
            ("files.s3.secret_key", secret_key),
        ):
            if not isinstance(value, str) or not value:
                raise S3Error(f"'{name}' is missing or empty in the config")

        return cls(
            endpoint=endpoint,
            region=region,
            access_key=access_key,
            secret_key=secret_key,
            public_base_url=s3.get("public_base_url"),
        )

    def available(self):
        return bool(self.endpoint and self.region and self.access_key and self.secret_key)

    def public_url(self, key):
        if not self.public_base_url:
            return None

        return f"{self.public_base_url}/{key.lstrip('/')}"

    def _sign(self, method, path, payload, content_type, now):
        parsed = urllib.parse.urlsplit(self.endpoint + path)
        host = parsed.netloc
        canonical_uri = parsed.path or "/"

        payload_hash = hashlib.sha256(payload).hexdigest()
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date = now.strftime("%Y%m%d")

        canonical_headers = (
            f"content-type:{content_type}\n"
            f"host:{host}\n"
            f"x-amz-content-sha256:{payload_hash}\n"
            f"x-amz-date:{amz_date}\n"
        )
        signed_headers = "content-type;host;x-amz-content-sha256;x-amz-date"
        canonical_request = "\n".join(
            [method, canonical_uri, "", canonical_headers, signed_headers, payload_hash]
        )

        scope = f"{date}/{self.region}/{_SERVICE}/aws4_request"
        string_to_sign = "\n".join(
            [
                _ALGORITHM,
                amz_date,
                scope,
                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
            ]
        )
        signing_key = _signing_key(self.secret_key, date, self.region, _SERVICE)
        signature = hmac.new(
            signing_key, string_to_sign.encode("utf-8"), hashlib.sha256
        ).hexdigest()

        authorization = (
            f"{_ALGORITHM} Credential={self.access_key}/{scope}, "
            f"SignedHeaders={signed_headers}, Signature={signature}"
        )

        return {
            "Content-Type": content_type,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
            "Authorization": authorization,
        }

    def put(self, key, data, content_type, timeout=60):
        """Upload ``data`` to ``key``; raises :class:`S3Error` on failure."""
        path = "/" + key.lstrip("/")
        now = datetime.datetime.now(datetime.timezone.utc)
        headers = self._sign("PUT", path, data, content_type, now)
        url = self.endpoint + urllib.parse.quote(path)

        request = urllib.request.Request(url, data=data, method="PUT", headers=headers)

        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = response.status
                response.read()
        except urllib.error.HTTPError as e:
            body = e.read(512).decode("utf-8", "replace")
            raise S3Error(f"PUT {path} returned HTTP {e.code}: {body}") from e
        except (urllib.error.URLError, OSError) as e:
            raise S3Error(f"PUT {path} failed: {e}") from e

        if status < 200 or status >= 300:
            raise S3Error(f"PUT {path} returned HTTP {status}")

        return True
