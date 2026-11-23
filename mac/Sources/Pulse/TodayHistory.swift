import SwiftUI

struct HistDay: Decodable, Identifiable {
    let day: String
    let subs: Int, trials: Int, cancels: Int, sales: Int
    let netUsd: Double, grossUsd: Double, refundUsd: Double
    let reviews: Int, lowReviews: Int
    let problems: Int?, services: Int?
    let alerts: Int
    let byApp: [String: [String: Int]]
    var id: String { day }
}

struct HistResponse: Decodable {
    let days: [HistDay]
    let eventsSince: String?
    let statusSince: String?
}

extension Store {
    func todayHistory(days: Int) async -> HistResponse? {
        guard let d = try? await fetchData("/v1/today/history?days=\(days)") else { return nil }
        return try? JSONDecoder().decode(HistResponse.self, from: d)
    }
}

private enum HistMetric: String, CaseIterable, Identifiable {
    case subs, trials, cancels, sales, net, reviews, problems, alerts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .subs: "Abone"
        case .trials: "Deneme"
        case .cancels: "İptal"
        case .sales: "Satış"
        case .net: "Net gelir"
        case .reviews: "Yorum"
        case .problems: "Sorunlu"
        case .alerts: "Uyarı"
        }
    }
    var icon: String {
        switch self {
        case .subs: "sparkles"
        case .trials: "hourglass"
        case .cancels: "xmark.circle.fill"
        case .sales: "cart.fill"
        case .net: "dollarsign.circle.fill"
        case .reviews: "star.bubble.fill"
        case .problems: "exclamationmark.triangle.fill"
        case .alerts: "bell.fill"
        }
    }
    var color: Color {
        switch self {
        case .subs, .trials, .sales: Theme.good
        case .cancels, .problems, .alerts: Theme.warn
        case .net: .yellow
        case .reviews: .blue
        }
    }
    func value(_ d: HistDay) -> Double {
        switch self {
        case .subs: Double(d.subs)
        case .trials: Double(d.trials)
        case .cancels: Double(d.cancels)
        case .sales: Double(d.sales)
        case .net: d.netUsd
        case .reviews: Double(d.reviews)
        case .problems: Double(d.problems ?? 0)
        case .alerts: Double(d.alerts)
        }
    }
}

struct TodayHistoryView: View {
    @EnvironmentObject var store: Store
    let onBack: () -> Void
    @AppStorage("histDays") private var days = 30
    @AppStorage("histMetric") private var metricRaw = HistMetric.subs.rawValue
    @State private var data: HistResponse?
    @State private var loading = true

    @State private var open: String? = {
        let a = devArgs
        if let i = a.firstIndex(of: "--history-day"), i + 1 < a.count { return a[i + 1] }
        return nil
    }()

    private var metric: HistMetric { HistMetric(rawValue: metricRaw) ?? .subs }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                Image(systemName: "calendar").font(.system(size: 18)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Günlük geçmiş").font(.system(size: 20, weight: .bold))
                    Text("BUGÜN kutusundaki sayılar, gün gün").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Spacer()
                Picker("", selection: $days) {
                    Text("30 gün").tag(30)
                    Text("60 gün").tag(60)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }.padding(16)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading && data == nil { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20) }
                    if let d = data {
                        chips
                        chart(d)
                        note(d)
                        LazyVStack(spacing: 6) {
                            ForEach(d.days) { day in
                                DayRow(day: day, open: open == day.day) {
                                    withAnimation(.snappy(duration: 0.2)) { open = open == day.day ? nil : day.day }
                                }
                            }
                        }
                    } else if !loading {
                        Text("Geçmiş yüklenemedi.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
        }
        .task(id: "\(days)#\(store.refreshTick)") { await load() }
    }

    private func load() async {
        loading = true
        if let r = await store.todayHistory(days: days) { data = r }
        loading = false
    }

    private var chips: some View {
        let all = HistMetric.allCases
        return VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(all[(r * 4)..<(r * 4 + 4)]) { m in
                        let on = m == metric
                        Button { withAnimation(.snappy(duration: 0.2)) { metricRaw = m.rawValue } } label: {
                            HStack(spacing: 4) {
                                Image(systemName: m.icon).font(.system(size: 10))
                                Text(m.title).font(.system(size: 11.5, weight: on ? .semibold : .medium)).lineLimit(1)
                            }
                            .foregroundStyle(on ? Color.black : m.color)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.07)))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func chart(_ d: HistResponse) -> some View {
        let pts = d.days.reversed().map { DayValue(day: $0.day, value: metric.value($0)) }
        let total = pts.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 4) {
            TrendChart(pts: Array(pts), label: "\(metric.title) · günlük", money: metric == .net, color: metric.color)
                .frame(height: 150)
            MText("\(days) günde toplam " + (metric == .net ? Fmt.usd(total) : Fmt.num(total)))
                .font(.system(size: 11)).foregroundStyle(Theme.dim)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    @ViewBuilder private func note(_ d: HistResponse) -> some View {
        if [.cancels, .alerts, .sales].contains(metric), let s = d.eventsSince {
            Text("İptal, satış ve uyarı kaydı \(TodayHistoryView.dayLabel(s)) tarihinden beri tutuluyor.")
                .font(.system(size: 11)).foregroundStyle(.orange)
        } else if metric == .problems {
            Text(d.statusSince.map { "Sorunlu ürün kaydı \(TodayHistoryView.dayLabel($0)) tarihinden beri tutuluyor." } ?? "Sorunlu ürün kaydı bugünden itibaren tutuluyor.")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }

    private static let months = Loc.months
    private static let weekdays = ["Paz", "Pzt", "Sal", "Çar", "Per", "Cum", "Cmt"]

    static func dayLabel(_ d: String, weekday: Bool = false) -> String {
        let p = d.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let g = Int(p[2]), (1...12).contains(m) else { return d }
        var s = "\(g) \(months[m - 1])"
        if weekday, let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: g)) {
            s += " " + weekdays[Calendar(identifier: .gregorian).component(.weekday, from: date) - 1]
        }
        return s
    }
}

private struct DayRow: View {
    @EnvironmentObject var store: Store
    let day: HistDay
    let open: Bool
    let onTap: () -> Void

    private var isToday: Bool { day.day == ISO8601DateFormatter.localDay(Date()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Text(isToday ? "Bugün" : TodayHistoryView.dayLabel(day.day, weekday: true))
                        .font(.system(size: 12.5, weight: .semibold)).frame(width: 78, alignment: .leading)
                    chipsLine
                    Spacer(minLength: 0)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { breakdown }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(open ? Theme.cardHover : Theme.card))
    }

    private var chipsLine: some View {
        let items: [(String, String, Color)] = [
            day.subs > 0 ? ("sparkles", "\(day.subs)", Theme.good) : nil,
            day.trials > 0 ? ("hourglass", "\(day.trials)", Theme.good) : nil,
            day.cancels > 0 ? ("xmark.circle.fill", "\(day.cancels)", Theme.warn) : nil,
            day.sales > 0 ? ("cart.fill", "\(day.sales)", Theme.good) : nil,
            day.netUsd != 0 ? ("dollarsign.circle.fill", Fmt.usd(day.netUsd), day.netUsd < 0 ? Theme.bad : .yellow) : nil,
            day.reviews > 0 ? ("star.bubble.fill", "\(day.reviews)", day.lowReviews > 0 ? Theme.bad : .blue) : nil,
            (day.problems ?? 0) > 0 ? ("exclamationmark.triangle.fill", "\(day.problems!)", Theme.warn) : nil,
            (day.services ?? 0) > 0 ? ("xmark.octagon.fill", "\(day.services!)", Theme.bad) : nil,
            day.alerts > 0 ? ("bell.fill", "\(day.alerts)", Theme.warn) : nil,
        ].compactMap { $0 }
        return HStack(spacing: 8) {
            if items.isEmpty {
                Text("sakin").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 2) {
                    Image(systemName: it.0).font(.system(size: 9))
                    MText(it.1).font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
                .foregroundStyle(it.2).lineLimit(1)
            }
        }
    }

    private static let order: [(String, String)] = [
        ("subs", "yeni abone"), ("trials", "yeni deneme"), ("cancels", "iptal"), ("sales", "satış"),
        ("reviews", "yorum"), ("problems", "sorunlu"), ("services", "servis çöktü"), ("alerts", "uyarı"),
    ]

    @ViewBuilder private var breakdown: some View {
        let apps = Set(day.byApp.values.flatMap { $0.keys })
        let cards = store.snap?.cards ?? []
        VStack(alignment: .leading, spacing: 6) {
            if day.grossUsd > 0 || day.refundUsd != 0 {
                MText("Brüt \(Fmt.usd(day.grossUsd)) · net \(Fmt.usd(day.netUsd))" + (day.refundUsd != 0 ? " · iade \(Fmt.usd(abs(day.refundUsd)))" : ""))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
            if apps.isEmpty {
                Text("Bu gün ürün bazında kayıt yok.").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
            }
            ForEach(apps.sorted { a, b in (cards.first { $0.id == a }?.name ?? a) < (cards.first { $0.id == b }?.name ?? b) }, id: \.self) { app in
                let card = cards.first { $0.id == app }
                let parts = Self.order.compactMap { k, label -> String? in
                    guard let n = day.byApp[k]?[app], n > 0 else { return nil }
                    return k == "problems" || k == "services" ? label : "\(n) \(label)"
                }
                HStack(spacing: 8) {
                    if let card { AppIcon(card: card, size: 20) }
                    Text(card?.name ?? app).font(.system(size: 12, weight: .semibold))
                    Text(parts.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.leading, 2)
    }
}

extension ISO8601DateFormatter {
    static func localDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
