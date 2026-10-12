#include <atomic>
#include <cstddef>
#include <cstdint>
#include <format>
#include <string_view>
#include <utility>

#include "bifrost_plugin.h"

namespace {

bifrost_str toStr(std::string_view text) noexcept {
    return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

class Greeter {
public:
    bifrost_status start(const bifrost_host &api) noexcept {
        host = api;
        return host.subscribe(host.context, BIFROST_EVENT_PLAYER_AUTHENTICATED, onAuthenticated, this);
    }

    void stop() noexcept {
        log("greeted {} player(s)", greeted.load());
    }

private:
    static void onAuthenticated(void *user, const bifrost_event *event, bifrost_transfer_decision *) noexcept {
        static_cast<Greeter *>(user)->greet(*event);
    }

    void greet(const bifrost_event &event) noexcept {
        greeted.fetch_add(1, std::memory_order_relaxed);
        std::string_view name{reinterpret_cast<const char *>(event.name.ptr), event.name.len};
        log("welcome, {}", name);
    }

    template <typename... Args>
    void log(std::format_string<Args...> format, Args &&...args) noexcept {
        char buffer[256];
        auto result = std::format_to_n(buffer, sizeof(buffer), format, std::forward<Args>(args)...);
        auto len = static_cast<std::size_t>(result.out - buffer);
        host.log(host.context, BIFROST_LOG_INFO, toStr({buffer, len}));
    }

    bifrost_host host{};
    std::atomic<std::uint32_t> greeted{0};
};

Greeter greeter;

void onShutdown(void *state) noexcept {
    static_cast<Greeter *>(state)->stop();
}

}

extern "C" BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) noexcept {
    if (host->abi_version != BIFROST_ABI_VERSION) return BIFROST_STATUS_INCOMPATIBLE;
    plugin->name = toStr("Greeter");
    plugin->plugin_version = toStr("1.0.0");
    plugin->capabilities = BIFROST_CAPABILITY_EVENTS;
    plugin->state = &greeter;
    plugin->shutdown = onShutdown;
    return greeter.start(*host);
}
