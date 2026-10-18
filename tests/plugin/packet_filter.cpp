#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include "../../examples/packets/src/PacketFilter.cpp"

#define CHECK(value) do { if (!(value)) { std::fprintf(stderr, "packet filter check failed at line %d\n", __LINE__); std::abort(); } } while (false)

namespace {
thread_local bifrost_text text;
thread_local bifrost_chunk_radius radius;
thread_local std::string encodedMessage;
thread_local std::string encodedSource;
thread_local bifrost_chunk_radius encodedRadius;
thread_local std::string injectedMessage;

struct Host {
    bifrost_packet_fn callbacks[2]{};
    void *users[2]{};
    bifrost_status decodeStatus = BIFROST_STATUS_OK;
    bifrost_status nameStatus = BIFROST_STATUS_OK;
    bifrost_status encodeStatus = BIFROST_STATUS_OK;

    bifrost_host api() noexcept {
        bifrost_host result{};
        result.struct_size = sizeof(result);
        result.abi_version = BIFROST_ABI_VERSION;
        result.context = this;
        result.subscribe_packet = [](void *context, bifrost_direction direction, uint32_t id, bifrost_packet_phase phase, uint32_t flags, bifrost_packet_fn fn, void *user) noexcept -> bifrost_status {
            CHECK(direction == BIFROST_DIRECTION_FROM_PLAYER && flags == BIFROST_PACKET_FIELDS);
            CHECK((id == 9 && phase == BIFROST_PHASE_IN_GAME) || (id == 69 && phase == BIFROST_PHASE_ANY));
            auto &host = *static_cast<Host *>(context);
            const auto index = id == 9 ? 0 : 1;
            host.callbacks[index] = fn;
            host.users[index] = user;
            return BIFROST_STATUS_OK;
        };
        result.player_name = [](void *context, bifrost_player player, uint8_t *out, size_t capacity, size_t *length) noexcept -> bifrost_status {
            const auto status = static_cast<Host *>(context)->nameStatus;
            if (status != BIFROST_STATUS_OK) return status;
            const std::string_view name = player.id == 2 ? "Alex" : "Steve";
            CHECK(capacity >= name.size());
            std::memcpy(out, name.data(), name.size());
            *length = name.size();
            return BIFROST_STATUS_OK;
        };
        result.decode_packet = [](void *context, const bifrost_packet *, bifrost_packet_type type, void *out, size_t size) noexcept -> bifrost_status {
            const auto status = static_cast<Host *>(context)->decodeStatus;
            if (status != BIFROST_STATUS_OK) return status;
            if (type == BIFROST_PACKET_TYPE_TEXT) {
                CHECK(size == sizeof(text));
                *static_cast<bifrost_text *>(out) = text;
            } else {
                CHECK(type == BIFROST_PACKET_TYPE_CHUNK_RADIUS && size == sizeof(radius));
                *static_cast<bifrost_chunk_radius *>(out) = radius;
            }
            return BIFROST_STATUS_OK;
        };
        result.encode_packet = [](void *context, bifrost_packet *packet, bifrost_packet_type type, const void *data, size_t size) noexcept -> bifrost_status {
            const auto status = static_cast<Host *>(context)->encodeStatus;
            if (status != BIFROST_STATUS_OK) return status;
            if (type == BIFROST_PACKET_TYPE_TEXT) {
                CHECK(size == sizeof(text));
                const auto &value = *static_cast<const bifrost_text *>(data);
                encodedMessage.assign(reinterpret_cast<const char *>(value.message.ptr), value.message.len);
                encodedSource.assign(value.source.len == 0 ? "" : reinterpret_cast<const char *>(value.source.ptr), value.source.len);
                packet->replacement = reinterpret_cast<uint8_t *>(encodedMessage.data());
                packet->replacement_len = encodedMessage.size();
            } else {
                CHECK(type == BIFROST_PACKET_TYPE_CHUNK_RADIUS && size == sizeof(radius));
                encodedRadius = *static_cast<const bifrost_chunk_radius *>(data);
            }
            return BIFROST_STATUS_OK;
        };
        result.send_packet = [](void *, bifrost_player, bifrost_packet_target target, bifrost_str bytes, bifrost_task_done_fn done, void *) noexcept -> bifrost_status {
            CHECK(target == BIFROST_PACKET_TO_PLAYER && done == nullptr);
            injectedMessage.assign(reinterpret_cast<const char *>(bytes.ptr), bytes.len);
            return BIFROST_STATUS_OK;
        };
        return result;
    }

    bifrost_packet_action run(unsigned index, uint64_t player = 1) {
        bifrost_packet packet{};
        packet.player.id = player;
        return callbacks[index](users[index], &packet);
    }
};
}

int main() {
    Host host;
    auto api = host.api();
    bifrost_plugin plugin{};
    CHECK(bifrost_plugin_init(&api, &plugin) == BIFROST_STATUS_OK);
    CHECK(plugin.state == nullptr && plugin.shutdown == nullptr);
    auto run = [&](uint64_t player) {
        for (unsigned i = 0; i < 1000; ++i) {
            std::string message(512, 'x');
            text = {};
            text.message_type = BIFROST_TEXT_CHAT;
            text.message = toStr(message);
            text.source = toStr(player == 2 ? "Alex" : "Steve");
            CHECK(host.run(0, player) == BIFROST_PACKET_PASS);
            text.source = toStr("spoofed");
            CHECK(host.run(0, player) == BIFROST_PACKET_REPLACE);
            CHECK(encodedMessage == message && encodedSource == (player == 2 ? "Alex" : "Steve"));
            message.push_back('x');
            text.message = toStr(message);
            CHECK(host.run(0, player) == BIFROST_PACKET_CANCEL);
            CHECK(injectedMessage == "Chat messages are limited to 512 bytes.");
            text.message_type = BIFROST_TEXT_RAW;
            CHECK(host.run(0, player) == BIFROST_PACKET_PASS);
            radius = {8, 12};
            CHECK(host.run(1, player) == BIFROST_PACKET_PASS);
            radius = {32, 64};
            CHECK(host.run(1, player) == BIFROST_PACKET_REPLACE);
            CHECK(encodedRadius.radius == 12 && encodedRadius.max_radius == 12);
            radius.radius = -1;
            CHECK(host.run(1, player) == BIFROST_PACKET_CANCEL);
        }
    };
    std::jthread first(run, 1);
    std::jthread second(run, 2);
    first.join();
    second.join();
    text = {};
    text.message_type = BIFROST_TEXT_CHAT;
    text.source = toStr("spoofed");
    text.message = toStr("hello");
    host.nameStatus = BIFROST_STATUS_STALE_HANDLE;
    CHECK(host.run(0) == BIFROST_PACKET_CANCEL);
    host.nameStatus = BIFROST_STATUS_OK;
    host.encodeStatus = BIFROST_STATUS_INVALID_ARGUMENT;
    CHECK(host.run(0) == BIFROST_PACKET_CANCEL);
    host.decodeStatus = BIFROST_STATUS_FAILED;
    CHECK(host.run(0) == BIFROST_PACKET_CANCEL && host.run(1) == BIFROST_PACKET_CANCEL);
    api.struct_size = offsetof(bifrost_host, decode_packet);
    CHECK(bifrost_plugin_init(&api, &plugin) == BIFROST_STATUS_INCOMPATIBLE);
}
