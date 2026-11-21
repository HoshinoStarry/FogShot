#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include "session.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <map>
#include <set>
#include <utility>

#include "monocypher.h"
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
constexpr int64_t kLanHeadStartNs = 400'000'000LL;
constexpr int64_t kPathFallbackNs = 1'000'000'000LL;
constexpr int64_t kPathSwitchCooldownNs = 1'000'000'000LL;
constexpr int64_t kRttSwitchCooldownNs = 10'000'000'000LL;
constexpr uint8_t kVpnPathPreference = 1;
constexpr uint8_t kPublicPathPreference = 2;
constexpr uint8_t kLanPathPreference = 3;

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

bool IsLoopbackIpv6(const rc::NetAddress& address) {
    if (!address.v6) return false;
    for (int i = 0; i < 15; ++i) {
        if (address.ip6[i] != 0) return false;
    }
    return address.ip6[15] == 1;
}

bool SamePrivateSubnet(uint32_t address, const std::vector<rc::NetInterface>& interfaces) {
    for (const auto& interface : interfaces) {
        if (interface.isVirtual || interface.netmask == 0 || !rc::IsPrivateLan(interface.ip)) continue;
        if ((address & interface.netmask) == (interface.ip & interface.netmask)) return true;
    }
    return false;
}

bool IsPublicIpv4(uint32_t ip) {
    const uint8_t a = uint8_t(ip >> 24);
    const uint8_t b = uint8_t(ip >> 16);
    const uint8_t c = uint8_t(ip >> 8);
    if (a == 0 || a == 10 || a == 127 || a >= 224) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;  // CGNAT and common VPN overlays
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 192 && b == 0 && (c == 0 || c == 2)) return false;
    if (a == 192 && b == 88 && c == 99) return false;
    if (a == 198 && (b == 18 || b == 19)) return false;
    if (a == 198 && b == 51 && c == 100) return false;
    if (a == 203 && b == 0 && c == 113) return false;
    return true;
}

bool IsPublicIpv6(const rc::NetAddress& address) {
    if (!address.IsGlobalV6()) return false;
    const uint8_t* b = address.ip6;
    if (b[0] == 0x20 && b[1] == 0x02) return false;                              // 6to4 tunnel
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00) return false;  // Teredo
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x02) return false;  // benchmark
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) return false;  // documentation
    return true;
}

std::optional<uint8_t> RemotePathPreference(const rc::NetAddress& address,
                                            const std::vector<rc::NetInterface>& interfaces) {
    if ((!address.v6 && (address.ip >> 24) == 127) || IsLoopbackIpv6(address)) {
        return kLanPathPreference;
    }
    if (address.v6) return IsPublicIpv6(address) ? std::optional<uint8_t>(kPublicPathPreference) : std::nullopt;
    if (rc::IsPrivateLan(address.ip)) {
        if (SamePrivateSubnet(address.ip, interfaces)) return kLanPathPreference;
        return rc::RoutesThroughTunnel(address.ip) ? std::optional<uint8_t>(kVpnPathPreference) : std::nullopt;
    }
    if (rc::IsCgnat(address.ip)) return kVpnPathPreference;
    if (IsPublicIpv4(address.ip)) return kPublicPathPreference;
    return rc::RoutesThroughTunnel(address.ip) ? std::optional<uint8_t>(kVpnPathPreference) : std::nullopt;
}

// LAN discovery still hides stale duplicate announcements behind the best address it has seen.
// Remote account connections use RemotePathPreference and authenticated Welcome results instead.
int DiscoveryPathRank(const rc::NetAddress& address) {
    if (!address.v6 && rc::RoutesThroughTunnel(address.ip)) return 1;
    if (!address.v6 && rc::IsPrivateLan(address.ip)) return 3;
    if (!address.v6 && rc::IsCgnat(address.ip)) return 1;
    return 2;
}

std::string RouteName(const rc::NetAddress& address) {
    if (!address.v6) {
        if (rc::IsPrivateLan(address.ip) || (address.ip >> 24) == 127) return "lan4";
        if (rc::RoutesThroughTunnel(address.ip)) return "vpn4";
        return "wan4";
    }
    const bool ula = (address.ip6[0] & 0xfe) == 0xfc;
    return address.IsLinkLocalV6() || ula || IsLoopbackIpv6(address) ? "lan6" : "wan6";
}

// A connected UDP probe selects a local interface without sending a datagram.
std::string LocalRouteIp(const rc::NetAddress& remote) {
    sockaddr_storage peer{};
    int peer_size;
    if (remote.v6) {
        auto& addr = reinterpret_cast<sockaddr_in6&>(peer);
        addr.sin6_family = AF_INET6;
        addr.sin6_port = htons(remote.port);
        addr.sin6_scope_id = remote.scope;
        std::memcpy(&addr.sin6_addr, remote.ip6, sizeof(remote.ip6));
        peer_size = sizeof(addr);
    } else {
        auto& addr = reinterpret_cast<sockaddr_in&>(peer);
        addr.sin_family = AF_INET;
        addr.sin_port = htons(remote.port);
        addr.sin_addr.s_addr = htonl(remote.ip);
        peer_size = sizeof(addr);
    }
    const auto probe = socket(remote.v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_storage bound{};
#ifdef _WIN32
    if (probe == INVALID_SOCKET) return {};
    int size = sizeof(bound);
#else
    if (probe < 0) return {};
    socklen_t size = sizeof(bound);
#endif
    const bool found = ::connect(probe, reinterpret_cast<const sockaddr*>(&peer), peer_size) == 0 &&
                       getsockname(probe, reinterpret_cast<sockaddr*>(&bound), &size) == 0;
#ifdef _WIN32
    closesocket(probe);
#else
    close(probe);
#endif
    if (!found) return {};
    rc::NetAddress local;
    local.v6 = remote.v6;
    if (local.v6) {
        const auto& addr = reinterpret_cast<const sockaddr_in6&>(bound);
        std::memcpy(local.ip6, &addr.sin6_addr, sizeof(local.ip6));
        local.scope = addr.sin6_scope_id;
    } else {
        local.ip = ntohl(reinterpret_cast<const sockaddr_in&>(bound).sin_addr.s_addr);
    }
    return local.IpString();
}

void SendWithPortGuesses(rc::UdpSocket& socket, const rc::NetAddress& address, const void* data, size_t size,
                         bool guess) {
    socket.SendTo(address, data, size);
    if (!guess || address.v6 || rc::IsPrivateLan(address.ip)) return;
    for (const int delta : {1, 2, 3, 4, -1}) {
        rc::NetAddress nearby = address;
        nearby.port = uint16_t(address.port + delta);
        socket.SendTo(nearby, data, size);
    }
}

nlohmann::json OwnCandidates(uint16_t port, bool dual_stack) {
    nlohmann::json out = nlohmann::json::array();
    for (const auto& interface : rc::ListInterfaces()) {
        if (!interface.isVirtual) out.push_back(rc::NetAddress{interface.ip, port}.ToString());
    }
    if (dual_stack) {
        for (const auto& address : rc::ListGlobalIpv6(port)) out.push_back(address.ToString());
    }
    return out;
}

void AppendEndpoint(std::vector<rc::NetAddress>& out, const rc::NetAddress& address, bool dual_stack) {
    if (!address.valid() || (address.v6 && !dual_stack) || out.size() >= 32) return;
    if (std::find(out.begin(), out.end(), address) == out.end()) out.push_back(address);
}

void AppendEndpoints(std::vector<rc::NetAddress>& out, const nlohmann::json& values, bool dual_stack) {
    if (!values.is_array()) return;
    for (const auto& value : values) {
        if (!value.is_string() || out.size() >= 32) continue;
        rc::NetAddress address;
        if (rc::NetAddress::ParseEndpoint(value.get<std::string>(), address)) AppendEndpoint(out, address, dual_stack);
    }
}

void ClearSecret(std::string& value) {
    if (!value.empty()) rc::crypto::Wipe(value.data(), value.size());
    value.clear();
}
void ClearSecret(std::vector<uint8_t>& value) {
    if (!value.empty()) rc::crypto::Wipe(value.data(), value.size());
    value.clear();
}

bool EligibleUnicastDiscoveryInterface(const rc::NetInterface& interface) {
    return !interface.isVirtual && interface.name.rfind("en", 0) == 0 && rc::IsPrivateLan(interface.ip);
}

uint32_t UnicastDiscoveryMask(const rc::NetInterface& interface) {
    return std::max(interface.netmask, 0xFFFFFF00u);
}

bool InDiscoverySubnet(uint32_t address, const rc::NetInterface& interface) {
    const uint32_t mask = UnicastDiscoveryMask(interface);
    return (address & mask) == (interface.ip & mask);
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
    // unicast_discovery 连 SO_BROADCAST 都不开启，避免 iOS 原始广播 entitlement 检查。
    if (!m_discovery_socket.Open(0, !m_config.unicast_discovery)) {
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
    m_remote = false;
    m_remote_session.clear();
    m_rendezvous.clear();
    m_pc_addresses.clear();
    m_peers.clear();
    m_remote_registered = false;
    m_last_register_ns = 0;
    m_last_path_probe_ns = 0;
    clear_remote_secrets();
    m_monitors.clear();
    m_streams.clear();
    m_reassemblers.clear();
    m_last_good_frame.clear();
    m_pending_keyframe.clear();
    m_waiting_recovery.clear();
    m_server_info = nlohmann::json::object();
    m_server_settings = nlohmann::json::object();
    m_server_stats = nlohmann::json::object();
    m_stream_stats.clear();
    m_stats_window_frames.clear();
    m_stats_window_bytes.clear();
    m_stats_window_ns = 0;
    m_fragments_received = 0;
    m_fragments_recovered = 0;
    m_fragments_lost = 0;

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

bool Session::connect_remote(const nlohmann::json& offer) {
    if (!offer.is_object()) {
        set_state(State::Failed, "Invalid RinCast connection offer");
        return false;
    }
    const auto string_field = [&](const char* name) -> std::string {
        if (!offer.contains(name) || !offer[name].is_string()) return {};
        return offer[name].get<std::string>();
    };

    const std::string session_id = string_field("sessionId");
    const std::string connect_secret = string_field("connectSecret");
    std::string relay_token = string_field("relayToken");
    if (relay_token.empty()) relay_token = string_field("sessionToken");
    if (session_id.empty() || session_id.size() > 256 || connect_secret.empty() || connect_secret.size() > 512 ||
        relay_token.empty() || relay_token.size() > 512) {
        set_state(State::Failed, "RinCast connection offer is missing credentials");
        return false;
    }

    std::vector<rc::NetAddress> rendezvous;
    if (!offer.contains("rendezvous")) {
        set_state(State::Failed, "RinCast connection offer is missing rendezvous");
        return false;
    }
    const auto& rv = offer["rendezvous"];
    if (rv.is_object()) {
        if (!rv.contains("host") || !rv["host"].is_string() || !rv.contains("port") || !rv["port"].is_number_integer()) {
            set_state(State::Failed, "Invalid RinCast rendezvous endpoint");
            return false;
        }
        const int port = rv["port"].get<int>();
        if (port <= 0 || port > 65535) {
            set_state(State::Failed, "Invalid RinCast rendezvous endpoint");
            return false;
        }
        rendezvous = rc::NetAddress::ResolveAll(rv["host"].get<std::string>(), uint16_t(port));
    } else if (rv.is_array()) {
        AppendEndpoints(rendezvous, rv, true);
    }
    if (rendezvous.empty()) {
        set_state(State::Failed, "Cannot resolve the RinCast rendezvous endpoint");
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
    m_server_stats = nlohmann::json::object();
    m_stream_stats.clear();
    m_stats_window_frames.clear();
    m_stats_window_bytes.clear();
    m_stats_window_ns = 0;
    m_fragments_received = 0;
    m_fragments_recovered = 0;
    m_fragments_lost = 0;
    m_pc_addresses.clear();
    m_peers.clear();
    clear_remote_secrets();

    std::string error;
    if (!open_stream_socket(error)) {
        set_state(State::Failed, error);
        return false;
    }
    const bool dual_stack = m_socket.DualStack();
    if (!dual_stack) {
        std::erase_if(rendezvous, [](const rc::NetAddress& address) { return address.v6; });
        if (rendezvous.empty()) {
            m_socket.Close();
            set_state(State::Failed, "The RinCast rendezvous is IPv6-only on this network");
            return false;
        }
    }

    m_remote = true;
    m_remote_session = session_id;
    m_connect_secret = connect_secret;
    m_relay_token = relay_token;
    m_rendezvous = std::move(rendezvous);
    m_remote_registered = false;
    m_last_register_ns = 0;
    m_last_path_probe_ns = 0;
    const std::string offered_name = string_field("pcName");
    m_target_name = offered_name.empty() ? "RinCast PC" : offered_name;
    if (offer.contains("pcLocalAddrs")) AppendEndpoints(m_pc_addresses, offer["pcLocalAddrs"], dual_stack);
    if (offer.contains("candidates")) AppendEndpoints(m_pc_addresses, offer["candidates"], dual_stack);

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
                            {"settings", m_config.settings},
                            {"cloudSession", m_remote_session},
                            {"proof", rc::HelloProof(m_connect_secret, m_keys.publicKey)}};
    const auto identity_key = rc::crypto::IdentityPublicKey(m_identity);
    const auto signature = rc::crypto::SignConnection(m_identity, m_keys.publicKey, m_client_nonce);
    hello["deviceKey"] = rc::HexEncode(identity_key.data(), identity_key.size());
    hello["deviceSig"] = rc::HexEncode(signature.data(), signature.size());

    m_hello = {};
    m_hello.type = rc::PacketType::Hello;
    m_hello.publicKey = m_keys.publicKey;
    m_hello.json = hello.dump();
    m_hello_bytes = rc::BuildHandshake(m_hello);

    const nlohmann::json register_message = {{"op", "register"},
                                             {"session", m_remote_session},
                                             {"role", 1},
                                             {"token", m_relay_token},
                                             {"candidates", OwnCandidates(m_socket.LocalPort(), dual_stack)}};
    const std::string register_json = "RCRV" + register_message.dump();
    m_register_bytes.assign(register_json.begin(), register_json.end());

    const int64_t now = rc::NowNs();
    m_session_start_ns = now;
    refresh_remote_candidates();
    const bool has_lan_candidate = std::any_of(
        m_path_candidates.begin(), m_path_candidates.end(),
        [](const RemotePathCandidate& candidate) { return candidate.preference == kLanPathPreference; });
    const bool has_public_candidate = std::any_of(
        m_path_candidates.begin(), m_path_candidates.end(),
        [](const RemotePathCandidate& candidate) { return candidate.preference == kPublicPathPreference; });
    m_public_race_start_ns = now + (has_lan_candidate ? kLanHeadStartNs : 0);
    m_vpn_race_start_ns = m_public_race_start_ns + (has_public_candidate ? kLanHeadStartNs : 0);
    m_deadline_ns = now + kConnectTimeoutNs;
    m_last_hello_ns = 0;
    m_last_feedback_ns = now;
    m_feedback_now = false;
    set_state(State::Connecting, "Connecting to " + m_target_name + " through RinCast...");
    send_remote_register(now);
    send_remote_hellos(now);
    return true;
}

void Session::send_hello(int64_t now_ns) {
    if (m_remote) {
        send_remote_hellos(now_ns);
        return;
    }
    if (!m_target || m_hello_bytes.empty()) return;
    m_socket.SendTo(*m_target, m_hello_bytes.data(), m_hello_bytes.size());
    m_last_hello_ns = now_ns;
}

void Session::clear_remote_secrets() {
    crypto_wipe(m_connect_secret.data(), m_connect_secret.size());
    crypto_wipe(m_relay_token.data(), m_relay_token.size());
    crypto_wipe(m_register_bytes.data(), m_register_bytes.size());
    m_connect_secret.clear();
    m_relay_token.clear();
    m_register_bytes.clear();
    m_path_candidates.clear();
    m_observed_local_v4.reset();
    m_observed_local_v6.reset();
    m_diagnostic_peer.reset();
    m_public_race_start_ns = 0;
    m_vpn_race_start_ns = 0;
    m_last_path_switch_ns = 0;
}

void Session::send_remote_register(int64_t now_ns) {
    if (!m_remote || m_register_bytes.empty() || m_rendezvous.empty()) return;
    const int64_t interval = m_remote_registered ? 3'000'000'000LL : 300'000'000LL;
    if (m_last_register_ns && now_ns - m_last_register_ns < interval) return;
    for (const auto& address : m_rendezvous) m_socket.SendTo(address, m_register_bytes.data(), m_register_bytes.size());
    m_last_register_ns = now_ns;
}

void Session::send_remote_hellos(int64_t now_ns) {
    if (!m_remote || m_hello_bytes.empty()) return;
    const bool guess_ports = now_ns - m_session_start_ns < 10'000'000'000LL;
    for (auto& candidate : m_path_candidates) {
        const bool eligible = candidate.preference == kLanPathPreference ||
                              (candidate.preference == kPublicPathPreference && now_ns >= m_public_race_start_ns) ||
                              (candidate.preference == kVpnPathPreference && now_ns >= m_vpn_race_start_ns);
        if (!eligible) continue;
        SendWithPortGuesses(m_socket, candidate.endpoint, m_hello_bytes.data(), m_hello_bytes.size(),
                            candidate.guess_ports && guess_ports);
        candidate.last_hello_ns = now_ns;
    }
    m_last_hello_ns = now_ns;
}

void Session::refresh_remote_candidates() {
    if (!m_remote) return;
    const auto interfaces = rc::ListInterfaces();
    const auto add = [this, &interfaces](const rc::NetAddress& endpoint, bool guess_ports) {
        const auto preference = RemotePathPreference(endpoint, interfaces);
        if (!preference) return;
        auto existing = std::find_if(m_path_candidates.begin(), m_path_candidates.end(),
                                     [&](const RemotePathCandidate& candidate) {
                                         return candidate.endpoint == endpoint;
                                     });
        if (existing != m_path_candidates.end()) {
            existing->guess_ports = existing->guess_ports || guess_ports;
            return;
        }
        RemotePathCandidate candidate;
        candidate.endpoint = endpoint;
        candidate.preference = *preference;
        candidate.guess_ports = guess_ports;
        m_path_candidates.push_back(candidate);
    };
    for (const auto& endpoint : m_pc_addresses) add(endpoint, false);
    for (const auto& endpoint : m_peers) add(endpoint, true);
}

void Session::record_path_response(const rc::NetAddress& from, int64_t now_ns) {
    auto candidate = std::find_if(m_path_candidates.begin(), m_path_candidates.end(),
                                  [&](const RemotePathCandidate& value) { return value.endpoint == from; });
    if (candidate == m_path_candidates.end() || candidate->last_hello_ns == 0) return;
    const int64_t elapsed = now_ns - candidate->last_hello_ns;
    if (elapsed < 0 || elapsed > 5'000'000'000LL) return;
    const double sample = rc::NsToMs(elapsed);
    candidate->response_ms = candidate->response_samples == 0 ? sample
                                                               : candidate->response_ms * 0.75 + sample * 0.25;
    candidate->response_samples = std::min<uint32_t>(candidate->response_samples + 1, 1024);
}

bool Session::should_switch_remote_path(const rc::NetAddress& from, int64_t now_ns) const {
    if (!m_remote || !m_connection || from == m_connection->Remote()) return false;
    if (m_last_path_switch_ns && now_ns - m_last_path_switch_ns < kPathSwitchCooldownNs) return false;
    const auto selected = m_connection->Remote();
    std::vector<rc::NetInterface> interfaces;
    bool have_interfaces = false;
    const auto resolve = [&](const rc::NetAddress& endpoint) -> std::optional<uint8_t> {
        const auto candidate = std::find_if(m_path_candidates.begin(), m_path_candidates.end(),
                                            [&](const RemotePathCandidate& value) {
                                                return value.endpoint == endpoint;
                                            });
        if (candidate != m_path_candidates.end()) return candidate->preference;
        if (!have_interfaces) {
            interfaces = rc::ListInterfaces();
            have_interfaces = true;
        }
        return RemotePathPreference(endpoint, interfaces);
    };

    const auto next = resolve(from);
    if (!next) return false;

    const bool current_unresponsive = now_ns - m_connection->LastReceiveNs() > kPathFallbackNs;
    if (current_unresponsive) return true;

    const auto current = resolve(selected);
    if (!current || *next > *current) return true;
    if (*next != *current) return false;

    const auto candidate = std::find_if(m_path_candidates.begin(), m_path_candidates.end(),
                                        [&](const RemotePathCandidate& value) { return value.endpoint == from; });
    const double current_rtt = m_connection->Stats().rttMs;
    if (m_last_path_switch_ns && now_ns - m_last_path_switch_ns < kRttSwitchCooldownNs) return false;
    if (candidate == m_path_candidates.end() || candidate->response_samples < 3 || current_rtt <= 0) return false;
    const double margin = std::max(10.0, current_rtt * 0.25);
    return candidate->response_ms + margin < current_rtt;
}

void Session::handle_rendezvous(const uint8_t* data, size_t size, const rc::NetAddress& from) {
    if (!m_remote || size <= 4 || std::find(m_rendezvous.begin(), m_rendezvous.end(), from) == m_rendezvous.end()) return;
    nlohmann::json message = nlohmann::json::parse(reinterpret_cast<const char*>(data) + 4,
                                                   reinterpret_cast<const char*>(data) + size, nullptr, false);
    if (!message.is_object() || !message.contains("op") || !message["op"].is_string() ||
        message["op"] != "registered" || (message.contains("session") && message["session"] != m_remote_session) ||
        (message.contains("role") && message["role"] != 1)) {
        return;
    }

    if (const auto self = message.find("self"); self != message.end() && self->is_string()) {
        rc::NetAddress endpoint;
        if (rc::NetAddress::ParseEndpoint(self->get<std::string>(), endpoint) && endpoint.valid()) {
            (endpoint.v6 ? m_observed_local_v6 : m_observed_local_v4) = endpoint;
        }
    }

    bool added = false;
    const bool dual_stack = m_socket.DualStack();
    auto add_endpoint = [&](const nlohmann::json& value) {
        if (!value.is_string() || m_peers.size() >= 32) return;
        rc::NetAddress address;
        if (!rc::NetAddress::ParseEndpoint(value.get<std::string>(), address)) return;
        if (address.v6 && !dual_stack) return;
        if (std::find(m_peers.begin(), m_peers.end(), address) == m_peers.end()) {
            m_peers.push_back(address);
            added = true;
        }
    };
    if (message.contains("peer")) add_endpoint(message["peer"]);
    if (message.contains("peers") && message["peers"].is_array()) {
        for (const auto& peer : message["peers"]) add_endpoint(peer);
    }
    m_remote_registered = true;
    if (added) {
        refresh_remote_candidates();
        send_remote_hellos(rc::NowNs());
    }
}

void Session::probe_remote_paths(int64_t now_ns) {
    if (!m_remote || !m_connection) return;
    const bool current_unresponsive = now_ns - m_connection->LastReceiveNs() > kPathFallbackNs;
    const int64_t interval = current_unresponsive ? 200'000'000LL
                                                   : now_ns - m_session_start_ns < 10'000'000'000LL
                                                         ? 500'000'000LL
                                                         : 5'000'000'000LL;
    if (m_last_path_probe_ns && now_ns - m_last_path_probe_ns < interval) return;
    m_last_path_probe_ns = now_ns;

    const rc::NetAddress selected = m_connection->Remote();
    const auto selected_candidate = std::find_if(m_path_candidates.begin(), m_path_candidates.end(),
                                                 [&](const RemotePathCandidate& candidate) {
                                                     return candidate.endpoint == selected;
                                                 });
    const auto current = selected_candidate != m_path_candidates.end()
                             ? std::optional<uint8_t>(selected_candidate->preference)
                             : RemotePathPreference(selected, rc::ListInterfaces());
    const bool guess_ports = current_unresponsive || now_ns - m_session_start_ns < 10'000'000'000LL;
    for (auto& candidate : m_path_candidates) {
        if (candidate.endpoint == selected) continue;
        const bool try_path = current_unresponsive || !current || candidate.preference >= *current;
        if (!try_path) continue;
        SendWithPortGuesses(m_socket, candidate.endpoint, m_hello_bytes.data(), m_hello_bytes.size(),
                            candidate.guess_ports && guess_ports);
        candidate.last_hello_ns = now_ns;
    }
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
        if (m_config.unicast_discovery) {
            const auto interfaces = rc::ListInterfaces();
            for (const auto& host : m_hosts) {
                if (!host.endpoint.valid() || host.endpoint.v6 || !rc::IsPrivateLan(host.endpoint.ip)) continue;
                const bool connected_subnet = std::any_of(interfaces.begin(), interfaces.end(), [&](const auto& interface) {
                    return EligibleUnicastDiscoveryInterface(interface) && InDiscoverySubnet(host.endpoint.ip, interface);
                });
                if (!connected_subnet) continue;
                rc::NetAddress discovery = host.endpoint;
                discovery.port = rc::kDiscoveryPort;
                m_discovery_socket.SendTo(discovery, bytes.data(), bytes.size());
            }
        } else {
            for (const auto& interface : rc::ListInterfaces()) {
                if (interface.isVirtual) continue;
                m_discovery_socket.SendTo({interface.broadcast(), rc::kDiscoveryPort}, bytes.data(), bytes.size());
            }
            m_discovery_socket.SendTo(rc::NetAddress::Broadcast(rc::kDiscoveryPort), bytes.data(), bytes.size());
            for (const auto& host : m_hosts) {
                if (host.endpoint.valid()) {
                    rc::NetAddress discovery = host.endpoint;
                    discovery.port = rc::kDiscoveryPort;
                    m_discovery_socket.SendTo(discovery, bytes.data(), bytes.size());
                }
            }
        }
        m_last_probe_ns = now_ns;
    }

    if (m_state == State::Idle || m_state == State::Failed) {
        if (m_sweep_index >= m_sweep_hosts.size() &&
            (m_last_sweep_ns == 0 || now_ns - m_last_sweep_ns > (m_hosts.empty() ? 30'000'000'000LL
                                                                                : 120'000'000'000LL))) {
            m_sweep_hosts.clear();
            for (const auto& interface : rc::ListInterfaces()) {
                if (m_config.unicast_discovery) {
                    if (!EligibleUnicastDiscoveryInterface(interface)) continue;
                    // 保留 /25–/32 等更窄实际网段；更宽的前缀最多按 /24 覆盖邻接集合。
                    for (const uint32_t address : rc::SubnetHosts(interface.ip, UnicastDiscoveryMask(interface), 254)) {
                        if (m_sweep_hosts.size() >= 256) break;
                        m_sweep_hosts.push_back(address);
                    }
                } else {
                    if (interface.isVirtual || (!rc::IsPrivateLan(interface.ip) && (interface.ip >> 16) != 0xA9FE)) continue;
                    for (const uint32_t address : rc::SubnetHosts(interface.ip, interface.netmask, 1024)) {
                        m_sweep_hosts.push_back(address);
                    }
                }
            }
            m_sweep_index = 0;
            m_last_sweep_ns = now_ns;
        }
        if (m_sweep_index < m_sweep_hosts.size() && now_ns - m_last_sweep_batch_ns >= 100'000'000LL) {
            const rc::DiscoveryProbe probe{m_device_id, m_config.device_name, m_probe_nonce};
            const auto bytes = rc::BuildProbe(probe);
            for (int count = 0; count < 12 && m_sweep_index < m_sweep_hosts.size(); ++count, ++m_sweep_index) {
                m_discovery_socket.SendTo({m_sweep_hosts[m_sweep_index], rc::kDiscoveryPort}, bytes.data(), bytes.size());
            }
            m_last_sweep_batch_ns = now_ns;
        }
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
        host.address_seen_ns = host.last_seen_ns;

        auto existing = std::find_if(m_hosts.begin(), m_hosts.end(),
                                     [&](const Host& value) { return value.id == host.id; });
        if (existing == m_hosts.end()) m_hosts.push_back(std::move(host));
        else {
            const int old_rank = DiscoveryPathRank(existing->endpoint);
            const int new_rank = DiscoveryPathRank(host.endpoint);
            const bool same_address = existing->endpoint == host.endpoint;
            const bool current_stale = host.last_seen_ns - existing->address_seen_ns > 12'000'000'000LL;
            const bool replace = new_rank > old_rank || (same_address) ||
                                 (new_rank == old_rank && host.last_seen_ns - existing->address_seen_ns > 6'000'000'000LL) ||
                                 current_stale;
            if (replace) {
                *existing = std::move(host);
            } else {
                existing->name = host.name;
                existing->version = host.version;
                existing->os = host.os;
                existing->gpu = host.gpu;
                existing->busy = host.busy;
                existing->account_linked = host.account_linked;
                existing->account_name = host.account_name;
                existing->last_seen_ns = host.last_seen_ns;
            }
        }
    }

    m_hosts.erase(std::remove_if(m_hosts.begin(), m_hosts.end(),
                                 [&](const Host& host) { return now_ns - host.last_seen_ns > kHostTimeoutNs; }),
                  m_hosts.end());
    std::sort(m_hosts.begin(), m_hosts.end(), [](const Host& a, const Host& b) {
        if (DiscoveryPathRank(a.endpoint) != DiscoveryPathRank(b.endpoint)) {
            return DiscoveryPathRank(a.endpoint) > DiscoveryPathRank(b.endpoint);
        }
        if (a.name != b.name) return a.name < b.name;
        return a.id < b.id;
    });
}

void Session::pump_handshake(int64_t now_ns) {
    if (m_remote) send_remote_register(now_ns);
    if (now_ns - m_last_hello_ns >= kHelloIntervalNs) send_hello(now_ns);

    uint8_t buffer[2048];
    rc::NetAddress from;
    for (int packet = 0; packet < 32 && m_state != State::Connected; ++packet) {
        const int size = m_socket.RecvFrom(buffer, sizeof(buffer), from, 0);
        if (size <= 0) break;
        if (size >= 4 && std::memcmp(buffer, "RCRV", 4) == 0) {
            handle_rendezvous(buffer, size_t(size), from);
            continue;
        }
        handle_handshake(buffer, size_t(size), from, now_ns);
        if (m_state == State::Failed) break;
    }

    if (m_state != State::Connected && m_state != State::Failed && now_ns > m_deadline_ns) {
        const std::string timeout = m_state == State::WaitingApproval
                                        ? "Approval timed out on the host"
                                        : m_remote ? (m_remote_registered ? "No direct route to the PC was possible"
                                                                         : "The RinCast rendezvous did not respond")
                                                   : "The host did not respond";
        set_state(State::Failed, timeout);
        m_socket.Close();
        m_target.reset();
    }
    if (m_state == State::Failed) {
        m_socket.Close();
        m_target.reset();
        m_hello_bytes.clear();
        clear_remote_secrets();
    }
}

void Session::handle_handshake(const uint8_t* data, size_t size, const rc::NetAddress& from, int64_t now_ns) {
    if (!m_remote && (!m_target || !SamePeer(from, *m_target))) return;
    if (m_remote) {
        const bool known = std::any_of(m_path_candidates.begin(), m_path_candidates.end(),
                                       [&](const RemotePathCandidate& candidate) {
                                           return candidate.endpoint == from;
                                       });
        if (!known && !RemotePathPreference(from, rc::ListInterfaces())) return;
    }

    rc::HandshakePacket reply;
    if (!rc::ParseHandshake(data, size, reply)) return;

    if (reply.type == rc::PacketType::Reject) {
        if (m_remote && std::none_of(m_path_candidates.begin(), m_path_candidates.end(),
                                      [&](const RemotePathCandidate& candidate) {
                                          return candidate.last_hello_ns && SamePeer(candidate.endpoint, from);
                                      })) return;
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
    if (m_remote) {
        const std::string expected = rc::WelcomeProof(m_connect_secret, reply.publicKey, m_keys.publicKey);
        if (!welcome.contains("proof") || !welcome["proof"].is_string() ||
            welcome["proof"].get<std::string>() != expected) {
            RC_LOGW("Ignored remote Welcome with an invalid proof");
            return;
        }
    }
    record_path_response(from, now_ns);

    const auto keys = rc::crypto::DeriveSessionKeys(
        m_keys.secretKey, reply.publicKey, m_keys.publicKey, reply.publicKey,
        rc::SessionContext(m_client_nonce, server_nonce, m_remote ? m_connect_secret : ""));
    const bool vpn = !m_remote && !from.v6 && rc::RoutesThroughTunnel(from.ip);
    auto connection = std::make_unique<rc::Connection>(&m_socket, from, reply.sessionId, keys, false,
                                                       m_remote || vpn ? rc::kMaxDatagramWan : rc::kMaxDatagramLan);
    connection->SetControlHandler([this](const std::string& text) { handle_control(text); });
    connection->SetPacketHandler(
        [this](rc::PacketType type, const uint8_t* payload, size_t payload_size) {
            handle_packet(type, payload, payload_size);
        });

    if (welcome.contains("name") && welcome["name"].is_string()) m_target_name = welcome["name"].get<std::string>();
    m_connection = std::move(connection);
    m_last_feedback_ns = now_ns;
    m_last_path_probe_ns = now_ns;
    set_state(State::Connected, "Connected to " + m_target_name);

    if (m_remote) {
        ClearSecret(m_relay_token);
        ClearSecret(m_register_bytes);
    }

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
        if (size >= 4 && std::memcmp(buffer, "RCRV", 4) == 0) {
            handle_rendezvous(buffer, size_t(size), from);
            continue;
        }
        if (rc::IsHandshakeDatagram(buffer, size_t(size))) {
            if (m_remote) {
                rc::HandshakePacket late;
                if (rc::ParseHandshake(buffer, size_t(size), late) && late.type == rc::PacketType::Welcome &&
                    late.sessionId == m_connection->SessionId()) {
                    const auto welcome = ParsedObject(late.json);
                    const std::string expected = rc::WelcomeProof(m_connect_secret, late.publicKey, m_keys.publicKey);
                    if (welcome.contains("proof") && welcome["proof"].is_string() &&
                        welcome["proof"].get<std::string>() == expected) {
                        record_path_response(from, now_ns);
                        if (should_switch_remote_path(from, now_ns)) {
                            RC_LOGI("Switching remote path %s -> %s", m_connection->Remote().ToString().c_str(),
                                    from.ToString().c_str());
                            m_connection->SetRemote(from);
                            m_last_path_switch_ns = now_ns;
                        }
                    }
                }
            }
            continue;
        }
        m_connection->HandleDatagram(buffer, size_t(size), from);
        if (m_connection->PeerDisconnected()) break;
    }

    m_connection->Tick(now_ns);
    probe_remote_paths(now_ns);
    update_stats_window(now_ns);
    const bool urgent = m_feedback_now && now_ns - m_last_feedback_ns >= 5'000'000LL;
    if (urgent || now_ns - m_last_feedback_ns >= 100'000'000LL) send_feedback(now_ns);

    if (m_connection->PeerDisconnected() || now_ns - m_connection->LastReceiveNs() > kDisconnectTimeoutNs) {
        const bool remote = m_connection->PeerDisconnected();
        release_controls();
        m_connection.reset();
        m_socket.Close();
        m_target.reset();
        m_pc_addresses.clear();
        m_peers.clear();
        m_reassemblers.clear();
        m_waiting_recovery.clear();
        m_streams.clear();
        m_stream_stats.clear();
        m_stats_window_frames.clear();
        m_stats_window_bytes.clear();
        m_server_stats = nlohmann::json::object();
        clear_remote_secrets();
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
    } else if (type == rc::msg::kServerStats) {
        m_server_stats = message;
        if (message.contains("desktop") && message["desktop"].is_array()) {
            for (const auto& item : message["desktop"]) {
                if (!item.is_object()) continue;
                const int id = item.value("streamId", 0);
                if (id < int(rc::kFirstMonitorStreamId) || id >= int(rc::kMaxStreams)) continue;
                auto& stats = m_stream_stats[uint8_t(id)];
                stats.stream_id = uint8_t(id);
                stats.server_fps = item.value("fps", 0.0);
                stats.server_encode_ms = item.value("encodeMs", 0.0);
                stats.server_mbps = item.value("mbps", 0.0);
                stats.target_bitrate_kbps = item.value("bitrateKbps", 0u);
                stats.server_frames_lost = item.value("framesLost", 0u);
                stats.updated_ns = rc::NowNs();
            }
        }
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
        m_stream_stats.clear();
        m_stats_window_frames.clear();
        m_stats_window_bytes.clear();
        m_stats_window_ns = 0;
        for (const uint8_t id : active) {
            m_last_good_frame[id] = 0;
            m_pending_keyframe[id] = true;
            m_waiting_recovery[id] = true;
            m_stream_stats[id].stream_id = id;
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
                    auto& stats = m_stream_stats[stream_id];
                    stats.stream_id = stream_id;
                    stats.last_frame = frame_index;
                    ++stats.frames_received;
                    ++m_stats_window_frames[stream_id];
                    stats.network_ms = rc::NsToMs(frame.completeNs - frame.firstFragmentNs);
                    if (frame.metadata.size() >= sizeof(rc::DesktopFrameMetadata) && m_connection &&
                        m_connection->HasClockOffset()) {
                        rc::DesktopFrameMetadata metadata;
                        std::memcpy(&metadata, frame.metadata.data(), sizeof(metadata));
                        const int64_t encoded_local = m_connection->RemoteToLocalNs(metadata.pcEncodeEndNs);
                        const double measured = rc::NsToMs(frame.completeNs - encoded_local);
                        if (measured >= 0) stats.latency_ms = measured;
                    } else if (stats.latency_ms <= 0) {
                        stats.latency_ms = stats.network_ms;
                    }
                    stats.updated_ns = rc::NowNs();
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
        auto& local = m_stream_stats[stream_id];
        local.stream_id = stream_id;
        local.frames_lost += stats.framesLost;
        local.fragments_recovered += stats.fragmentsRecovered;
        local.network_ms = stats.framesComplete ? stats.spreadMsSum / stats.framesComplete : local.network_ms;
        m_stats_window_bytes[stream_id] += stats.bytesReceived;
        m_fragments_received += stats.fragmentsReceived;
        m_fragments_recovered += stats.fragmentsRecovered;
        m_fragments_lost += stats.fragmentsLost;
        local.updated_ns = now_ns;
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
        m_stream_stats.clear();
        m_stats_window_frames.clear();
        m_stats_window_bytes.clear();
        m_server_stats = nlohmann::json::object();
        if (m_callbacks.on_stream_config) m_callbacks.on_stream_config(m_streams);
    }
    return sent;
}

bool Session::update_settings(const nlohmann::json& settings) {
    if (!settings.is_object()) return false;
    if (!m_config.settings.is_object()) m_config.settings = nlohmann::json::object();
    m_config.settings.update(settings);
    if (!m_connection) return true;
    return send_control({{"type", rc::msg::kUpdateSettings}, {"settings", m_config.settings}});
}

void Session::set_decode_limits(uint32_t width, uint32_t height) {
    if (width == 0 || height == 0) return;
    if (!m_config.decoders.is_object()) m_config.decoders = nlohmann::json::object();
    m_config.decoders["maxWidth"] = width;
    m_config.decoders["maxHeight"] = height;
}

bool Session::focus_monitor(std::string monitor_id) {
    if (!m_connection) return false;
    return send_control({{"type", "desktop.active"}, {"monitorId", std::move(monitor_id)}});
}

bool Session::prefer_monitor(const std::string& monitor_id) { return focus_monitor(monitor_id); }

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

bool Session::send_mic(const uint8_t* opus_packet, size_t size) {
    if (!m_connection || !opus_packet || size == 0 || size > m_connection->MaxPayload() - sizeof(rc::AudioPacketHeader)) {
        return false;
    }
    rc::AudioPacketHeader header{};
    header.stream = uint8_t(rc::AudioStream::MicToPc);
    header.channels = 1;
    header.frameSamples = 480;
    header.sequence = m_mic_sequence + 1;
    header.timestampNs = uint64_t(rc::NowNs());
    if (!m_connection->Send2(rc::PacketType::Audio, &header, sizeof(header), opus_packet, size)) return false;
    m_mic_sequence = header.sequence;
    return true;
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

void Session::report_decode(uint8_t stream_id, double decode_ms, double latency_ms) {
    if (stream_id < rc::kFirstMonitorStreamId || stream_id >= rc::kMaxStreams || !std::isfinite(decode_ms) ||
        !std::isfinite(latency_ms)) {
        return;
    }
    auto& stats = m_stream_stats[stream_id];
    stats.stream_id = stream_id;
    stats.decode_ms = std::max(0.0, decode_ms);
    if (latency_ms > 0) stats.latency_ms = latency_ms;
    stats.updated_ns = rc::NowNs();
}

void Session::update_stats_window(int64_t now_ns) {
    if (m_stats_window_ns == 0) {
        m_stats_window_ns = now_ns;
        return;
    }
    const int64_t elapsed = now_ns - m_stats_window_ns;
    if (elapsed < 1'000'000'000LL) return;
    const double seconds = double(elapsed) / 1e9;
    for (auto& [stream_id, stats] : m_stream_stats) {
        const uint32_t frames = m_stats_window_frames[stream_id];
        const uint64_t bytes = m_stats_window_bytes[stream_id];
        stats.receive_fps = frames / seconds;
        stats.receive_mbps = double(bytes) * 8.0 / seconds / 1e6;
        stats.updated_ns = now_ns;
    }
    m_stats_window_frames.clear();
    m_stats_window_bytes.clear();
    m_stats_window_ns = now_ns;
}

Health Session::health() const {
    Health value;
    if (m_connection) {
        value.connection = m_connection->Stats();
        value.last_receive_age_ms = std::max<int64_t>(0, (rc::NowNs() - m_connection->LastReceiveNs()) / 1'000'000);
        value.clock_offset_ns = m_connection->ClockOffsetNs();
        value.clock_synchronized = m_connection->HasClockOffset();
        value.control_queue_chunks = m_connection->SendQueueChunks();
        const rc::NetAddress remote = m_connection->Remote();
        value.remote_endpoint = remote.ToString();
        if (m_diagnostic_peer != remote) {
            m_diagnostic_peer = remote;
            m_diagnostic_route = RouteName(remote);
            m_diagnostic_local_ip = LocalRouteIp(remote);
        }
        value.route = m_diagnostic_route;
        value.local_ip = m_diagnostic_local_ip;
        const auto& observed = remote.v6 ? m_observed_local_v6 : m_observed_local_v4;
        if (observed) value.observed_local_ip = observed->IpString();
    }
    value.fragments_received = m_fragments_received;
    value.fragments_recovered = m_fragments_recovered;
    value.fragments_lost = m_fragments_lost;
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
    clear_remote_secrets();
    set_state(State::Idle, m_config.discover ? "Searching for LAN hosts..." : "LAN discovery is disabled");
}

void Session::disconnect() {
    release_controls();
    if (m_connection) m_connection->SendDisconnect();
    m_connection.reset();
    m_socket.Close();
    m_target.reset();
    clear_remote_secrets();
    m_monitors.clear();
    m_streams.clear();
    m_reassemblers.clear();
    m_last_good_frame.clear();
    m_pending_keyframe.clear();
    m_waiting_recovery.clear();
    m_stream_stats.clear();
    m_stats_window_frames.clear();
    m_stats_window_bytes.clear();
    m_stats_window_ns = 0;
    m_server_stats = nlohmann::json::object();
    m_feedback_now = false;
    set_state(State::Idle, m_config.discover ? "Searching for LAN hosts..." : "LAN discovery is disabled");
}

}  // namespace rincast
