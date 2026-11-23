import Charts
import SwiftUI

struct MetricResponse: Decodable {
    struct AppRow: Decodable, Identifiable { let id: String; let now: Double?; let then: Double?; let pct: Double?; let yday: Double? }
    struct Day: Decodable, Identifiable { let day: String; let byApp: [String: Double]; let gross: [String: Double]?; var id: String { day } }
    struct Pt: Decodable { let m: Int; let app: String; let v: Double }
    struct Intra: Decodable { let today: [Pt]; let yday: [Pt] }
    let key: String
    let days: Int
    let sameHourEstimated: Bool
    let baseLabel: String?
    let baseDays: Int
    let intradaySince: Int?
    let apps: [AppRow]
    let series: [Day]
    let intraday: Intra
}

extension Store {
    func metric(_ key: String, days: Int) async -> MetricResponse? {
        guard let d = try? await fetchData("/v1/metric/\(key)?days=\(days)") else { return nil }
        do { return try JSONDecoder().decode(MetricResponse.self, from: d) } catch { print("metric decode", error); return nil }
    }
}

struct MetricInfo {
    let key: String, title: String, icon: String, tint: Color, money: Bool
    static let all: [String: MetricInfo] = [
        "users": .init(key: "users", title: "App'te aktif", icon: "iphone", tint: .blue, money: false),
        "web": .init(key: "web", title: "Site ziyareti", icon: "globe", tint: .teal, money: false),
        "installs": .init(key: "installs", title: "Kurulum", icon: "arrow.down.circle.fill", tint: .cyan, money: false),
        "net": .init(key: "net", title: "Net gelir", icon: "dollarsign.circle.fill", tint: .yellow, money: true),
        "mrr": .init(key: "mrr", title: "MRR", icon: "repeat.circle.fill", tint: .purple, money: true),
        "devices": .init(key: "devices", title: "Aktif cihaz (Google Play)", icon: "iphone", tint: .blue, money: false),
    ]
}

struct MetricDetailView: View {
    @EnvironmentObject var store: Store
    let info: MetricInfo
    let onBack: () -> Void
    @AppStorage("metricDays") private var days = 30
    @State private var app: String = ""
    @State private var data: MetricResponse?
    @State private var loading = true
    @State private var open: String?

    private func fmt(_ v: Double?) -> String { info.money ? Fmt.usd(v) : Fmt.num(v) }
    private var cards: [Card] { store.snap?.cards ?? [] }
    private func name(_ id: String) -> String { cards.first { $0.id == id }?.name ?? id }

    private func pick(_ by: [String: Double]) -> Double? {
        if !app.isEmpty { return by[app] }
        return by.isEmpty ? nil : by.values.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                Image(systemName: info.icon).font(.system(size: 18)).foregroundStyle(info.tint)
                Text(info.title).font(.system(size: 20, weight: .bold))
                Spacer()
                Picker("", selection: $days) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("90").tag(90)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }.padding(16)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading && data == nil { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20) }
                    if let d = data {
                        appFilter(d)
                        headline(d)
                        intradayChart(d)
                        dailyChart(d)
                        if app.isEmpty { appsTable(d) }
                        SectionLabel(text: "Gün gün")
                        dayList(d)
                    } else if !loading {
                        Text("Veri yüklenemedi.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
        }
        .task(id: "\(days)#\(store.refreshTick)") { await load() }
    }

    private func load() async {
        loading = true
        if let r = await store.metric(info.key, days: days) { data = r }
        loading = false
    }

    private func appFilter(_ d: MetricResponse) -> some View {
        let ids = d.apps.map(\.id)

        return FlowLayout(spacing: 6) {
            chip(id: "", label: "Tümü", card: nil)
            ForEach(ids, id: \.self) { id in chip(id: id, label: name(id), card: cards.first { $0.id == id }) }
        }
    }

    private func chip(id: String, label: String, card: Card?) -> some View {
        let on = app == id
        return Button { withAnimation(.snappy(duration: 0.2)) { app = id; open = nil } } label: {
            HStack(spacing: 5) {
                if let card { AppIcon(card: card, size: 16) }
                Text(label).font(.system(size: 12, weight: on ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }

    private func headline(_ d: MetricResponse) -> some View {
        let rows = app.isEmpty ? d.apps : d.apps.filter { $0.id == app }
        let nowV = rows.compactMap(\.now).isEmpty ? nil : rows.compactMap(\.now).reduce(0, +)

        let both = rows.filter { $0.now != nil && $0.then != nil }
        let a = both.reduce(0) { $0 + ($1.now ?? 0) }, b = both.reduce(0) { $0 + ($1.then ?? 0) }
        let pct: Double? = both.isEmpty || b == 0 ? nil : ((a - b) / abs(b) * 100).rounded()
        let ydayTotal = d.series.count >= 2 ? pick(d.series[d.series.count - 2].byApp) : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fmt(nowV)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().moneyBlur(info.money)
                Text(info.key == "mrr" ? "şu an" : "bugün şu ana kadar").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            if let pct {
                HStack(spacing: 8) {
                    let median = d.baseLabel == "normal bu saat"
                    DeltaChip(pct: pct, label: median ? "normale göre" : "dün bu saat")
                    MText((median ? "normalde bu saatte \(fmt(b))" : "dün bu saatte \(fmt(b))") + (d.sameHourEstimated ? " (tahmini)" : ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                if d.baseLabel == "normal bu saat" {
                    Text("Normal: son \(d.baseDays) günün aynı saatindeki değerlerin ortancası, tek günlük sıçramalar etkilemez.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                }
            } else {
                Text(sinceNote(d)).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if info.key != "mrr", let ydayTotal {
                MText("dün gün toplamı \(fmt(ydayTotal))").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [info.tint.opacity(0.16), Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func sinceNote(_ d: MetricResponse) -> String {
        guard let s = d.intradaySince else { return "Dün bu saatle karşılaştırma için kayıt yeni başladı." }
        let f = DateFormatter()
        f.locale = Loc.numberLocale
        f.timeZone = .current
        f.dateFormat = "d MMM HH:mm"
        return "Saat saat kayıt yeni başladı. Dün bu saatle kıyas \(f.string(from: Date(timeIntervalSince1970: Double(s + 86400)))), son 7 günün normaliyle kıyas \(f.string(from: Date(timeIntervalSince1970: Double(s + 3 * 86400)))) itibarıyla çıkar."
    }

    private struct CurvePt: Identifiable { let m: Int; let v: Double; let which: String; var id: String { "\(which)\(m)" } }
    private func curve(_ pts: [MetricResponse.Pt], _ which: String) -> [CurvePt] {
        var by: [Int: Double] = [:]
        for p in pts where app.isEmpty || p.app == app { by[p.m, default: 0] += p.v }
        return by.keys.sorted().map { CurvePt(m: $0, v: by[$0]!, which: which) }
    }

    @ViewBuilder private func intradayChart(_ d: MetricResponse) -> some View {
        let t = curve(d.intraday.today, "Bugün"), y = curve(d.intraday.yday, "Dün")
        if t.count >= 2 || y.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Gün içinde").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    legend("Bugün", info.tint)
                    legend("Dün", Color.white.opacity(0.45))
                }
                Chart {
                    ForEach(y) { p in
                        LineMark(x: .value("Saat", Double(p.m) / 60), y: .value("Değer", p.v), series: .value("Gün", "Dün"))
                            .foregroundStyle(Color.white.opacity(0.45)).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                    ForEach(t) { p in
                        LineMark(x: .value("Saat", Double(p.m) / 60), y: .value("Değer", p.v), series: .value("Gün", "Bugün"))
                            .foregroundStyle(info.tint).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartXScale(domain: 0...24)
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 24]) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0):00").font(.system(size: 9)) } } }
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine(); AxisValueLabel().font(.system(size: 9)) } }
                .moneyBlur(info.money)
                .frame(height: 120)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        }
    }

    private func legend(_ s: String, _ c: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(c).frame(width: 12, height: 2)
            Text(s).font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
    }

    private func dailyChart(_ d: MetricResponse) -> some View {
        let pts = d.series.compactMap { s in pick(s.byApp).map { DayValue(day: s.day, value: $0) } }
        return TrendChart(pts: pts, label: "\(app.isEmpty ? "Tümü" : name(app)) · günlük", money: info.money, color: info.tint)
            .frame(height: 150)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func appsTable(_ d: MetricResponse) -> some View {
        let rows = d.apps.sorted { ($0.now ?? -1) > ($1.now ?? -1) }
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Ürün ürün")
            ForEach(rows) { r in
                Button { withAnimation(.snappy(duration: 0.2)) { app = r.id } } label: {
                    HStack(spacing: 8) {
                        if let c = cards.first(where: { $0.id == r.id }) { AppIcon(card: c, size: 22) }
                        Text(name(r.id)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let p = r.pct { DeltaChip(pct: p, label: "") }
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(fmt(r.now)).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit().moneyBlur(info.money)
                            if info.key != "mrr" { MText("dün \(fmt(r.yday))").font(.system(size: 10)).foregroundStyle(Theme.faint) }
                        }.frame(minWidth: 64, alignment: .trailing)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func dayList(_ d: MetricResponse) -> some View {
        let days = Array(d.series.reversed())
        return LazyVStack(spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
                let v = pick(day.byApp)
                let prev = i + 1 < days.count ? pick(days[i + 1].byApp) : nil
                let ch: Double? = v != nil && prev != nil && prev! != 0 ? ((v! - prev!) / abs(prev!) * 100).rounded() : nil
                let isOpen = open == day.day
                VStack(alignment: .leading, spacing: 6) {
                    Button { withAnimation(.snappy(duration: 0.2)) { open = isOpen ? nil : day.day } } label: {
                        HStack(spacing: 8) {
                            Text(i == 0 ? "Bugün" : TodayHistoryView.dayLabel(day.day, weekday: true))
                                .font(.system(size: 12.5, weight: .semibold)).frame(width: 78, alignment: .leading)
                            MText(fmt(v)).font(.system(size: 12.5, weight: .bold, design: .rounded)).monospacedDigit()
                            if let ch, i > 0 { DeltaChip(pct: ch, label: "önceki güne") }
                            Spacer(minLength: 0)
                            if app.isEmpty { Image(systemName: isOpen ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.faint) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!app.isEmpty)
                    if isOpen && app.isEmpty {
                        if let g = day.gross, info.key == "net", !g.isEmpty {
                            MText("brüt \(fmt(g.values.reduce(0, +)))").font(.system(size: 11)).foregroundStyle(Theme.dim)
                        }
                        ForEach(day.byApp.sorted { $0.value > $1.value }, id: \.key) { id, val in
                            HStack(spacing: 8) {
                                if let c = cards.first(where: { $0.id == id }) { AppIcon(card: c, size: 18) }
                                Text(name(id)).font(.system(size: 12))
                                Spacer()
                                MText(fmt(val)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isOpen ? Theme.cardHover : Theme.card))
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let w = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            let add = rows[rows.count - 1].items.isEmpty ? s.width : s.width + spacing
            if rows[rows.count - 1].width + add > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let extra = rows[rows.count - 1].items.isEmpty ? s.width : s.width + spacing
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += extra
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, s.height)
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
