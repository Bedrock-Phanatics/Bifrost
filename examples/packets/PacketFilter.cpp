#include <algorithm>
#include <cstring>
#include <string_view>
#include "bifrost_plugin.h"
#include "bifrost_manifest.h"

namespace {
bifrost_str toStr(std::string_view text) noexcept {
    return {reinterpret_cast<const uint8_t *>(text.data()), text.size()};
}

class PacketFilter {
public:
    static bifrost_status start(const bifrost_host *host) noexcept {
        const auto status = host->subscribe_packet(host->context, BIFROST_DIRECTION_FROM_PLAYER, 9,
            BIFROST_PHASE_IN_GAME, BIFROST_PACKET_FIELDS, onText, const_cast<bifrost_host *>(host));
        if (status != BIFROST_STATUS_OK) return status;
        return host->subscribe_packet(host->context, BIFROST_DIRECTION_FROM_PLAYER, 69,
            BIFROST_PHASE_ANY, BIFROST_PACKET_FIELDS, onRadius, const_cast<bifrost_host *>(host));
    }

private:
    static constexpr size_t maxChatBytes = 512;
    static constexpr int32_t maxChunkRadius = 12;

    static bifrost_packet_action onText(void *user, bifrost_packet *packet) noexcept {
        const auto *host = static_cast<const bifrost_host *>(user);
        bifrost_text text{};
        if (host->decode_packet(host->context, packet, BIFROST_PACKET_TYPE_TEXT, &text, sizeof(text)) != BIFROST_STATUS_OK)
            return BIFROST_PACKET_CANCEL;
        if (text.message_type != BIFROST_TEXT_CHAT) return BIFROST_PACKET_PASS;
        if (text.message.len > maxChatBytes) {
            text = {};
            text.message_type = BIFROST_TEXT_RAW;
            text.message = toStr("Chat messages are limited to 512 bytes.");
            if (host->encode_packet(host->context, packet, BIFROST_PACKET_TYPE_TEXT, &text, sizeof(text)) == BIFROST_STATUS_OK)
                (void)host->send_packet(host->context, packet->player, BIFROST_PACKET_TO_PLAYER,
                    {packet->replacement, packet->replacement_len}, nullptr, nullptr);
            return BIFROST_PACKET_CANCEL;
        }

        uint8_t name[64];
        size_t length = 0;
        if (host->player_name(host->context, packet->player, name, sizeof(name), &length) != BIFROST_STATUS_OK || length > sizeof(name))
            return BIFROST_PACKET_CANCEL;
        if (text.source.len == length && (length == 0 || std::memcmp(text.source.ptr, name, length) == 0))
            return BIFROST_PACKET_PASS;
        text.source = {name, length};
        return host->encode_packet(host->context, packet, BIFROST_PACKET_TYPE_TEXT, &text, sizeof(text)) == BIFROST_STATUS_OK
            ? BIFROST_PACKET_REPLACE : BIFROST_PACKET_CANCEL;
    }

    static bifrost_packet_action onRadius(void *user, bifrost_packet *packet) noexcept {
        const auto *host = static_cast<const bifrost_host *>(user);
        bifrost_chunk_radius radius{};
        if (host->decode_packet(host->context, packet, BIFROST_PACKET_TYPE_CHUNK_RADIUS, &radius, sizeof(radius)) != BIFROST_STATUS_OK)
            return BIFROST_PACKET_CANCEL;
        if (radius.radius < 0) return BIFROST_PACKET_CANCEL;
        if (radius.radius <= maxChunkRadius && radius.max_radius <= maxChunkRadius) return BIFROST_PACKET_PASS;
        radius.radius = std::min(radius.radius, maxChunkRadius);
        radius.max_radius = std::min<uint32_t>(radius.max_radius, maxChunkRadius);
        return host->encode_packet(host->context, packet, BIFROST_PACKET_TYPE_CHUNK_RADIUS, &radius, sizeof(radius)) == BIFROST_STATUS_OK
            ? BIFROST_PACKET_REPLACE : BIFROST_PACKET_CANCEL;
    }
};
}

extern "C" BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) noexcept {
    if (host->abi_version != BIFROST_ABI_VERSION || !BIFROST_HOST_HAS(host, send_packet)) return BIFROST_STATUS_INCOMPATIBLE;
    plugin->capabilities = BIFROST_CAPABILITY_PACKETS;
    return PacketFilter::start(host);
}
