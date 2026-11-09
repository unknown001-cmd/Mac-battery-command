# mac-battery · PowerWidget

**A native macOS menu bar + desktop widget that shows how many watts your Mac is actually drawing — plus battery health, cycles, temperature, and a rolling 6-hour power chart.**

macOS never tells you the number that matters most: right now, this machine is pulling **X watts**. Activity Monitor's Energy tab is a relative score, the Battery pane only shows charge state, and `pmset` gives you nothing useful without root. PowerWidget reads Apple's own hardware sensors and puts the real figure in your menu bar.

No Electron. No Python. No daemons. One Swift + one small C file, built into a universal binary that runs on both Apple Silicon and Intel Macs.

```
┌──────────────────────────┐
│          12.4w           │   ← real system draw, color-coded by zone
│         整机功耗          │
│      86%  ·  输出 12.0w    │   ← charge level + battery input/output
│  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬     │
└──────────────────────────┘
```

---

## Features

- **Live total system power** in the menu bar, refreshed every 1.5 s, colored by configurable wattage zones.
- **Desktop-level floating card** — a glass panel that sits *below* every normal window (so it never blocks your work) and above the desktop icons. Drag it anywhere; the position is remembered.
- **Input / output split** — when plugged in you see what is flowing *into* the battery; on battery you see what the machine is *drawing*.
- **Battery health details** — design vs. full-charge capacity, health %, cycle count, temperature, remaining Wh, estimated time left, and auto-detected nominal voltage.
- **6-hour power history** — 3 s per sample, switchable ranges (5 m / 30 m / 1 h / 3 h / 6 h), hover for exact values, peak marker, and shaded bands for periods on AC power. Persisted across restarts.
- **Configurable color zones** — plain JSON, hot-reloadable with ⌘R, no restart.
- **Auto-adapts to the machine** — suggested zones are derived from battery size (a 12″ MacBook and a 16″ MacBook Pro should not share the same thresholds), and the app degrades gracefully on Macs without a battery or without the `PSTR` sensor key.
- **Universal binary**, no third-party dependencies, no network access, no telemetry.

## Requirements

- macOS 11 Big Sur or later (tested on macOS 12.7.6, MacBook Pro 13″ 2016, Intel)
- Xcode Command Line Tools (`xcode-select --install`) to build — only `swiftc` and `clang` are used

## Build & run

```bash
git clone https://github.com/<you>/mac-battery.git
cd mac-battery
./build.sh            # compile both slices, sign ad-hoc, and launch
./build.sh --no-run   # compile only
```

The build produces `PowerWidget.app` in the repo root. To install it permanently:

```bash
cp -R PowerWidget.app /Applications/
open /Applications/PowerWidget.app
```

**First launch is blocked by Gatekeeper** because the app is ad-hoc signed, not notarized. Either right-click → *Open* → *Open*, or run:

```bash
xattr -dr com.apple.quarantine /Applications/PowerWidget.app
```

To start it at login: System Settings → General → Login Items → add `PowerWidget.app`.

## Usage

Click the menu bar figure to open the menu:

| Item | What it does |
|---|---|
| 整机功耗 / CPU 功耗 | Total system draw and CPU package power |
| 电池输入端 / 输出端 | Current flow into or out of the battery |
| 电量 | Charge %, remaining Wh, estimated hours left |
| 健康度 / 循环次数 / 温度 / 标称电压 | Battery health telemetry |
| 功耗来源 | Which sensor the number came from (`SMC PSTR` vs. fallback) |
| 功耗历史… `⌘H` | Open the power history chart |
| 编辑颜色区间… `⌘,` | Reveal the config file in Finder |
| 重新加载配置 `⌘R` | Apply config edits without restarting |
| 显示桌面浮窗 `⌘P` | Toggle the floating card |
| 退出 `⌘Q` | Quit |

The menu labels are currently Chinese — see [known issues](ISSUES.md).

## Configuration

`~/Library/Application Support/PowerWidget/config.json` (created on first launch):

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

- `zones` — upper bound in watts for each color band. Colors accept names (`green`, `orange`, `red`, `blue`, `purple`, `pink`, `teal`, `yellow`, `gray`) or hex (`"#7C4DFF"`).
- `nominalVoltage` — **omit it** to let the app detect the battery's nominal voltage (`DesignVoltage`, falling back to `cell count × 3.8 V`). Only add it if you think the detected value is wrong; Wh figures are derived from it.

On first run the zones are seeded from the battery's design capacity:

| Battery | Green ≤ | Orange ≤ | Red ≤ |
|---|---|---|---|
| < 45 Wh (12″ MacBook, early Air) | 8 w | 15 w | 25 w |
| 45–70 Wh (13″ Pro/Air) | 12 w | 22 w | 35 w |
| 70–90 Wh (14″/15″) | 16 w | 30 w | 50 w |
| ≥ 90 Wh (16″ Pro) | 22 w | 40 w | 70 w |
| No battery (desktop) | 30 w | 60 w | 120 w |

## How it reads the data

| Value | Source |
|---|---|
| Current / voltage / charge / cycles / temperature | IOKit `AppleSmartBattery` registry properties (all battery packs are enumerated and summed) |
| Total system power | SMC key `PSTR` via the `AppleSMC` user client (read-only) |
| CPU package power | SMC key `PCPT` |

If `PSTR` is unavailable (common on Apple Silicon), the app falls back to battery current × voltage and says so in the **功耗来源** menu row — it does not silently pretend. On AC power with no `PSTR`, there is no honest source for total draw, and the reading will be the charge rate instead.

Everything is read-only. The app never writes SMC keys, never changes charging behaviour, and needs no root privileges.

## Project layout

```
mac-battery/
├── main.swift          # menu bar item, floating panel, battery/SMC reading, config
├── history.swift       # ring buffer + history window and chart view
├── smc.c               # AppleSMC user-client bridge (PSTR / PCPT)
├── smc_bridge.h        # C interface exposed to Swift
├── Info.plist          # bundle metadata (LSUIElement: no Dock icon)
├── build.sh            # universal build: x86_64 + arm64 → lipo → ad-hoc sign
├── ISSUES.md           # known issues, mirrored as GitHub issues
└── README.zh-CN.md     # 中文说明
```

## Known issues

See **[ISSUES.md](ISSUES.md)** (中文版：[ISSUES.zh-CN.md](ISSUES.zh-CN.md)) — it mirrors the open GitHub issues: Apple Silicon fallback behaviour, Gatekeeper on first launch, off-screen panel after display changes, 6-hour history limit, and the untested desktop / multi-battery branches. The GitHub issues themselves carry bilingual bodies.

## License

MIT — see [LICENSE](LICENSE).

Not affiliated with Apple. "Apple", "Mac", "MacBook" are trademarks of Apple Inc. Sensor key names are used for interoperability only; they are undocumented and may change between macOS releases.
