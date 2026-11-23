# FogShot 项目说明

FogShot 是普通显示器和触屏设备使用的 RinCast 客户端。Windows 和 macOS 桌面包也可以共享本机桌面。所有平台共用 Flutter 界面和原生串流核心。开发时优先用中文，按实际完成情况更新 `HISTORY.md`。

| 路径 | 职责 |
| --- | --- |
| `lib/main.dart`、`lib/lobby.dart`、`lib/stream_view.dart` | Flutter 会话生命周期、连接界面、画面与输入 |
| `lib/input.dart` | Flutter 物理按键到协议虚拟键的映射 |
| `lib/virtual_keyboard.dart`、`lib/stream_network.dart`、`lib/ip_location.dart` | 屏幕键盘、实时串流统计与 P2P 地址归属地 |
| `lib/desktop_settings*.dart`、`lib/microphone_permission.dart`、`lib/device_name.dart` | 串流偏好、重连设置、麦克风授权与系统设备名称 |
| `lib/account.dart`、`lib/account_panel.dart` | RinCast 登录、多账号凭据存储、主机列表与跨网连接 |
| `lib/client.dart`、`lib/native_bindings.dart` | Dart 客户端、FFI 类型、帧生命周期 |
| `lib/host_controller.dart`、`lib/host_dialog.dart`、`host/` | 桌面共享入口、内置主机生命周期与 RinCast Streamer 构建 |
| `src/bridge.h`、`src/bridge.cpp` | C ABI、会话工作线程、设备身份文件、最新画面与状态快照 |
| `src/session.*` | 局域网发现、账号引介、UDP 直连选路与认证、控制消息、视频组帧和输入 |
| `src/media.*` | 视频解码、颜色转换、Opus 播放与麦克风采集 |
| `CMakeLists.txt`、`cmake/`、`hook/` | 原生依赖、CMake 构建与 Flutter Native Assets 打包 |
| `android/`、`ios/`、`linux/`、`macos/`、`windows/` | Flutter 各平台运行器与权限 |
| `test/`、`licenses/` | Flutter 回归测试与第三方许可证 |

修改连接、输入或视频接收逻辑后，优先用实际 RinCast Streamer 验证。单独的编译、组件或模拟器测试应按验证范围记录。说明附加依赖的用途，保留上游版本锁定和许可证。
