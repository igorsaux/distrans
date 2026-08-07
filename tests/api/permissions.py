# Shared permission-bit constants for the API tests.
#
# These mirror the `Permissions` packed struct in `src/types.zig`
# (bit 0 = first field; stored in the DB as 16-byte big-endian bytea).
# They MUST be updated in the same change whenever a field is added,
# renamed or reordered in `src/types.zig`. Do not redefine these
# constants in test files; import them from here.

# read_messages
READ_MESSAGES = 1 << 0
SEND_MESSAGES = 1 << 1
DELETE_MESSAGES = 1 << 2
CREATE_CHANNELS = 1 << 3
MODIFY_CHANNELS = 1 << 4
DELETE_CHANNELS = 1 << 5
CREATE_ROLES = 1 << 6
MODIFY_ROLES = 1 << 7
DELETE_ROLES = 1 << 8
GRANT_ROLES = 1 << 9
REVOKE_ROLES = 1 << 10
MANAGE_OVERWRITES = 1 << 11
SKIP_ALLOWS = 1 << 12
SKIP_DENIES = 1 << 13
GUILD_MODIFY = 1 << 14
ADD_REACTIONS = 1 << 15
DELETE_REACTIONS = 1 << 16
CREATE_EMOJI = 1 << 17
MODIFY_EMOJI = 1 << 18
DELETE_EMOJI = 1 << 19
MENTION_EVERYONE = 1 << 20
ADD_PINS = 1 << 21
DELETE_PINS = 1 << 22
CREATE_WEBHOOKS = 1 << 23
MODIFY_WEBHOOKS = 1 << 24
DELETE_WEBHOOKS = 1 << 25
VIEW_AUDIT_LOG = 1 << 26

ALL_BITS = (
    READ_MESSAGES
    | SEND_MESSAGES
    | DELETE_MESSAGES
    | CREATE_CHANNELS
    | MODIFY_CHANNELS
    | DELETE_CHANNELS
    | CREATE_ROLES
    | MODIFY_ROLES
    | DELETE_ROLES
    | GRANT_ROLES
    | REVOKE_ROLES
    | MANAGE_OVERWRITES
    | SKIP_ALLOWS
    | SKIP_DENIES
    | GUILD_MODIFY
    | ADD_REACTIONS
    | DELETE_REACTIONS
    | CREATE_EMOJI
    | MODIFY_EMOJI
    | DELETE_EMOJI
    | MENTION_EVERYONE
    | ADD_PINS
    | DELETE_PINS
    | CREATE_WEBHOOKS
    | MODIFY_WEBHOOKS
    | DELETE_WEBHOOKS
    | VIEW_AUDIT_LOG
)
