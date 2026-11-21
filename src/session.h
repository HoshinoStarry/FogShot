#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

#include "nlohmann/json.hpp"
#include "rc/connection.h"
#include "rc/crypto.h"
#include "rc/handshake.h"
#include "rc/protocol.h"
#include "rc/socket.h"
#include "rc/video_transport.h"

namespace rincast {

// 局域网中由 RinCast Streamer 广播的主机。endpoint 已包含实际流端口。
struct Host {
    std::string id;
    std::string name;
    std::string version;
    std::string os;
    std::string gpu;
    std::string address;  // 供界面显示，例如 "192.168.1.42:38711"
    rc::NetAddress endpoint;
    bool busy = false;
    bool account_linked = false;
    std::string account_name;
    int64_t last_seen_ns = 0;
};

struct Monitor {
    std::string id;
    std::string name;
    uint32_t index = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    float refresh_hz = 0;
    bool primary = false;
};

// stream.config 的桌面流部分。空 monitor_id 表示 PC 没有填写这一字段。
struct StreamConfig {
    uint8_t stream_id = 0;
    std::string monitor_id;
    std::string name;
    rc::VideoCodec codec = rc::VideoCodec::H264;
    uint32_t width = 0;
    uint32_t height = 0;
    float fps = 0;
    bool ten_bit = false;
};

struct SessionConfig {
    std::string device_id;    // 留空时从身份公钥生成，重连时应保持稳定
    std::string device_name = "RinCast Desktop";
    std::string model = "Desktop";
    std::string app_version = "0.1.0";
    // TOFU 身份种子。由应用持久化并在后续启动时传回；留空时 Session 生成临时身份。
    std::optional<rc::crypto::IdentitySeed> identity;
    // PC 只支持 H.264 时也必须据此选择编码器。
    nlohmann::json decoders = {{"h264", true}, {"hevc", false}, {"hevc10", false},
                               {"av1", false}, {"av110", false}, {"maxWidth", 8192},
                               {"maxHeight", 8192}};
    nlohmann::json display = {{"eyeWidth", 1920}, {"eyeHeight", 1080},
                              {"refreshRates", {60.0f}}, {"ipd", 0.063f}};
    nlohmann::json settings = {{"codec", "h264"}, {"tenBit", false}, {"desktopFps", 60},
                               {"desktopBitrateMbps", 0}, {"streamAudio", true},
                               {"micPassthrough", false}, {"adaptiveBitrate", true}};
    // 空列表表示由 PC 选择全部显示器。
    std::vector<std::string> monitors;
    // iOS 的原始广播需要额外 entitlement；关闭后仍可直接连接已知地址。
    bool discover = true;
    bool auto_start_desktop = true;
};

struct Health {
    rc::ConnectionStats connection;
    int64_t last_receive_age_ms = 0;
    int64_t clock_offset_ns = 0;
    bool clock_synchronized = false;
    size_t control_queue_chunks = 0;
    size_t video_streams = 0;
};

// Session 不创建网络线程。SDL 主循环每次调用 pump()，所有回调也在该线程同步触发。
// 除析构外，公开方法必须由同一个线程调用；回调中不要重入 Session。
class Session final {
   public:
    enum class State { Idle, Connecting, WaitingApproval, Connected, Failed };

    struct Callbacks {
        std::function<void(State, const std::string&)> on_state;
        // 每条可靠控制消息都先更新内部状态，再原样通知调用方。
        std::function<void(const nlohmann::json&)> on_control;
        std::function<void(const std::vector<Monitor>&)> on_monitors;
        std::function<void(const std::vector<StreamConfig>&)> on_stream_config;
        // frame.bitstream 是 Annex-B H.264 access unit。返回 false 会暂停该流的预测帧，
        // 立即请求 recovery/keyframe，直到解码器重新成功。
        std::function<bool(rc::ReceivedFrame&&)> on_video;
        // payload 仅含 Opus packet，可直接传给 Media::DecodeOpus；有效期止于回调返回。
        std::function<void(const rc::AudioPacketHeader&, const uint8_t*, size_t)> on_audio;
        std::function<void(const rc::HapticsPayload&)> on_haptics;
    };

    explicit Session(SessionConfig config = {});
    ~Session();

    Session(const Session&) = delete;
    Session& operator=(const Session&) = delete;

    void set_callbacks(Callbacks callbacks);

    // 驱动发现、握手、收包、可靠重传、FEC、恢复和断开检测。非阻塞。
    void pump();

    // address 可写 IPv4、主机名或 host:port；省略端口时使用 kStreamPort。
    bool connect(std::string_view address, std::string name = {});
    bool connect(const Host& host);
    bool connect(const rc::NetAddress& endpoint, std::string name = {});
    // 主动发送 Disconnect 并释放本端持有的鼠标键和键盘键。
    void disconnect();
    void cancel();

    State state() const { return m_state; }
    bool connected() const { return m_state == State::Connected; }
    std::string status() const { return m_status; }
    const std::vector<Host>& hosts() const { return m_hosts; }
    const std::vector<Monitor>& monitors() const { return m_monitors; }
    const std::vector<StreamConfig>& streams() const { return m_streams; }
    const nlohmann::json& server_info() const { return m_server_info; }
    const nlohmann::json& server_settings() const { return m_server_settings; }
    Health health() const;

    rc::crypto::IdentitySeed identity() const { return m_identity; }
    // 仅可在未连接时更换；应用应持久化此种子以供 PC 的 TOFU pin 校验。
    bool set_identity(const rc::crypto::IdentitySeed& identity);

    // 空列表表示全部显示器。已经连接时，这会停止并重新配置桌面视频流。
    bool select_monitors(const std::vector<std::string>& monitor_ids = {});
    bool start_desktop(const std::vector<std::string>& monitor_ids = {});
    bool stop_desktop();
    bool update_settings(const nlohmann::json& settings);
    bool send_control(const nlohmann::json& message);

    // 绝对位置是 0..1。只有流 ID 1..15 有效。
    bool send_pointer(const rc::PointerPayload& pointer);
    bool pointer(uint8_t stream_id, float u, float v, bool visible = true);
    bool mouse_button(int button, bool down);
    bool mouse_wheel(float dx, float dy);
    bool key(uint16_t virtual_key, bool down);
    bool text(std::string_view utf8);
    // 释放本 Session 发送过且仍按下的鼠标键和键盘键。断线时自动调用。
    void release_controls();

    // 解码层成功解出 frame_index 后调用；丢包恢复会以此为 lastGoodFrame。
    void set_last_good_frame(uint8_t stream_id, uint32_t frame_index);
    void request_keyframe(uint8_t stream_id);

   private:
    void set_state(State state, std::string status);
    bool open_discovery(std::string& error);
    bool open_stream_socket(std::string& error);
    void pump_discovery(int64_t now_ns);
    void pump_handshake(int64_t now_ns);
    void pump_session(int64_t now_ns);
    void handle_handshake(const uint8_t* data, size_t size, const rc::NetAddress& from, int64_t now_ns);
    void handle_control(std::string_view text);
    void handle_packet(rc::PacketType type, const uint8_t* payload, size_t size);
    void send_hello(int64_t now_ns);
    void send_client_info();
    void send_feedback(int64_t now_ns);

    SessionConfig m_config;
    Callbacks m_callbacks;
    State m_state = State::Idle;
    std::string m_status = "正在搜索局域网主机";
    rc::crypto::IdentitySeed m_identity{};
    std::string m_device_id;

    rc::UdpSocket m_discovery_socket;
    bool m_discovery_open = false;
    int64_t m_last_probe_ns = 0;
    uint32_t m_probe_nonce = 1;
    std::vector<Host> m_hosts;

    rc::UdpSocket m_socket;
    std::optional<rc::NetAddress> m_target;
    std::string m_target_name;
    rc::crypto::KeyPair m_keys{};
    std::string m_client_nonce;
    rc::HandshakePacket m_hello;
    std::vector<uint8_t> m_hello_bytes;
    int64_t m_last_hello_ns = 0;
    int64_t m_deadline_ns = 0;

    std::unique_ptr<rc::Connection> m_connection;
    int64_t m_last_feedback_ns = 0;
    bool m_feedback_now = false;
    std::vector<Monitor> m_monitors;
    std::vector<StreamConfig> m_streams;
    nlohmann::json m_server_info = nlohmann::json::object();
    nlohmann::json m_server_settings = nlohmann::json::object();
    std::map<uint8_t, std::unique_ptr<rc::VideoReassembler>> m_reassemblers;
    std::map<uint8_t, uint32_t> m_last_good_frame;
    std::map<uint8_t, bool> m_pending_keyframe;
    std::map<uint8_t, bool> m_waiting_recovery;
    std::set<int> m_mouse_buttons;
    std::set<uint16_t> m_held_keys;
    uint32_t m_pointer_sequence = 0;
};

}  // namespace rincast
