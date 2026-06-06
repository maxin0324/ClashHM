# ClashHM
HarmonyOS NEXT 平台的 Clash 代理客户端，基于 [mihomo](https://github.com/metacubex/mihomo) (Clash.Meta) 内核。

## 功能特性

- **代理核心**：集成 mihomo v1.19.26 引擎，支持 Shadowsocks、VMess、VLESS、Trojan、Hysteria2、TUIC、WireGuard 等协议
- **订阅管理**：支持导入标准 Clash 订阅链接，自动解析节点信息、流量用量和到期时间
- **代理切换**：代理组可视化管理，支持手动选择节点、延迟测试和自动选择
- **VPN 隧道**：通过 HarmonyOS VpnExtensionAbility 创建系统级 VPN 隧道，使用 native tun2socks 转发到本机 mihomo mixed-port
- **流量监控**：实时显示上传/下载速度、会话流量统计和活跃连接数
- **连接日志**：实时连接日志，支持按域名/规则/代理链过滤
- **当前状态**：MVP 可用版本，UI 进程运行 mihomo 核心，VPN Extension 负责 TUN/tun2socks
- **多语言**：中文 / English
- **深色模式**：跟随系统自动切换明暗主题

## 架构

```
┌─────────────────────────────────────┐
│        ArkUI 页面 / 组件             │
│  Home · Proxy · Subscribe · Settings │
├─────────────────────────────────────┤
│           Service 层                 │
│  NapiClashService · SubscriptionSvc  │
├─────────────────────────────────────┤
│        NAPI C++ 桥接层               │
│  clash_bridge.cpp · hev tun2socks    │
├─────────────────────────────────────┤
│      libmihomo.so (Go c-shared)      │
│  UI 进程内运行 mihomo v1.19.26 核心   │
├─────────────────────────────────────┤
│     VpnExtensionAbility              │
│       TUN fd → tun2socks → 127.0.0.1:7890 │
└─────────────────────────────────────┘
```

连接流程：

1. App 启动后，UI 进程通过 NAPI 加载 `libmihomo.so`，用于节点列表、测速、代理组选择和本机 mixed-port。
2. 点击连接时，`ClashVpnAbility` 创建系统 VPN TUN。
3. VPN Extension 启动内置 native tun2socks，把 TUN 流量转发到 UI 进程的 `127.0.0.1:7890`。
4. 断开连接时停止 VPN Extension/tun2socks，UI 侧 mihomo 核心保留，便于继续选择节点和测速。

注意：当前 MVP 仍依赖 UI 进程中的 mihomo 核心。如果系统杀掉 UI 进程，VPN Extension 内的 tun2socks 将失去上游代理核心，后续需要再演进为 Extension 内独立核心或系统级保活方案。

## 环境要求

- **DevEco Studio** 5.0+ (HarmonyOS NEXT)
- **HarmonyOS SDK** API 12 (6.0.2)
- **Go** 1.22+ (编译 mihomo 引擎)
- **HarmonyOS Native SDK clang** (CGO 编译依赖)
- 真机运行需要 ARM64 设备

## 构建指南

### 1. 编译 mihomo 引擎

```bash
# 安装 Go (如未安装)
# Linux ARM64:
wget https://go.dev/dl/go1.22.10.linux-arm64.tar.gz
sudo tar -C /usr/local -xzf go1.22.10.linux-arm64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# 编译 HarmonyOS 可加载的 libmihomo.so
cd mihomo-bridge
chmod +x build-ohos.sh
OHOS_SDK_ROOT=/path/to/command-line-tools/sdk/default ./build-ohos.sh
```

编译完成后 `libmihomo.so` (约 32MB) 会自动复制到：

- `clash/src/main/libs/arm64-v8a/libmihomo.so`
- `clash/src/main/libs/arm64/libmihomo.so`

旧的 `build.sh` 是早期 Linux/musl 构建脚本，不适合作为 HarmonyOS NEXT 运行包的默认构建方式。

### 2. 构建 HarmonyOS 应用

1. 用 DevEco Studio 打开项目根目录
2. Sync 项目依赖
3. Build → Build Hap(s)/APP(s) → Build Hap(s)
4. 连接设备，Run 安装运行

## 使用方法

1. **添加订阅**：进入「订阅」页 → 点击右上角 `+` → 输入名称和 Clash 订阅链接 → 确认
2. **选择节点**：进入「代理」页 → 展开代理组 → 选择节点 → 可点击「Test」测试延迟。未连接状态也可以选择节点和测速
3. **连接代理**：回到「首页」→ 点击连接按钮 → 允许 VPN 权限 → 等待连接成功
4. **切换模式**：首页顶部可切换 Rule（规则）/ Global（全局）/ Direct（直连）模式
5. **查看日志**：首页右上角进入日志页面，实时查看连接信息

## 项目结构

```
ClashHM/
├── mihomo-bridge/              # Go 引擎封装层
│   ├── main.go                 # C 导出函数封装 mihomo API
│   ├── go.mod                  # Go 模块定义
│   ├── build-ohos.sh           # HarmonyOS libmihomo.so 编译脚本
│   └── build.sh                # 早期 Linux/musl 编译脚本
├── clash/src/main/
│   ├── cpp/                    # NAPI C++ 桥接层
│   │   ├── clash_bridge.cpp    # NAPI 函数实现
│   │   ├── CMakeLists.txt      # CMake 配置
│   │   ├── third_party/hev-socks5-tunnel/ # native tun2socks
│   │   └── types/libclash/     # ArkTS 类型声明
│   ├── libs/arm64-v8a/         # 预编译 libmihomo.so（本地构建产物，默认 ignored）
│   ├── libs/arm64/             # 预编译 libmihomo.so（本地构建产物，默认 ignored）
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
│   │   │   ├── NapiClashService.ets  # NAPI 真实引擎实现
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
| 引擎 | mihomo v1.19.26 (Go, c-shared) |
| 桥接 | Node-API (NAPI) / C++ |
| TUN 转发 | VpnExtensionAbility / TUN / hev-socks5-tunnel |
| 存储 | Preferences / FileSystem |

## 参考项目

- [mihomo](https://github.com/metacubex/mihomo) — Clash.Meta 内核
- [clashmi](https://github.com/KaringX/clashmi) — Flutter Clash 客户端
- [hiddify-app](https://github.com/hiddify/hiddify-app) — 跨平台代理客户端

## License

MIT
