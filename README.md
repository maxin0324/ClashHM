# ClashHM
HarmonyOS NEXT 平台的 Clash 代理客户端，基于 [mihomo](https://github.com/metacubex/mihomo) (Clash.Meta) 内核。

## 功能特性

- **代理核心**：集成 mihomo v1.19.26 引擎，支持 Shadowsocks、VMess、VLESS、Trojan、Hysteria2、TUIC、WireGuard 等协议
- **订阅管理**：支持导入标准 Clash 订阅链接，自动解析节点信息、流量用量和到期时间
- **代理切换**：代理组可视化管理，支持手动选择节点、延迟测试和自动选择
- **VPN 隧道**：通过 HarmonyOS VpnExtensionAbility 创建系统级 VPN 隧道，TUN 模式全局代理
- **流量监控**：实时显示上传/下载速度、会话流量统计和活跃连接数
- **连接日志**：实时连接日志，支持按域名/规则/代理链过滤
- **后台运行**：支持后台持续运行，不被系统杀掉
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
│         clash_bridge.cpp             │
├─────────────────────────────────────┤
│      libmihomo.so (Go c-shared)      │
│        mihomo v1.19.26 核心           │
├─────────────────────────────────────┤
│     VpnExtensionAbility              │
│       TUN fd → mihomo                │
└─────────────────────────────────────┘
```

## 环境要求

- **DevEco Studio** 5.0+ (HarmonyOS NEXT)
- **HarmonyOS SDK** API 12 (6.0.2)
- **Go** 1.22+ (编译 mihomo 引擎)
- **GCC** (CGO 编译依赖)
- 真机运行需要 ARM64 设备

## 构建指南

### 1. 编译 mihomo 引擎

```bash
# 安装 Go (如未安装)
# Linux ARM64:
wget https://go.dev/dl/go1.22.10.linux-arm64.tar.gz
sudo tar -C /usr/local -xzf go1.22.10.linux-arm64.tar.gz
export PATH=$PATH:/usr/local/go/bin

# 安装 GCC (如未安装)
# openEuler/CentOS:
sudo dnf install -y gcc gcc-c++
# Ubuntu/Debian:
# sudo apt install -y gcc g++

# 编译
cd mihomo-bridge
chmod +x build.sh
./build.sh
```

编译完成后 `libmihomo.so` (约 32MB) 会自动复制到 `clash/src/main/cpp/libs/arm64-v8a/`。

### 2. 构建 HarmonyOS 应用

1. 用 DevEco Studio 打开项目根目录
2. Sync 项目依赖
3. Build → Build Hap(s)/APP(s) → Build Hap(s)
4. 连接设备，Run 安装运行

## 使用方法

1. **添加订阅**：进入「订阅」页 → 点击右上角 `+` → 输入名称和 Clash 订阅链接 → 确认
2. **连接代理**：回到「首页」→ 点击连接按钮 → 允许 VPN 权限 → 等待连接成功
3. **切换节点**：进入「代理」页 → 展开代理组 → 选择节点 → 可点击「Test」测试延迟
4. **切换模式**：首页顶部可切换 Rule（规则）/ Global（全局）/ Direct（直连）模式
5. **查看日志**：首页右上角进入日志页面，实时查看连接信息

## 项目结构

```
ClashHM/
├── mihomo-bridge/              # Go 引擎封装层
│   ├── main.go                 # C 导出函数封装 mihomo API
│   ├── go.mod                  # Go 模块定义
│   └── build.sh                # 编译脚本
├── clash/src/main/
│   ├── cpp/                    # NAPI C++ 桥接层
│   │   ├── clash_bridge.cpp    # NAPI 函数实现
│   │   ├── CMakeLists.txt      # CMake 配置
│   │   ├── libs/arm64-v8a/     # 预编译 libmihomo.so
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
│   │   │   ├── NapiClashService.ets  # NAPI 真实引擎实现
│   │   │   ├── MockClashService.ets  # Mock 实现（开发用）
│   │   │   ├── SubscriptionService.ets
│   │   │   ├── SettingsService.ets
│   │   │   ├── ConfigManager.ets
│   │   │   └── TrafficMonitor.ets
│   │   ├── vpnability/         # VPN 扩展
│   │   │   └── ClashVpnAbility.ets
│   │   └── common/             # 工具类
│   └── resources/              # 资源文件（字符串/颜色/图标）
└── AppScope/                   # 应用级配置
```

## 技术栈

| 层级 | 技术 |
|------|------|
| UI | ArkTS / ArkUI (HarmonyOS 原生) |
| 引擎 | mihomo v1.19.26 (Go, c-shared) |
| 桥接 | Node-API (NAPI) / C++ |
| VPN | VpnExtensionAbility / TUN |
| 存储 | Preferences / FileSystem |

## 参考项目

- [mihomo](https://github.com/metacubex/mihomo) — Clash.Meta 内核
- [clashmi](https://github.com/KaringX/clashmi) — Flutter Clash 客户端
- [hiddify-app](https://github.com/hiddify/hiddify-app) — 跨平台代理客户端

## License

MIT
