# FogShot

FogShot 是供 **Windows、Linux、macOS、Android、iOS** 使用的桌面串流客户端，应用标识为 `host.hoshino.fogshot`。五个平台共用 Flutter 界面。C++ 核心复用 RinCast 的 UDP 会话、加密、可靠控制和视频纠错实现。兼容性目标为 RinCast Streamer 的 **wire protocol 3**，项目锁定的上游版本是 `1.2.1`、提交 `10ebeb207a65fad7ea23ebdca038e59ccff2315b`。[RinCast 上游协议](https://github.com/TheReal-Flo/RinCast/blob/10ebeb207a65fad7ea23ebdca038e59ccff2315b/docs/PROTOCOL.md)

## 自动构建

每次向 `main` 推送、提交 PR、打 `v*` 标签或手动运行 workflow 后，构建包会出现在该次 GitHub Actions 的 **Artifacts** 中。[构建记录](https://github.com/HoshinoStarry/FogShot/actions/workflows/build.yml)

| 平台 | 产物 |
| --- | --- |
| Windows | x64、ARM64 便携 ZIP |
| Linux | x64、ARM64 tar.gz |
| macOS | x64 与 ARM64 通用 DMG 和 `.app` ZIP |
| Android | ARMv7、ARM64、x86_64 APK（CI 使用调试签名） |
| iOS | 未签名 ARM64 真机 `.app` |

这些是 Flutter 3.50 正式支持的五个平台架构。iOS 真机包需要在 Xcode 签名后安装。[Flutter 平台支持矩阵](https://docs.flutter.dev/reference/supported-platforms)

## 连接和操作

1. 在主机打开 RinCast Streamer。客户端点击附近的主机，或输入 Streamer 首页显示的 IPv4 或 IPv6 地址。串流默认使用 UDP `38711`。可填写 `192.168.1.42:38711` 或 `[2001:db8::42]:38711`。
2. 首次连接时，在 Streamer 上允许配对。客户端上报系统提供的设备名称，并保留本地设备身份。iOS 16 及以上按系统公开的名称上报。[Apple 设备名称接口](https://developer.apple.com/documentation/uikit/uidevice/name)
3. 默认打开主显示器。浮动工具栏可切换或平铺显示器，空闲 3 秒后隐藏。移动鼠标或点按画面顶部的短横即可唤回。音频按钮可调音量和静音，网络按钮显示质量图标和 RTT。
4. 桌面设备可直接在画面里使用鼠标和物理键盘。触屏上单击、长按、拖动和双指滑动分别对应左键、右键、左键拖动和滚动。键盘菜单提供屏幕 QWERTY 键盘、粘滞修饰键和独立文字输入框。
5. 串流设置提供自动、30、60、90 FPS、目标码率、自适应码率、解码尺寸、播放音量、亮度、自动连接和断线重连。解码尺寸在下次连接时生效。
6. 麦克风回传需要本机授权，并在 Streamer 配置可用的虚拟麦克风设备。

展开网络状态可看到实际地址、收发码率、丢包与纠错，以及各显示器的帧率和延迟。面板打开时使用 ip.sb 查询两端公网 IP 的归属地。本机优先展示 RinCast 引介服务观测到的同族 UDP 地址，也可展示明确标注的 HTTPS 出口地址。[IP.SB API](https://ip.sb/api/)

iOS 使用局域网单播探测，也可手动输入地址。第一次使用时请允许系统弹出的「本地网络」权限。[Apple 本地网络说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

## 账号与跨网络串流

1. 在主机的 RinCast Streamer 登录账号并允许远程连接。
2. 打开 FogShot 的 RinCast 账户，选择设备码登录后在系统浏览器确认，也可以使用 RinCast 邮箱与密码登录。
3. 可添加多个账号。主页同时显示各账号下的主机，点击一台在线主机就会使用它所属的账号。若 Streamer 要求首次配对，按主机提示允许。

默认使用 `https://rincast.com`。在 RinCast 账户设置中可配置自建服务的 HTTPS 地址。登录凭据由系统安全存储保存。RinCast 服务交换连接候选地址。FogShot 优先试可用的局域网地址，再并行尝试公网 IPv4 和 IPv6 直连。当前路径失去响应时会探测其他候选。画面和声音始终经由两端的 UDP 直连传输。[RinCast 账户和引介协议](https://github.com/TheReal-Flo/RinCast/blob/10ebeb207a65fad7ea23ebdca038e59ccff2315b/server/README.md)

桌面默认请求 60 FPS，移动设备默认请求 30 FPS。默认使用 H.264 软件解码。可选择 AV1，主机支持时可协商 10 位码流并转换为屏幕预览。HEVC 解码和硬件解码仍待接入。FogShot 沿用上游局域网配对模型，局域网模式适用于可信网络。

## 从源码构建

安装 Flutter 3.50.1、CMake 3.24 或以上、Python 3、Ninja 及目标平台工具链。初次构建需下载固定版本的原生依赖。在项目目录运行 `flutter pub get`，随后按目标平台构建。

| 平台 | 工具链 | 命令 |
| --- | --- | --- |
| Windows | Visual Studio 的「使用 C++ 的桌面开发」工作负载 | `flutter build windows --release` |
| Linux | Clang、Ninja、pkg-config、GTK 3、libsecret 和 jsoncpp 开发库 | `flutter build linux --release` |
| Android | Android SDK、NDK、JDK、Ninja | `flutter build apk --release --split-per-abi` |
| macOS | Xcode 与命令行工具 | `flutter build macos --release` |
| iOS | macOS 上的 Xcode | `flutter build ios --release --no-codesign` |

真机 iOS 安装需要用自己的 Apple Team 和描述文件签名。可以用 `flutter build ios --simulator` 检查模拟器构建。各平台的实际验证范围见 `HISTORY.md`。

开发检查使用 `flutter analyze` 和 `flutter test`。桌面端可传入 `--connect <IPv4[:port]>` 直接打开会话。可以用 `cmake -S . -B build/native`、`cmake --build build/native --config Release` 单独构建原生后端。

## 实现与许可

Flutter 负责连接界面、视频显示、键鼠和触控。C++ 后台线程负责网络、音视频解码和回传。Flutter 逐帧读取最新的 BGRA 缓冲，控件和输入逻辑在五个平台共享。

项目采用 MIT 许可证。第三方授权见 `licenses/`，包括 RinCast、OpenH264、dav1d、Opus、Monocypher、nlohmann/json、libyuv 和 miniaudio。
