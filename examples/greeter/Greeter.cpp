#include <atomic>
#include <cstddef>
#include <cstdint>
#include <format>
#include <string_view>
#include <utility>

#include "bifrost_plugin.h"
#include "bifrost_manifest.h"

namespace {

bifrost_str toStr(std::string_view text) noexcept {
    return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

class Greeter {
public:
    bifrost_status start(const bifrost_host &api) noexcept {
        host = &api;
        return host->subscribe(host->context, BIFROST_EVENT_PLAYER_AUTHENTICATED, onAuthenticated, this);
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
        if (BIFROST_HOST_HAS(host, player_info)) {
            bifrost_player_info info{};
            if (host->player_info(host->context, event.player, &info, sizeof(info)) == BIFROST_STATUS_OK)
                log("player {} is on worker {} with backend {}", name, info.worker, info.state.backend);
        }
        if (BIFROST_HOST_HAS(host, network_stats))
            host->post(host->context, event.player, onNetwork, this);
    }

    static void onNetwork(void *user, const bifrost_task_result *result) noexcept {
        if (result->status != BIFROST_STATUS_OK) return;
        auto &self = *static_cast<Greeter *>(user);
        bifrost_network_stats stats{};
        if (self.host->network_stats(self.host->context, result->player, BIFROST_PACKET_TO_PLAYER, &stats, sizeof(stats)) != BIFROST_STATUS_OK) return;
        if (stats.available & BIFROST_NETWORK_RTT) self.log("player RTT {} ms", stats.rtt_ms);
    }

    template <typename... Args>
    void log(std::format_string<Args...> format, Args &&...args) noexcept {
        char buffer[256];
        auto result = std::format_to_n(buffer, sizeof(buffer), format, std::forward<Args>(args)...);
        auto len = static_cast<std::size_t>(result.out - buffer);
        host->log(host->context, BIFROST_LOG_INFO, toStr({buffer, len}));
    }

    const bifrost_host *host{};
    std::atomic<std::uint32_t> greeted{0};
};

Greeter greeter;

void onShutdown(void *state) noexcept {
    static_cast<Greeter *>(state)->stop();
}

}

extern "C" BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) noexcept {
    if (host->abi_version != BIFROST_ABI_VERSION) return BIFROST_STATUS_INCOMPATIBLE;
    plugin->capabilities = BIFROST_CAPABILITY_EVENTS;
    plugin->state = &greeter;
    plugin->shutdown = onShutdown;
    return greeter.start(*host);
}
