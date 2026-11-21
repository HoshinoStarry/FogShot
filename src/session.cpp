#include "session.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <utility>

#include "rc/discovery.h"
#include "rc/handshake.h"
#include "rc/platform.h"

namespace rincast {
namespace {

constexpr int64_t kHelloIntervalNs = 200'000'000LL;
constexpr int64_t kConnectTimeoutNs = 30'000'000'000LL;
constexpr int64_t kApprovalTimeoutNs = 120'000'000'000LL;
constexpr int64_t kDisconnectTimeoutNs = 6'000'000'000LL;
constexpr int64_t kHostTimeoutNs = 12'000'000'000LL;

const char* StateName(Session::State state) {
    switch (state) {
        case Session::State::Idle: return "idle";
        case Session::State::Connecting: return "connecting";
        case Session::State::WaitingApproval: return "waiting_approval";
        case Session::State::Connected: return "connected";
        case Session::State::Failed: return "failed";
    }
    return "unknown";
}

bool SamePeer(const rc::NetAddress& a, const rc::NetAddress& b) {
    if (a.v6 != b.v6) return false;
    if (a.v6) return std::memcmp(a.ip6, b.ip6, sizeof(a.ip6)) == 0;
    return a.ip == b.ip;
}

nlohmann::json ParsedObject(std::string_view text) {
    nlohmann::json value = nlohmann::json::parse(text.begin(), text.end(), nullptr, false);
    return value.is_object() ? value : nlohmann::json::object();
}

nlohmann::json StringArray(const std::vector<std::string>& values) {
    nlohmann::json out = nlohmann::json::array();
    for (const auto& value : values) out.push_back(value);
    return out;
}

}  // namespace

Session::Session(SessionConfig config) : m_config(std::move(config)) {
    rc::NetInit();

    if (m_config.identity) m_identity = *m_config.identity;
    else m_identity = rc::crypto::NewIdentitySeed();

    const auto public_key = rc::crypto::IdentityPublicKey(m_identity);
    const std::string public_hex = rc::HexEncode(public_key.data(), public_key.size());
    m_device_id = m_config.device_id.empty() ? "desktop-" + public_hex.substr(0, 40) : m_config.device_id;
    if (m_device_id.size() > 64) m_device_id.resize(64);

    if (m_config.discover) {
        std::string error;
        if (!open_discovery(error)) m_status = error;
        else m_status = "Searching for LAN hosts...";
    } else {
        m_status = "LAN discovery is disabled";
    }
}

Session::~Session() {
    m_callbacks = {};
    disconnect();
}

void Session::set_callbacks(Callbacks callbacks) { m_callbacks = std::move(callbacks); }

void Session::set_state(State state, std::string status) {
    if (m_state == state && m_status == status) return;
    m_state = state;
    m_status = std::move(status);
    RC_LOGI("Session state: %s (%s)", StateName(state), m_status.c_str());
    if (m_callbacks.on_state) m_callbacks.on_state(m_state, m_status);
}

bool Session::open_discovery(std::string& error) {
    if (m_discovery_socket.IsOpen()) return true;
    // 客户端只发 Probe 并接收单播 Announce。绑定固定发现端口会被防火墙视为监听服务。
    if (!m_discovery_socket.Open(0, true)) {
        error = "Cannot open the LAN discovery socket";
        return false;
    }
    m_discovery_open = true;
    m_last_probe_ns = 0;
    return true;
}

bool Session::open_stream_socket(std::string& error) {
    m_socket.Close();
    if (!m_socket.Open(0)) {
        error = "Cannot open a UDP stream socket";
        return false;
    }
    m_socket.SetBuffers(4 << 20, 16 << 20);
    m_socket.SetTos(0xB8);
    return true;
}

bool Session::connect(std::string_view address, std::string name) {
    const std::string text(address);
    rc::NetAddress endpoint;
    bool parsed = false;
    if (text.find(':') != std::string::npos) {
        parsed = rc::NetAddress::ParseEndpoint(text, endpoint);
    } else {
        parsed = rc::NetAddress::Parse(text, rc::kStreamPort, endpoint);
    }
    if (!parsed || !endpoint.valid()) {
        set_state(State::Failed, "Invalid host address");
        return false;
    }
    if (endpoint.port == 0) endpoint.port = rc::kStreamPort;
    return connect(endpoint, std::move(name));
}

bool Session::connect(const Host& host) { return connect(host.endpoint, host.name); }

bool Session::connect(const rc::NetAddress& endpoint, std::string name) {
    if (!endpoint.valid()) {
        set_state(State::Failed, "Invalid host address");
        return false;
    }

    if (m_connection) release_controls();
    if (m_connection) m_connection->SendDisconnect();
    m_connection.reset();
    m_socket.Close();
    m_target.reset();
    m_monitors.clear();
    m_streams.clear();
    m_reassemblers.clear();
    m_last_good_frame.clear();
    m_pending_keyframe.clear();
    m_waiting_recovery.clear();
    m_server_info = nlohmann::json::object();
    m_server_settings = nlohmann::json::object();

    std::string error;
    if (!open_stream_socket(error)) {
        set_state(State::Failed, error);
        return false;
    }

    m_target = endpoint;
    m_target_name = name.empty() ? endpoint.ToString() : std::move(name);
    m_keys = rc::crypto::KeyPair::Generate();

    uint8_t nonce[16];
    rc::RandomBytes(nonce, sizeof(nonce));
    m_client_nonce = rc::HexEncode(nonce, sizeof(nonce));

    nlohmann::json hello = {{"deviceId", m_device_id},
                            {"deviceName", m_config.device_name},
                            {"model", m_config.model},
                            {"appVersion", m_config.app_version},
                            {"nonce", m_client_nonce},
                            {"display", m_config.display},
                            {"decoders", m_config.decoders},
                            {"settings", m_config.settings}};
    const auto identity_key = rc::crypto::IdentityPublicKey(m_identity);
    const auto signature = rc::crypto::SignConnection(m_identity, m_keys.publicKey, m_client_nonce);
    hello["deviceKey"] = rc::HexEncode(identity_key.data(), identity_key.size());
    hello["deviceSig"] = rc::HexEncode(signature.data(), signature.size());

    m_hello = {};
    m_hello.type = rc::PacketType::Hello;
    m_hello.publicKey = m_keys.publicKey;
    m_hello.json = hello.dump();
    m_hello_bytes = rc::BuildHandshake(m_hello);

    const int64_t now = rc::NowNs();
    m_deadline_ns = now + kConnectTimeoutNs;
    m_last_hello_ns = 0;
    m_last_feedback_ns = now;
    m_feedback_now = false;
    set_state(State::Connecting, "Connecting to " + m_target_name + "...");
    send_hello(now);
    return true;
}

void Session::send_hello(int64_t now_ns) {
    if (!m_target || m_hello_bytes.empty()) return;
    m_socket.SendTo(*m_target, m_hello_bytes.data(), m_hello_bytes.size());
    m_last_hello_ns = now_ns;
}

void Session::pump() {
    const int64_t now = rc::NowNs();
    if (m_config.discover) pump_discovery(now);
    if (m_state == State::Connecting || m_state == State::WaitingApproval) pump_handshake(now);
    else if (m_state == State::Connected) pump_session(now);
}

void Session::pump_discovery(int64_t now_ns) {
    if (!m_discovery_open) {
        std::string error;
        if (!open_discovery(error)) {
            m_status = error;
            return;
        }
    }

    if (m_last_probe_ns == 0 || now_ns - m_last_probe_ns >= 2'000'000'000LL) {
        const rc::DiscoveryProbe probe{m_device_id, m_config.device_name, m_probe_nonce++};
        const auto bytes = rc::BuildProbe(probe);
        for (const auto& interface : rc::ListInterfaces()) {
            if (interface.isVirtual) continue;
            m_discovery_socket.SendTo({interface.broadcast(), rc::kDiscoveryPort}, bytes.data(), bytes.size());
        }
        m_discovery_socket.SendTo(rc::NetAddress::Broadcast(rc::kDiscoveryPort), bytes.data(), bytes.size());
        m_last_probe_ns = now_ns;
    }

    uint8_t buffer[2048];
    rc::NetAddress from;
    for (int packet = 0; packet < 64; ++packet) {
        const int size = m_discovery_socket.RecvFrom(buffer, sizeof(buffer), from, 0);
        if (size <= 0) break;
        rc::DiscoveryAnnounce announce;
        if (!rc::ParseAnnounce(buffer, size_t(size), announce) || from.v6) continue;

        Host host;
        host.id = announce.serverId;
        host.name = announce.name.empty() ? announce.serverId : announce.name;
        host.version = announce.version;
        host.os = announce.os;
        host.gpu = announce.gpu;
        host.busy = announce.busy;
        host.account_linked = announce.accountLinked;
        host.account_name = announce.accountName;
        host.endpoint = {from.ip, announce.streamPort ? announce.streamPort : rc::kStreamPort};
        if (!host.endpoint.valid()) continue;
        host.address = host.endpoint.ToString();
        host.last_seen_ns = rc::NowNs();

        auto existing = std::find_if(m_hosts.begin(), m_hosts.end(),
                                     [&](const Host& value) { return value.id == host.id; });
        if (existing == m_hosts.end()) m_hosts.push_back(std::move(host));
        else *existing = std::move(host);
    }

    m_hosts.erase(std::remove_if(m_hosts.begin(), m_hosts.end(),
                                 [&](const Host& host) { return now_ns - host.last_seen_ns > kHostTimeoutNs; }),
                  m_hosts.end());
    std::sort(m_hosts.begin(), m_hosts.end(), [](const Host& a, const Host& b) {
        if (a.name != b.name) return a.name < b.name;
        return a.id < b.id;
    });
}

void Session::pump_handshake(int64_t now_ns) {
    if (now_ns - m_last_hello_ns >= kHelloIntervalNs) send_hello(now_ns);

    uint8_t buffer[2048];
    rc::NetAddress from;
    for (int packet = 0; packet < 32 && m_state != State::Connected; ++packet) {
        const int size = m_socket.RecvFrom(buffer, sizeof(buffer), from, 0);
        if (size <= 0) break;
        handle_handshake(buffer, size_t(size), from, now_ns);
        if (m_state == State::Failed) break;
    }

    if (m_state != State::Connected && m_state != State::Failed && now_ns > m_deadline_ns) {
        const std::string timeout = m_state == State::WaitingApproval
                                        ? "Approval timed out on the host"
                                        : "The host did not respond";
        set_state(State::Failed, timeout);
        m_socket.Close();
        m_target.reset();
    }
    if (m_state == State::Failed) {
        m_socket.Close();
        m_target.reset();
        m_hello_bytes.clear();
    }
}

void Session::handle_handshake(const uint8_t* data, size_t size, const rc::NetAddress& from, int64_t now_ns) {
    if (!m_target || !SamePeer(from, *m_target)) return;

    rc::HandshakePacket reply;
    if (!rc::ParseHandshake(data, size, reply)) return;

    if (reply.type == rc::PacketType::Reject) {
        const auto message = ParsedObject(reply.json);
        const std::string reason = message.value("reason", "");
        const std::string text = message.value("message", "The host refused the connection");
        if (reason == "pending_approval") {
            m_deadline_ns = std::max(m_deadline_ns, now_ns + kApprovalTimeoutNs);
            set_state(State::WaitingApproval, text);
        } else {
            set_state(State::Failed, text);
        }
        return;
    }
    if (reply.type != rc::PacketType::Welcome || reply.sessionId == 0) return;

    const auto welcome = ParsedObject(reply.json);
    if (!welcome.contains("nonce") || !welcome["nonce"].is_string()) return;
    const std::string server_nonce = welcome["nonce"].get<std::string>();
    if (server_nonce.empty()) return;

    const auto keys = rc::crypto::DeriveSessionKeys(
        m_keys.secretKey, reply.publicKey, m_keys.publicKey, reply.publicKey,
        rc::SessionContext(m_client_nonce, server_nonce, ""));
    auto connection = std::make_unique<rc::Connection>(&m_socket, from, reply.sessionId, keys, false,
                                                       rc::kMaxDatagramLan);
    connection->SetControlHandler([this](const std::string& text) { handle_control(text); });
    connection->SetPacketHandler(
        [this](rc::PacketType type, const uint8_t* payload, size_t payload_size) {
            handle_packet(type, payload, payload_size);
        });

    m_target_name = welcome.value("name", m_target_name);
    m_connection = std::move(connection);
    m_last_feedback_ns = now_ns;
    set_state(State::Connected, "Connected to " + m_target_name);

    send_client_info();
    // Upstream starts VR for every client.info. Stop that pipeline immediately so this desktop
    // session consumes only the monitor streams selected below.
    send_control({{"type", rc::msg::kStopVr}});
    if (m_config.auto_start_desktop) start_desktop(m_config.monitors);
}

void Session::send_client_info() {
    nlohmann::json info = {{"type", rc::msg::kClientInfo},
                           {"deviceId", m_device_id},
                           {"deviceName", m_config.device_name},
                           {"model", m_config.model},
                           {"appVersion", m_config.app_version},
                           {"display", m_config.display},
                           {"decoders", m_config.decoders},
                           {"settings", m_config.settings}};
    send_control(info);
}

void Session::pump_session(int64_t now_ns) {
    uint8_t buffer[2048];
    rc::NetAddress from;
    for (int packet = 0; packet < 128; ++packet) {
        const int size = m_socket.RecvFrom(buffer, sizeof(buffer), from, 0);
        if (size <= 0) break;
        if (rc::IsHandshakeDatagram(buffer, size_t(size))) continue;
        m_connection->HandleDatagram(buffer, size_t(size), from);
        if (m_connection->PeerDisconnected()) break;
    }

    m_connection->Tick(now_ns);
    const bool urgent = m_feedback_now && now_ns - m_last_feedback_ns >= 5'000'000LL;
    if (urgent || now_ns - m_last_feedback_ns >= 100'000'000LL) send_feedback(now_ns);

    if (m_connection->PeerDisconnected() || now_ns - m_connection->LastReceiveNs() > kDisconnectTimeoutNs) {
        const bool remote = m_connection->PeerDisconnected();
        release_controls();
        m_connection.reset();
        m_socket.Close();
        m_target.reset();
        m_reassemblers.clear();
        m_waiting_recovery.clear();
        m_streams.clear();
        set_state(State::Failed, remote ? "The host ended the session" : "Connection lost");
    }
}

void Session::handle_control(std::string_view text) {
    nlohmann::json message = ParsedObject(text);
    if (message.empty() || !message.contains("type") || !message["type"].is_string()) return;
    const std::string type = message["type"].get<std::string>();

    try {
    if (type == rc::msg::kServerInfo) {
        m_server_info = message;
    } else if (type == rc::msg::kSettings) {
        if (!message.contains("settings") || !message["settings"].is_object()) return;
        m_server_settings = message["settings"];
    } else if (type == rc::msg::kMonitors) {
        m_monitors.clear();
        if (message.contains("monitors") && message["monitors"].is_array()) {
            for (const auto& item : message["monitors"]) {
                if (!item.is_object()) continue;
                Monitor monitor;
                monitor.id = item.value("id", "");
                monitor.name = item.value("name", "");
                monitor.index = item.value("index", 0u);
                monitor.width = item.value("width", 0u);
                monitor.height = item.value("height", 0u);
                monitor.refresh_hz = item.value("refreshHz", 0.f);
                monitor.primary = item.value("primary", false);
                m_monitors.push_back(std::move(monitor));
            }
        }
        if (m_callbacks.on_monitors) m_callbacks.on_monitors(m_monitors);
    } else if (type == rc::msg::kStreamConfig && message.value("kind", "") == "desktop") {
        std::vector<StreamConfig> streams;
        std::set<uint8_t> active;
        if (message.contains("streams") && message["streams"].is_array()) {
            for (const auto& item : message["streams"]) {
                if (!item.is_object()) continue;
                const int id = item.value("streamId", 0);
                if (id < int(rc::kFirstMonitorStreamId) || id >= int(rc::kMaxStreams)) continue;
                StreamConfig stream;
                stream.stream_id = uint8_t(id);
                stream.monitor_id = item.value("monitorId", "");
                stream.name = item.value("name", "");
                const int codec = item.value("codec", int(rc::VideoCodec::H264));
                stream.codec = codec >= 0 && codec <= int(rc::VideoCodec::AV1)
                                   ? rc::VideoCodec(codec)
                                   : rc::VideoCodec::H264;
                stream.width = item.value("width", 0u);
                stream.height = item.value("height", 0u);
                stream.fps = item.value("fps", 0.f);
                stream.ten_bit = item.value("tenBit", false);
                active.insert(stream.stream_id);
                streams.push_back(std::move(stream));
            }
        }

        // 新配置代表显示器布局切换；旧流的帧号和参考链都不能继续使用。
        m_reassemblers.clear();
        for (const uint8_t id : active) {
            m_last_good_frame[id] = 0;
            m_pending_keyframe[id] = true;
            m_waiting_recovery[id] = true;
        }
        for (auto it = m_last_good_frame.begin(); it != m_last_good_frame.end();) {
            if (active.contains(it->first)) ++it;
            else it = m_last_good_frame.erase(it);
        }
        for (auto it = m_pending_keyframe.begin(); it != m_pending_keyframe.end();) {
            if (active.contains(it->first)) ++it;
            else it = m_pending_keyframe.erase(it);
        }
        for (auto it = m_waiting_recovery.begin(); it != m_waiting_recovery.end();) {
            if (active.contains(it->first)) ++it;
            else it = m_waiting_recovery.erase(it);
        }
        m_streams = std::move(streams);
        m_feedback_now = true;
        m_last_feedback_ns = 0;
        if (m_callbacks.on_stream_config) m_callbacks.on_stream_config(m_streams);
        send_feedback(rc::NowNs());
    }
    } catch (const nlohmann::json::exception& e) {
        RC_LOGW("Ignored malformed control message: %s", e.what());
        return;
    }

    if (m_callbacks.on_control) {
        try {
            m_callbacks.on_control(message);
        } catch (const nlohmann::json::exception& e) {
            RC_LOGW("Ignored invalid control payload in callback: %s", e.what());
        }
    }
}

void Session::handle_packet(rc::PacketType type, const uint8_t* payload, size_t size) {
    switch (type) {
        case rc::PacketType::Video:
        case rc::PacketType::VideoParity: {
            if (size < 1) return;
            const uint8_t stream_id = payload[0];
            if (stream_id < rc::kFirstMonitorStreamId || stream_id >= rc::kMaxStreams) return;
            const bool active = std::any_of(m_streams.begin(), m_streams.end(),
                                            [&](const StreamConfig& stream) { return stream.stream_id == stream_id; });
            if (!active) return;

            auto& reassembler = m_reassemblers[stream_id];
            if (!reassembler) {
                reassembler = std::make_unique<rc::VideoReassembler>([this, stream_id](rc::ReceivedFrame&& frame) {
                    const uint32_t frame_index = frame.frameIndex;
                    const bool recovery_frame = (frame.flags & (rc::kVideoKeyframe | rc::kVideoRecovery)) != 0;
                    if (m_waiting_recovery[stream_id] && !recovery_frame) return;
                    bool decoded = false;
                    if (m_callbacks.on_video) decoded = m_callbacks.on_video(std::move(frame));
                    if (decoded) {
                        m_last_good_frame[stream_id] = frame_index;
                        m_waiting_recovery[stream_id] = false;
                    } else if (m_callbacks.on_video) {
                        // A failed decode leaves the reference chain broken. Do not submit more
                        // predicted frames until a keyframe or kVideoRecovery frame succeeds.
                        m_waiting_recovery[stream_id] = true;
                        m_pending_keyframe[stream_id] = true;
                        m_feedback_now = true;
                        m_last_feedback_ns = 0;
                    }
                });
            }
            if (type == rc::PacketType::Video) reassembler->HandleFragment(payload, size);
            else reassembler->HandleParity(payload, size);
            return;
        }
        case rc::PacketType::Audio: {
            if (size < sizeof(rc::AudioPacketHeader)) return;
            rc::AudioPacketHeader header;
            std::memcpy(&header, payload, sizeof(header));
            if (header.stream != uint8_t(rc::AudioStream::PcToHeadset)) return;
            if (m_callbacks.on_audio) {
                m_callbacks.on_audio(header, payload + sizeof(header), size - sizeof(header));
            }
            return;
        }
        case rc::PacketType::Haptics: {
            if (size < sizeof(rc::HapticsPayload)) return;
            rc::HapticsPayload haptics;
            std::memcpy(&haptics, payload, sizeof(haptics));
            if (m_callbacks.on_haptics) m_callbacks.on_haptics(haptics);
            return;
        }
        default:
            return;
    }
}

void Session::send_feedback(int64_t now_ns) {
    if (!m_connection) return;
    std::vector<rc::VideoFeedbackPayload> feedback;
    const int64_t window_ns = std::max<int64_t>(now_ns - m_last_feedback_ns, 1'000'000LL);
    m_last_feedback_ns = now_ns;

    for (const auto& [stream_id, reassembler] : m_reassemblers) {
        if (!reassembler) continue;
        const bool lost = reassembler->Expire(now_ns, 250'000'000LL);
        const auto stats = reassembler->TakeStats();

        rc::VideoFeedbackPayload packet{};
        packet.streamId = stream_id;
        packet.requestKeyframe = (lost || m_pending_keyframe[stream_id]) ? 1 : 0;
        packet.lastCompleteFrame = reassembler->LastCompleteFrame();
        packet.lastGoodFrame = m_last_good_frame[stream_id];
        packet.framesLost = stats.framesLost;
        packet.fragmentsReceived = stats.fragmentsReceived;
        packet.fragmentsRecovered = stats.fragmentsRecovered;
        packet.fragmentsLost = stats.fragmentsLost;
        packet.networkMs = stats.framesComplete ? float(stats.spreadMsSum / stats.framesComplete) : 0.f;
        packet.receivedKbps = uint32_t(stats.bytesReceived * 8 * 1000 / uint64_t(window_ns / 1000));
        packet.queueDelayMs = -1.f;
        feedback.push_back(packet);
        if (lost) m_waiting_recovery[stream_id] = true;
        m_pending_keyframe[stream_id] = false;
    }

    for (auto& [stream_id, pending] : m_pending_keyframe) {
        if (!pending || m_reassemblers.contains(stream_id)) continue;
        rc::VideoFeedbackPayload packet{};
        packet.streamId = stream_id;
        packet.requestKeyframe = 1;
        packet.queueDelayMs = -1.f;
        feedback.push_back(packet);
        pending = false;
    }

    for (const auto& packet : feedback) {
        m_connection->Send(rc::PacketType::VideoFeedback, &packet, sizeof(packet));
    }
    m_feedback_now = false;
}

bool Session::select_monitors(const std::vector<std::string>& monitor_ids) {
    return start_desktop(monitor_ids);
}

bool Session::start_desktop(const std::vector<std::string>& monitor_ids) {
    if (!m_connection) return false;
    m_config.monitors = monitor_ids;
    const bool sent = send_control({{"type", rc::msg::kStartDesktop},
                                    {"monitors", StringArray(monitor_ids)}});
    if (sent) set_state(State::Connected, m_status.empty() ? "Connected" : m_status);
    return sent;
}

bool Session::stop_desktop() {
    if (!m_connection) return false;
    const bool sent = send_control({{"type", rc::msg::kStopDesktop}});
    if (sent) {
        m_streams.clear();
        m_reassemblers.clear();
        m_waiting_recovery.clear();
        if (m_callbacks.on_stream_config) m_callbacks.on_stream_config(m_streams);
    }
    return sent;
}

bool Session::update_settings(const nlohmann::json& settings) {
    if (!m_connection || !settings.is_object()) return false;
    m_config.settings = settings;
    return send_control({{"type", rc::msg::kUpdateSettings}, {"settings", settings}});
}

bool Session::send_control(const nlohmann::json& message) {
    if (!m_connection || !message.is_object()) return false;
    m_connection->SendControl(message.dump(-1, ' ', false, nlohmann::json::error_handler_t::replace));
    return true;
}

bool Session::send_pointer(const rc::PointerPayload& pointer) {
    if (!m_connection || pointer.monitorStreamId < rc::kFirstMonitorStreamId ||
        pointer.monitorStreamId >= rc::kMaxStreams || !std::isfinite(pointer.u) ||
        !std::isfinite(pointer.v) || pointer.u < 0.f || pointer.u > 1.f ||
        pointer.v < 0.f || pointer.v > 1.f) {
        return false;
    }
    return m_connection->Send(rc::PacketType::Pointer, &pointer, sizeof(pointer));
}

bool Session::pointer(uint8_t stream_id, float u, float v, bool visible) {
    rc::PointerPayload pointer{};
    pointer.monitorStreamId = stream_id;
    pointer.visible = visible ? 1 : 0;
    pointer.u = u;
    pointer.v = v;
    pointer.inputSeq = ++m_pointer_sequence;
    return send_pointer(pointer);
}

bool Session::mouse_button(int button, bool down) {
    if (button < 0 || button > 4 || !m_connection) return false;
    if (!send_control({{"type", rc::msg::kMouseButton}, {"button", button}, {"down", down}})) return false;
    if (down) m_mouse_buttons.insert(button);
    else m_mouse_buttons.erase(button);
    return true;
}

bool Session::mouse_wheel(float dx, float dy) {
    if (!m_connection || !std::isfinite(dx) || !std::isfinite(dy)) return false;
    return send_control({{"type", rc::msg::kMouseWheel}, {"dx", dx}, {"dy", dy}});
}

bool Session::key(uint16_t virtual_key, bool down) {
    if (!m_connection || virtual_key == 0) return false;
    if (!send_control({{"type", rc::msg::kKey}, {"vk", virtual_key}, {"down", down}})) return false;
    if (down) m_held_keys.insert(virtual_key);
    else m_held_keys.erase(virtual_key);
    return true;
}

bool Session::text(std::string_view utf8) {
    if (!m_connection || utf8.empty()) return false;
    const std::string value(utf8);
    return send_control({{"type", rc::msg::kText}, {"text", value}});
}

void Session::release_controls() {
    if (m_connection) {
        const std::set<uint16_t> keys = m_held_keys;
        const std::set<int> buttons = m_mouse_buttons;
        for (const uint16_t key : keys) {
            m_connection->SendControl(nlohmann::json{{"type", rc::msg::kKey},
                                                     {"vk", key},
                                                     {"down", false}}
                                          .dump());
        }
        for (const int button : buttons) {
            m_connection->SendControl(nlohmann::json{{"type", rc::msg::kMouseButton},
                                                     {"button", button},
                                                     {"down", false}}
                                          .dump());
        }
    }
    m_held_keys.clear();
    m_mouse_buttons.clear();
}

void Session::set_last_good_frame(uint8_t stream_id, uint32_t frame_index) {
    if (stream_id < rc::kFirstMonitorStreamId || stream_id >= rc::kMaxStreams) return;
    m_last_good_frame[stream_id] = frame_index;
    m_waiting_recovery[stream_id] = false;
}

void Session::request_keyframe(uint8_t stream_id) {
    if (stream_id < rc::kFirstMonitorStreamId || stream_id >= rc::kMaxStreams) return;
    m_pending_keyframe[stream_id] = true;
    m_waiting_recovery[stream_id] = true;
    m_feedback_now = true;
    m_last_feedback_ns = 0;
}

Health Session::health() const {
    Health value;
    if (m_connection) {
        value.connection = m_connection->Stats();
        value.last_receive_age_ms = std::max<int64_t>(0, (rc::NowNs() - m_connection->LastReceiveNs()) / 1'000'000);
        value.clock_offset_ns = m_connection->ClockOffsetNs();
        value.clock_synchronized = m_connection->HasClockOffset();
        value.control_queue_chunks = m_connection->SendQueueChunks();
    }
    value.video_streams = m_streams.size();
    return value;
}

bool Session::set_identity(const rc::crypto::IdentitySeed& identity) {
    if (m_connection || m_target) return false;
    m_identity = identity;
    if (m_config.device_id.empty()) {
        const auto public_key = rc::crypto::IdentityPublicKey(m_identity);
        const std::string public_hex = rc::HexEncode(public_key.data(), public_key.size());
        m_device_id = "desktop-" + public_hex.substr(0, 40);
    }
    m_last_probe_ns = 0;
    return true;
}

void Session::cancel() {
    if (m_connection) {
        disconnect();
        return;
    }
    m_socket.Close();
    m_target.reset();
    set_state(State::Idle, m_config.discover ? "Searching for LAN hosts..." : "LAN discovery is disabled");
}

void Session::disconnect() {
    release_controls();
    if (m_connection) m_connection->SendDisconnect();
    m_connection.reset();
    m_socket.Close();
    m_target.reset();
    m_monitors.clear();
    m_streams.clear();
    m_reassemblers.clear();
    m_last_good_frame.clear();
    m_pending_keyframe.clear();
    m_waiting_recovery.clear();
    m_feedback_now = false;
    set_state(State::Idle, m_config.discover ? "Searching for LAN hosts..." : "LAN discovery is disabled");
}

}  // namespace rincast
