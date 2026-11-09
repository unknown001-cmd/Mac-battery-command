# mac-battery · 功率小组件

**一个原生 macOS 菜单栏 + 桌面浮窗工具：实时显示这台 Mac 真正的功耗（瓦特），外加电池健康、循环次数、温度和最近 6 小时的功耗曲线。**

[English README](README.md)

macOS 从来不告诉你最关键的那个数字：**此刻这台机器到底在吃多少瓦**。活动监视器的"能耗"是相对值，电池面板只报充电状态。这个工具直接读苹果自己的硬件传感器，把真实功率放进菜单栏。

没有 Electron，没有 Python 守护进程，不联网、不上报。一个 Swift 文件 + 一个 C 文件，编译成 Intel / Apple Silicon 通用二进制。

```
┌──────────────────────────┐
│          12.4w           │   ← 整机实时功耗，按区间变色
│         整机功耗          │
│      86%  ·  输出 12.0w    │   ← 电量 + 电池输入/输出
│  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬     │
└──────────────────────────┘
```

## 功能

- **菜单栏实时整机功耗**，每 1.5 秒刷新，按可配置的功率区间变色
- **桌面层浮窗**：毛玻璃卡片压在普通窗口之下、桌面图标之上，不挡任何软件；可拖动，位置自动记住
- **输入 / 输出分开**：接电时显示流进电池的功率，用电池时显示整机放电功率
- **电池详情**：设计容量 / 满充容量 / 健康度 / 循环次数 / 温度 / 剩余 Wh / 预估可用时间 / 自动探测的标称电压
- **6 小时功耗曲线**：3 秒一个点，支持 5 分 / 30 分 / 1 时 / 3 时 / 6 时切换，悬停读数，峰值打点，接电时段用蓝条标出，重启不丢
- **颜色区间可配置**：纯 JSON，⌘R 热重载，不用重启
- **自动适配机型**：首次运行按电池容量推区间（12 寸和 16 寸不该用同一套阈值）；无电池机型、无 `PSTR` 传感器机型会降级而不是假装有数
- **通用二进制**：`x86_64` + `arm64`，无第三方依赖

## 环境要求

- macOS 11 Big Sur 及以上（实测 macOS 12.7.6 / MacBook Pro 13″ 2016 / Intel）
- 编译需要 Xcode Command Line Tools：`xcode-select --install`（只用 `swiftc` 和 `clang`）

## 编译与安装

```bash
git clone https://github.com/<you>/mac-battery.git
cd mac-battery
./build.sh            # 编译双架构 → ad-hoc 签名 → 启动
./build.sh --no-run   # 只编译
```

产物是仓库根目录的 `PowerWidget.app`。长期使用：

```bash
cp -R PowerWidget.app /Applications/
open /Applications/PowerWidget.app
```

**首次打开会被 Gatekeeper 拦下**（应用只有 ad-hoc 签名，没有公证）。右键 → 打开 → 再点"打开"，或者直接：

```bash
xattr -dr com.apple.quarantine /Applications/PowerWidget.app
```

开机自启：系统设置 → 通用 → 登录项 → 添加 `PowerWidget.app`。

## 使用

点菜单栏数字打开菜单：

| 菜单项 | 作用 |
|---|---|
| 整机功耗 / CPU 功耗 | 整机总功耗与 CPU 封装功耗 |
| 电池输入端 / 输出端 | 当前流入 / 流出电池的功率 |
| 电量 | 电量百分比、剩余 Wh、预估可用时间 |
| 健康度 / 循环次数 / 温度 / 标称电压 | 电池遥测 |
| 功耗来源 | 这个数字来自哪个传感器（`SMC PSTR` 还是回退值） |
| 功耗历史… `⌘H` | 打开功耗曲线窗口 |
| 编辑颜色区间… `⌘,` | 在 Finder 中显示配置文件 |
| 重新加载配置 `⌘R` | 改完配置立即生效 |
| 显示桌面浮窗 `⌘P` | 开关浮窗 |
| 退出 `⌘Q` | 退出 |

## 配置

`~/Library/Application Support/PowerWidget/config.json`（首次启动自动生成）：

```json
{
  "zones": [
    { "max": 12,   "color": "green"  },
    { "max": 22,   "color": "orange" },
    { "max": 35,   "color": "red"    },
    { "max": 9999, "color": "purple" }
  ],
  "nominalVoltage": 11.4
}
```

- `zones`：每档的功率上限（瓦），颜色支持名字（`green` / `orange` / `red` / `blue` / `purple` / `pink` / `teal` / `yellow` / `gray`）或十六进制 `"#7C4DFF"`
- `nominalVoltage`：**建议直接删掉这一行**，程序会自动用电池的 `DesignVoltage` 探测；只有你觉得探测值不对时才手动填

首次运行会按电池设计容量给一套区间：小于 45 Wh 用 8/15/25，45–70 Wh 用 12/22/35，70–90 Wh 用 16/30/50，90 Wh 以上用 22/40/70，无电池机型用 30/60/120。

## 数据从哪来

| 数值 | 来源 |
|---|---|
| 电流 / 电压 / 电量 / 循环 / 温度 | IOKit `AppleSmartBattery` 注册表属性（多电池机型会遍历相加） |
| 整机总功耗 | SMC 键 `PSTR`（通过 `AppleSMC` user client，只读） |
| CPU 封装功耗 | SMC 键 `PCPT` |

`PSTR` 读不到时（Apple Silicon 常见）自动回退到「电池电流 × 电压」，并在菜单 **功耗来源** 一行明确标注。接电且没有 `PSTR` 的情况下，没有任何诚实的整机功耗来源，此时显示的是充电功率。

全部只读：不写 SMC、不改充电策略、不需要 root。

## 已知问题

见 **[ISSUES.md](ISSUES.md)**（与 GitHub Issues 一一对应）：Apple Silicon 回退、首次打开被 Gatekeeper 拦、改显示器后浮窗跑到屏幕外、历史只有 6 小时、无测试无 CI 等。

## 许可

MIT，见 [LICENSE](LICENSE)。

与苹果公司无关。"Apple"、"Mac"、"MacBook" 是 Apple Inc. 的商标；代码中出现的传感器键名仅用于互操作，它们是未公开接口，可能随系统版本变化。
