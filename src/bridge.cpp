#include "bridge.h"

#include "extra_video.h"
#include "media.h"
#include "rc/platform.h"
#include "session.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

using namespace std::chrono_literals;
using nlohmann::json;

namespace {

enum class CommandKind { Connect, Disconnect, Display, Mute, Text, Remote, Settings, Microphone, Pointer, Button, Wheel, Key, Release };

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

struct Average {
    std::optional<double> value;
    void observe(double sample) {
        if (std::isfinite(sample) && sample >= 0 && sample <= 5000) {
            const auto previous = value.value_or(sample);
            value = previous + (sample - previous) * 0.2;
        }
    }
};

struct VideoStream {
    explicit VideoStream(const rincast::StreamConfig& stream) : config(stream) {}
    rincast::StreamConfig config;
    rincast::Media decoder;
    std::unique_ptr<rincast::ExtraVideoDecoder> extra;
    uint64_t framesThisSecond = 0;
    Average decode, captureEncode, downlink, total;

    bool initialize() {
        if (config.codec == rc::VideoCodec::H264) return decoder.Initialize(false);
        if (config.codec == rc::VideoCodec::AV1) {
            extra = rincast::ExtraVideoDecoder::Create(rincast::ExtraVideoCodec::AV1, config.ten_bit);
        }
        return bool(extra);
    }
    int width() const { return extra ? extra->VideoWidth() : decoder.VideoWidth(); }
    int height() const { return extra ? extra->VideoHeight() : decoder.VideoHeight(); }
    bool picture(const std::vector<uint8_t>& bitstream) {
        return extra ? extra->Decode(bitstream.data(), bitstream.size())
                     : decoder.DecodeVideo(bitstream.data(), bitstream.size());
    }
    std::vector<uint8_t> take() { return extra ? extra->TakeVideoPixels() : decoder.TakeVideoPixels(); }
};

double differenceMs(int64_t end, int64_t start) { return (double(end) - double(start)) / 1e6; }

const char* codecName(rc::VideoCodec codec) {
    switch (codec) {
        case rc::VideoCodec::H264: return "H.264";
        case rc::VideoCodec::HEVC: return "HEVC";
        case rc::VideoCodec::AV1: return "AV1";
    }
    return "";
}

rincast::SessionConfig makeConfig(const char* directory, const char* platform, bool mobile) {
    rincast::SessionConfig config;
    config.device_name = std::string("FogShot (") + platform + ")";
    config.auto_start_desktop = false;
    config.settings["desktopFps"] = mobile ? 30 : 60;
    config.decoders["maxWidth"] = mobile ? 1920 : 2560;
    config.decoders["maxHeight"] = mobile ? 1920 : 2560;
    const auto extra = rincast::ProbeExtraVideo();
    config.decoders["av1"] = extra.av1_8bit;
    config.decoders["av110"] = extra.av110bit;
#ifdef RINCAST_UNICAST_DISCOVERY
    config.unicast_discovery = true;
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
                frames.clear();
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
    std::map<uint8_t, std::shared_ptr<const FrameData>> frames;
    std::string state = R"({"state":0,"status":"Starting client..."})";
    std::atomic<bool> stopping = false;
    std::thread worker;
};

void RcdClient::run(rincast::SessionConfig config) {
    const bool discover = config.discover;
    const auto defaultWidth = config.decoders.value("maxWidth", 2560u);
    const auto defaultHeight = config.decoders.value("maxHeight", 2560u);
    const bool av1 = config.decoders.value("av1", false), av1TenBit = config.decoders.value("av110", false);
    const auto codecs = av1 ? json::array({"h264", "av1"}) : json::array({"h264"});
    rincast::Media audio;
    if (!audio.Initialize()) throw std::runtime_error("Could not initialize media");
    audio.SetPlaybackActive(false);
    rincast::Session session(std::move(config));
    std::map<uint8_t, VideoStream> video;
    std::string monitorId, notice;
    uint8_t focus = 0;
    uint64_t sequence = 0, generation = 0, decoded = 0, audioPackets = 0;
    bool showAll = false, microphone = false, micSettingsDirty = false, audioActive = false, dirty = true;
    std::vector<uint8_t> micPacket;
    json network = json::object();

    const auto clearVideo = [&] {
        video.clear();
        focus = 0;
        ++generation;
        network = json::object();
        dirty = true;
        std::lock_guard lock(mutex);
        frames.clear();
    };
    const auto setMic = [&](bool enabled) {
        if (enabled && !session.connected()) return;
        if (microphone == enabled) return;
        if (enabled) {
            microphone = audio.StartMicrophone();
            notice = microphone ? "" : "无法打开此设备的麦克风。";
        } else {
            audio.StopMicrophone();
            microphone = false;
        }
        session.update_settings({{"micPassthrough", microphone}});
        dirty = true;
    };
    const auto select = [&](const std::string& id, bool all) {
        if (showAll == all && monitorId == id) return;
        std::vector<std::string> selected;
        if (!all) selected.push_back(id);
        if (!session.select_monitors(selected)) return;
        session.release_controls();
        showAll = all;
        monitorId = id;
        clearVideo();
    };

    rincast::Session::Callbacks callbacks;
    callbacks.on_state = [&](rincast::Session::State status, const std::string&) {
        dirty = true;
        if (status == rincast::Session::State::Connected) {
            if (!audioActive) {
                audio.Reset();
                audio.SetMuted(false);
                audioActive = audio.AudioAvailable();
                audio.SetPlaybackActive(audioActive);
            }
        } else {
            if (audioActive) {
                audio.SetPlaybackActive(false);
                audio.Reset();
            }
            audioActive = false;
            if (microphone) {
                audio.StopMicrophone();
                microphone = false;
                micSettingsDirty = true;
            }
            monitorId.clear();
            showAll = false;
            notice.clear();
            decoded = 0;
            audioPackets = 0;
            if (!video.empty()) {
                clearVideo();
            }
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
        clearVideo();
        for (const auto& stream : streams) {
            VideoStream receiver(stream);
            if (receiver.initialize()) {
                video.emplace(stream.stream_id, std::move(receiver));
            } else {
                notice = std::string("无法初始化视频解码器 ") + codecName(stream.codec);
            }
        }
        const auto preferred = std::find_if(video.begin(), video.end(), [&](const auto& entry) {
            return entry.second.config.monitor_id == monitorId;
        });
        if (!video.empty()) focus = preferred != video.end() ? preferred->first : video.begin()->first;
    };
    callbacks.on_video = [&](rc::ReceivedFrame&& received) {
        const auto it = video.find(received.streamId);
        if (it == video.end()) return false;
        auto& stream = it->second;
        const int64_t start = rc::NowNs();
        if (!stream.picture(received.bitstream)) return stream.extra && stream.extra->LastError().empty();
        const int64_t end = rc::NowNs();
        stream.decode.observe(differenceMs(end, start));
        if (received.metadata.size() >= sizeof(rc::DesktopFrameMetadata)) {
            rc::DesktopFrameMetadata metadata{};
            std::memcpy(&metadata, received.metadata.data(), sizeof(metadata));
            if (metadata.pcCaptureNs > 0 && metadata.pcEncodeEndNs >= metadata.pcCaptureNs) {
                stream.captureEncode.observe(differenceMs(metadata.pcEncodeEndNs, metadata.pcCaptureNs));
                const auto health = session.health();
                if (health.clock_synchronized) {
                    const auto transport = differenceMs(received.completeNs, metadata.pcEncodeEndNs) +
                                           double(health.clock_offset_ns) / 1e6;
                    stream.downlink.observe(transport);
                    const auto total = differenceMs(end, metadata.pcCaptureNs) + double(health.clock_offset_ns) / 1e6;
                    stream.total.observe(total);
                }
            }
        }
        auto latest = std::make_shared<FrameData>(FrameData{++sequence, generation, uint32_t(stream.width()),
                                                           uint32_t(stream.height()), stream.take()});
        if (latest->pixels.empty()) return false;
        ++stream.framesThisSecond;
        ++decoded;
        std::lock_guard lock(mutex);
        frames[received.streamId] = std::move(latest);
        return true;
    };
    callbacks.on_audio = [&](const rc::AudioPacketHeader&, const uint8_t* packet, size_t size) {
        if (audio.DecodeOpus(packet, size)) ++audioPackets;
    };
    session.set_callbacks(std::move(callbacks));

    auto nextState = std::chrono::steady_clock::now();
    auto lastSample = nextState;
    auto connectedAt = nextState;
    uint64_t lastRxBytes = 0, lastTxBytes = 0;
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
                case CommandKind::Connect: setMic(false); session.connect(command.text); break;
                case CommandKind::Disconnect: setMic(false); session.cancel(); break;
                case CommandKind::Display:
                    if (command.down) select({}, true);
                    else if (std::any_of(session.monitors().begin(), session.monitors().end(),
                                         [&](const auto& monitor) { return monitor.id == command.text; })) {
                        select(command.text, false);
                    }
                    break;
                case CommandKind::Mute: audio.SetMuted(command.down); break;
                case CommandKind::Text: session.text(command.text); break;
                case CommandKind::Remote: {
                    const auto offer = json::parse(command.text, nullptr, false);
                    if (offer.is_object()) {
                        setMic(false);
                        session.connect_remote(offer);
                    }
                    break;
                }
                case CommandKind::Settings: {
                    const auto settings = json::parse(command.text, nullptr, false);
                    if (!settings.is_object()) break;
                    json wire = json::object();
                    for (const auto* name : {"desktopFps", "desktopBitrateMbps", "adaptiveBitrate", "streamAudio", "codec"}) {
                        if (settings.contains(name)) wire[name] = settings[name];
                    }
                    wire["tenBit"] = av1TenBit && settings.contains("tenBit") && settings["tenBit"] == true &&
                                     (!wire.contains("codec") || wire["codec"] != "h264");
                    if (settings.contains("volume") && settings["volume"].is_number()) audio.SetVolume(settings["volume"].get<float>());
                    if (settings.contains("maxDecodeWidth") && settings["maxDecodeWidth"].is_number_integer() &&
                        settings.contains("maxDecodeHeight") && settings["maxDecodeHeight"].is_number_integer()) {
                        const auto width = settings["maxDecodeWidth"].get<int>();
                        const auto height = settings["maxDecodeHeight"].get<int>();
                        session.set_decode_limits(width <= 0 ? defaultWidth : uint32_t(std::clamp(width, 640, 4096)),
                                                  height <= 0 ? defaultHeight : uint32_t(std::clamp(height, 480, 4096)));
                    }
                    session.update_settings(wire);
                    break;
                }
                case CommandKind::Microphone: setMic(command.down); break;
                case CommandKind::Pointer: {
                    const auto stream = video.find(command.code == 0 ? focus : uint8_t(command.code));
                    if (stream != video.end()) {
                        if (focus != stream->first) {
                            focus = stream->first;
                            session.prefer_monitor(stream->second.config.monitor_id);
                        }
                        session.pointer(stream->first, command.x, command.y);
                    }
                    break;
                }
                case CommandKind::Button: session.mouse_button(command.code, command.down); break;
                case CommandKind::Wheel: session.mouse_wheel(command.x, command.y); break;
                case CommandKind::Key: session.key(uint16_t(command.code), command.down); break;
                case CommandKind::Release: session.release_controls(); break;
            }
        }
        pending.clear();
        session.pump();
        if (micSettingsDirty) {
            session.update_settings({{"micPassthrough", false}});
            micSettingsDirty = false;
        }
        if (microphone) {
            for (int i = 0; i < 4 && audio.TakeMicPacket(micPacket); ++i) session.send_mic(micPacket.data(), micPacket.size());
        }

        const auto& monitors = session.monitors();
        if (session.connected() && !showAll && !monitors.empty() &&
            std::none_of(monitors.begin(), monitors.end(), [&](const auto& item) { return item.id == monitorId; })) {
            const auto primary = std::find_if(monitors.begin(), monitors.end(), [](const auto& item) { return item.primary; });
            select((primary == monitors.end() ? monitors.front() : *primary).id, false);
        }

        const auto now = std::chrono::steady_clock::now();
        if (!session.connected()) {
            connectedAt = lastSample = now;
            lastRxBytes = lastTxBytes = 0;
            if (!network.empty()) network = json::object();
        }
        if (session.connected() && (network.empty() || now - lastSample >= 1s)) {
            const auto health = session.health();
            const auto& link = health.connection;
            network = {{"route", health.route}, {"endpoint", health.remote_endpoint},
                       {"activeSeconds", std::chrono::duration_cast<std::chrono::seconds>(now - connectedAt).count()},
                       {"lastPacketMs", health.last_receive_age_ms}, {"clockSynchronized", health.clock_synchronized},
                       {"bytesReceived", link.bytesReceived}, {"bytesSent", link.bytesSent},
                       {"packetsReceived", link.packetsReceived}, {"packetsSent", link.packetsSent},
                       {"packetsRejected", link.packetsRejected}, {"controlRetransmits", link.controlRetransmits},
                       {"fragmentsReceived", health.fragments_received}, {"fragmentsLost", health.fragments_lost},
                       {"recovered", health.fragments_recovered}, {"audioPackets", audioPackets}};
            if (health.connection.rttMs > 0) {
                network["rttMs"] = health.connection.rttMs;
                network["jitterMs"] = health.connection.rttVarMs;
            }
            const auto fragments = health.fragments_received + health.fragments_lost + health.fragments_recovered;
            if (fragments) network["lossPercent"] = double(health.fragments_lost) * 100.0 / double(fragments);
            const auto seconds = std::chrono::duration<double>(now - lastSample).count();
            if (seconds >= 1 && link.bytesReceived >= lastRxBytes && link.bytesSent >= lastTxBytes) {
                network["mbps"] = double(link.bytesReceived - lastRxBytes) * 8e-6 / seconds;
                network["uploadMbps"] = double(link.bytesSent - lastTxBytes) * 8e-6 / seconds;
            }
            lastRxBytes = link.bytesReceived;
            lastTxBytes = link.bytesSent;
            uint64_t targetKbps = 0;
            auto streamMetrics = json::array();
            for (auto& [id, stream] : video) {
                json metrics = {{"name", stream.config.name}, {"active", id == focus},
                                {"width", stream.width() > 0 ? stream.width() : stream.config.width},
                                {"height", stream.height() > 0 ? stream.height() : stream.config.height},
                                {"codec", std::string(codecName(stream.config.codec)) + (stream.config.ten_bit ? " 10-bit" : "")}};
                const auto fps = seconds >= 1 ? double(stream.framesThisSecond) / seconds : 0;
                if (seconds >= 1) metrics["fps"] = fps;
                if (const auto it = session.stream_stats().find(id); it != session.stream_stats().end()) {
                    const auto& stats = it->second;
                    if (stats.server_fps > 0) metrics["hostFps"] = stats.server_fps;
                    if (stats.server_mbps > 0) metrics["hostMbps"] = stats.server_mbps;
                    if (stats.server_encode_ms > 0) metrics["encodeMs"] = stats.server_encode_ms;
                    if (stats.target_bitrate_kbps) metrics["targetMbps"] = double(stats.target_bitrate_kbps) / 1000;
                    targetKbps += stats.target_bitrate_kbps;
                    if (seconds >= 1) {
                        metrics["receiveFps"] = stats.receive_fps;
                        metrics["receiveMbps"] = stats.receive_mbps;
                    }
                    metrics["framesReceived"] = stats.frames_received;
                    metrics["framesLost"] = stats.frames_lost;
                    if (stats.frames_received) metrics["assemblyMs"] = stats.network_ms;
                }
                const auto report = [&](const char* name, const Average& measurement) {
                    if (measurement.value) metrics[name] = *measurement.value;
                };
                report("decodeMs", stream.decode);
                report("captureEncodeMs", stream.captureEncode);
                report("downlinkMs", stream.downlink);
                report("captureToDecodeMs", stream.total);
                if (seconds >= 1 && stream.decode.value) {
                    session.report_decode(id, *stream.decode.value, stream.total.value.value_or(0));
                    if (id == focus) {
                        json stages = {{"decode", *stream.decode.value}};
                        if (stream.captureEncode.value) stages["capture"] = *stream.captureEncode.value;
                        if (stream.downlink.value) stages["downlink"] = *stream.downlink.value;
                        session.send_control({{"type", rc::msg::kStats}, {"stats", {
                            {"fps", fps}, {"latencyMs", stream.total.value.value_or(0)},
                            {"decodeMs", *stream.decode.value}, {"latencyStages", stages}}}});
                    }
                }
                streamMetrics.push_back(std::move(metrics));
                stream.framesThisSecond = 0;
            }
            if (targetKbps) network["targetMbps"] = double(targetKbps) / 1000;
            network["streams"] = std::move(streamMetrics);
            lastSample = now;
        }

        if (dirty || now >= nextState) {
            auto hosts = json::array(), displays = json::array(), streams = json::array();
            for (const auto& item : session.hosts())
                hosts.push_back({{"name", item.name}, {"address", item.address}, {"busy", item.busy}, {"os", item.os}});
            for (const auto& item : monitors)
                displays.push_back({{"id", item.id}, {"name", item.name}, {"width", item.width}, {"height", item.height}});
            for (const auto& [id, stream] : video) {
                streams.push_back({{"streamId", id}, {"id", stream.config.monitor_id}, {"name", stream.config.name},
                                   {"width", stream.config.width}, {"height", stream.config.height}});
            }
            std::string updated = json{{"state", int(session.state())}, {"status", session.status()},
                                       {"deviceId", session.device_id()}, {"discover", discover}, {"hosts", std::move(hosts)},
                                       {"displays", std::move(displays)}, {"display", monitorId}, {"streams", std::move(streams)},
                                       {"allDisplays", showAll}, {"notice", notice}, {"microphone", microphone}, {"network", network},
                                       {"codecs", codecs}, {"av1TenBit", av1TenBit},
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
    audio.SetPlaybackActive(false);
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
    if (!client || kind < 0 || kind > int(CommandKind::Microphone)) return;
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
    return rcd_acquire_stream_frame(client, 0, after, generation, output);
}

RcdFrame* rcd_acquire_stream_frame(RcdClient* client, int32_t id, uint64_t after, uint64_t generation, RcdFrameView* output) {
    std::lock_guard lock(client->mutex);
    const auto lookup = id ? client->frames.find(uint8_t(id)) : client->frames.begin();
    if (lookup == client->frames.end()) return nullptr;
    const auto& frame = lookup->second;
    if (frame->sequence <= after || frame->generation != generation) return nullptr;
    *output = {frame->sequence, frame->width, frame->height, frame->pixels.data()};
    return new RcdFrame{frame};
}

void rcd_release_frame(RcdFrame* frame) { delete frame; }
