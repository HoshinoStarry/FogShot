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
- Android SDK 安装完成后，Maven Central 对 CI Runner 返回 HTTP 429。Android CI 优先使用 Google Cloud 的 Maven Central 镜像，保留 Gradle Plugin Portal 和 Google Maven。
- macOS 通用包随后通过 x64 与 ARM64 校验并上传。iOS 已进入链接阶段，补上 miniaudio 所用的 Objective-C 运行时和系统框架，并保留详细构建日志。
- iOS ARM64 真机包已通过编译和架构校验。Android 原生钩子误选已预装的 NDK 27.3，ARM64 的 libyuv 编译报错。原生钩子固定使用和 Flutter Gradle 配置相同的 NDK 28.2，本机已用该版本编出 ARMv7 和 ARM64 原生库。
- 添加 RinCast 设备码授权、凭据安全存储、同账号主机列表与 UDP 引介。用独立的 RinCast 服务与测试 Streamer 通过设备码批准、账号主机查询和连接申请。清空直连候选后，FogShot 仍通过引介建连并解码 30 帧 2560×1600 桌面画面，测试 Streamer 记录了键鼠与中文文本回传。该测试在同一台 Windows 机器上运行。
- 用 IPv4 和 IPv6 分别复验只通过引介获取连接地址的情形。提交 `2dde88e` 的七项 GitHub Actions 构建全部通过，均生成了经过架构校验的产物。[验证记录](https://github.com/HoshinoStarry/FogShot/actions/runs/44925932245)
- 按上游 `/auth/login` 加入注册邮箱和密码登录，沿用设备身份、令牌安全存储和主机列表。`dart analyze` 通过，七项 Flutter 测试全部通过，覆盖密码错误、重试、令牌存储、密码遮蔽和窄屏布局。
- 排查 M2 上 macOS 27.3 Beta 的启动失败。旧 ZIP 内的主程序保留了执行权限和 ARM64/x64 切片。构建新增 DMG 和严格签名校验，并用 macOS 27 Runner 挂载发布包、复制应用及启动验证。
- macOS 27.0.1 Runner 复现启动失败。AMFI 拒绝由临时签名声明的 `keychain-access-groups`。删除 macOS 的该项权限，令牌改用 macOS 登录钥匙串。独立的上游 RinCast 服务验证了邮箱密码登录、主机查询和连接申请。
- 提交 `21095ae` 的七项平台构建通过。macOS 27.0.1 Runner 用发布 DMG 安装应用，严格校验签名后实际启动并持续运行。[CI 与发布包](https://github.com/HoshinoStarry/FogShot/actions/runs/44929978529)
- 重整串流顶栏和实时网络状态。新增多显示器平铺与独立指针路由、桌面帧率与码率设置、画面亮度、屏幕键盘、麦克风回传、自动连接与断线重连，加入私有子网单播发现和 AV1 解码。
- Windows 隔离回环测试分别解码两路 H.264 和 AV1 10 位视频，验证第二显示器的指针路由、实时状态快照和发往主机的 `stats.client`。Android ARM64 原生库交叉编译通过。HEVC 尚未接入。真实公网路径和移动设备麦克风回传需分别验收。
