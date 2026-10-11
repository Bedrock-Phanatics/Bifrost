#include <stddef.h>
#include "bifrost_plugin.h"

static uint32_t events;
static uint32_t shutdowns;

static void on_connected(void *user, const bifrost_event *event, bifrost_transfer_decision *decision) {
    (void)decision;
    if (user == &events && event->kind == BIFROST_EVENT_PLAYER_CONNECTED) events++;
}

static void on_shutdown(void *state) {
    if (state == &shutdowns) shutdowns++;
}

BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) {
    if (host->abi_version != BIFROST_ABI_VERSION || !BIFROST_HOST_HAS(host, register_command_info)) return BIFROST_STATUS_INCOMPATIBLE;
    plugin->struct_size = sizeof(bifrost_plugin);
    plugin->abi_version = BIFROST_ABI_VERSION;
    plugin->name = (bifrost_str){(const uint8_t *)"c-fixture", 9};
    plugin->plugin_version = (bifrost_str){(const uint8_t *)"1.0.0", 5};
    plugin->capabilities = BIFROST_CAPABILITY_EVENTS;
    plugin->state = &shutdowns;
    plugin->shutdown = on_shutdown;
    if (BIFROST_HOST_HAS(host, set_description)) {
        bifrost_status status = host->set_description(host->context, (bifrost_str){(const uint8_t *)"Counts players", 14});
        if (status != BIFROST_STATUS_OK) return status;
    }
    return host->subscribe(host->context, BIFROST_EVENT_PLAYER_CONNECTED, on_connected, &events);
}

BIFROST_EXPORT uint32_t bifrost_fixture_events(void) {
    return events;
}

BIFROST_EXPORT uint32_t bifrost_fixture_shutdowns(void) {
    return shutdowns;
}

#define SIZE(T) layout[n++] = sizeof(T)
#define FIELD(T, f) layout[n++] = offsetof(T, f)

/* Same order the Zig test builds its list in */
BIFROST_EXPORT size_t bifrost_fixture_layout(uint64_t *out, size_t capacity) {
    uint64_t layout[128];
    size_t n = 0;
    SIZE(bifrost_str);
    FIELD(bifrost_str, ptr);
    FIELD(bifrost_str, len);
    SIZE(bifrost_player);
    FIELD(bifrost_player, id);
    SIZE(bifrost_event);
    FIELD(bifrost_event, struct_size);
    FIELD(bifrost_event, kind);
    FIELD(bifrost_event, player);
    FIELD(bifrost_event, backend);
    FIELD(bifrost_event, from_backend);
    FIELD(bifrost_event, failure);
    FIELD(bifrost_event, name);
    FIELD(bifrost_event, xuid);
    FIELD(bifrost_event, address);
    SIZE(bifrost_transfer_decision);
    FIELD(bifrost_transfer_decision, struct_size);
    FIELD(bifrost_transfer_decision, action);
    FIELD(bifrost_transfer_decision, backend);
    SIZE(bifrost_packet);
    FIELD(bifrost_packet, struct_size);
    FIELD(bifrost_packet, direction);
    FIELD(bifrost_packet, id);
    FIELD(bifrost_packet, worker);
    FIELD(bifrost_packet, player);
    FIELD(bifrost_packet, bytes);
    FIELD(bifrost_packet, replacement);
    FIELD(bifrost_packet, replacement_capacity);
    FIELD(bifrost_packet, replacement_len);
    SIZE(bifrost_command);
    FIELD(bifrost_command, struct_size);
    FIELD(bifrost_command, worker);
    FIELD(bifrost_command, player);
    FIELD(bifrost_command, name);
    FIELD(bifrost_command, args);
    SIZE(bifrost_command_info);
    FIELD(bifrost_command_info, struct_size);
    FIELD(bifrost_command_info, permission);
    FIELD(bifrost_command_info, name);
    FIELD(bifrost_command_info, description);
    FIELD(bifrost_command_info, callback);
    FIELD(bifrost_command_info, user);
    SIZE(bifrost_task_result);
    FIELD(bifrost_task_result, struct_size);
    FIELD(bifrost_task_result, status);
    FIELD(bifrost_task_result, worker);
    FIELD(bifrost_task_result, player);
    SIZE(bifrost_host);
    FIELD(bifrost_host, struct_size);
    FIELD(bifrost_host, abi_version);
    FIELD(bifrost_host, context);
    FIELD(bifrost_host, log);
    FIELD(bifrost_host, subscribe);
    FIELD(bifrost_host, backend_count);
    FIELD(bifrost_host, backend_name);
    FIELD(bifrost_host, player_name);
    FIELD(bifrost_host, transfer);
    FIELD(bifrost_host, worker_count);
    FIELD(bifrost_host, subscribe_packet);
    FIELD(bifrost_host, register_command);
    FIELD(bifrost_host, spawn_task);
    FIELD(bifrost_host, send_message);
    FIELD(bifrost_host, post);
    FIELD(bifrost_host, register_command_info);
    FIELD(bifrost_host, set_description);
    SIZE(bifrost_plugin);
    FIELD(bifrost_plugin, struct_size);
    FIELD(bifrost_plugin, abi_version);
    FIELD(bifrost_plugin, name);
    FIELD(bifrost_plugin, plugin_version);
    FIELD(bifrost_plugin, capabilities);
    FIELD(bifrost_plugin, state);
    FIELD(bifrost_plugin, shutdown);
    layout[n++] = BIFROST_ABI_VERSION;
    if (n > capacity) return 0;
    for (size_t i = 0; i < n; i++) out[i] = layout[i];
    return n;
}
