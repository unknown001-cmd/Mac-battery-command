import Cocoa

// ─────────────────────────────────────────────
//  功耗历史：每 3 秒落一个点，保留 6 小时，落盘可跨重启
//  文件 ~/Library/Application Support/PowerWidget/history.json
// ─────────────────────────────────────────────
struct HistPoint {
    var t: Double      // unix 时间戳
    var w: Double      // 整机功耗 w
    var soc: Int       // 电量 %
    var ext: Bool      // 是否接电源
}

final class PowerHistory {
    static let shared = PowerHistory()

    private(set) var points: [HistPoint] = []
    private let bucket: Double = 3.0          // 秒/点
    private let retention: Double = 6 * 3600  // 保留 6 小时

    private var curStart: Double = 0
    private var sumW = 0.0
    private var cnt = 0
    private var lastSoc = 0
    private var lastExt = false
    private var lastSaveAt: Double = 0
    private var loaded = false

    private static var fileURL: URL {
        Config.dirURL.appendingPathComponent("history.json")
    }

    // ── 采样 ──────────────────────────────
    func ingest(_ s: Snapshot) {
        if !loaded { load() }
        let now = Date().timeIntervalSince1970
        let w = s.totalWatts

        if curStart == 0 {
            curStart = now
            sumW = 0; cnt = 0
        }
        sumW += w
        cnt += 1
        lastSoc = s.soc
        lastExt = s.external

        if now - curStart >= bucket {
            append(HistPoint(t: curStart + bucket / 2, w: sumW / Double(max(cnt, 1)),
                             soc: lastSoc, ext: lastExt))
            curStart = now
            sumW = 0; cnt = 0
        }

        if now - lastSaveAt > 60 {
            save()
            lastSaveAt = now
        }
    }

    private func append(_ p: HistPoint) {
        points.append(p)
        let cutoff = Date().timeIntervalSince1970 - retention
        if points.count > 64, points[0].t < cutoff {
            let drop = points.firstIndex { $0.t >= cutoff } ?? points.count
            if drop > 0 { points.removeFirst(drop) }
        }
    }

    /// 取某时间跨度内的点（含最近未落盘的当前值）
    func slice(span: Double, current: HistPoint?) -> [HistPoint] {
        let t0 = Date().timeIntervalSince1970 - span
        var out = points.filter { $0.t >= t0 - bucket }
        if let c = current, c.t > (out.last?.t ?? 0) { out.append(c) }
        return out
    }

    // ── 持久化 ────────────────────────────
    func load() {
        loaded = true
        guard let data = try? Data(contentsOf: PowerHistory.fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["p"] as? [[Any]] else { return }
        let cutoff = Date().timeIntervalSince1970 - retention
        var tmp: [HistPoint] = []
        for row in arr where row.count >= 4 {
            let t = (row[0] as? Double) ?? 0
            guard t > cutoff else { continue }
            let w = (row[1] as? Double) ?? 0
            let soc = (row[2] as? Int) ?? Int((row[2] as? Double) ?? 0)
            let ext = (row[3] as? Bool) ?? ((row[3] as? Int) ?? 0 == 1)
            tmp.append(HistPoint(t: t, w: w, soc: soc, ext: ext))
        }
        points = tmp.sorted { $0.t < $1.t }
    }

    func save() {
        let rows: [[Any]] = points.suffix(8000).map { [$0.t, $0.w, $0.soc, $0.ext] }
        let obj: [String: Any] = ["v": 1, "b": bucket, "p": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(at: Config.dirURL, withIntermediateDirectories: true)
        try? data.write(to: PowerHistory.fileURL)
    }

    func clear() {
        points.removeAll()
        curStart = 0; sumW = 0; cnt = 0
        save()
    }
}

// ─────────────────────────────────────────────
//  折线图
// ─────────────────────────────────────────────
final class HistoryChartView: NSView {
    var points: [HistPoint] = [] { didSet { needsDisplay = true } }
    var span: Double = 3600 { didSet { needsDisplay = true } }
    var accent: NSColor = .systemGreen { didSet { needsDisplay = true } }

    private var hoverX: CGFloat? = nil
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { false }

    private var plotRect: NSRect {
        let b = bounds
        return NSRect(x: 46, y: 26, width: max(10, b.width - 46 - 14),
                      height: max(10, b.height - 26 - 14))
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect

        // 背景
        NSColor.secondaryLabelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: plot, xRadius: 9, yRadius: 9).fill()

        guard points.count >= 2 else {
            drawEmpty(in: plot)
            return
        }

        let now = Date().timeIntervalSince1970
        let t0 = now - span
        let vis = points.filter { $0.t >= t0 - span * 0.02 }
        guard vis.count >= 2 else { drawEmpty(in: plot); return }

        // Y 轴上限（取整到 5w 的倍数）
        var peak = 5.0
        for p in vis { peak = max(peak, p.w) }
        let yMax = (peak / 5).rounded(.up) * 5
        let yMaxD = max(yMax, 5)

        func xFor(_ t: Double) -> CGFloat {
            plot.minX + CGFloat((t - t0) / span) * plot.width
        }
        func yFor(_ w: Double) -> CGFloat {
            plot.minY + CGFloat(min(max(w, 0), yMaxD) / yMaxD) * plot.height
        }

        drawGrid(plot: plot, yMax: yMaxD, t0: t0)

        // 接电时段：底部蓝色细条
        NSColor.systemBlue.withAlphaComponent(0.55).setFill()
        var i = 0
        while i < vis.count - 1 {
            if vis[i].ext {
                var j = i
                while j + 1 < vis.count && vis[j + 1].ext { j += 1 }
                let x1 = xFor(vis[i].t), x2 = xFor(vis[j].t)
                if x2 > x1 {
                    NSRect(x: x1, y: plot.minY + 2, width: max(1, x2 - x1), height: 3).fill()
                }
                i = j + 1
            } else {
                i += 1
            }
        }

        // 曲线
        let line = NSBezierPath()
        line.lineWidth = 1.8
        line.lineJoinStyle = .round
        line.move(to: NSPoint(x: xFor(vis[0].t), y: yFor(vis[0].w)))
        for p in vis.dropFirst() {
            line.line(to: NSPoint(x: xFor(p.t), y: yFor(p.w)))
        }

        // 渐变填充
        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            let fill = line.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: xFor(vis[vis.count - 1].t), y: plot.minY))
            fill.line(to: NSPoint(x: xFor(vis[0].t), y: plot.minY))
            fill.close()
            fill.addClip()
            let grad = NSGradient(colors: [accent.withAlphaComponent(0.34),
                                           accent.withAlphaComponent(0.02)])
            grad?.draw(in: plot, angle: -90)
            ctx.restoreGraphicsState()
        }

        accent.setStroke()
        line.stroke()

        // 峰值标记
        if let pk = vis.max(by: { $0.w < $1.w }), pk.w > 0.5 {
            let c = NSPoint(x: xFor(pk.t), y: yFor(pk.w))
            NSColor.secondaryLabelColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)).fill()
        }

        // 悬停指示
        if let hx = hoverX, plot.contains(NSPoint(x: hx, y: plot.midY)) {
            let tAt = t0 + Double((hx - plot.minX) / plot.width) * span
            if let near = vis.min(by: { abs($0.t - tAt) < abs($1.t - tAt) }) {
                let px = xFor(near.t), py = yFor(near.w)
                let dash = NSBezierPath()
                dash.move(to: NSPoint(x: px, y: plot.minY))
                dash.line(to: NSPoint(x: px, y: plot.maxY))
                dash.lineWidth = 1
                dash.setLineDash([3, 3], count: 2, phase: 0)
                NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
                dash.stroke()

                NSColor.labelColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: px - 3, y: py - 3, width: 6, height: 6)).fill()

                // 气泡
                let df = DateFormatter()
                df.dateFormat = "HH:mm:ss"
                let text = String(format: "%.1fw  %@", near.w, df.string(from: Date(timeIntervalSince1970: near.t)))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
                let size = (text as NSString).size(withAttributes: attrs)
                var bx = px + 8
                if bx + size.width + 12 > plot.maxX { bx = px - size.width - 20 }
                let box = NSRect(x: bx, y: min(py + 10, plot.maxY - size.height - 6),
                                 width: size.width + 12, height: size.height + 6)
                NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
                NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
                NSColor.secondaryLabelColor.withAlphaComponent(0.25).setStroke()
                let border = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
                border.lineWidth = 1
                border.stroke()
                (text as NSString).draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
            }
        }
    }

    private func drawGrid(plot: NSRect, yMax: Double, t0: Double) {
        let gridColor = NSColor.secondaryLabelColor.withAlphaComponent(0.16)
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let steps = 4
        for s in 0...steps {
            let frac = CGFloat(s) / CGFloat(steps)
            let y = plot.minY + frac * plot.height
            let p = NSBezierPath()
            p.move(to: NSPoint(x: plot.minX, y: y))
            p.line(to: NSPoint(x: plot.maxX, y: y))
            p.lineWidth = 1
            gridColor.setStroke()
            p.stroke()

            let val = yMax * Double(frac)
            let label = String(format: "%.0f", val)
            let size = (label as NSString).size(withAttributes: textAttrs)
            (label as NSString).draw(at: NSPoint(x: plot.minX - size.width - 8, y: y - size.height / 2),
                                     withAttributes: textAttrs)
        }

        // 时间轴标签
        let now = Date().timeIntervalSince1970
        let ticks: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        for f in ticks {
            let t = t0 + (now - t0) * f
            let x = plot.minX + CGFloat(f) * plot.width
            let label: String
            if f == 1.0 {
                label = "现在"
            } else if span <= 600 {
                label = String(format: "−%.0f分", (1 - f) * span / 60)
            } else if span <= 3600 {
                label = String(format: "−%.0f分", (1 - f) * span / 60)
            } else {
                label = df.string(from: Date(timeIntervalSince1970: t))
            }
            let size = (label as NSString).size(withAttributes: textAttrs)
            var lx = x - size.width / 2
            lx = min(max(lx, plot.minX - 6), plot.maxX - size.width + 6)
            (label as NSString).draw(at: NSPoint(x: lx, y: plot.minY - size.height - 6),
                                     withAttributes: textAttrs)
        }
    }

    private func drawEmpty(in plot: NSRect) {
        let text = "正在收集数据…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2),
                  withAttributes: attrs)
    }

    // ── 悬停 ──────────────────────────────
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }
}

// ─────────────────────────────────────────────
//  历史窗口
// ─────────────────────────────────────────────
final class HistoryWindowController: NSWindowController {
    private let chart = HistoryChartView()
    private let seg = NSSegmentedControl(labels: ["5分", "30分", "1时", "3时", "6时"],
                                         trackingMode: .selectOne, target: nil, action: nil)
    private let statsLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "蓝色细条 = 接电源时段")
    private let spans: [Double] = [300, 1800, 3600, 3 * 3600, 6 * 3600]

    convenience init() {
        let w: CGFloat = 660, h: CGFloat = 340
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "功耗历史"
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        win.backgroundColor = .windowBackgroundColor
        win.minSize = NSSize(width: 420, height: 240)
        win.center()
        self.init(window: win)
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let W = content.bounds.width
        let H = content.bounds.height

        let title = NSTextField(labelWithString: "整机功耗历史")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 18, y: H - 34, width: 160, height: 18)
        title.autoresizingMask = [.minYMargin]
        content.addSubview(title)

        seg.target = self
        seg.action = #selector(rangeChanged(_:))
        seg.selectedSegment = 2
        seg.frame = NSRect(x: W - 320, y: H - 38, width: 302, height: 24)
        seg.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(seg)

        statsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.frame = NSRect(x: 18, y: H - 56, width: W - 36, height: 16)
        statsLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(statsLabel)

        chart.span = spans[2]
        chart.frame = NSRect(x: 0, y: 6, width: W, height: H - 66)
        chart.autoresizingMask = [.width, .height]
        content.addSubview(chart)

        hintLabel.font = NSFont.systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.frame = NSRect(x: 18, y: 6, width: 260, height: 14)
        hintLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        content.addSubview(hintLabel)

        refresh()
    }

    @objc private func rangeChanged(_ sender: NSSegmentedControl) {
        let i = max(0, min(spans.count - 1, sender.selectedSegment))
        chart.span = spans[i]
        refresh()
    }

    func refresh() {
        let s = delegateSnapshot()
        let cur = HistPoint(t: Date().timeIntervalSince1970,
                            w: s?.totalWatts ?? 0,
                            soc: s?.soc ?? 0,
                            ext: s?.external ?? false)
        let pts = PowerHistory.shared.slice(span: chart.span, current: s == nil ? nil : cur)
        chart.points = pts
        chart.accent = CONFIG.color(for: cur.w)

        guard !pts.isEmpty else {
            statsLabel.stringValue = "还没有足够的数据，继续挂着它就会画出来"
            return
        }
        let avg = pts.reduce(0.0) { $0 + $1.w } / Double(pts.count)
        let peak = pts.map { $0.w }.max() ?? 0
        let mins = max(1, Int((Date().timeIntervalSince1970 - (pts.first?.t ?? 0)) / 60))
        statsLabel.stringValue = String(format: "当前 %.1f w   ·   平均 %.1f w   ·   峰值 %.1f w   ·   覆盖 %d 分钟   ·   %d 个采样点",
                                        cur.w, avg, peak, mins, pts.count)
    }

    private func delegateSnapshot() -> Snapshot? {
        (NSApp.delegate as? AppDelegate)?.snap
    }
}
