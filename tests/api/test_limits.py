import json
from pathlib import Path

CONFIG_PATH = Path(__file__).resolve().parent.parent.parent / "config.tests.json"

with CONFIG_PATH.open() as f:
    CONFIG = json.load(f)


def test_limits_ok(http_client):
    response = http_client.get("/api/limits")

    assert response.status_code == 200

    limits = response.json()

    assert limits == {
        "guilds": {
            "max_name_codepoints": CONFIG["api"]["guilds"]["max_name_codepoints"],
            "max_emojis": CONFIG["api"]["guilds"]["max_emojis"],
        },
        "channels": {
            "max_name_codepoints": CONFIG["api"]["channels"]["max_name_codepoints"],
            "max_topic_codepoints": CONFIG["api"]["channels"]["max_topic_codepoints"],
        },
        "messages": {
            "max_messages_limit": CONFIG["api"]["messages"]["max_messages_limit"],
            "max_codepoints_per_message": CONFIG["api"]["messages"]["max_codepoints"],
            "max_reactions": CONFIG["api"]["messages"]["max_reactions"],
            "max_reactions_users_limit": CONFIG["api"]["messages"][
                "max_reactions_users_limit"
            ],
            "max_embeds": CONFIG["api"]["messages"]["max_embeds"],
            "max_attachments": CONFIG["api"]["messages"]["max_attachments"],
            "max_mention_users": CONFIG["api"]["messages"]["max_mention_users"],
            "max_mention_roles": CONFIG["api"]["messages"]["max_mention_roles"],
            "max_allowed_mention_users": CONFIG["api"]["messages"][
                "max_allowed_mention_users"
            ],
            "max_allowed_mention_roles": CONFIG["api"]["messages"][
                "max_allowed_mention_roles"
            ],
        },
        "search": {
            "min_content_codepoints": CONFIG["api"]["search"][
                "min_content_codepoints"
            ],
            "max_content_codepoints": CONFIG["api"]["search"][
                "max_content_codepoints"
            ],
            "max_filter_ids": CONFIG["api"]["search"]["max_filter_ids"],
        },
        "sync": {
            "max_lookback_s": CONFIG["api"]["sync"]["max_lookback_s"],
        },
        "audit_log": {
            "max_entries_limit": CONFIG["api"]["audit_log"]["max_entries_limit"],
        },
        "embeds": {
            "max_title_codepoints": CONFIG["api"]["embeds"]["max_title_codepoints"],
            "max_description_codepoints": CONFIG["api"]["embeds"][
                "max_description_codepoints"
            ],
            "max_fields": CONFIG["api"]["embeds"]["max_fields"],
            "max_footer_codepoints": CONFIG["api"]["embeds"]["max_footer_codepoints"],
            "max_author_name_codepoints": CONFIG["api"]["embeds"][
                "max_author_name_codepoints"
            ],
            "max_field_name_codepoints": CONFIG["api"]["embeds"][
                "max_field_name_codepoints"
            ],
            "max_field_value_codepoints": CONFIG["api"]["embeds"][
                "max_field_value_codepoints"
            ],
            "max_url_codepoints": CONFIG["api"]["embeds"]["max_url_codepoints"],
            "max_total_codepoints": CONFIG["api"]["embeds"]["max_total_codepoints"],
        },
        "roles": {
            "max_name_codepoints": CONFIG["api"]["roles"]["max_name_codepoints"],
        },
        "emojis": {
            "min_name_codepoints": CONFIG["api"]["emojis"]["min_name_codepoints"],
            "max_name_codepoints": CONFIG["api"]["emojis"]["max_name_codepoints"],
        },
        "users": {
            "min_username_codepoints": CONFIG["api"]["users"]["min_username_codepoints"],
            "max_username_codepoints": CONFIG["api"]["users"]["max_username_codepoints"],
            "min_display_name_codepoints": CONFIG["api"]["users"]["min_display_name_codepoints"],
            "max_display_name_codepoints": CONFIG["api"]["users"]["max_display_name_codepoints"],
            "max_userdata_bytes": CONFIG["api"]["users"]["max_userdata_bytes"],
        },
        "auth": {
            "password": {
                "min_codepoints": CONFIG["auth"]["password"]["min_password_codepoints"],
                "max_codepoints": CONFIG["auth"]["password"]["max_password_codepoints"],
                "max_bytes": CONFIG["auth"]["password"]["max_password_len"],
            },
        },
        "media": {
            "avatar": {
                "max_dimensions": CONFIG["media"]["avatar"]["max_dimensions"],
                "max_bytes": CONFIG["media"]["avatar"]["max_input_bytes"],
                "max_animation_frames": CONFIG["media"]["avatar"]["max_animation_frames"],
                "max_animation_duration_ms": CONFIG["media"]["avatar"]["max_animation_duration_ms"],
            },
            "emoji": {
                "max_dimensions": CONFIG["media"]["emoji"]["max_dimensions"],
                "max_bytes": CONFIG["media"]["emoji"]["max_input_bytes"],
                "max_animation_frames": CONFIG["media"]["emoji"]["max_animation_frames"],
                "max_animation_duration_ms": CONFIG["media"]["emoji"]["max_animation_duration_ms"],
            },
        },
        "files": {
            "max_name_codepoints": CONFIG["api"]["files"]["max_name_codepoints"],
            "max_size": CONFIG["files"]["max_size"],
            "whitelist": CONFIG["files"]["whitelist"],
            "public_base_urls": [CONFIG["files"]["s3"]["public_base_url"]],
        },
        "push": {
            "enabled": CONFIG["push"]["enabled"],
            "vapid_public_key": CONFIG["push"]["vapid"]["public_key"],
            "max_subscriptions_per_user": CONFIG["api"]["push"][
                "max_subscriptions_per_user"
            ],
        },
        "webhooks": {
            "max_webhooks_per_channel": CONFIG["api"]["webhooks"][
                "max_webhooks_per_channel"
            ],
            "max_name_codepoints": CONFIG["api"]["webhooks"]["max_name_codepoints"],
        },
    }
