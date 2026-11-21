# 开发记录

## 2026-11-21 · 0.1.0

1. 核对 RinCast `10ebeb207a65fad7ea23ebdca038e59ccff2315b` 的 MIT 许可证和协议 v3，通过固定提交复用上游加密、传输、纠错及 Opus 代码。
2. 按需求将统一界面切换为 Flutter，添加 Windows、Linux、macOS、Android 和 iOS 运行器。原生后端通过 Flutter Native Assets 打包。会话、软解码和声音在后台线程运行，界面上传最新画面。实现显示器切换、键鼠、触控和独立的 Unicode 文字输入框。
3. Windows 对接由同一上游提交构建的独立测试 Streamer。测试实例使用独立端口和配置，首连流程经过待批准状态。原生后端解码了 2560×1600 H.264 画面，处理了 210 个 Opus 包，主机端测试日志记录了鼠标坐标、点击、滚轮、按键抬起及中文输入。测试实例拦截输入注入，避免操作本机正在使用的窗口。
4. Windows Flutter Release 包启动后连入该测试实例，窗口实际显示了远端桌面。三个 Flutter 回归测试覆盖了地址、窄屏配对取消和物理键映射。Linux 原生库在 Ubuntu 24.04 WSL 构建通过。
5. iOS 默认使用手动 IPv4 地址。项目加入本地网络用途说明。macOS 同时声明沙盒的 UDP 客户端和服务器网络权限。
6. 应用户要求统一应用名 FogShot 与应用标识 `host.hoshino.fogshot`。添加 GitHub Actions 工作流，为 Flutter 支持的桌面、手机及 iOS 模拟器架构分别构建，并检查最终包和原生库的架构。

## 2026-11-22

- 按用户要求移除 CI 的 iOS 模拟器，只保留未签名的 ARM64 真机包。首轮 Linux x64 和 ARM64 构建通过。首轮 Android Runner 缺少 `sdkmanager`，加入显式的 SDK 和 NDK 安装步骤。
- 首轮 iOS 编译器将 miniaudio 的 AVAudioSession 头文件作为纯 C++ 处理，导致编译失败。将 iOS 的媒体实现交由 Objective-C++ 编译。
- 首轮 Windows x64、ARM64 已生成经架构校验的便携包。macOS 通用应用已编译，校验命令因 `lipo` 参数顺序失败，已修正命令。
