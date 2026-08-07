# Shared helpers for the webhook API tests.

from conftest import CONFIG, seed_role

WEBHOOK_LIMITS = CONFIG["api"]["webhooks"]


def auth(token):
    return {"Authorization": f"Bearer {token}"}


def system_auth(http_client, username):
    """Creates the user and returns (user_id, access_token)."""
    from conftest import system_create_user, system_login

    body = system_create_user(http_client, username=username)
    access_token, _ = system_login(http_client, username)

    return body["id"], access_token


def set_everyone_permissions(db_conn, guild_id, permissions):
    with db_conn.cursor() as cur:
        cur.execute(
            "UPDATE app.roles SET permissions = %s WHERE id = %s",
            (permissions.to_bytes(16), guild_id),
        )


def create_role(db_conn, guild_id, role_id, name, permissions=0, position=None):
    seed_role(db_conn, guild_id, role_id, name, position, permissions)


def assign_role(db_conn, guild_id, user_id, role_id):
    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.member_roles (guild_id, user_id, role_id)"
            " VALUES (%s, %s, %s)",
            (guild_id, user_id, role_id),
        )


def grant(db_conn, guild_id, user_id, permissions):
    """Gives the user a fresh role carrying exactly `permissions`."""
    role_id = f"9{guild_id[-6:]}"
    create_role(db_conn, guild_id, role_id, "webhook-role", permissions=permissions)
    assign_role(db_conn, guild_id, user_id, role_id)


def post_webhook(http_client, token, channel_id, payload):
    return http_client.post(
        f"/api/channels/{channel_id}/webhooks", json=payload, headers=auth(token)
    )


def create_webhook(http_client, token, channel_id, name="hook"):
    response = post_webhook(http_client, token, channel_id, {"name": name})
    assert response.status_code == 201, response.content

    return response.json()


def list_webhooks(http_client, token, channel_id):
    return http_client.get(
        f"/api/channels/{channel_id}/webhooks", headers=auth(token)
    )


def get_webhook(http_client, token, webhook_id):
    return http_client.get(f"/api/webhooks/{webhook_id}", headers=auth(token))


def patch_webhook(http_client, token, webhook_id, payload):
    return http_client.patch(
        f"/api/webhooks/{webhook_id}", json=payload, headers=auth(token)
    )


def delete_webhook(http_client, token, webhook_id):
    return http_client.delete(
        f"/api/webhooks/{webhook_id}", headers=auth(token)
    )


def execute_webhook(http_client, webhook_id, token, payload):
    return http_client.post(f"/api/webhooks/{webhook_id}/{token}", json=payload)


def insert_file(
    db_conn,
    file_id,
    name="f.webp",
    hash_value=None,
    size=10,
    content_type="image/webp",
):
    hash_value = hash_value or f"{int(file_id):064d}"

    with db_conn.cursor() as cur:
        cur.execute(
            "INSERT INTO app.files (id, name, hash, size, content_type)"
            " VALUES (%s, %s, %s, %s, %s)",
            (file_id, name, hash_value, size, content_type),
        )

    return hash_value


def get_messages(http_client, token, channel_id):
    response = http_client.get(
        f"/api/channels/{channel_id}/messages", headers=auth(token)
    )
    assert response.status_code == 200, response.content

    return response.json()
