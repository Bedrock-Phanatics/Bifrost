#ifndef BIFROST_PLUGIN_H
#define BIFROST_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Plugins run in-process, so a crash takes the proxy down. Callbacks run on several workers at once; never block.
   From your own threads use log, counts, names, player_info and queued actions. Query network_stats on the player's worker.
   Stop your threads before shutdown returns. Anything passed in is only valid until the callback returns.
   The full contract is in docs/plugin-abi.md. */

#define BIFROST_ABI_VERSION 1u
#define BIFROST_API_REVISION 2u
#define BIFROST_NO_BACKEND UINT32_MAX
#define BIFROST_NO_WORKER UINT32_MAX

#if defined(_WIN32)
#define BIFROST_EXPORT __declspec(dllexport)
#else
#define BIFROST_EXPORT __attribute__((visibility("default")))
#endif

/* An exception escaping into Bifrost terminates the proxy instead of unwinding through it */
#if defined(__cplusplus) && __cplusplus >= 201703L
#define BIFROST_NOEXCEPT noexcept
#else
#define BIFROST_NOEXCEPT
#endif

typedef int32_t bifrost_status;
enum {
    BIFROST_STATUS_OK = 0,
    BIFROST_STATUS_FAILED = -1,
    BIFROST_STATUS_INCOMPATIBLE = -2,
    BIFROST_STATUS_STALE_HANDLE = -3,
    BIFROST_STATUS_INVALID_ARGUMENT = -4,
    BIFROST_STATUS_UNSUPPORTED = -5,
    BIFROST_STATUS_TOO_LATE = -6,
    BIFROST_STATUS_BUSY = -7,
    BIFROST_STATUS_WRONG_THREAD = -8,
    BIFROST_STATUS_CANCELED = -9,
};

/* Only valid until the call returns */
typedef struct bifrost_str {
    const uint8_t *ptr;
    size_t len;
} bifrost_str;

typedef struct bifrost_player {
    uint64_t id;
} bifrost_player;

typedef uint32_t bifrost_connection_state;
enum { BIFROST_CONNECTION_CONNECTED, BIFROST_CONNECTION_CLOSING, BIFROST_CONNECTION_DISCONNECTED };
typedef uint32_t bifrost_authentication_state;
enum { BIFROST_AUTHENTICATION_PENDING, BIFROST_AUTHENTICATION_AUTHENTICATED, BIFROST_AUTHENTICATION_DISABLED, BIFROST_AUTHENTICATION_UNAVAILABLE, BIFROST_AUTHENTICATION_REJECTED };
typedef uint32_t bifrost_session_mode;
enum { BIFROST_MODE_PASSTHROUGH, BIFROST_MODE_MANAGED };
typedef uint32_t bifrost_connection_phase;
enum { BIFROST_CONNECTION_PHASE_UNKNOWN, BIFROST_CONNECTION_PHASE_SETTINGS, BIFROST_CONNECTION_PHASE_LOGIN, BIFROST_CONNECTION_PHASE_HANDSHAKE, BIFROST_CONNECTION_PHASE_RESOURCE_PACKS, BIFROST_CONNECTION_PHASE_JOINING, BIFROST_CONNECTION_PHASE_IN_GAME, BIFROST_CONNECTION_PHASE_CLOSING, BIFROST_CONNECTION_PHASE_DISCONNECTED };
typedef uint32_t bifrost_transfer_state;
enum { BIFROST_TRANSFER_STATE_NONE, BIFROST_TRANSFER_STATE_REQUESTED, BIFROST_TRANSFER_STATE_DIALING, BIFROST_TRANSFER_STATE_LOGGING_IN, BIFROST_TRANSFER_STATE_JOINING, BIFROST_TRANSFER_STATE_PREPARING_CLIENT, BIFROST_TRANSFER_STATE_SYNCING_CLIENT, BIFROST_TRANSFER_STATE_CLOSING_SOURCE };

typedef struct bifrost_player_state {
    uint32_t backend;
    bifrost_connection_state connection;
    bifrost_authentication_state authentication;
    bifrost_session_mode mode;
    bifrost_connection_phase phase;
    bifrost_transfer_state transfer;
} bifrost_player_state;

typedef struct bifrost_player_info {
    uint32_t struct_size;
    uint32_t worker;
    bifrost_player_state state;
    uint64_t connection_duration_ms;
    uint32_t name_len;
    uint32_t xuid_len;
    uint32_t uuid_len;
    uint32_t online;
    uint8_t name[64];
    uint8_t xuid[32];
    uint8_t uuid[36];
} bifrost_player_info;

#define BIFROST_NETWORK_RTT (UINT64_C(1) << 0)
#define BIFROST_NETWORK_RELIABILITY (UINT64_C(1) << 1)
#define BIFROST_NETWORK_QUEUES (UINT64_C(1) << 2)
#define BIFROST_NETWORK_LOSS_ESTIMATE (UINT64_C(1) << 3)
#define BIFROST_NETWORK_RATES (UINT64_C(1) << 4)
#define BIFROST_NETWORK_JITTER (UINT64_C(1) << 5)
#define BIFROST_NETWORK_DUPLICATES (UINT64_C(1) << 6)
#define BIFROST_NETWORK_OUT_OF_ORDER (UINT64_C(1) << 7)
#define BIFROST_NETWORK_ANOMALIES (UINT64_C(1) << 8)

typedef struct bifrost_network_stats {
    uint32_t struct_size;
    uint32_t mtu;
    uint64_t available;
    uint64_t sampled_at_ms;
    uint64_t rtt_ms;
    uint64_t jitter_ms;
    uint32_t loss_estimate_ppm;
    uint32_t retransmission_timeout_ms;
    uint64_t acknowledged_datagrams;
    uint64_t lost_datagrams;
    uint64_t retransmitted_datagrams;
    uint64_t ack_records_received;
    uint64_t nack_records_received;
    uint64_t ack_records_sent;
    uint64_t nack_records_sent;
    uint64_t queued_packets;
    uint64_t queued_bytes;
    uint64_t queued_packets_high_water;
    uint64_t recovery_packets;
    uint64_t recovery_bytes;
    uint64_t ordered_packets;
    uint64_t ordered_bytes;
    uint64_t in_flight_bytes;
    uint64_t congestion_window_bytes;
    uint64_t incoming_packets_per_second;
    uint64_t outgoing_packets_per_second;
    uint64_t incoming_bytes_per_second;
    uint64_t outgoing_bytes_per_second;
    uint64_t duplicate_packets;
    uint64_t out_of_order_packets;
    uint64_t reliability_anomalies;
    uint64_t rate_interval_ms;
} bifrost_network_stats;

#define BIFROST_CAPABILITY_EVENTS (UINT64_C(1) << 0)
#define BIFROST_CAPABILITY_COMMANDS (UINT64_C(1) << 1)
#define BIFROST_CAPABILITY_PACKETS (UINT64_C(1) << 2)
#define BIFROST_CAPABILITY_TASKS (UINT64_C(1) << 3)

typedef uint32_t bifrost_log_level;
enum {
    BIFROST_LOG_ERR = 0,
    BIFROST_LOG_WARN = 1,
    BIFROST_LOG_INFO = 2,
    BIFROST_LOG_DEBUG = 3,
};

typedef uint32_t bifrost_event_kind;
enum {
    BIFROST_EVENT_PROXY_STARTED = 0,
    BIFROST_EVENT_PROXY_STOPPING = 1,
    BIFROST_EVENT_PLAYER_CONNECTED = 2,
    BIFROST_EVENT_PLAYER_AUTHENTICATED = 3,
    BIFROST_EVENT_PLAYER_DISCONNECTED = 4,
    BIFROST_EVENT_BACKEND_SELECTED = 5,
    BIFROST_EVENT_TRANSFER_REQUESTED = 6,
    BIFROST_EVENT_TRANSFER_FAILED = 7,
    BIFROST_EVENT_TRANSFER_COMPLETED = 8,
    BIFROST_EVENT_CONNECTION_PHASE_CHANGED = 9,
};

typedef uint32_t bifrost_transfer_failure;
enum {
    BIFROST_FAILURE_NONE = 0,
    BIFROST_FAILURE_REJECTED = 1,
    BIFROST_FAILURE_FAILED_BEFORE_COMMIT = 2,
    BIFROST_FAILURE_FAILED_AFTER_COMMIT = 3,
    BIFROST_FAILURE_TIMED_OUT = 4,
    BIFROST_FAILURE_INCOMPATIBLE_CONTENT = 5,
};

typedef struct bifrost_event {
    uint32_t struct_size;
    bifrost_event_kind kind;
    bifrost_player player;
    uint32_t backend;
    uint32_t from_backend;
    bifrost_transfer_failure failure;
    bifrost_str name;
    bifrost_str xuid;
    bifrost_str address;
    uint32_t worker;
    bifrost_connection_phase phase;
    bifrost_connection_phase previous_phase;
} bifrost_event;

typedef uint32_t bifrost_transfer_action;
enum {
    BIFROST_TRANSFER_PROCEED = 0,
    BIFROST_TRANSFER_CANCEL = 1,
    BIFROST_TRANSFER_REDIRECT = 2,
};

typedef struct bifrost_transfer_decision {
    uint32_t struct_size;
    bifrost_transfer_action action;
    uint32_t backend;
} bifrost_transfer_decision;

typedef uint32_t bifrost_direction;
enum {
    BIFROST_DIRECTION_FROM_PLAYER = 0,
    BIFROST_DIRECTION_FROM_BACKEND = 1,
};

typedef uint32_t bifrost_packet_phase;
enum {
    BIFROST_PHASE_ANY = 0,
    BIFROST_PHASE_BEFORE_GAME = 1,
    BIFROST_PHASE_IN_GAME = 2,
};

#define BIFROST_PACKET_VALIDATED (UINT32_C(1) << 0)
#define BIFROST_PACKET_FIELDS (UINT32_C(1) << 1)

typedef uint32_t bifrost_packet_action;
enum {
    BIFROST_PACKET_PASS = 0,
    BIFROST_PACKET_CANCEL = 1,
    BIFROST_PACKET_REPLACE = 2,
};

/* Whole packets, header included. Replacements preserve the packet ID and both sub-client indices. */
typedef struct bifrost_packet {
    uint32_t struct_size;
    bifrost_direction direction;
    uint32_t id;
    uint32_t worker;
    bifrost_player player;
    bifrost_str bytes;
    uint8_t *replacement;
    size_t replacement_capacity;
    size_t replacement_len;
} bifrost_packet;

typedef bifrost_packet_action (*bifrost_packet_fn)(void *user, bifrost_packet *packet) BIFROST_NOEXCEPT;

typedef uint32_t bifrost_packet_type;
enum { BIFROST_PACKET_TYPE_TEXT = 1, BIFROST_PACKET_TYPE_CHUNK_RADIUS = 2 };
typedef uint32_t bifrost_text_type;
enum {
    BIFROST_TEXT_RAW = 0, BIFROST_TEXT_CHAT = 1, BIFROST_TEXT_TRANSLATE = 2,
    BIFROST_TEXT_POPUP = 3, BIFROST_TEXT_JUKEBOX_POPUP = 4, BIFROST_TEXT_TIP = 5,
    BIFROST_TEXT_SYSTEM_MESSAGE = 6, BIFROST_TEXT_WHISPER = 7, BIFROST_TEXT_ANNOUNCEMENT = 8,
    BIFROST_TEXT_TEXT_OBJECT_WHISPER = 9, BIFROST_TEXT_TEXT_OBJECT = 10, BIFROST_TEXT_TEXT_OBJECT_ANNOUNCEMENT = 11,
};

/* Strings borrow the current packet until the callback returns. These layouts are frozen. */
typedef struct bifrost_text {
    bifrost_text_type message_type;
    uint32_t localize;
    uint32_t has_filtered_message;
    uint32_t parameter_count;
    bifrost_str source;
    bifrost_str message;
    bifrost_str xuid;
    bifrost_str platform_id;
    bifrost_str filtered_message;
    bifrost_str parameters[4];
} bifrost_text;

typedef struct bifrost_chunk_radius {
    int32_t radius;
    uint32_t max_radius;
} bifrost_chunk_radius;

typedef struct bifrost_command {
    uint32_t struct_size;
    uint32_t worker;
    bifrost_player player;
    bifrost_str name;
    bifrost_str args;
} bifrost_command;

typedef void (*bifrost_command_fn)(void *user, const bifrost_command *command) BIFROST_NOEXCEPT;

/* Permission only hides the command in autocomplete and is never enforced. Replaces any backend command with the same name */
typedef uint32_t bifrost_command_permission;
enum {
    BIFROST_PERMISSION_ANY = 0,
    BIFROST_PERMISSION_GAME_DIRECTORS = 1,
    BIFROST_PERMISSION_ADMIN = 2,
    BIFROST_PERMISSION_HOST = 3,
    BIFROST_PERMISSION_OWNER = 4,
};

typedef struct bifrost_command_info {
    uint32_t struct_size;
    bifrost_command_permission permission;
    bifrost_str name;
    bifrost_str description;
    bifrost_command_fn callback;
    void *user;
} bifrost_command_info;

typedef void (*bifrost_task_fn)(void *user) BIFROST_NOEXCEPT;

typedef struct bifrost_task_result {
    uint32_t struct_size;
    bifrost_status status;
    uint32_t worker;
    bifrost_player player;
} bifrost_task_result;

typedef void (*bifrost_task_done_fn)(void *user, const bifrost_task_result *result) BIFROST_NOEXCEPT;

typedef uint32_t bifrost_packet_target;
#define BIFROST_PACKET_TO_PLAYER ((bifrost_packet_target)0)
#define BIFROST_PACKET_TO_BACKEND ((bifrost_packet_target)1)

typedef void (*bifrost_event_fn)(void *user, const bifrost_event *event, bifrost_transfer_decision *decision) BIFROST_NOEXCEPT;

typedef struct bifrost_host {
    uint32_t struct_size;
    uint32_t abi_version;
    void *context;
    void (*log)(void *context, bifrost_log_level level, bifrost_str message) BIFROST_NOEXCEPT;
    bifrost_status (*subscribe)(void *context, bifrost_event_kind kind, bifrost_event_fn callback, void *user) BIFROST_NOEXCEPT;
    uint32_t (*backend_count)(void *context) BIFROST_NOEXCEPT;
    bifrost_status (*backend_name)(void *context, uint32_t backend, bifrost_str *name) BIFROST_NOEXCEPT;
    bifrost_status (*player_name)(void *context, bifrost_player player, uint8_t *out, size_t capacity, size_t *len) BIFROST_NOEXCEPT;
    bifrost_status (*transfer)(void *context, bifrost_player player, uint32_t backend) BIFROST_NOEXCEPT;
    uint32_t (*worker_count)(void *context) BIFROST_NOEXCEPT;
    bifrost_status (*subscribe_packet)(void *context, bifrost_direction direction, uint32_t id, bifrost_packet_phase phase, uint32_t flags, bifrost_packet_fn callback, void *user) BIFROST_NOEXCEPT;
    bifrost_status (*register_command)(void *context, bifrost_str name, bifrost_command_fn callback, void *user) BIFROST_NOEXCEPT;
    /* run shares a few threads with every plugin. done runs once on the player's worker,
       with STALE_HANDLE if they left or CANCELED if run never started */
    bifrost_status (*spawn_task)(void *context, bifrost_player player, bifrost_task_fn run, bifrost_task_done_fn done, void *user) BIFROST_NOEXCEPT;
    bifrost_status (*send_message)(void *context, bifrost_player player, bifrost_str text) BIFROST_NOEXCEPT;
    /* Runs done on the player's worker, same rules as spawn_task */
    bifrost_status (*post)(void *context, bifrost_player player, bifrost_task_done_fn done, void *user) BIFROST_NOEXCEPT;
    bifrost_status (*register_command_info)(void *context, const bifrost_command_info *info) BIFROST_NOEXCEPT;
    /* Check BIFROST_HOST_HAS(host, set_description) first */
    bifrost_status (*set_description)(void *context, bifrost_str description) BIFROST_NOEXCEPT;
    /* Check BIFROST_HOST_HAS and subscribe with BIFROST_PACKET_FIELDS. Use the callback's packet pointer. */
    bifrost_status (*decode_packet)(void *context, const bifrost_packet *packet, bifrost_packet_type type, void *out, size_t capacity) BIFROST_NOEXCEPT;
    /* Writes replacement and replacement_len; return BIFROST_PACKET_REPLACE to apply it. */
    bifrost_status (*encode_packet)(void *context, bifrost_packet *packet, bifrost_packet_type type, const void *data, size_t size) BIFROST_NOEXCEPT;
    /* Copies a complete Bedrock packet. OK means queued; optional done reports delivery.
       Thread-safe, bypasses listeners. Text in either direction; RequestChunkRadius to backend.
       In-game only, main sub-client only, <= 65536 bytes. Check BIFROST_HOST_HAS first. */
    bifrost_status (*send_packet)(void *context, bifrost_player player, bifrost_packet_target target, bifrost_str bytes, bifrost_task_done_fn done, void *user) BIFROST_NOEXCEPT;
    bifrost_status (*player_info)(void *context, bifrost_player player, bifrost_player_info *out, size_t capacity) BIFROST_NOEXCEPT;
    bifrost_status (*network_stats)(void *context, bifrost_player player, bifrost_packet_target target, bifrost_network_stats *out, size_t capacity) BIFROST_NOEXCEPT;
    bifrost_status (*disconnect)(void *context, bifrost_player player, bifrost_str reason, bifrost_task_done_fn done, void *user) BIFROST_NOEXCEPT;
    bifrost_status (*request_transfer)(void *context, bifrost_player player, uint32_t backend, bifrost_task_done_fn done, void *user) BIFROST_NOEXCEPT;
} bifrost_host;

/* Older hosts have a shorter table, so use this instead of sizeof */
#define BIFROST_HOST_HAS(host, fn) ((host)->struct_size >= offsetof(bifrost_host, fn) + sizeof((host)->fn))

typedef struct bifrost_plugin {
    uint32_t struct_size;
    uint32_t abi_version;
    bifrost_str name;
    bifrost_str plugin_version;
    uint64_t capabilities;
    void *state;
    void (*shutdown)(void *state) BIFROST_NOEXCEPT;
} bifrost_plugin;

BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) BIFROST_NOEXCEPT;

/* Returns static UTF-8 TOML bytes valid until the library is unloaded */
BIFROST_EXPORT bifrost_status bifrost_plugin_get_manifest(bifrost_str *out) BIFROST_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#endif
