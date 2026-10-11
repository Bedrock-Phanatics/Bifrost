#include <atomic>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <type_traits>

#include "bifrost_plugin.h"

static_assert(std::is_nothrow_invocable_v<bifrost_event_fn, void *, const bifrost_event *, bifrost_transfer_decision *>);
static_assert(std::is_nothrow_invocable_v<bifrost_command_fn, void *, const bifrost_command *>);
static_assert(std::is_nothrow_invocable_r_v<bifrost_status, decltype(&bifrost_plugin_init), const bifrost_host *, bifrost_plugin *>);

namespace {

std::atomic<std::uint32_t> events;
std::atomic<std::uint32_t> caught;
std::atomic<std::uint32_t> shutdowns;
std::string last_args;

bifrost_str str(std::string_view text) {
    return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

void throws_on_empty(std::string_view args) {
    if (args.empty()) throw std::invalid_argument("no args");
}

void on_connected(void *, const bifrost_event *event, bifrost_transfer_decision *) noexcept {
    if (event->kind == BIFROST_EVENT_PLAYER_CONNECTED) events++;
}

void on_echo(void *, const bifrost_command *command) noexcept {
    try {
        std::string_view args{reinterpret_cast<const char *>(command->args.ptr), command->args.len};
        throws_on_empty(args);
        last_args.assign(args);
    } catch (const std::exception &) {
        caught++;
    }
}

void on_shutdown(void *) noexcept {
    shutdowns++;
}

}

extern "C" {

BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) noexcept {
    if (host->abi_version != BIFROST_ABI_VERSION || !BIFROST_HOST_HAS(host, register_command_info)) return BIFROST_STATUS_INCOMPATIBLE;
    plugin->name = str("cpp-fixture");
    plugin->plugin_version = str("1.0.0");
    plugin->capabilities = BIFROST_CAPABILITY_EVENTS | BIFROST_CAPABILITY_COMMANDS;
    plugin->shutdown = on_shutdown;
    if (BIFROST_HOST_HAS(host, set_description)) host->set_description(host->context, str("Built as C++23"));
    bifrost_status status = host->subscribe(host->context, BIFROST_EVENT_PLAYER_CONNECTED, on_connected, nullptr);
    if (status != BIFROST_STATUS_OK) return status;
    return host->register_command(host->context, str("echo"), on_echo, nullptr);
}

BIFROST_EXPORT std::uint32_t bifrost_fixture_events() noexcept {
    return events;
}

BIFROST_EXPORT std::uint32_t bifrost_fixture_caught() noexcept {
    return caught;
}

BIFROST_EXPORT std::uint32_t bifrost_fixture_shutdowns() noexcept {
    return shutdowns;
}

BIFROST_EXPORT std::size_t bifrost_fixture_args(char *out, std::size_t capacity) noexcept {
    std::size_t len = last_args.size() < capacity ? last_args.size() : capacity;
    last_args.copy(out, len);
    return len;
}

BIFROST_EXPORT std::size_t bifrost_fixture_host_size() noexcept {
    return sizeof(bifrost_host);
}

}
