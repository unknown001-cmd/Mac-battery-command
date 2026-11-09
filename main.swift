import Cocoa
import IOKit

// ─────────────────────────────────────────────
//  配置：颜色功率区间、电池标称电压（可适配其他电脑）
//  文件位置 ~/Library/Application Support/PowerWidget/config.json
//  菜单栏图标 → 「重新加载配置」无需重启即可生效
// ─────────────────────────────────────────────
struct Zone {
    var maxW: Double
    var color: NSColor
}

final class Config {
    var nominalVoltage = 11.4
    var voltageAuto = true        // true = 自动探测电池标称电压
    var zones: [Zone] = [
        Zone(maxW: 15, color: .systemGreen),
        Zone(maxW: 25, color: .systemOrange),
        Zone(maxW: 9999, color: .systemRed)
    ]
    var existedAtLaunch = true    // 首次运行（没有配置文件）时据此写入按机器推的区间

    static let dirURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PowerWidget", isDirectory: true)
    }()
    static let fileURL = dirURL.appendingPathComponent("config.json")

    // 注意：默认配置里不写 nominalVoltage —— 键不存在时程序自动探测电池标称电压；
    // 只有用户手动写入该键，才会覆盖自动探测结果。
    static let defaultJSON: [String: Any] = [
        "zones": [
            ["max": 15,   "color": "green"],
            ["max": 25,   "color": "orange"],
            ["max": 9999, "color": "red"]
        ]
    ]

    /// 按机器规格推一套合理的颜色区间（不同 Mac 功耗量级差别很大：
    /// 13 寸轻办公 5-15w，16 寸满载 60-90w，台式机更高）
    static func suggestZones(designWh: Double, hasBattery: Bool) -> [Zone] {
        if !hasBattery || designWh <= 0 {
            return [Zone(maxW: 30, color: .systemGreen),
                    Zone(maxW: 60, color: .systemOrange),
                    Zone(maxW: 120, color: .systemRed),
                    Zone(maxW: 9999, color: .systemPurple)]
        }
        let g: Double, o: Double, r: Double
        switch designWh {
        case ..<45:      // 12 寸 MacBook、MacBook Air 早期
            g = 8;  o = 15; r = 25
        case ..<70:      // 13 寸 Pro / Air
            g = 12; o = 22; r = 35
        case ..<90:      // 14 寸 / 15 寸
            g = 16; o = 30; r = 50
        default:         // 16 寸 Pro 等大电池机型
            g = 22; o = 40; r = 70
        }
        return [Zone(maxW: g, color: .systemGreen),
                Zone(maxW: o, color: .systemOrange),
                Zone(maxW: r, color: .systemRed),
                Zone(maxW: 9999, color: .systemPurple)]
    }

    func save() {
        let json: [String: Any] = [
            "zones": zones.map { ["max": $0.maxW, "color": Config.colorName($0.color)] }
        ]
        var out = json
        if !voltageAuto { out["nominalVoltage"] = nominalVoltage }
        guard let data = try? JSONSerialization.data(withJSONObject: out,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Config.dirURL, withIntermediateDirectories: true)
        try? data.write(to: Config.fileURL)
    }

    /// 反向映射，尽量保持用户写的名字（用于自动生成配置时不覆盖成 hex）
    static func colorName(_ c: NSColor) -> String {
        let pairs: [(String, NSColor)] = [
            ("green", .systemGreen), ("orange", .systemOrange), ("red", .systemRed),
            ("blue", .systemBlue), ("purple", .systemPurple), ("pink", .systemPink),
            ("teal", .systemTeal), ("yellow", .systemYellow), ("gray", .systemGray)
        ]
        let t = c.usingColorSpace(.deviceRGB)
        for (name, cand) in pairs {
            if let u = cand.usingColorSpace(.deviceRGB), let v = t,
               abs(u.redComponent - v.redComponent) < 0.02,
               abs(u.greenComponent - v.greenComponent) < 0.02,
               abs(u.blueComponent - v.blueComponent) < 0.02 {
                return name
            }
        }
        if let v = t {
            return String(format: "#%02X%02X%02X",
                          Int(v.redComponent * 255), Int(v.greenComponent * 255), Int(v.blueComponent * 255))
        }
        return "green"
    }

    static func load() -> Config {
        let cfg = Config()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirURL.path) {
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            cfg.existedAtLaunch = false
        }
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cfg }

        if let v = obj["nominalVoltage"] as? Double, v > 1, v < 100 {
            cfg.nominalVoltage = v
            cfg.voltageAuto = false
        }
        if let arr = obj["zones"] as? [[String: Any]], !arr.isEmpty {
            var zones: [Zone] = []
            for item in arr {
                guard let c = item["color"] as? String else { continue }
                let maxW = (item["max"] as? Double) ?? (item["max"] as? Int).map(Double.init) ?? 9999
                zones.append(Zone(maxW: maxW, color: parseColor(c)))
            }
            if !zones.isEmpty { cfg.zones = zones.sorted { $0.maxW < $1.maxW } }
        }
        return cfg
    }

    static func parseColor(_ s: String) -> NSColor {
        let str = s.trimmingCharacters(in: .whitespaces).lowercased()
        // #RGB / #RRGGBB / #RRGGBBAA
        if str.hasPrefix("#") {
            let hex = String(str.dropFirst()).replacingOccurrences(of: "0x", with: "")
            var value: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&value)
            var r = 0.0, g = 0.0, b = 0.0, a = 1.0
            switch hex.count {
            case 3:
                r = Double((value >> 8) & 0xF) / 15.0
                g = Double((value >> 4) & 0xF) / 15.0
                b = Double(value & 0xF) / 15.0
            case 6:
                r = Double((value >> 16) & 0xFF) / 255.0
                g = Double((value >> 8) & 0xFF) / 255.0
                b = Double(value & 0xFF) / 255.0
            case 8:
                r = Double((value >> 24) & 0xFF) / 255.0
                g = Double((value >> 16) & 0xFF) / 255.0
                b = Double((value >> 8) & 0xFF) / 255.0
                a = Double(value & 0xFF) / 255.0
            default:
                return .systemGreen
            }
            return NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
        }
        let named: [String: NSColor] = [
            "green": .systemGreen, "orange": .systemOrange, "red": .systemRed,
            "blue": .systemBlue, "purple": .systemPurple, "pink": .systemPink,
            "teal": .systemTeal, "yellow": .systemYellow, "gray": .systemGray,
            "grey": .systemGray, "white": .white, "black": .black,
            "cyan": NSColor(calibratedRed: 0.25, green: 0.78, blue: 0.88, alpha: 1),
            "mint": NSColor(calibratedRed: 0.39, green: 0.90, blue: 0.89, alpha: 1),
            "indigo": NSColor(calibratedRed: 0.37, green: 0.36, blue: 0.90, alpha: 1),
            "brown": NSColor(calibratedRed: 0.67, green: 0.56, blue: 0.41, alpha: 1)
        ]
        return named[str] ?? .systemGreen
    }

    func color(for watts: Double) -> NSColor {
        for z in zones where watts <= z.maxW { return z.color }
        return zones.last?.color ?? .systemGreen
    }
}

let CONFIG = Config.load()

// ─────────────────────────────────────────────
//  数据快照
// ─────────────────────────────────────────────
struct Snapshot {
    var hasBattery      = false    // 台式机（Mac mini / Studio / 部分 iMac）为 false
    var amperage        = 0        // mA，放电为负
    var voltage         = 0        // mV
    var currentCapacity = 0        // mAh 当前电量
    var maxCapacity     = 0        // mAh 满充容量
    var designCapacity  = 0        // mAh 设计容量
    var cycleCount      = 0
    var temperature     = 0        // 1/100 ℃
    var soc             = 0        // %
    var nominalV        = 11.4     // 电池标称电压（自动探测或配置指定）
    var external        = false
    var charging        = false
    var full            = false
    var systemWatts     = 0.0      // 整机总功耗（SMC PSTR），-1 不可用
    var cpuWatts        = -1.0     // CPU 封装功耗（SMC PCPT），-1 不可用

    var batteryWatts: Double {
        guard voltage > 0 else { return 0 }
        return Double(abs(amperage)) * Double(voltage) / 1_000_000.0
    }
    var totalWatts: Double {
        if systemWatts >= 0 { return systemWatts }
        return batteryWatts
    }
    /// 功耗读数来源，菜单里显示给用户看（不同 Mac 能力不同）
    var wattsSource: String {
        if systemWatts >= 0 { return "SMC PSTR（整机总功耗）" }
        if hasBattery { return "电池放电速率（本机 SMC 无 PSTR）" }
        return "不可用"
    }
    var remainWh: Double { Double(currentCapacity) * nominalV / 1000.0 }
    var health: Double {
        guard designCapacity > 0, maxCapacity > 0 else { return 0 }
        return Double(maxCapacity) / Double(designCapacity) * 100.0
    }
    var hoursLeft: Double {
        guard totalWatts > 0.3, !external else { return 0 }
        return remainWh / totalWatts
    }
    var flowText: String {
        if !hasBattery { return "本机无电池" }
        if external {
            if full || batteryWatts < 0.05 { return "输入 0.0w" }
            return String(format: "输入 +%.1fw", batteryWatts)
        }
        return String(format: "输出 %.1fw", batteryWatts)
    }
}

func readBattery() -> Snapshot {
    var s = Snapshot()

    var totalAmp = 0, totalCur = 0, totalMax = 0, totalDesign = 0, totalVolt = 0
    var packs = 0, cycles = 0, tempRaw = 0, socSum = 0, socN = 0, designVoltMV = 0
    var external = false, charging = false, full = false

    // 遍历所有 AppleSmartBattery（正常 Mac 只有一块，双电池老机型也能正确相加）
    if let matching = IOServiceMatching("AppleSmartBattery") {
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &iter) == KERN_SUCCESS {
            while true {
                let svc = IOIteratorNext(iter)
                if svc == 0 { break }
                defer { IOObjectRelease(svc) }

                var cfProps: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(svc, &cfProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let d = cfProps?.takeRetainedValue() as? [String: Any] else { continue }

                packs += 1
                totalAmp    += d["Amperage"] as? Int ?? d["InstantAmperage"] as? Int ?? 0
                totalVolt   += d["Voltage"] as? Int ?? 0
                totalCur    += d["CurrentCapacity"] as? Int ?? 0
                totalMax    += d["AppleRawMaxCapacity"] as? Int ?? d["MaxCapacity"] as? Int ?? 0
                totalDesign += d["DesignCapacity"] as? Int ?? 0
                cycles      += d["CycleCount"] as? Int ?? 0
                if let t = d["Temperature"] as? Int, t > 0, tempRaw == 0 { tempRaw = t }
                if let dv = d["DesignVoltage"] as? Int, dv > 3000, designVoltMV == 0 { designVoltMV = dv }

                if let bd = d["BatteryData"] as? [String: Any], let sc = bd["StateOfCharge"] as? Int, sc > 0 {
                    socSum += sc; socN += 1
                }
                external = external || ((d["ExternalConnected"] as? Bool) ?? false)
                charging = charging || ((d["IsCharging"] as? Bool) ?? false)
                full     = full || ((d["FullyCharged"] as? Bool) ?? false)
            }
            IOObjectRelease(iter)
        }
    }

    s.hasBattery      = packs > 0
    s.amperage        = totalAmp
    s.voltage         = packs > 0 ? totalVolt / packs : 0
    s.currentCapacity = totalCur
    s.maxCapacity     = totalMax
    s.designCapacity  = totalDesign
    s.cycleCount      = cycles
    s.temperature     = tempRaw
    s.external        = external
    s.charging        = charging
    s.full            = full
    if socN > 0 {
        s.soc = socSum / socN
    } else if s.maxCapacity > 0 {
        s.soc = Int((Double(s.currentCapacity) / Double(s.maxCapacity) * 100).rounded())
    }

    // 标称电压：配置里显式指定优先；否则用电池报告的 DesignVoltage；
    // 再不行按电芯数推算（单串满电 4.2V、标称 3.8V），最后回退 11.4V
    if CONFIG.voltageAuto {
        if designVoltMV > 3000 {
            s.nominalV = Double(designVoltMV) / 1000.0
        } else if s.voltage > 0 {
            let cells = max(1, Int((Double(s.voltage) / 4200.0).rounded()))
            s.nominalV = Double(cells) * 3.8
        } else {
            s.nominalV = 11.4
        }
        CONFIG.nominalVoltage = s.nominalV
    } else {
        s.nominalV = CONFIG.nominalVoltage
    }

    // 整机功耗：SMC PSTR。Apple Silicon 多数机型没有这个键，读不到会返回 -1（自动回退）
    s.systemWatts = SMC_ReadSystemPower()
    s.cpuWatts    = SMC_ReadCPUPower()
    return s
}

// ─────────────────────────────────────────────
//  电量进度条
// ─────────────────────────────────────────────
final class BarView: NSView {
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let radius = r.height / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()

        let w = max(0, min(1, CGFloat(progress))) * r.width
        if w > 0.5 {
            color.setFill()
            let fill = NSRect(x: 0, y: 0, width: max(w, r.height), height: r.height)
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
    }
}

// ─────────────────────────────────────────────
//  主控制器
// ─────────────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem!
    var timer: Timer?
    var panel: NSPanel?
    var bigLabel: NSTextField?
    var capLabel: NSTextField?
    var flowLabel: NSTextField?
    var barView: BarView?
    var snap = Snapshot()

    var miPower: NSMenuItem!
    var miCPU: NSMenuItem!
    var miFlow: NSMenuItem!
    var miBattery: NSMenuItem!
    var miHealth: NSMenuItem!
    var miCycle: NSMenuItem!
    var miTemp: NSMenuItem!
    var miVolt: NSMenuItem!
    var miSource: NSMenuItem!
    var miPanel: NSMenuItem!
    var historyWC: HistoryWindowController?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupMenu()
        if UserDefaults.standard.bool(forKey: "showPanel") { showPanel() }
        refresh()
        // 首次运行：按这台机器的规格推一套颜色区间（不同 Mac 功耗量级差很多）
        if !CONFIG.existedAtLaunch {
            CONFIG.zones = Config.suggestZones(designWh: snap.remainWh > 0
                                               ? Double(snap.designCapacity) * snap.nominalV / 1000.0
                                               : 0,
                                               hasBattery: snap.hasBattery)
            CONFIG.save()
        }
        // 启动时记录一次探测结果，便于外部核查自动探测是否生效
        UserDefaults.standard.set(snap.nominalV, forKey: "probeNominalV")
        UserDefaults.standard.set(CONFIG.voltageAuto, forKey: "probeVoltageAuto")
        UserDefaults.standard.set(snap.designCapacity, forKey: "probeDesignMah")
        UserDefaults.standard.set(snap.hasBattery, forKey: "probeHasBattery")
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // 启动参数 --history 或 defaults 键 openHistoryAtLaunch：开机即打开历史窗口
        if CommandLine.arguments.contains("--history")
            || UserDefaults.standard.bool(forKey: "openHistoryAtLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.showHistory(nil)
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        timer?.invalidate()
        PowerHistory.shared.save()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 72)
        guard let btn = statusItem.button else { return }
        btn.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        btn.title = "— w"
    }

    func setupMenu() {
        let menu = NSMenu()

        miPower   = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miPower.isEnabled = false
        miCPU     = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miCPU.isEnabled = false
        miFlow    = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miFlow.isEnabled = false
        miBattery = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miBattery.isEnabled = false
        miHealth  = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miHealth.isEnabled = false
        miCycle   = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miCycle.isEnabled = false
        miTemp    = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miTemp.isEnabled = false
        miVolt    = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miVolt.isEnabled = false
        miSource  = NSMenuItem(title: "…", action: nil, keyEquivalent: ""); miSource.isEnabled = false

        menu.addItem(miPower)
        menu.addItem(miCPU)
        menu.addItem(miFlow)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(miBattery)
        menu.addItem(miHealth)
        menu.addItem(miCycle)
        menu.addItem(miTemp)
        menu.addItem(miVolt)
        menu.addItem(miSource)
        menu.addItem(NSMenuItem.separator())

        let hist = NSMenuItem(title: "功耗历史…", action: #selector(showHistory(_:)), keyEquivalent: "h")
        hist.target = self
        menu.addItem(hist)

        let edit = NSMenuItem(title: "编辑颜色区间…", action: #selector(openConfig(_:)), keyEquivalent: ",")
        edit.target = self
        menu.addItem(edit)
        let reload = NSMenuItem(title: "重新加载配置", action: #selector(reloadConfig(_:)), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        miPanel = NSMenuItem(title: "显示桌面浮窗", action: #selector(togglePanel(_:)), keyEquivalent: "p")
        miPanel.target = self
        menu.addItem(miPanel)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func refresh() {
        snap = readBattery()
        PowerHistory.shared.ingest(snap)
        updateStatusTitle()
        updateMenu()
        if panel?.isVisible == true { updatePanel() }
        if historyWC?.window?.isVisible == true { historyWC?.refresh() }
    }

    func toneColor() -> NSColor { CONFIG.color(for: snap.totalWatts) }

    func updateStatusTitle() {
        guard let btn = statusItem.button else { return }
        let color: NSColor
        let text: String
        if !snap.hasBattery && snap.systemWatts < 0 {
            text = "N/A"
            color = .secondaryLabelColor
        } else {
            // 100w 以上省掉小数，省菜单栏空间（16 寸满载、台式机常见）
            text = snap.totalWatts >= 100 ? String(format: "%.0fw", snap.totalWatts)
                                          : String(format: "%.1fw", snap.totalWatts)
            color = toneColor()
        }
        let attr = NSMutableAttributedString(string: text)
        attr.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.font,
                          value: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                          range: NSRange(location: 0, length: attr.length))
        btn.attributedTitle = attr
        statusItem.length = max(50, min(86, CGFloat(text.count) * 8.5 + 12))
    }

    func updateMenu() {
        let s = snap
        miPower.title = s.totalWatts >= 0
            ? String(format: "整机功耗：%.1f w", s.totalWatts)
            : "整机功耗：不可读"
        miCPU.title   = s.cpuWatts >= 0
            ? String(format: "CPU 功耗：%.1f w", s.cpuWatts)
            : "CPU 功耗：本机不可读"
        if s.hasBattery {
            miFlow.title = (s.external ? "电池输入端：" : "电池输出端：") + s.flowText
        } else {
            miFlow.title = "电池：本机无电池（台式机）"
        }

        if !s.hasBattery {
            miBattery.title = "电量：—（无电池）"
        } else if s.hoursLeft > 0 {
            let h = Int(s.hoursLeft)
            let m = Int((s.hoursLeft - Double(h)) * 60)
            miBattery.title = String(format: "电量：%d%%  ·  约 %d 小时 %d 分", s.soc, h, m)
        } else {
            miBattery.title = String(format: "电量：%d%%  ·  可用 %.1f Wh", s.soc, s.remainWh)
        }
        miHealth.title = s.health > 0
            ? String(format: "健康度：%.1f%%  (%d / %d mAh)", s.health, s.maxCapacity, s.designCapacity)
            : "健康度：—"
        miCycle.title  = s.hasBattery ? String(format: "循环次数：%d 次", s.cycleCount) : "循环次数：—"
        miTemp.title   = s.temperature > 0
            ? String(format: "电池温度：%.1f ℃", Double(s.temperature) / 100.0)
            : "电池温度：—"
        miVolt.title   = s.hasBattery
            ? String(format: "标称电压：%.1f V（%@）", s.nominalV,
                     CONFIG.voltageAuto ? "自动探测" : "配置指定")
            : "标称电压：—"
        miSource.title = "功耗来源：" + s.wattsSource
        miPanel.state  = (panel?.isVisible == true) ? .on : .off
    }

    // ── 历史窗口 ─────────────────────────────
    @objc func showHistory(_ sender: Any?) {
        if historyWC == nil { historyWC = HistoryWindowController() }
        historyWC?.refresh()
        NSApp.activate(ignoringOtherApps: true)
        historyWC?.showWindow(nil)
        historyWC?.window?.makeKeyAndOrderFront(nil)
    }

    // ── 配置操作 ─────────────────────────────
    @objc func openConfig(_ sender: Any?) {
        if !FileManager.default.fileExists(atPath: Config.fileURL.path) { _ = Config.load() }
        NSWorkspace.shared.open(Config.dirURL)
    }

    @objc func reloadConfig(_ sender: Any?) {
        let fresh = Config.load()
        CONFIG.nominalVoltage = fresh.nominalVoltage
        CONFIG.voltageAuto = fresh.voltageAuto
        CONFIG.zones = fresh.zones
        updateStatusTitle()
        updateMenu()
        if panel?.isVisible == true { updatePanel() }
    }

    // ── 浮窗 ─────────────────────────────────
    @objc func togglePanel(_ sender: Any?) {
        if panel?.isVisible == true { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        UserDefaults.standard.set(true, forKey: "showPanel")
        updatePanel()
        updateMenu()
    }

    func hidePanel() {
        panel?.orderOut(nil)
        UserDefaults.standard.set(false, forKey: "showPanel")
        updateMenu()
    }

    func buildPanel() {
        let w: CGFloat = 222, h: CGFloat = 126

        var rect = NSRect(x: 0, y: 0, width: w, height: h)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            rect.origin = NSPoint(x: vf.maxX - w - 30, y: vf.maxY - h - 20)
        }

        let p = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false

        let deskLevel = CGWindowLevelForKey(.desktopIconWindow)
        p.level = NSWindow.Level(rawValue: Int(deskLevel) + 1)

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        p.contentView = blur

        let big = NSTextField(labelWithAttributedString: NSAttributedString(string: "0.0w"))
        big.alignment = .center
        big.frame = NSRect(x: 0, y: 62, width: w, height: 46)
        blur.addSubview(big)
        bigLabel = big

        let cap = NSTextField(labelWithString: "整机功耗")
        cap.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        cap.textColor = .secondaryLabelColor
        cap.alignment = .center
        cap.frame = NSRect(x: 0, y: 48, width: w, height: 13)
        blur.addSubview(cap)
        capLabel = cap

        let flow = NSTextField(labelWithString: "—")
        flow.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        flow.textColor = .secondaryLabelColor
        flow.alignment = .center
        flow.frame = NSRect(x: 0, y: 26, width: w, height: 16)
        blur.addSubview(flow)
        flowLabel = flow

        let bar = BarView(frame: NSRect(x: 22, y: 13, width: w - 44, height: 6))
        blur.addSubview(bar)
        barView = bar

        p.setFrameAutosaveName("PowerWidgetPanel")
        p.setContentSize(NSSize(width: w, height: h))
        panel = p
    }

    let centerPar: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }()

    func updatePanel() {
        let s = snap

        let num = String(format: "%.1f", s.totalWatts)
        let color = toneColor()
        let attr = NSMutableAttributedString(
            string: num,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: color,
                .paragraphStyle: centerPar
            ])
        attr.append(NSAttributedString(
            string: "w",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .medium),
                .foregroundColor: color.withAlphaComponent(0.72),
                .paragraphStyle: centerPar
            ]))
        bigLabel?.attributedStringValue = attr

        if s.hasBattery {
            capLabel?.stringValue = "整机功耗"
            flowLabel?.stringValue = "\(s.soc)%  ·  " + s.flowText
            if s.external {
                flowLabel?.textColor = s.batteryWatts > 0.2 ? .systemBlue : NSColor.secondaryLabelColor
            } else {
                flowLabel?.textColor = NSColor.secondaryLabelColor
            }
            barView?.progress = Double(s.soc) / 100.0
            barView?.color = s.soc <= 15 ? .systemRed : (s.soc <= 30 ? .systemOrange : .systemGreen)
        } else {
            // 台式机（Mac mini / Studio / iMac）：没有电池，只有 SMC 整机功耗
            capLabel?.stringValue = s.systemWatts >= 0 ? "整机功耗（无电池）" : "本机无电池"
            flowLabel?.stringValue = s.systemWatts >= 0 ? "台式机  ·  无电池" : "读不到功耗数据"
            flowLabel?.textColor = NSColor.secondaryLabelColor
            barView?.progress = 0
        }
    }
}

// ─────────────────────────────────────────────
//  启动
// ─────────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
