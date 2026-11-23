#ifdef _WIN32
#include <windows.h>
#elif defined(__APPLE__)
#include <arpa/inet.h>
#include <csignal>
#include <unistd.h>
#endif

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>

#include "app.h"
#include "settings.h"
#ifndef _WIN32
#include "platform/posix/platform_main.h"
#endif

namespace {
using rcs::json;
using namespace std::chrono_literals;
std::mutex output;

void Emit(const std::string& line) {
    const std::lock_guard lock(output);
    std::cout << line << '\n' << std::flush;
}

void Error(const char* message) {
    Emit(json{{"type", "error"}, {"message", message}}.dump());
}

void ReplyError(const json& command, const char* message) {
    Emit(json{{"type", "reply"}, {"requestId", command.value("requestId", "")},
              {"ok", false}, {"error", message}}.dump());
}

#ifdef __APPLE__
bool AttachToApp(const char* arg) {
    uint16_t port = 0;
    const std::string_view value(arg);
    const auto [end, error] = std::from_chars(value.data(), value.data() + value.size(), port);
    const char* raw = std::getenv("FOGSHOT_HOST_NONCE");
    if (error != std::errc() || end != value.data() + value.size() || !port || !raw) return false;
    const std::string nonce(raw);
    unsetenv("FOGSHOT_HOST_NONCE");
    if (nonce.size() != 64 || nonce.find_first_not_of("0123456789abcdef") != std::string::npos) return false;
    std::signal(SIGPIPE, SIG_IGN);
    const int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd == -1) return false;
    sockaddr_in loopback{};
    loopback.sin_family = AF_INET;
    loopback.sin_port = htons(port);
    loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    const bool attached = connect(fd, reinterpret_cast<const sockaddr*>(&loopback), sizeof(loopback)) == 0 &&
                          dup2(fd, STDIN_FILENO) >= 0 && dup2(fd, STDOUT_FILENO) >= 0;
    if (fd > STDOUT_FILENO) close(fd);
    if (attached) Emit(json{{"type", "hello"}, {"nonce", nonce}}.dump());
    return attached;
}
#endif

void RunCommand(const json& command, rcs::App& app) {
    const std::string type = command.value("type", "");
    if (type == "getState" || type == "signOut" || type == "disconnect") {
        app.HandleUiMessage(command.dump());
    } else if (type == "approve" || type == "deny" || type == "removeTrusted") {
        if (const auto id = command.value("deviceId", ""); !id.empty()) {
            if (type != "removeTrusted") {
                const auto state = app.StateJson();
                const auto& pending = state.at("pendingApproval");
                if (!pending.is_object() || pending.value("deviceId", "") != id) return;
            }
            app.HandleUiMessage(command.dump());
        }
    } else if (type == "signIn") {
        const auto email = command.value("email", ""), password = command.value("password", "");
        if (!email.empty() && !password.empty()) app.HandleUiMessage(command.dump());
    } else if (type == "setSettings") {
        const auto changes = command.value("settings", json::object());
        const auto current = rcs::SettingsStore::Get().Snapshot();
        const bool signedIn = !current.cloudRefreshTokenProtected.empty();
        auto settings = json::object();
        if (changes.contains("pcName") && changes["pcName"].is_string()) settings["pcName"] = changes["pcName"];
        if (changes.contains("allowRemote") && changes["allowRemote"].is_boolean() &&
            signedIn) {
            settings["allowRemote"] = changes["allowRemote"];
        }
        if (changes.contains("cloudUrl")) {
            const auto url = changes.value("cloudUrl", "");
            if (signedIn) return ReplyError(command, "退出主机账户后才能更改服务地址。");
            if (!url.starts_with("https://") || url.size() <= 8 || url[8] == '/' ||
                url.find_first_of("@?# \r\n\t") != std::string::npos) {
                return ReplyError(command, "请输入 HTTPS 服务地址。");
            }
            settings["cloudUrl"] = url;
        }
        auto request = command;
        request["settings"] = std::move(settings);
        app.HandleUiMessage(request.dump());
    }
}
}

int main(int argc, char** argv) {
    if (argc == 2 && std::string_view(argv[1]) == "--version") {
        Emit("FogShot Streamer " + rcs::App::Get().Version());
        return 0;
    }
#ifdef _WIN32
    rcs::ScopedCoInit com;
#else
#ifdef __APPLE__
    if (argc != 3 || std::string_view(argv[1]) != "--fogshot-ipc" || !AttachToApp(argv[2])) return 1;
#endif
    if (!rcs::PreparePlatform()) return 1;
#endif
    auto& app = rcs::App::Get();
    if (!app.Init()) {
        Error("无法启动 RinCast Streamer。");
        return 1;
    }
    app.SetUiSink(Emit);
    Emit(app.StateJson().dump());
    std::jthread ticker([&app](std::stop_token stopped) {
        while (!stopped.stop_requested()) {
            std::this_thread::sleep_for(1s);
            if (!stopped.stop_requested()) app.Tick();
        }
    });
    for (std::string line; std::getline(std::cin, line);) {
        try {
            const auto command = json::parse(line, nullptr, false);
            if (!command.is_object()) continue;
            if (command.value("type", "") == "stop") break;
            RunCommand(command, app);
        } catch (const json::exception&) {
        }
    }
    ticker.request_stop();
    ticker.join();
    app.SetUiSink(nullptr);
    app.Shutdown();
    return 0;
}
