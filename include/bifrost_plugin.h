#ifndef BIFROST_PLUGIN_H
#define BIFROST_PLUGIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Callbacks can run on several worker threads at once, so never block in them */

#define BIFROST_ABI_VERSION 1u
#define BIFROST_NO_BACKEND UINT32_MAX

#if defined(_WIN32)
#define BIFROST_EXPORT __declspec(dllexport)
#else
#define BIFROST_EXPORT __attribute__((visibility("default")))
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
};

/* Only valid until the call returns */
typedef struct bifrost_str {
    const uint8_t *ptr;
    size_t len;
} bifrost_str;

typedef struct bifrost_player {
    uint64_t id;
} bifrost_player;

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

typedef uint32_t bifrost_packet_action;
enum {
    BIFROST_PACKET_PASS = 0,
    BIFROST_PACKET_CANCEL = 1,
    BIFROST_PACKET_REPLACE = 2,
};

/* Whole packets, header included, for both bytes and the replacement */
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

typedef bifrost_packet_action (*bifrost_packet_fn)(void *user, bifrost_packet *packet);

typedef void (*bifrost_event_fn)(void *user, const bifrost_event *event, bifrost_transfer_decision *decision);

typedef struct bifrost_host {
    uint32_t struct_size;
    uint32_t abi_version;
    void *context;
    void (*log)(void *context, bifrost_log_level level, bifrost_str message);
    bifrost_status (*subscribe)(void *context, bifrost_event_kind kind, bifrost_event_fn callback, void *user);
    uint32_t (*backend_count)(void *context);
    bifrost_status (*backend_name)(void *context, uint32_t backend, bifrost_str *name);
    bifrost_status (*player_name)(void *context, bifrost_player player, uint8_t *out, size_t capacity, size_t *len);
    bifrost_status (*transfer)(void *context, bifrost_player player, uint32_t backend);
    uint32_t (*worker_count)(void *context);
    bifrost_status (*subscribe_packet)(void *context, bifrost_direction direction, uint32_t id, bifrost_packet_phase phase, uint32_t flags, bifrost_packet_fn callback, void *user);
} bifrost_host;

typedef struct bifrost_plugin {
    uint32_t struct_size;
    uint32_t abi_version;
    bifrost_str name;
    bifrost_str plugin_version;
    uint64_t capabilities;
    void *state;
    void (*shutdown)(void *state);
} bifrost_plugin;

BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin);

#ifdef __cplusplus
}
#endif

#endif
