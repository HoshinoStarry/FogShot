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
- Dart 静态分析和 15 项 Flutter 测试通过，覆盖窄屏串流顶栏、状态面板和 AV1 色深切换。Android CI 的插件依赖遇到 Maven Central 限流，已让 Gradle 插件依赖优先使用现有 Google 镜像。本地 Gradle 9.5 测试确认镜像顺序。
- 提交 `5e7f772` 的七项构建均通过架构校验，macOS 27 从该次构建的 DMG 安装并通过启动检查。下载的 Windows x64 包也通过 H.264 和 AV1 10 位双屏回环、指针路由与实时统计复验。[CI 与产物](https://github.com/HoshinoStarry/FogShot/actions/runs/44935793331)
- 排查 `ce4fba0` 引入的远端音频残留。断线清理原先嵌在视频非空条件内，可能保留本地 PCM 队列，并让 Dart 在断线时发出的 `mute(false)` 放出旧声音。原生媒体增加会话级本地播放门控，断线、退出和重连前独立于视频状态清空音频队列；`ResetAudio` 现在只在设备停止成功后重建队列。使用 miniaudio Null 后端的隔离回归覆盖静音、未激活、重置和并发控制，Windows 原生库重新编译通过；未改动正在使用的 Streamer 或系统音频设置。
- 统一 Dart 关窗、退出和页面销毁时的资源回收，取消待处理的重连。Mac 安装验证加入系统正常退出请求。
- 主界面只保留连接、附近主机、RinCast 账户和设置入口。设备码登录收到授权链接后自动打开系统浏览器，支持复制设备码及手动重开。
- 串流工具栏改为可闲置隐藏的浮动胶囊。网络面板按连接、收发、纠错和显示器组织实际会话数据。H.264 和 AV1 10 位双屏回环分别验证了逐屏编码和接收统计、有效地址以及上、下行流量。
- 账号串流优先探测可用的局域网候选，并行尝试公网 IPv4 和 IPv6。增加同类候选的响应时间比较与连接失去响应时的回退。独立 IPv4 和 IPv6 回环测试都在保持同一加密会话的情况下切换了端点。
- 24 项 Flutter 测试通过，覆盖 3 秒闲置隐藏、静音按钮、窄屏网络面板、账号入口与设备码浏览器请求。系统浏览器请求以模拟平台通道验证。
- 移除主界面的装饰性渐变，使用主题纯色。局域网发现关闭时，宽窗口也只展示直接连接入口。
- 缩短胶囊工具栏，网络入口只呈现质量图标与 RTT。音频弹出层加入即时本机音量和静音控制，确认音量后写入偏好。
- 从系统取得设备名称，应用用于发现、串流握手和账号登录。网络面板显示双方地址与 ip.sb 归属地，使用当前会话路径和同族引介观测值。
- 将旧单账号凭据迁移为多账号安全存储。主页列出所有已登录账号的主机，连接与重连按所属账号获取引介信息。
- 44 项 Flutter 测试和静态分析通过，覆盖跨账号同名主机标识的精确路由、凭据迁移和刷新、音量以及 ip.sb 查询。Windows 双屏回环验证串流握手报告系统传入的名称。RinCast 引介测试验证 IPv4 与 IPv6 的本机地址、引介观测和端点回退。
- 使用独立的原版 RinCast 服务实测两个账号登录、同时读取两台主机、恢复会话和分别获取连接信息。首轮 macOS 构建设备名称调用未正确处理 Swift 桥接类型，改为使用 Swift 已管理的 `CFString`。
- 实测 IP.SB 的响应使用 gzip，启用 Dart HTTP 客户端的自动解压后，公网 IPv4 和 IPv6 样本均能通过应用查询解析。
- 提交 `cc27938` 的七项平台与架构构建均通过，macOS 27.0.1 已从该版 DMG 实际启动并响应系统正常退出请求。[CI 与产物](https://github.com/HoshinoStarry/FogShot/actions/runs/44943870281)

## 2026-11-23

- 在桌面端加入「共享本机」，由 FogShot 控制内置 RinCast Streamer 的启动、停止、配对、设备信任和主机账户。上游 Linux 采集是占位实现，主机入口由可用组件决定。
- Windows 通过进程管道管理主机。macOS 由系统单独启动同一安装包中的主机组件，并验证本机连接。主机由系统管理录屏和辅助功能授权。
- Windows x64 内置主机构建、Dart 静态分析、45 项 Flutter 测试及工作流静态检查通过。
