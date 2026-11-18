// Spoolup menu bar app — one status item; its popover switches between Claude Code and Codex,
// and ⤢ opens the full dashboard. Data comes from the local collector (127.0.0.1:8787).

import SwiftUI
import Charts
import AppKit
import Combine
import WebKit
import UserNotifications

// MARK: - Language

/// UI language, shared with the web dashboard through the collector's /api/prefs.
/// Read by the free formatting functions as well as views, hence a global.
nonisolated(unsafe) var uiLang: String = UserDefaults.standard.string(forKey: "lang")
    ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")

func L(_ zh: String, _ en: String) -> String { uiLang == "en" ? en : zh }

// MARK: - API models

struct Summary: Decodable {
    let now: Double
    let window: Int
    let indexing: Bool
    let minTpsTokens: Int
    let agents: [String: AgentStats]
    let status: String?
    let issues: [Issue]?
    let verified: [String: [String]]?
    let lang: String?
}

/// A self-check finding from the collector (parse failures, rule drift, untested versions…).
struct Issue: Decodable, Identifiable {
    let level: String          // error | warn | info
    let agent: String?         // nil = applies to both
    let id: String
    let title: String
    let detail: String
    let file: String?
    let message: String?
    let sample: String?
    var titleEn: String? = nil
    var detailEn: String? = nil

    var text: String { uiLang == "en" ? titleEn ?? title : title }
    var detailText: String { uiLang == "en" ? detailEn ?? detail : detail }

    /// Only errors badge / notify; warnings live in the dashboard's diagnostic record.
    var loud: Bool { level == "error" }
    func applies(to a: Agent) -> Bool { agent == nil || agent == a.rawValue }
    var color: Color { level == "error" ? .red : level == "warn" ? .orange : .secondary }
    var symbol: String {
        level == "error" ? "xmark.octagon.fill" : level == "warn" ? "exclamationmark.triangle.fill" : "info.circle"
    }
}

struct AgentStats: Decodable {
    let calls: Int
    let ttftP50: Double?
    let ttftP90: Double?
    let tpsP50: Double?
    let tpsP10: Double?
    let tpsP90: Double?
    let tpsWeighted: Double?
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let last: Call?
    let lastValid: Call?
    let recent: [Point]
    let models: [ModelStats]
    let live: [Live]
}

struct Call: Decodable {
    let ts: Double
    let model: String?
    let ttftMs: Double?
    let durationMs: Double?
    let outputTokens: Int?
    let tps: Double?
}

struct Point: Decodable {
    let ts: Double
    let ttft: Double?
    let tps: Double?
    let out: Int?
    let model: String?
}

struct ModelStats: Decodable, Identifiable {
    let model: String
    let calls: Int
    let ttftP50: Double?
    let tpsP50: Double?
    var id: String { model }
}

struct Live: Decodable {
    let model: String?
    let elapsedMs: Double
}

// MARK: - Agents, styles, formatting

enum Agent: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    var color: Color {
        self == .claude ? Color(red: 0.851, green: 0.443, blue: 0.298) : Color(red: 0.239, green: 0.545, blue: 0.878)
    }
    var shortcut: KeyEquivalent { self == .claude ? "1" : "2" }
}

let windows: [(Int, String)] = [(3600, "1h"), (21600, "6h"), (86400, "24h"), (604800, "7d"), (1209600, "14d")]

/// "近 1 小时" / "last 1 hour".
func windowPhrase(_ sec: Int) -> String {
    let zh = [3600: "1 小时", 21600: "6 小时", 86400: "24 小时", 604800: "7 天", 1209600: "14 天"]
    let en = [3600: "1 hour", 21600: "6 hours", 86400: "24 hours", 604800: "7 days", 1209600: "14 days"]
    return L("近 \(zh[sec] ?? "")", "last \(en[sec] ?? "")")
}

func fmtMs(_ v: Double?) -> String {
    guard let v else { return "—" }
    if v < 1000 { return "\(Int(v.rounded()))ms" }
    return String(format: v < 10000 ? "%.2fs" : "%.1fs", v / 1000)
}

func fmtTps(_ v: Double?) -> String {
    guard let v else { return "—" }
    return v >= 100 ? "\(Int(v.rounded()))" : String(format: "%.1f", v)
}

func fmtTok(_ v: Int) -> String {
    let d = Double(v)
    if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
    if d >= 1e6 { return String(format: "%.2fM", d / 1e6) }
    if d >= 1e4 { return String(format: "%.1fk", d / 1e3) }
    return "\(v)"
}

func ago(_ ts: Double) -> String {
    let s = Int((Date().timeIntervalSince1970 * 1000 - ts) / 1000)
    if s < 60 { return L("\(max(s, 0)) 秒前", "\(max(s, 0))s ago") }
    if s < 3600 { return L("\(s / 60) 分钟前", "\(s / 60)m ago") }
    if s < 86400 { return L("\(s / 3600) 小时前", "\(s / 3600)h ago") }
    return L("\(s / 86400) 天前", "\(s / 86400)d ago")
}

func shortModel(_ m: String?) -> String {
    (m ?? "unknown").replacingOccurrences(of: "claude-", with: "")
}

/// Round up to a readable gauge maximum (1, 2, 2.5, 5 × 10^n).
func niceCeil(_ x: Double) -> Double {
    guard x > 0 else { return 1 }
    let p = pow(10, floor(log10(x)))
    for m in [1, 2, 2.5, 5, 10] where m * p >= x { return m * p }
    return 10 * p
}

extension AgentStats {
    var tpsScale: Double { niceCeil(max(tpsP90 ?? 0, lastValid?.tps ?? 0, 50) * 1.15) }
    var ttftScale: Double { niceCeil(max(ttftP90 ?? 0, lastValid?.ttftMs ?? 0, 1000) * 1.1) }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var summary: Summary?
    @Published var offline = false
    @Published var lang = uiLang {
        didSet { uiLang = lang; UserDefaults.standard.set(lang, forKey: "lang") }
    }
    private var misses = 0

    /// Switch language here and tell the collector, so the web dashboard follows.
    func setLang(_ l: String) {
        lang = l
        var req = URLRequest(url: base.appendingPathComponent("api/prefs"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["lang": l])
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    /// Collector findings plus our own "can't reach it" error.
    var issues: [Issue] {
        var list = summary?.issues ?? []
        if offline {
            list.insert(Issue(level: "error", agent: nil, id: "offline", title: "采集服务无响应",
                              detail: "无法连接 \(base.absoluteString)，菜单栏数据停在上次刷新。", file: nil, message: nil, sample: nil,
                              titleEn: "Collector not responding",
                              detailEn: "Can't reach \(base.absoluteString); menu bar data is from the last refresh."), at: 0)
        }
        return list
    }
    @Published var windowSec: Int = UserDefaults.standard.object(forKey: "windowSec") as? Int ?? 3600 {
        didSet { UserDefaults.standard.set(windowSec, forKey: "windowSec"); Task { await refresh() } }
    }

    let base: URL = {
        let port = ProcessInfo.processInfo.environment["SPOOLUP_PORT"] ?? "8787"
        return URL(string: "http://127.0.0.1:\(port)")!
    }()
    private var timer: Timer?
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Poll fast only while the panel is open. The icon alone can lag: even Claude's median TTFT is ~20 s.
    var panelOpen = false {
        didSet { if panelOpen != oldValue { schedule() } }
    }

    func start() {
        Task { await refresh() }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: panelOpen ? 2 : 20, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        var comps = URLComponents(url: base.appendingPathComponent("api/summary"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "window", value: String(windowSec))]
        do {
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 3
            let (data, _) = try await URLSession.shared.data(for: req)
            let s = try decoder.decode(Summary.self, from: data)
            // Pick up a language change made in the web dashboard.
            if let l = s.lang, l != lang { lang = l }
            summary = s
            misses = 0
            offline = false
        } catch {
            // One slow poll isn't an outage; three in a row (~6 s) is.
            misses += 1
            if misses >= 3 || summary == nil { offline = true }
        }
    }

    func startService() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.spoolup.server"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { await self.refresh() } }
    }
}

// MARK: - Gauge primitives

/// A 240° arc opening downwards, like Stats' tachometer. `from`/`to` are 0…1 of the sweep.
struct GaugeArc: Shape {
    var from: Double
    var to: Double
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: r,
                 startAngle: .degrees(150 + 240 * from), endAngle: .degrees(150 + 240 * to), clockwise: false)
        return p
    }
}

struct Gauge: View {
    let fraction: Double
    var marker: Double? = nil
    let color: Color
    var track: Color = .primary.opacity(0.12)
    var lineWidth: CGFloat = 8

    var body: some View {
        let f = min(max(fraction, 0), 1)
        ZStack {
            GaugeArc(from: 0, to: 1).stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            if f > 0 {
                GaugeArc(from: 0, to: f).stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
            if let marker {
                // Median tick: a short notch across the track.
                let m = min(max(marker, 0), 1)
                GaugeArc(from: m - 0.004, to: m + 0.004)
                    .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth + 4, lineCap: .butt))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// The Spoolup mark (same geometry as assets/logo.svg): graphite squircle,
/// two-agent tachometer, white needle, faint rate sparkline.
struct LogoMark: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 64
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            let body = Path(roundedRect: CGRect(x: 2 * k, y: 2 * k, width: 60 * k, height: 60 * k), cornerRadius: 14 * k, style: .continuous)
            ctx.fill(body, with: .linearGradient(Gradient(colors: [Color(red: 0.204, green: 0.204, blue: 0.227), Color(red: 0.071, green: 0.071, blue: 0.078)]),
                                                 startPoint: p(32, 2), endPoint: p(32, 62)))
            ctx.fill(body, with: .linearGradient(Gradient(colors: [.white.opacity(0.14), .white.opacity(0)]), startPoint: p(32, 2), endPoint: p(32, 32)))
            ctx.stroke(body, with: .color(.white.opacity(0.08)), lineWidth: k)
            var spark = Path()
            spark.addLines([p(15, 52), p(21, 49.5), p(26, 51), p(32, 46.5), p(38, 48.5), p(43, 44.5), p(49, 46)])
            ctx.stroke(spark, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1.6 * k, lineCap: .round, lineJoin: .round))
            func arc(_ from: Double, _ to: Double) -> Path {
                var a = Path()
                a.addArc(center: p(32, 35), radius: 18 * k, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                return a
            }
            ctx.stroke(arc(150, 266), with: .color(Agent.claude.color), style: StrokeStyle(lineWidth: 6 * k, lineCap: .round))
            ctx.stroke(arc(274, 390), with: .color(Agent.codex.color), style: StrokeStyle(lineWidth: 6 * k, lineCap: .round))
            var needle = Path()
            needle.move(to: p(32, 35)); needle.addLine(to: p(42.6, 24.4))
            ctx.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: 3 * k, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 28.6 * k, y: 31.6 * k, width: 6.8 * k, height: 6.8 * k)), with: .color(.white))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Menu bar icon

/// The single status item: the Spoolup mark drawn monochrome in the menu bar's ink,
/// with a dot while a request is in flight and a red/orange badge when self-checks fail.
struct MenuBarIcon: View {
    let ink: Color
    var live: Agent? = nil
    var issueLevel: String? = nil
    var dimmed = false

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: 9, y: 10)
            func arc(_ from: Double, _ to: Double) -> Path {
                var a = Path()
                a.addArc(center: c, radius: 6.6, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
                return a
            }
            let style = StrokeStyle(lineWidth: 2.1, lineCap: .round)
            ctx.stroke(arc(150, 264), with: .color(ink), style: style)
            ctx.stroke(arc(276, 390), with: .color(ink.opacity(0.55)), style: style)
            var needle = Path()
            needle.move(to: c)
            needle.addLine(to: CGPoint(x: c.x + 4.4, y: c.y - 4.4))
            ctx.stroke(needle, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)), with: .color(ink))
        }
        .frame(width: 18, height: 18)
        .opacity(dimmed ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if let live { Circle().fill(live.color).frame(width: 5, height: 5).offset(x: 1, y: -1) }
        }
        .overlay(alignment: .topTrailing) {
            if let issueLevel {
                Text("!")
                    .font(.system(size: 6.5, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 8.5, height: 8.5)
                    .background(Circle().fill(issueLevel == "error" ? Color.red : Color.orange))
                    .offset(x: 2.5, y: 0)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
    }
}

@MainActor
func renderIcon(store: Store, dark: Bool, scale: CGFloat) -> NSImage? {
    let loud = store.issues.filter(\.loud)
    let level = loud.contains { $0.level == "error" } ? "error" : loud.isEmpty ? nil : "warn"
    let live = Agent.allCases.first { !(store.summary?.agents[$0.rawValue]?.live.isEmpty ?? true) }
    let r = ImageRenderer(content: MenuBarIcon(ink: dark ? .white : .black, live: live, issueLevel: level, dimmed: store.offline))
    r.scale = scale
    return r.nsImage
}

/// Two-segment switch between the agents; each segment carries the agent's color,
/// a live dot and an issue mark so the other side's state is visible too.
struct AgentSwitch: View {
    @Binding var selected: String
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Agent.allCases) { a in
                let on = selected == a.rawValue
                let st = store.summary?.agents[a.rawValue]
                let issue = store.issues.first { $0.loud && $0.agent == a.rawValue }
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selected = a.rawValue }
                } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(a.color).frame(width: 7, height: 7)
                        Text(a.name).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        if issue != nil {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(issue!.color)
                        } else if !(st?.live.isEmpty ?? true) {
                            Circle().fill(.green).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 9)
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(on ? Color(nsColor: .controlBackgroundColor) : .clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 0.5)
                    )
                    .foregroundStyle(on ? .primary : .secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(a.shortcut, modifiers: .command)
                .help("\(a.name) (⌘\(String(a.shortcut.character)))")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Popover dashboard

struct AgentPanel: View {
    @ObservedObject var store: Store
    // @AppStorage rather than @State: the Command Line Tools swiftc ships without the SwiftUI macro plugin.
    @AppStorage("agent") var selected = Agent.claude.rawValue
    var agent: Agent { Agent(rawValue: selected) ?? .claude }

    var body: some View {
        VStack(spacing: 0) {
            top
            issueBanner
            if let s = store.summary, let st = s.agents[agent.rawValue] {
                content(st, s)
            } else {
                offlineView
            }
            footer
        }
        .frame(width: 300)
    }

    var top: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                LogoMark(size: 20)
                Text("Spoolup").font(.system(size: 13, weight: .semibold))
                    .help(ruleText)
                Spacer()
                if store.summary?.indexing == true {
                    Text(L("索引中…", "Indexing…")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            AgentSwitch(selected: $selected, store: store)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    func content(_ st: AgentStats, _ s: Summary) -> some View {
        VStack(spacing: 0) {
            header(st)
            dashboard(st)
            SectionTitle(L("TPS 历史 · 最近 \(st.recent.count) 次", "TPS history · last \(st.recent.count)"))
            History(points: st.recent, value: { ($0.out ?? 0) >= s.minTpsTokens ? $0.tps : nil },
                    color: agent.color, unit: "", format: { "\(fmtTps($0)) t/s" })
                .id("tps-\(agent.rawValue)")
                .frame(height: 64).padding(.horizontal, 12)
            SectionTitle(L("TTFT 历史", "TTFT history"))
            History(points: st.recent, value: { $0.ttft.map { $0 / 1000 } },
                    color: agent.color, unit: "s", format: { fmtMs($0 * 1000) })
                .id("ttft-\(agent.rawValue)")
                .frame(height: 64).padding(.horizontal, 12)
            SectionTitle(L("详情 · ", "Details · ") + windowPhrase(s.window))
            VStack(spacing: 3) {
                DetailRow(color: agent.color, label: "TTFT P50 / P90", value: "\(fmtMs(st.ttftP50)) / \(fmtMs(st.ttftP90))")
                DetailRow(color: agent.color.opacity(0.6), label: "TPS P50", value: "\(fmtTps(st.tpsP50)) t/s")
                DetailRow(color: agent.color.opacity(0.35), label: "TPS P10 / P90", value: "\(fmtTps(st.tpsP10)) / \(fmtTps(st.tpsP90))")
                DetailRow(color: nil, label: L("加权 TPS", "Weighted TPS"), value: "\(fmtTps(st.tpsWeighted)) t/s")
                DetailRow(color: nil, label: L("调用 / 进行中", "Calls / in flight"), value: "\(st.calls) / \(st.live.count)")
            }
            .padding(.horizontal, 12)
            SectionTitle("Token")
            VStack(spacing: 3) {
                DetailRow(color: nil, label: L("输入", "Input"), value: fmtTok(st.inputTokens))
                DetailRow(color: nil, label: L("缓存命中", "Cache hit"), value: st.inputTokens > 0 ? "\(Int(100 * Double(st.cachedTokens) / Double(st.inputTokens)))%" : "—")
                DetailRow(color: nil, label: L("输出（思考）", "Output (reasoning)"),
                          value: L("\(fmtTok(st.outputTokens))（\(fmtTok(st.reasoningTokens))）", "\(fmtTok(st.outputTokens)) (\(fmtTok(st.reasoningTokens)))"))
            }
            .padding(.horizontal, 12)
            if !st.models.isEmpty {
                SectionTitle(L("模型", "Models"))
                VStack(spacing: 3) {
                    ForEach(st.models.prefix(5)) { m in
                        HStack(spacing: 6) {
                            Text(shortModel(m.model)).lineLimit(1)
                            Spacer()
                            Text(L("\(m.calls) 次", "\(m.calls)×")).foregroundStyle(.secondary)
                            Text(fmtMs(m.ttftP50)).frame(width: 48, alignment: .trailing)
                            Text("\(fmtTps(m.tpsP50)) t/s").frame(width: 58, alignment: .trailing)
                        }
                        .font(.system(size: 11).monospacedDigit())
                    }
                }
                .padding(.horizontal, 12)
            }
            Spacer().frame(height: 10)
        }
    }

    func header(_ st: AgentStats) -> some View {
        HStack(spacing: 6) {
            if !st.live.isEmpty {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(L("\(st.live.count) 个请求进行中", "\(st.live.count) in flight"))
            } else if let last = st.last {
                Text(L("上次调用 ", "Last call ") + "\(ago(last.ts)) · \(shortModel(last.model))")
            } else {
                Text(L("此窗口内暂无调用", "No calls in this window"))
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }

    func dashboard(_ st: AgentStats) -> some View {
        let lv = st.lastValid
        let call = lv.map { L("最近有效调用", "Latest valid call") + " · \(shortModel($0.model)) · \(fmtTok($0.outputTokens ?? 0)) tok\n" } ?? ""
        return HStack(spacing: 8) {
            GaugeTile(title: "TPS", value: fmtTps(lv?.tps), unit: "t/s",
                      fraction: (lv?.tps ?? 0) / st.tpsScale, marker: st.tpsP50.map { $0 / st.tpsScale }, color: agent.color)
                .help(call + L("量程", "Range") + " 0–\(Int(st.tpsScale)) t/s · " + L("刻线", "tick") + " = P50 \(fmtTps(st.tpsP50))")
            GaugeTile(title: "TTFT", value: fmtMs(lv?.ttftMs), unit: L("首块延迟", "first block"),
                      fraction: (lv?.ttftMs ?? 0) / st.ttftScale, marker: st.ttftP50.map { $0 / st.ttftScale }, color: agent.color)
                .help(call + L("量程", "Range") + " 0–\(fmtMs(st.ttftScale)) · " + L("刻线", "tick") + " = P50 \(fmtMs(st.ttftP50))")
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    var mine: [Issue] { store.issues.filter { $0.applies(to: agent) } }

    @ViewBuilder
    var issueBanner: some View {
        let loud = mine.filter(\.loud)
        if !loud.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(loud.prefix(3)) { i in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: i.symbol).foregroundStyle(i.color).font(.system(size: 11))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.text).font(.system(size: 11.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(i.detailText).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if loud.count > 3 {
                    Text(L("还有 \(loud.count - 3) 条，在完整统计中查看", "\(loud.count - 3) more in the full dashboard")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((loud.contains { $0.level == "error" } ? Color.red : Color.orange).opacity(0.1))
        }
    }

    /// Reminder that every number here is inferred from log formats (shown on hover over the title).
    var ruleText: String {
        let v = store.summary?.verified
        let cc = v?["claude"]?.joined(separator: "/") ?? "?", cx = v?["codex"]?.joined(separator: "/") ?? "?"
        return L("数值由日志时间戳按规则推断（已验证 Claude Code \(cc)、Codex \(cx)）",
                 "Numbers are inferred from log timestamps by rules (verified on Claude Code \(cc), Codex \(cx))")
    }

    var offlineView: some View {
        VStack(spacing: 8) {
            LogoMark(size: 44).opacity(0.85)
            Text(store.offline ? L("采集服务未运行", "Collector not running") : L("连接中…", "Connecting…")).font(.system(size: 13, weight: .medium))
            Text(L("Spoolup 读取本地日志的服务没有响应", "The service that reads your local logs isn't responding")).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L("启动服务", "Start service")) { store.startService() }.controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Picker("", selection: $store.windowSec) {
                    ForEach(windows, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Spacer()
                Button { store.setLang(store.lang == "en" ? "zh" : "en") } label: {
                    Text(L("EN", "中")).font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .help(L("Switch to English（网页同步切换）", "切换到中文 (the web dashboard follows)"))
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: L("完整统计", "Full dashboard")) { DashboardWindow.shared.show(store: store) }
                IconButton(symbol: "power", help: L("退出", "Quit")) { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 5)
    }
}

struct DetailRow: View {
    let color: Color?
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.system(size: 11).monospacedDigit())
    }
}

struct GaugeTile: View {
    let title: String
    let value: String
    let unit: String
    let fraction: Double
    let marker: Double?
    let color: Color

    var body: some View {
        ZStack {
            Gauge(fraction: fraction, marker: marker, color: color, lineWidth: 7)
                .frame(width: 104, height: 104)
            VStack(spacing: 0) {
                Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 20, weight: .semibold).monospacedDigit())
                if !unit.isEmpty { Text(unit).font(.system(size: 9.5)).foregroundStyle(.secondary) }
            }
            .offset(y: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }
}

/// Hover / pin state for one History chart (an ObservableObject: no SwiftUI macro plugin here).
final class ChartPick: ObservableObject {
    @Published var hover: Int?
    @Published var pinned: Int?
}

/// Recent-call curve. Hovering snaps to the nearest call and draws crosshair lines at its
/// value; clicking pins that call (click it again to unpin).
struct History: View {
    let points: [Point]
    let value: (Point) -> Double?
    let color: Color
    let unit: String
    let format: (Double) -> String
    @StateObject private var pick = ChartPick()

    var body: some View {
        let pts = points.enumerated().compactMap { i, p in value(p).map { (i, $0) } }
        let sorted = pts.map(\.1).sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        let sel = (pick.hover ?? pick.pinned).flatMap { i in pts.first { $0.0 == i } }
        if pts.count < 2 {
            Text(L("暂无数据", "No data")).font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart {
                ForEach(pts, id: \.0) { i, v in
                    AreaMark(x: .value("i", i), y: .value("v", v))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("i", i), y: .value("v", v))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                if let median, sel == nil {
                    RuleMark(y: .value("median", median))
                        .foregroundStyle(color.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let (i, v) = sel {
                    RuleMark(x: .value("i", i))
                        .foregroundStyle(Color.primary.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    RuleMark(y: .value("v", v))
                        .foregroundStyle(color.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("i", i), y: .value("v", v))
                        .symbolSize(42)
                        .foregroundStyle(color)
                    PointMark(x: .value("i", i), y: .value("v", v))
                        .symbolSize(12)
                        .foregroundStyle(.white)
                }
            }
            .chartXAxis(.hidden)
            .chartXScale(domain: 0...max(points.count - 1, 1))
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text("\(Int(d))\(unit)") }
                    }
                    .font(.system(size: 8.5))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { g in
                    let plot = proxy.plotFrame.map { g[$0] } ?? .zero
                    // Nearest call that has a value at this x.
                    let nearest = { (x: CGFloat) -> Int? in
                        guard let f: Double = proxy.value(atX: x - plot.minX) else { return nil }
                        return pts.min { abs(Double($0.0) - f) < abs(Double($1.0) - f) }?.0
                    }
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): pick.hover = nearest(p.x)
                            case .ended: pick.hover = nil
                            }
                        }
                        .onTapGesture { p in
                            let i = nearest(p.x)
                            pick.pinned = pick.pinned == i ? nil : i
                        }
                }
            }
            .overlay(alignment: .topLeading) {
                if let (i, v) = sel {
                    let p = points[i]
                    HStack(spacing: 4) {
                        if pick.pinned == i { Image(systemName: "pin.fill").font(.system(size: 7.5)) }
                        Text(format(v)).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.primary)
                        Text("· \(shortModel(p.model)) · \(ago(p.ts))").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
                    .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Full dashboard window

/// The "maximize" view — Stats opens Activity Monitor; Spoolup opens the full
/// dashboard (trends, per-project, every call) in a native window.
@MainActor
final class DashboardWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, NSToolbarDelegate {
    static let shared = DashboardWindow()
    private var window: NSWindow?
    private var web: WKWebView?
    private var store: Store?

    func show(store: Store) {
        self.store = store
        if window == nil { build() }
        // Labels are set when created; rebuild them so they match the current language.
        let toolbar = NSToolbar(identifier: "spoolup-\(uiLang)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        // The page streams updates itself; only reload for a new time window or after a failed load.
        if web?.url != url { reload() }
        NSApp.setActivationPolicy(.regular)
        installMenu()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var url: URL {
        var c = URLComponents(url: store!.base, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "w", value: String(store!.windowSec))]
        return c.url!
    }

    private func build() {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground") // no white flash before the page paints
        // A comfortable default that never fills the screen; the user's own resize is remembered below.
        let vis = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1040, vis.width * 0.7), height: min(700, vis.height * 0.75))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Spoolup"
        w.contentView = web
        w.minSize = NSSize(width: 720, height: 520)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.toolbarStyle = .unifiedCompact
        w.center()
        w.setFrameAutosaveName("SpoolupDashboard.v2") // v1 saved the old near-fullscreen default
        self.web = web
        self.window = w
    }

    @objc func reload() { web?.load(URLRequest(url: url)) }
    @objc func closeWindow() { window?.performClose(nil) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        webView.loadHTMLString("""
            <html><body style="font:14px -apple-system;color:#888;display:grid;place-items:center;height:90vh">
            <div style="text-align:center">\(L("采集服务未运行", "Collector not running"))<br><br><small>\(L("启动 com.spoolup.server 后按 ⌘R 刷新", "Start com.spoolup.server, then press ⌘R"))</small></div>
            </body></html>
            """, baseURL: nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a pure menu bar app once the big window is gone.
        NSApp.setActivationPolicy(.accessory)
    }

    // Toolbar: refresh only — on macOS the native window is the dashboard (browsers are for Windows).
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("reload")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .init("reload")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L("刷新", "Reload"))
        item.label = L("刷新", "Reload"); item.toolTip = L("刷新", "Reload") + " (⌘R)"; item.action = #selector(reload)
        return item
    }

    /// Minimal menu so ⌘W / ⌘R / ⌘Q / ⌘C work while the window is frontmost.
    private func installMenu() {
        // Rebuilt on every show so the titles follow the current language.
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector, String, AnyObject?)]) {
            let holder = NSMenuItem()
            let m = NSMenu(title: title)
            for (t, sel, key, target) in items { m.addItem(withTitle: t, action: sel, keyEquivalent: key).target = target }
            holder.submenu = m
            main.addItem(holder)
        }
        submenu("Spoolup", [(L("退出 Spoolup", "Quit Spoolup"), #selector(NSApplication.terminate(_:)), "q", nil)])
        submenu(L("编辑", "Edit"), [(L("拷贝", "Copy"), #selector(NSText.copy(_:)), "c", nil), (L("全选", "Select All"), #selector(NSText.selectAll(_:)), "a", nil)])
        submenu(L("显示", "View"), [(L("刷新", "Reload"), #selector(reload), "r", self)])
        submenu(L("窗口", "Window"), [(L("关闭", "Close"), #selector(closeWindow), "w", self),
                       (L("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", nil)])
        NSApp.mainMenu = main
    }
}

// MARK: - Notifications

/// Posts a system notification the first time each error / warning shows up, and again
/// only if it clears and later comes back — loud, but not spammy.
@MainActor
final class IssueNotifier {
    private var active: Set<String> = []
    private var primed = false
    private let bundled = Bundle.main.bundleIdentifier != nil

    init() {
        if bundled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }

    func update(_ issues: [Issue]) {
        let loud = issues.filter(\.loud)
        let ids = Set(loud.map(\.id))
        // Don't replay everything that was already wrong at launch — the badge shows those.
        if primed {
            for i in loud where !active.contains(i.id) { post(i) }
        }
        primed = true
        active = ids
    }

    private func post(_ i: Issue) {
        let title = "Spoolup " + (i.level == "error" ? L("错误", "error") : L("警告", "warning"))
        if bundled {
            let c = UNMutableNotificationContent()
            c.title = title
            c.subtitle = i.text
            c.body = i.detailText
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: i.id, content: c, trigger: nil))
        } else {
            // Unbundled binary (dev runs): AppleScript notifications need no entitlement.
            let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc(i.detailText))\" with title \"\(esc(title))\" subtitle \"\(esc(i.text))\""]
            try? p.run()
        }
    }
}

// MARK: - Status items

@MainActor
final class StatusController: NSObject {
    let store: Store
    let item: NSStatusItem
    let popover = NSPopover()

    init(store: Store) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.autosaveName = "spoolup"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Spoolup"
        let host = NSHostingController(rootView: AgentPanel(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSWindow)?.title == "Spoolup" else { return }
                self.popover.performClose(nil)
            }
        }
        popover.animates = false
        update()
    }

    func update() {
        guard let button = item.button else { return }
        // The badge is colored, so this can't be a template image; pick the ink from the menu bar's appearance.
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = renderIcon(store: store, dark: dark, scale: button.window?.backingScaleFactor ?? 2)
        let loud = store.issues.filter(\.loud)
        button.toolTip = loud.isEmpty ? "Spoolup" : "Spoolup\n" + loud.map(\.text).joined(separator: "\n")
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.panelOpen = true
            Task { await store.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

}

extension StatusController: NSPopoverDelegate {
    // Covers every way the panel closes: click outside, the toggle, opening the dashboard.
    func popoverDidClose(_ notification: Notification) { store.panelOpen = false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let notifier = IssueNotifier()
    var controller: StatusController?
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        controller = StatusController(store: store)
        store.start()
        // objectWillChange fires before the new value lands; redraw on the next runloop turn.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.controller?.update()
                if self.store.summary?.indexing != true { self.notifier.update(self.store.issues) }
            }
            .store(in: &bag)
    }
}

// MARK: - Entry

@MainActor
func writePNG(_ img: NSImage?, _ url: URL) {
    guard let img, let tiff = img.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

/// `Spoolup --snapshot out-dir` renders the menu bar icon states and the panel for each agent to PNGs, then exits.
@MainActor
func snapshot(to dir: URL) async {
    let store = Store()
    await store.refresh()
    let icons = ImageRenderer(content: VStack(spacing: 0) {
        ForEach([false, true], id: \.self) { dark in
            HStack(spacing: 18) {
                MenuBarIcon(ink: dark ? .white : .black)
                MenuBarIcon(ink: dark ? .white : .black, live: .claude)
                MenuBarIcon(ink: dark ? .white : .black, issueLevel: "warn")
                MenuBarIcon(ink: dark ? .white : .black, live: .codex, issueLevel: "error")
                MenuBarIcon(ink: dark ? .white : .black, issueLevel: "error", dimmed: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
            .background(dark ? Color(white: 0.16) : Color(white: 0.93))
        }
    })
    icons.scale = 5
    writePNG(icons.nsImage, dir.appendingPathComponent("icons.png"))
    for a in Agent.allCases {
        UserDefaults.standard.set(a.rawValue, forKey: "agent")
        for dark in [true, false] {
            let panel = AgentPanel(store: store)
                .background(dark ? Color(white: 0.14) : Color(white: 0.97))
                .environment(\.colorScheme, dark ? .dark : .light)
            let r = ImageRenderer(content: panel)
            r.scale = 2
            writePNG(r.nsImage, dir.appendingPathComponent("panel-\(a.rawValue)-\(dark ? "dark" : "light").png"))
        }
    }
    // The full dashboard as the native window shows it.
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860))
    let host = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    host.contentView = web
    host.setFrameOrigin(NSPoint(x: -4000, y: -4000))
    host.orderBack(nil)
    web.load(URLRequest(url: store.base.appending(queryItems: [URLQueryItem(name: "w", value: "604800")])))
    try? await Task.sleep(for: .seconds(4))
    if let img = try? await web.takeSnapshot(configuration: nil) {
        writePNG(img, dir.appendingPathComponent("window.png"))
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                await snapshot(to: dir)
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
