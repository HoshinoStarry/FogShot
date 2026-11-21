#include "bridge.h"

#include "media.h"
#include "session.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using namespace std::chrono_literals;
using nlohmann::json;

namespace {

enum class CommandKind { Connect, Disconnect, Display, Mute, Text, Pointer, Button, Wheel, Key, Release };

struct Command {
    CommandKind kind;
    std::string text;
    int code = 0;
    bool down = false;
    float x = 0, y = 0;
};

struct FrameData {
    uint64_t sequence, generation;
    uint32_t width, height;
    std::vector<uint8_t> pixels;
};

rincast::SessionConfig makeConfig(const char* directory, const char* platform, bool mobile) {
    rincast::SessionConfig config;
    config.device_name = std::string("FogShot (") + platform + ")";
    config.auto_start_desktop = false;
    config.settings["desktopFps"] = mobile ? 30 : 60;
    config.decoders["maxWidth"] = mobile ? 1920 : 2560;
    config.decoders["maxHeight"] = mobile ? 1920 : 2560;
#ifdef RINCAST_DISABLE_DISCOVERY
    config.discover = false;
#endif
    const auto keyFile = std::filesystem::u8path(directory) / "identity.key";
    rc::crypto::IdentitySeed seed{};
    std::ifstream input(keyFile, std::ios::binary);
    if (input.read(reinterpret_cast<char*>(seed.data()), seed.size()) && input.peek() == EOF) {
        config.identity = seed;
        return config;
    }
    input.close();
    config.identity = rc::crypto::NewIdentitySeed();
    const auto temporary = keyFile.parent_path() / "identity.tmp";
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char*>(config.identity->data()), config.identity->size());
    output.close();
    if (!output) throw std::runtime_error("Could not save the RinCast client identity");
    std::filesystem::permissions(temporary, std::filesystem::perms::owner_read | std::filesystem::perms::owner_write);
    std::filesystem::rename(temporary, keyFile);
    return config;
}

} // namespace

struct RcdFrame {
    std::shared_ptr<const FrameData> view;
};

struct RcdClient {
    explicit RcdClient(rincast::SessionConfig config) {
        worker = std::thread([this, config = std::move(config)]() mutable {
            try {
                run(std::move(config));
            } catch (const std::exception& error) {
                std::lock_guard lock(mutex);
                state = json{{"state", 4}, {"status", error.what()}}.dump(-1, ' ', false, json::error_handler_t::replace);
                frame.reset();
            }
        });
    }

    ~RcdClient() {
        stopping = true;
        wake.notify_one();
        worker.join();
    }

    void enqueue(Command command) {
        {
            std::lock_guard lock(mutex);
            if (command.kind == CommandKind::Pointer && !commands.empty() && commands.back().kind == CommandKind::Pointer)
                commands.back() = std::move(command);
            else commands.push_back(std::move(command));
        }
        wake.notify_one();
    }

    void run(rincast::SessionConfig config);

    std::mutex mutex;
    std::condition_variable wake;
    std::vector<Command> commands;
    std::shared_ptr<const FrameData> frame;
    std::string state = R"({"state":0,"status":"Starting client..."})";
    std::atomic<bool> stopping = false;
    std::thread worker;
};

void RcdClient::run(rincast::SessionConfig config) {
    const bool discover = config.discover;
    rincast::Media media;
    if (!media.Initialize()) throw std::runtime_error("Could not initialize the H.264 decoder");
    rincast::Session session(std::move(config));
    std::string monitorId, notice;
    uint8_t streamId = 0;
    uint64_t sequence = 0, generation = 0, decoded = 0, audioPackets = 0;
    bool dirty = true;
    const auto clearVideo = [&] {
        media.Reset();
        ++generation;
        dirty = true;
        std::lock_guard lock(mutex);
        frame.reset();
    };
    const auto select = [&](const std::string& id) {
        if (monitorId == id || !session.select_monitors({id})) return;
        session.release_controls();
        monitorId = id;
        streamId = 0;
        clearVideo();
    };

    rincast::Session::Callbacks callbacks;
    callbacks.on_state = [&](rincast::Session::State status, const std::string&) {
        dirty = true;
        if (status != rincast::Session::State::Connected && (streamId != 0 || !monitorId.empty())) {
            streamId = 0;
            monitorId.clear();
            notice.clear();
            decoded = 0;
            audioPackets = 0;
            clearVideo();
        }
    };
    callbacks.on_control = [&](const json& message) {
        if (message.contains("type") && message["type"] == rc::msg::kNotice &&
            message.contains("text") && message["text"].is_string()) {
            notice = message["text"].get<std::string>();
            dirty = true;
        }
    };
    callbacks.on_monitors = [&](const auto&) { dirty = true; };
    callbacks.on_stream_config = [&](const std::vector<rincast::StreamConfig>& streams) {
        const auto matching = std::find_if(streams.begin(), streams.end(), [&](const auto& it) {
            return it.monitor_id == monitorId || (it.monitor_id.empty() && streams.size() == 1);
        });
        streamId = matching == streams.end() ? 0 : matching->stream_id;
        clearVideo();
    };
    callbacks.on_video = [&](rc::ReceivedFrame&& received) {
        if (received.streamId != streamId || !media.DecodeVideo(received.bitstream.data(), received.bitstream.size()))
            return false;
        auto latest = std::make_shared<FrameData>(FrameData{++sequence, generation, uint32_t(media.VideoWidth()),
                                                           uint32_t(media.VideoHeight()), media.TakeVideoPixels()});
        if (latest->pixels.empty()) return false;
        ++decoded;
        std::lock_guard lock(mutex);
        frame = std::move(latest);
        return true;
    };
    callbacks.on_audio = [&](const rc::AudioPacketHeader&, const uint8_t* packet, size_t size) {
        if (media.DecodeOpus(packet, size)) ++audioPackets;
    };
    session.set_callbacks(std::move(callbacks));

    auto nextState = std::chrono::steady_clock::now();
    std::vector<Command> pending;
    while (!stopping) {
        {
            std::unique_lock lock(mutex);
            wake.wait_for(lock, session.connected() ? 2ms : 12ms,
                          [&] { return !commands.empty() || stopping; });
            if (stopping) break;
            commands.swap(pending);
        }
        for (const auto& command : pending) {
            switch (command.kind) {
                case CommandKind::Connect: session.connect(command.text); break;
                case CommandKind::Disconnect: session.cancel(); break;
                case CommandKind::Display:
                    if (std::any_of(session.monitors().begin(), session.monitors().end(),
                                    [&](const auto& monitor) { return monitor.id == command.text; })) select(command.text);
                    break;
                case CommandKind::Mute: media.SetMuted(command.down); break;
                case CommandKind::Text: session.text(command.text); break;
                case CommandKind::Pointer: if (streamId) session.pointer(streamId, command.x, command.y); break;
                case CommandKind::Button: session.mouse_button(command.code, command.down); break;
                case CommandKind::Wheel: session.mouse_wheel(command.x, command.y); break;
                case CommandKind::Key: session.key(uint16_t(command.code), command.down); break;
                case CommandKind::Release: session.release_controls(); break;
            }
        }
        pending.clear();
        session.pump();

        const auto& monitors = session.monitors();
        if (session.connected() && !monitors.empty() &&
            std::none_of(monitors.begin(), monitors.end(), [&](const auto& item) { return item.id == monitorId; })) {
            const auto primary = std::find_if(monitors.begin(), monitors.end(), [](const auto& item) { return item.primary; });
            select((primary == monitors.end() ? monitors.front() : *primary).id);
        }

        if (const auto now = std::chrono::steady_clock::now(); dirty || now >= nextState) {
            auto hosts = json::array(), displays = json::array();
            for (const auto& item : session.hosts())
                hosts.push_back({{"name", item.name}, {"address", item.address}, {"busy", item.busy}, {"os", item.os}});
            for (const auto& item : monitors)
                displays.push_back({{"id", item.id}, {"name", item.name}, {"width", item.width}, {"height", item.height}});
            std::string updated = json{{"state", int(session.state())}, {"status", session.status()},
                                       {"discover", discover}, {"hosts", std::move(hosts)},
                                       {"displays", std::move(displays)}, {"display", monitorId}, {"notice", notice},
                                       {"generation", generation}, {"decoded", decoded}, {"audioPackets", audioPackets}}
                                      .dump(-1, ' ', false, json::error_handler_t::replace);
            {
                std::lock_guard lock(mutex);
                state = std::move(updated);
            }
            dirty = false;
            nextState = now + 200ms;
        }
    }
    session.disconnect();
}

RcdClient* rcd_create(const char* profile_dir, const char* platform, int32_t mobile) {
    try {
        return new RcdClient(makeConfig(profile_dir, platform, mobile != 0));
    } catch (const std::exception& error) {
        std::fprintf(stderr, "FogShot: %s\n", error.what());
        return nullptr;
    }
}

void rcd_destroy(RcdClient* client) { delete client; }

void rcd_command(RcdClient* client, int32_t kind, const char* value, int32_t flag) {
    if (!client || kind < 0 || kind > int(CommandKind::Text)) return;
    client->enqueue({static_cast<CommandKind>(kind), value ? value : "", 0, flag != 0});
}

void rcd_input(RcdClient* client, int32_t kind, int32_t code, int32_t down, float x, float y) {
    if (!client || kind < 0 || kind > 4) return;
    client->enqueue({static_cast<CommandKind>(kind + int(CommandKind::Pointer)), {}, code, down != 0, x, y});
}

size_t rcd_state(RcdClient* client, uint8_t* output, size_t capacity) {
    std::lock_guard lock(client->mutex);
    const auto size = client->state.size();
    if (capacity >= size) std::memcpy(output, client->state.data(), size);
    return size;
}

RcdFrame* rcd_acquire_frame(RcdClient* client, uint64_t after, uint64_t generation, RcdFrameView* output) {
    std::lock_guard lock(client->mutex);
    const auto& frame = client->frame;
    if (!frame || frame->sequence <= after || frame->generation != generation) return nullptr;
    *output = {frame->sequence, frame->width, frame->height, frame->pixels.data()};
    return new RcdFrame{frame};
}

void rcd_release_frame(RcdFrame* frame) { delete frame; }
