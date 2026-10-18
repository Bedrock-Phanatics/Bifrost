#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <format>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include "bifrost_plugin.h"
#include "bifrost_manifest.h"

namespace {

constexpr std::uint32_t textPacketId = 9;
constexpr std::uint32_t maxStrikes = 3;
constexpr std::array<std::string_view, 2> blockedWords{"griefing", "free robux"};

bifrost_str toStr(std::string_view text) noexcept {
    return {reinterpret_cast<const std::uint8_t *>(text.data()), text.size()};
}

std::string_view toView(bifrost_str text) noexcept {
    return {reinterpret_cast<const char *>(text.ptr), text.len};
}

bool isBlocked(std::string_view message) noexcept {
    const auto same = [](char a, char b) { return std::tolower(static_cast<unsigned char>(a)) == b; };
    return std::ranges::any_of(blockedWords, [&](std::string_view word) {
        return !std::ranges::search(message, word, same).empty();
    });
}

class ChatGuard {
public:
    bifrost_status start(const bifrost_host &api) noexcept {
        host = &api;
        // A player stays on one worker, so each worker gets its own map and no lock
        try {
            strikes.assign(host->worker_count(host->context), {});
        } catch (...) {
            return BIFROST_STATUS_FAILED;
        }
        auto status = host->subscribe(host->context, BIFROST_EVENT_PLAYER_AUTHENTICATED, onAuthenticated, this);
        if (status == BIFROST_STATUS_OK)
            status = host->subscribe(host->context, BIFROST_EVENT_PLAYER_DISCONNECTED, onDisconnected, this);
        if (status == BIFROST_STATUS_OK)
            status = host->subscribe_packet(host->context, BIFROST_DIRECTION_FROM_PLAYER, textPacketId,
                BIFROST_PHASE_IN_GAME, BIFROST_PACKET_FIELDS, onText, this);
        return status;
    }

    void stop() noexcept {
        log("blocked {} message(s) and removed {} player(s)", blocked.load(), removed.load());
    }

private:
    static ChatGuard &from(void *user) noexcept {
        return *static_cast<ChatGuard *>(user);
    }

    static void onAuthenticated(void *user, const bifrost_event *event, bifrost_transfer_decision *) noexcept {
        auto &self = from(user);
        bifrost_player_info info{};
        if (self.host->player_info(self.host->context, event->player, &info, sizeof(info)) != BIFROST_STATUS_OK) return;
        std::string_view name{reinterpret_cast<const char *>(info.name), info.name_len};
        self.log("{} joined on worker {}, backend {}", name, info.worker, info.state.backend);
    }

    static void onDisconnected(void *user, const bifrost_event *event, bifrost_transfer_decision *) noexcept {
        auto &self = from(user);
        if (event->worker < self.strikes.size()) self.strikes[event->worker].erase(event->player.id);
    }

    static bifrost_packet_action onText(void *user, bifrost_packet *packet) noexcept {
        auto &self = from(user);
        bifrost_text text{};
        if (self.host->decode_packet(self.host->context, packet, BIFROST_PACKET_TYPE_TEXT, &text, sizeof(text)) != BIFROST_STATUS_OK)
            return BIFROST_PACKET_CANCEL;
        if (text.message_type != BIFROST_TEXT_CHAT || !isBlocked(toView(text.message))) return BIFROST_PACKET_PASS;

        self.blocked.fetch_add(1, std::memory_order_relaxed);
        const auto count = self.strike(*packet);
        if (count >= maxStrikes) {
            self.removed.fetch_add(1, std::memory_order_relaxed);
            self.host->disconnect(self.host->context, packet->player, toStr("Removed for repeated blocked messages"), nullptr, nullptr);
        } else {
            self.warn(*packet, maxStrikes - count);
        }
        return BIFROST_PACKET_CANCEL;
    }

    std::uint32_t strike(const bifrost_packet &packet) noexcept {
        if (packet.worker >= strikes.size()) return 1;
        try {
            return ++strikes[packet.worker][packet.player.id];
        } catch (...) {
            return 1;
        }
    }

    void warn(bifrost_packet &packet, std::uint32_t left) noexcept {
        char buffer[128];
        bifrost_text warning{};
        warning.message_type = BIFROST_TEXT_RAW;
        warning.message = toStr(format(buffer, "That message was blocked. {} more and you will be removed.", left));
        // encode_packet writes into the replacement buffer and send_packet copies it out before we cancel
        if (host->encode_packet(host->context, &packet, BIFROST_PACKET_TYPE_TEXT, &warning, sizeof(warning)) != BIFROST_STATUS_OK) return;
        host->send_packet(host->context, packet.player, BIFROST_PACKET_TO_PLAYER,
            {packet.replacement, packet.replacement_len}, nullptr, nullptr);
    }

    template <std::size_t N, typename... Args>
    static std::string_view format(char (&buffer)[N], std::format_string<Args...> pattern, Args &&...args) noexcept {
        auto result = std::format_to_n(buffer, N, pattern, std::forward<Args>(args)...);
        return {buffer, static_cast<std::size_t>(result.out - buffer)};
    }

    template <typename... Args>
    void log(std::format_string<Args...> pattern, Args &&...args) noexcept {
        char buffer[256];
        host->log(host->context, BIFROST_LOG_INFO, toStr(format(buffer, pattern, std::forward<Args>(args)...)));
    }

    const bifrost_host *host{};
    std::vector<std::unordered_map<std::uint64_t, std::uint32_t>> strikes;
    std::atomic<std::uint32_t> blocked{0};
    std::atomic<std::uint32_t> removed{0};
};

ChatGuard guard;

void onShutdown(void *state) noexcept {
    static_cast<ChatGuard *>(state)->stop();
}

}

extern "C" BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) noexcept {
    if (host->abi_version != BIFROST_ABI_VERSION || !BIFROST_HOST_HAS(host, disconnect)) return BIFROST_STATUS_INCOMPATIBLE;
    plugin->capabilities = BIFROST_CAPABILITY_EVENTS | BIFROST_CAPABILITY_PACKETS;
    plugin->state = &guard;
    plugin->shutdown = onShutdown;
    return guard.start(*host);
}
