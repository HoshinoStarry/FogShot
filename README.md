# FogShot

FogShot 是供 **Windows、Linux、macOS、Android、iOS** 使用的桌面串流客户端，应用标识为 `host.hoshino.fogshot`。五个平台共用 Flutter 界面。C++ 核心复用 RinCast 的 UDP 会话、加密、可靠控制和视频纠错实现。兼容性目标为 RinCast Streamer 的 **wire protocol 3**，项目锁定的上游版本是 `1.2.1`、提交 `10ebeb207a65fad7ea23ebdca038e59ccff2315b`。[RinCast 上游协议](https://github.com/TheReal-Flo/RinCast/blob/10ebeb207a65fad7ea23ebdca038e59ccff2315b/docs/PROTOCOL.md)

## 自动构建

每次向 `main` 推送、提交 PR、打 `v*` 标签或手动运行 workflow 后，构建包会出现在该次 GitHub Actions 的 **Artifacts** 中。[构建记录](https://github.com/HoshinoStarry/FogShot/actions/workflows/build.yml)

| 平台 | 产物 |
| --- | --- |
| Windows | x64、ARM64 便携 ZIP |
| Linux | x64、ARM64 tar.gz |
| macOS | x64 与 ARM64 通用 `.app` ZIP |
| Android | ARMv7、ARM64、x86_64 APK（CI 使用调试签名） |
| iOS | 未签名 ARM64 真机 `.app`，以及 x64、ARM64 模拟器 `.app` |

这些是 Flutter 3.50 正式支持的五个平台架构。iOS 真机包需要在 Xcode 签名后安装。[Flutter 平台支持矩阵](https://docs.flutter.dev/reference/supported-platforms)

## 连接和操作

1. 在主机打开 RinCast Streamer。客户端点击附近的主机，或输入 Streamer 首页显示的 IPv4 地址。默认串流端口是 UDP `38711`，也可填写 `192.168.1.42:38711`。
2. 首次连接时，在 Streamer 上允许配对。客户端保留本地设备身份，方便下次重连。
3. 默认打开主显示器。串流顶部可以切换显示器、发送文字、静音、隐藏工具栏或断开连接。
4. 桌面设备可直接在画面里使用鼠标和物理键盘。触屏上单击、长按、拖动和双指滑动分别对应左键、右键、左键拖动和滚动。输入中文等文字时，使用工具栏的键盘按钮打开输入框。

iOS 默认使用手动地址。第一次发起连接时允许系统弹出的「本地网络」权限。Apple 对设备上的 UDP 广播另设签名权限。[Apple 本地网络说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

首版使用 H.264 软件解码和 Opus 主机声音，一次播放一台显示器，以降低移动端负载。桌面默认请求 60 FPS，移动设备默认请求 30 FPS。实际帧率受主机、网络和客户端性能影响。RinCast 账号登录、公网引介、VR、麦克风回传和硬件视频解码暂未实现。客户端沿用上游局域网配对模型，局域网模式适用于可信网络。

## 从源码构建

安装 Flutter 3.50.1、CMake 3.24 或以上及目标平台工具链。初次构建需下载固定版本的原生依赖。在项目目录运行 `flutter pub get`，随后按目标平台构建。

| 平台 | 工具链 | 命令 |
| --- | --- | --- |
| Windows | Visual Studio 的「使用 C++ 的桌面开发」工作负载 | `flutter build windows --release` |
| Linux | Clang、Ninja、pkg-config、GTK 3 开发库 | `flutter build linux --release` |
| Android | Android SDK、NDK、JDK、Ninja | `flutter build apk --release --split-per-abi` |
| macOS | Xcode 与命令行工具 | `flutter build macos --release` |
| iOS | macOS 上的 Xcode | `flutter build ios --release --no-codesign` |

真机 iOS 安装需要用自己的 Apple Team 和描述文件签名。可以用 `flutter build ios --simulator` 检查模拟器构建。各平台的实际验证范围见 `HISTORY.md`。

开发检查使用 `flutter analyze` 和 `flutter test`。桌面端可传入 `--connect <IPv4[:port]>` 直接打开会话。可以用 `cmake -S . -B build/native`、`cmake --build build/native --config Release` 单独构建原生后端。

## 实现与许可

Flutter 负责连接界面、视频显示、键鼠和触控。C++ 后台线程负责网络、音视频解码和回传。Flutter 逐帧读取最新的 BGRA 缓冲，控件和输入逻辑在五个平台共享。

项目采用 MIT 许可证。第三方授权见 `licenses/`，包括 RinCast、OpenH264、Opus、Monocypher、nlohmann/json、libyuv 和 miniaudio。
