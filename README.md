# ClashHM
HarmonyOS NEXT 平台的 Clash 代理客户端。当前数据面固定为 `VpnExtensionAbility` 内的 Rust/C++ native-core，不再保留 UI 进程 mihomo 或 tun2socks 回退路径。

## 功能特性

- **代理核心**：Extension 内嵌 Rust native-core，支持常见 Clash 节点解析和选中节点 TUN 转发
- **订阅管理**：支持导入标准 Clash 订阅链接，自动解析节点信息、流量用量和到期时间
- **代理切换**：代理组可视化管理，支持手动选择节点、延迟测试和自动选择
- **VPN 隧道**：通过 HarmonyOS `VpnExtensionAbility` 创建系统级 VPN 隧道，TUN fd 直接交给 Extension native-core
- **流量监控**：实时显示上传/下载速度、会话流量统计和活跃连接数
- **连接日志**：实时连接日志，支持按域名/规则/代理链过滤
- **当前状态**：native-core 为唯一运行核心；缺少 Rust 静态库时构建会失败，不再编出回退版
- **多语言**：中文 / English
- **深色模式**：跟随系统自动切换明暗主题

## 当前架构

```
┌─────────────────────────────────────┐
│        ArkUI 页面 / 组件             │
│  Home · Proxy · Subscribe · Settings │
├─────────────────────────────────────┤
│           Service 层                 │
│  Extension bridge · SubscriptionSvc  │
├─────────────────────────────────────┤
│        NAPI C++ 桥接层               │
│        nativeCore* FFI only          │
├─────────────────────────────────────┤
│     VpnExtensionAbility              │
│       TUN fd → Rust/C++ native-core  │
└─────────────────────────────────────┘
```

连接流程：

1. App 启动后不会启动任何 UI 进程代理核心；代理页优先从订阅配置解析节点和已保存选择。
2. 点击连接时，`ClashVpnAbility` 创建系统 VPN TUN，并启动 Extension 内 native-core。
3. UI 通过 CommonEvent 命令通道查询 Extension 里的节点、选择、测速、流量和连接状态。
4. 断开连接时停止 VPN Extension 和 native-core。

根治保活问题的目标不是增加无关后台能力，而是把完整代理数据面放进 `VpnExtensionAbility`：

```
ArkUI 进程
  ├─ 订阅管理
  ├─ 节点选择 / 测速命令
  └─ 状态与流量展示
        │
        │ CommonEvent command channel + chunked config events
        ▼
VpnExtensionAbility 进程
  ├─ VpnConnection / TUN fd
  ├─ Rust/C++ native proxy core
  ├─ 规则路由 / DNS / 策略组
  └─ 协议客户端
```

方案详见 [Extension Native Core Design](docs/extension-native-core.md)。当前判断是：不要从零手写完整 Clash 核心；更可靠的路线是嵌入成熟 Rust 多协议核心，并实现 Clash 配置转换层。

当前仓库的 native-core 已经成为 DevEco 构建必需项：`clash/src/main/cpp/native-core/libclashhm_native_core.a` 和 `native_core.h` 必须存在，或 CMake 必须能自动执行 `native-core/build-ohos.sh` 构建成功。缺少 native-core 时构建会失败，避免生成不可保活的回退版本。`shoes-backend` 已具备 TUN 启动骨架、Clash 选中节点转换、proxy-provider 本地展开、rule-provider 本地展开和常见规则转换，当前覆盖 `direct`、Shadowsocks、Snell、AnyTLS、NaiveProxy、SOCKS5、HTTP/HTTPS、VMess、VLESS、Trojan，以及 TLS/WebSocket/Reality/ShadowTLS/v2ray-plugin WebSocket 包装。Hysteria2、TUIC、gRPC/H2 传输、GEOIP、GEOSITE、DOMAIN-KEYWORD、simple-obfs/obfs、无法展开的 RULE-SET 和完整 Clash URL-test 仍未实现；native-core 会显式返回不支持错误，避免静默错误路由。

## 环境要求

- **DevEco Studio** 5.0+ (HarmonyOS NEXT)
- **HarmonyOS SDK** API 12 (6.0.2)
- **Rust** 1.96+ (用于构建 Extension native-core)
- **HarmonyOS Native SDK clang/sysroot** (Rust OHOS staticlib 链接依赖)
- 真机运行需要 ARM64 设备

## 构建指南

### 1. 构建 Rust native-core

CMake 会在 DevEco/Hvigor 原生构建阶段尝试自动运行 `native-core/build-ohos.sh`。如果自动构建不可用，可以手动执行：

```bash
source "$HOME/.cargo/env"
export OHOS_NATIVE_HOME=/data/app/sdk.org/sdk_1.0.0/default/openharmony/native
bash native-core/build-ohos.sh
```

脚本会生成并复制：

- `clash/src/main/cpp/native-core/libclashhm_native_core.a`
- `clash/src/main/cpp/native-core/native_core.h`

### 2. 构建 HarmonyOS 应用

1. 用 DevEco Studio 打开项目根目录
2. Sync 项目依赖
3. Build → Build Hap(s)/APP(s) → Build Hap(s)
4. 连接设备，Run 安装运行

## 使用方法

1. **添加订阅**：进入「订阅」页 → 点击右上角 `+` → 输入名称和 Clash 订阅链接 → 确认
2. **选择节点**：进入「代理」页 → 展开代理组 → 选择节点。未连接状态也可以查看和选择节点；测速需要 VPN Extension native-core 正在运行
3. **连接代理**：回到「首页」→ 点击连接按钮 → 允许 VPN 权限 → 等待连接成功
4. **切换模式**：首页顶部可切换 Rule（规则）/ Global（全局）/ Direct（直连）模式
5. **查看日志**：首页右上角进入日志页面，实时查看连接信息

## 项目结构

```
ClashHM/
├── native-core/                # Rust Extension native-core
│   ├── src/lib.rs              # Clash adapter + native FFI
│   ├── src/native_core.h       # C ABI header
│   └── build-ohos.sh           # OHOS staticlib build script
├── clash/src/main/
│   ├── cpp/                    # NAPI C++ 桥接层
│   │   ├── clash_bridge.cpp    # nativeCore* NAPI 导出
│   │   ├── CMakeLists.txt      # CMake 配置
│   │   ├── native-core/        # 生成的 staticlib/header
│   │   └── types/libclash/     # ArkTS 类型声明
│   ├── ets/
│   │   ├── pages/              # 页面
│   │   │   ├── Index.ets       # TabBar 导航主页
│   │   │   ├── HomePage.ets    # 首页（连接/流量）
│   │   │   ├── ProxyPage.ets   # 代理页（组/节点）
│   │   │   ├── SubscriptionPage.ets  # 订阅管理
│   │   │   ├── SettingsPage.ets      # 设置
│   │   │   └── LogPage.ets     # 连接日志
│   │   ├── components/         # UI 组件
│   │   ├── models/             # 数据模型
│   │   ├── services/           # 业务服务
│   │   │   ├── ClashService.ets      # 引擎接口抽象
│   │   │   ├── NapiClashService.ets  # Extension native-core 服务门面
│   │   │   ├── NativeClash.ets       # libclash.so ArkTS 封装
│   │   │   ├── ProxySelectionService.ets
│   │   │   ├── MockClashService.ets  # Mock 实现（开发用）
│   │   │   ├── SubscriptionService.ets
│   │   │   ├── SettingsService.ets
│   │   │   ├── ConfigManager.ets
│   │   │   └── TrafficMonitor.ets
│   │   ├── vpnability/         # VPN 扩展
│   │   │   └── ClashVpnAbility.ets
│   │   └── common/             # 工具类
│   └── resources/              # 资源文件（字符串/颜色/图标/rawfile）
└── AppScope/                   # 应用级配置
```

## 技术栈

| 层级 | 技术 |
|------|------|
| UI | ArkTS / ArkUI (HarmonyOS 原生) |
| 引擎 | Rust native-core / shoes backend adapter |
| 桥接 | Node-API (NAPI) / C++ / C FFI |
| TUN 转发 | VpnExtensionAbility / TUN / native-core |
| 存储 | Preferences / FileSystem |

## 参考项目

- [mihomo](https://github.com/metacubex/mihomo) — Clash.Meta 内核
- [clashmi](https://github.com/KaringX/clashmi) — Flutter Clash 客户端
- [hiddify-app](https://github.com/hiddify/hiddify-app) — 跨平台代理客户端

## License

MIT
