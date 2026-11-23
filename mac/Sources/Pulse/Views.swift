import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case all = "Tümü", app = "Uygulamalar", game = "Oyunlar", web = "Web", social = "Sosyal", infra = "Altyapı", alerts = "Uyarılar"
    var id: String { rawValue }
    var segment: String? {
        switch self {
        case .app: "app"
        case .game: "game"
        case .web: "web"
        case .social: "social"
        case .infra: "infra"
        default: nil
        }
    }
    var icon: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .app: "iphone"
        case .game: "gamecontroller.fill"
        case .web: "globe"
        case .social: "megaphone.fill"
        case .infra: "server.rack"
        case .alerts: "bell.fill"
        }
    }

    var segmentId: String {
        switch self {
        case .app: "app"
        case .game: "game"
        case .web: "web"
        case .social: "social"
        case .infra: "infra"
        default: ""
        }
    }
}

enum Theme {
    static let card = Color.white.opacity(0.07)
    static let cardHover = Color.white.opacity(0.11)
    static let stroke = Color.white.opacity(0.08)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.68, blue: 0.25)
    static let bad = Color(red: 1.0, green: 0.36, blue: 0.36)
}

struct PanelView: View {
    @EnvironmentObject var store: Store
    let onClose: () -> Void
    @State private var tab: Tab = .all

    @AppStorage("todayFilter") private var todayFilter = ""

    @State private var showHistory = devArgs.contains("--history")

    @State private var showSources = devArgs.contains("--sources")

    @State private var showReviews = false

    @State private var metricKey: String? = {
        let a = devArgs
        if let i = a.firstIndex(of: "--metric"), i + 1 < a.count { return a[i + 1] }
        return nil
    }()
    @State private var openApp: String? = {
        let a = devArgs
        if let i = a.firstIndex(of: "--open"), i + 1 < a.count { return a[i + 1] }
        return nil
    }()

    var body: some View {
        ZStack {
            Color.black.opacity(0.38)
            VStack(spacing: 0) {
                TopBar(onClose: onClose).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                if let k = metricKey, openApp == nil, let info = MetricInfo.all[k] {
                    MetricDetailView(info: info, onBack: { withAnimation(.snappy) { metricKey = nil } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showReviews, openApp == nil {
                    ReviewsDetailView(onBack: { withAnimation(.snappy) { showReviews = false } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showSources, openApp == nil {
                    SourcesDetailView(onBack: { withAnimation(.snappy) { showSources = false } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showHistory, openApp == nil {
                    TodayHistoryView(onBack: { withAnimation(.snappy) { showHistory = false } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if let id = openApp, let card = store.snap?.cards.first(where: { $0.id == id }) {
                    DetailView(card: card, onBack: { withAnimation(.snappy) { openApp = nil } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    header
                    tabs
                    content.transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpdateBanner()
            if let e = store.error {
                Label(e, systemImage: "wifi.exclamationmark").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            if let snap = store.snap {
                let t = snap.totals
                if let sp = snap.spotlight {
                    SpotlightBanner(spot: sp, card: snap.cards.first { $0.id == sp.app }) {
                        withAnimation(.snappy) { openApp = sp.app }
                    }
                }

                VStack(spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        if t.usersToday == nil && t.liveUsers == nil, let dev = t.activeDevices {
                            SummaryTile(title: "Aktif cihaz", value: Fmt.num(dev), sub: "Google Play, son rapor",
                                        change: nil, changeLabel: "", spark: nil, tint: .blue, icon: "iphone", onTap: { openMetric("devices") })
                        } else if t.usersToday == nil && t.usersYday == nil && t.liveUsers == nil {
                            SummaryTile(title: "App'te aktif", value: "–", sub: "Analytics bağla, kullanıcıları gör",
                                        change: nil, changeLabel: "", spark: nil, tint: .blue, icon: "iphone", onTap: { openConnections("ga4") })
                        } else {
                            SummaryTile(title: "App'te aktif", value: Fmt.num(t.usersToday),
                                        sub: t.usersYday.map { "dün \(Fmt.num($0))" },
                                        change: hourPct("users") ?? snap.changes?.appUsers, changeLabel: hourLabel("users") ?? "dün / 7g ort.",
                                        spark: snap.series?.appUsers, tint: .blue, icon: "iphone", onTap: { openMetric("users") })
                        }

                        if !snap.cards.contains(where: { $0.site != nil }), let avg = t.ratingAvg {
                            SummaryTile(title: "Puan · 30 gün", value: (Loc.isTurkish ? String(format: "%.1f", avg).replacingOccurrences(of: ".", with: ",") : String(format: "%.1f", avg)) + " ★",
                                        sub: "\(t.ratingCount ?? 0) yorum", change: nil, changeLabel: "", spark: nil, tint: .teal, icon: "star.fill",
                                        onTap: { withAnimation(.snappy) { showReviews = true } })
                        } else if !snap.cards.contains(where: { $0.site != nil }) {
                            SummaryTile(title: "Site ziyareti", value: "–", sub: "Siteni bağla, ziyaretçiyi gör",
                                        change: nil, changeLabel: "", spark: nil, tint: .teal, icon: "globe", onTap: { openConnections("site") })
                        } else {
                            SummaryTile(title: "Site ziyareti", value: Fmt.num(t.webVisitorsToday),
                                        sub: t.visitors1h.map { "son 1 saat \(Fmt.num($0))" },
                                        change: hourPct("web") ?? snap.changes?.web, changeLabel: hourLabel("web") ?? "dün / 7g ort.",
                                        spark: snap.series?.web, tint: .teal, icon: "globe", onTap: { openMetric("web") })
                        }

                        if t.installsToday == nil, let last = t.installsLast {
                            SummaryTile(title: "Kurulum", value: Fmt.num(last), sub: t.installsLastDay.map { "son rapor \(Fmt.shortDay($0))" },
                                        change: snap.changes?.installs, changeLabel: "7g ort.",
                                        spark: snap.series?.installs, tint: .cyan, icon: "arrow.down.circle.fill", onTap: { openMetric("installs") })
                        } else {
                            SummaryTile(title: "Kurulum", value: Fmt.num(t.installsToday),
                                        sub: t.installsYday.map { "dün \(Fmt.num($0))" },
                                        change: hourPct("installs") ?? snap.changes?.installs, changeLabel: hourLabel("installs") ?? "dün / 7g ort.",
                                        spark: snap.series?.installs, tint: .cyan, icon: "arrow.down.circle.fill", onTap: { openMetric("installs") })
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        SummaryTile(title: "Net gelir · 7 gün", value: Fmt.usd(t.revenue7d),
                                    sub: t.gross7d.map { "brüt \(Fmt.usd($0)) · dün net \(Fmt.usd(t.revenueYday))" },
                                    change: snap.changes?.revenue7d, changeLabel: "hafta",
                                    spark: snap.series?.revenue, tint: .yellow, icon: "dollarsign.circle.fill", money: true, onTap: { openMetric("net") })
                        if t.mrr == nil && t.activeSubs == nil {
                            SummaryTile(title: "Abonelik", value: "–", sub: "RevenueCat bağla, aboneleri gör",
                                        change: nil, changeLabel: "", spark: nil, tint: .purple, icon: "repeat.circle.fill",
                                        onTap: { openConnections("revenuecat") })
                        } else {
                            SummaryTile(title: "MRR", value: Fmt.usd(t.mrr),
                                        sub: t.activeSubs.map { "\(Fmt.num($0)) abone · \(Fmt.num(t.trials)) deneme" },
                                        change: hourPct("mrr"), changeLabel: hourLabel("mrr") ?? "dün bu saat", spark: nil, tint: .purple, icon: "repeat.circle.fill", money: true,
                                        onTap: { openMetric("mrr") })
                        }
                        TodayTile(today: snap.today, totals: t, openAlerts: openAlertCount, filter: $todayFilter,
                                  onAlerts: { withAnimation(.snappy) { tab = .alerts } },
                                  onHistory: { withAnimation(.snappy) { showHistory = true } })
                    }

                    if let src = snap.sources, snap.cards.contains(where: { $0.site != nil }) {
                        SourcesStrip(s: src) { withAnimation(.snappy) { showSources = true } }
                    }
                    if let ad = t.adSpendToday, ad > 0 {
                        AdSpendStrip(spend: ad) { DetailNav.tab = 6; withAnimation(.snappy) { openApp = snap.cards.first { $0.m("ad_spend_7d") != nil }?.id } }
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private func hourPct(_ k: String) -> Double? { store.snap?.changes?.sameHour?[k]?.pct }

    private func hourLabel(_ k: String) -> String? {
        guard let v = store.snap?.changes?.sameHour?[k], v.pct != nil else { return nil }
        return (v.estimated == true ? "~" : "") + (v.label ?? "dün bu saat")
    }
    private func openMetric(_ k: String) { withAnimation(.snappy) { metricKey = k } }

    private var openAlertCount: Int {
        store.snap?.alerts.filter { $0.acked == 0 && ($0.severity == "critical" || $0.severity == "warning") }.count ?? 0
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Tab.allCases.filter { t in
                    t == .all || t == .alerts || (store.snap?.cards.contains { $0.segment == t.segmentId } ?? false)
                }) { t in
                    let badge = badgeCount(t)
                    let selected = tab == t
                    Button { withAnimation(.snappy) { tab = t } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.icon).font(.system(size: 11))
                            Text(t.rawValue).font(.system(size: 13, weight: selected ? .semibold : .medium))
                            if badge > 0 {
                                Text("\(badge)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(t == .alerts ? Theme.bad : Color.white.opacity(0.18)))
                            }
                        }
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.8))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.07)))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    private func badgeCount(_ t: Tab) -> Int {
        guard let s = store.snap else { return 0 }
        if t == .alerts { return openAlertCount }
        if let seg = t.segment { return s.cards.filter { $0.segment == seg }.count }
        return 0
    }

    @ViewBuilder private var content: some View {
        if tab == .alerts {
            AlertsView()
        } else if let s = store.snap {
            let only = todayFilter.isEmpty ? nil : Set(s.today?.byApp?[todayFilter] ?? [])
            let cards = s.cards.filter { (tab.segment == nil ? true : $0.segment == tab.segment) && (only?.contains($0.id) ?? true) }
            let live = cards.filter { $0.hero != nil }
            let idle = cards.filter { $0.hero == nil }
            ScrollView {
                LazyVStack(spacing: 10) {
                    if only != nil {
                        FilterBar(title: TodayTile.title(todayFilter), count: cards.count) {
                            withAnimation(.snappy) { todayFilter = "" }
                        }
                        if cards.isEmpty {
                            Text("Bugün bu başlıkta bir şey yok.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                                .frame(maxWidth: .infinity).padding(.vertical, 18)
                        }
                    }
                    ForEach(Array(live.enumerated()), id: \.element.id) { i, c in
                        CardView(card: c, rank: i + 1)
                            .onTapGesture { withAnimation(.snappy) { openApp = c.id } }
                    }
                    if !idle.isEmpty {
                        if only == nil { SectionLabel(text: live.isEmpty ? "Veri bekleyenler" : "Henüz veri yok") }
                        ForEach(idle) { c in
                            VStack(spacing: 6) {
                                CompactCard(card: c)

                                if only != nil, let n = c.note { BuddyNote(note: n) }
                            }
                            .onTapGesture { withAnimation(.snappy) { openApp = c.id } }
                        }
                    }
                    if todayFilter == "reviews" {
                        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
                        let todays = s.reviews.filter { Double($0.ts) >= dayStart }
                        if !todays.isEmpty { ReviewsBlock(reviews: todays, cards: s.cards) }
                    } else if tab == .all, only == nil, !s.reviews.isEmpty {
                        SectionLabel(text: "Son yorumlar")
                        ReviewsBlock(reviews: Array(s.reviews.prefix(4)), cards: s.cards)
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 14)
            }
        } else {
            Spacer()
        }
    }
}

struct TopBar: View {
    @EnvironmentObject var store: Store
    let onClose: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            LiveDot(ok: store.error == nil)
            Text("PULSE").font(.system(size: 12, weight: .bold)).tracking(1.5).foregroundStyle(Theme.dim)
            Spacer()
            if let d = store.lastFetch {
                Text(d, style: .time).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.faint).monospacedDigit()
            }
            if store.refreshing {
                ProgressView().controlSize(.small).frame(width: 26, height: 26)
            } else {
                IconButton(icon: "arrow.clockwise", help: "Şimdi yenile") { Task { await store.manualRefresh() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            MoneyToggle()
            IconButton(icon: "gearshape", help: "Bağlantılar: hesaplar ve ürünler") { openConnections() }
            IconButton(icon: store.pinned ? "pin.fill" : "pin", help: "Paneli sabitle") { store.pinned.toggle() }
            IconButton(icon: "xmark", help: "Kapat", action: onClose)
        }
    }
}

struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hover ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain).help(help).onHover { hover = $0 }
    }
}

struct SummaryTile: View {
    let title: String
    let value: String
    let sub: String?
    let change: Double?
    let changeLabel: String
    let spark: [Double?]?
    let tint: Color
    let icon: String
    var money = false
    var onTap: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        Button { onTap?() } label: { content }
            .buttonStyle(.plain)
            .onHover { hover = $0 && onTap != nil }
            .help(onTap != nil ? "Ayrıntı ve geçmiş" : "")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint)
                Text(title.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.dim).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 25, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .foregroundStyle(value == "–" ? Theme.faint : .white)
                    .contentTransition(.numericText())
                    .moneyBlur(money && value != "–")
            }
            if let change { DeltaChip(pct: change, label: changeLabel) }
            MText(value == "–" ? (sub ?? "bağlı değil") : (sub ?? " "))
                .font(.system(size: 10.5)).foregroundStyle(Theme.dim).lineLimit(1).minimumScaleFactor(0.75)
            if let spark, spark.compactMap({ $0 }).count > 2 {
                MiniBars(values: spark, tint: tint, money: money).frame(height: 20).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [tint.opacity(hover ? 0.26 : 0.16), Theme.card], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(tint.opacity(hover ? 0.45 : 0.22)))
        .contentShape(Rectangle())
    }
}

struct DeltaChip: View {
    let pct: Double
    let label: String
    var body: some View {
        let up = pct >= 0
        let strong = abs(pct) >= 25
        let color: Color = abs(pct) < 5 ? Theme.dim : (up ? Theme.good : Theme.bad)
        HStack(spacing: 2) {
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
            Text("%\(Int(abs(pct)))").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10)).opacity(0.8)
        }
        .foregroundStyle(strong ? .white : color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(strong ? color.opacity(0.85) : color.opacity(0.15)))
    }
}

struct SpotlightBanner: View {
    let spot: Spotlight
    let card: Card?
    let onTap: () -> Void
    @State private var glow = false
    var body: some View {
        let (icon, color): (String, Color) = switch spot.mood {
        case "critical": ("exclamationmark.octagon.fill", Theme.bad)
        case "bad": ("exclamationmark.triangle.fill", Theme.warn)
        case "fire": ("flame.fill", Color.orange)
        default: ("hand.thumbsup.fill", Theme.good)
        }
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    if let card { AppIcon(card: card, size: 46) }
                    Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .padding(4).background(Circle().fill(color)).offset(x: 6, y: 6)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(spot.mood == "fire" ? "GÜNÜN İYİ HABERİ · \(spot.name.uppercased())" : "BUGÜN BAKMAN GEREKEN · \(spot.name.uppercased())")
                        .font(.system(size: 10, weight: .heavy)).tracking(0.8).foregroundStyle(color)
                    MText(spot.headline).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(color)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.10)], startPoint: .leading, endPoint: .trailing))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(color.opacity(glow ? 0.95 : 0.4), lineWidth: 1.5)
            )
            .shadow(color: color.opacity(glow ? 0.45 : 0.1), radius: glow ? 12 : 4)
        }
        .buttonStyle(.plain)
        .onAppear {
            guard spot.mood != "good" else { return }

            withAnimation(.easeInOut(duration: 1.2).repeatCount(5, autoreverses: true)) { glow = true }
        }
    }
}

struct TodayTile: View {
    let today: TodayCounts?
    let totals: Totals
    let openAlerts: Int
    @Binding var filter: String
    let onAlerts: () -> Void
    let onHistory: () -> Void

    static func title(_ key: String) -> String {
        switch key {
        case "subs": "Bugün yeni abone"
        case "trials": "Bugün yeni deneme"
        case "cancels": "Bugün iptal"
        case "sales": "Bugün satış"
        case "problems": "Sorunlu ürünler"
        case "reviews": "Bugünkü yorumlar"
        case "services": "Çöken servisler"
        default: key
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button(action: onHistory) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 10)).foregroundStyle(.orange)
                        Text("BUGÜN").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.dim)
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.faint)
                    }.fixedSize().contentShape(Rectangle())
                }.buttonStyle(.plain).help("Günlük geçmiş")
                Spacer(minLength: 0)
                if openAlerts > 0 {
                    Button(action: onAlerts) {
                        Text("\(openAlerts) uyarı ›").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.warn)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }.buttonStyle(.plain)
                }
            }.padding(.bottom, 2)
            row("subs", "sparkles", "\(today?.newSubs ?? 0) yeni abone" + (today?.newSubsYday.map { " · dün \(Int($0))" } ?? ""), (today?.newSubs ?? 0) > 0 ? Theme.good : Theme.dim)
            if let tr = today?.trials, tr > 0 { row("trials", "hourglass", "\(tr) yeni deneme", Theme.good) }
            if let c = today?.cancels, c > 0 { row("cancels", "xmark.circle.fill", "\(c) iptal", Theme.warn) }
            row("sales", "cart.fill", "\(today?.sales ?? 0) satış", (today?.sales ?? 0) > 0 ? Theme.good : Theme.dim)
            row("problems", "exclamationmark.triangle.fill", "\(today?.problems ?? 0) ürün sorunlu", (today?.problems ?? 0) > 0 ? Theme.warn : Theme.dim)
            row("reviews", "star.bubble.fill", "\(today?.reviews ?? 0) yorum" + ((today?.lowReviews ?? 0) > 0 ? " (\(today!.lowReviews) kötü)" : ""), (today?.lowReviews ?? 0) > 0 ? Theme.bad : Theme.dim)

            if totals.servicesTotal > 0 {
                row("services", totals.servicesDown > 0 ? "xmark.octagon.fill" : "checkmark.seal.fill",
                    totals.servicesDown > 0 ? "\(totals.servicesDown) servis çöktü" : "\(totals.servicesTotal) servis ayakta",
                    totals.servicesDown > 0 ? Theme.bad : Theme.good)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(!filter.isEmpty ? Color.white.opacity(0.5) : openAlerts > 0 ? Theme.warn.opacity(0.6) : Theme.stroke))
    }

    private func row(_ key: String, _ icon: String, _ text: String, _ color: Color) -> some View {
        let on = filter == key
        return Button { withAnimation(.snappy(duration: 0.2)) { filter = on ? "" : key } } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5)).frame(width: 12)
                MText(text).font(.system(size: 11, weight: on ? .bold : .medium)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 3).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.white.opacity(0.16) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Filtreyi kaldır" : "Listeyi buna göre süz")
    }
}

struct FilterBar: View {
    let title: String
    let count: Int
    let onClear: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.system(size: 12))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text("· \(count) ürün").font(.system(size: 12)).foregroundStyle(Theme.dim)
            Spacer()
            Button(action: onClear) {
                Label("Temizle", systemImage: "xmark").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }
}

struct StatusStrip: View {
    let totals: Totals
    let openAlerts: Int
    let onAlerts: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            let down = totals.servicesDown
            Pill(icon: down > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                 text: down > 0 ? "\(down) servis çalışmıyor" : "\(totals.servicesTotal) servis çalışıyor",
                 tint: down > 0 ? Theme.bad : Theme.good)
            Button(action: onAlerts) {
                Pill(icon: openAlerts > 0 ? "bell.badge.fill" : "bell",
                     text: openAlerts > 0 ? "\(openAlerts) uyarı" : "uyarı yok",
                     tint: openAlerts > 0 ? Theme.warn : Theme.dim)
            }.buttonStyle(.plain)
            if let n = totals.subsNewToday, n > 0 {
                Pill(icon: "sparkles", text: "bugün +\(Fmt.num(n)) abone", tint: Theme.good)
            }
            Spacer(minLength: 0)
        }
    }
}

struct Pill: View {
    let icon: String, text: String, tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8).padding(.leading, 4)
    }
}

struct LiveDot: View {
    let ok: Bool
    var body: some View {
        ZStack {
            Circle().fill(ok ? Theme.good : Theme.warn).frame(width: 8, height: 8)
            Circle().fill((ok ? Theme.good : Theme.warn).opacity(0.25)).frame(width: 14, height: 14)
        }
    }
}

struct AppIcon: View {
    @EnvironmentObject var store: Store
    let card: Card
    var size: CGFloat = 56
    var body: some View {
        Group {
            if let u = store.iconURL(card) {
                AsyncImage(url: u) { phase in
                    if let img = phase.image { img.resizable().interpolation(.high).scaledToFill() } else { fallback }
                }
            } else { fallback }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: card.color), Color(hex: card.color).opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text(String(card.name.prefix(1))).font(.system(size: size * 0.46, weight: .heavy, design: .rounded)).foregroundStyle(.white)
        }
    }
}

struct Metric: Identifiable {
    let id: String, label: String, value: String
    var money = false
}

func cardMetrics(_ c: Card) -> [Metric] {
    func n(_ k: String, _ l: String) -> Metric? { c.m(k).map { Metric(id: k, label: l, value: Fmt.num($0)) } }
    func u(_ k: String, _ l: String) -> Metric? { c.m(k).map { Metric(id: k, label: l, value: Fmt.usd($0), money: true) } }
    func p(_ k: String, _ l: String) -> Metric? { c.m(k).map { Metric(id: k, label: l, value: Fmt.pct($0)) } }
    let list: [Metric?]
    switch c.segment {
    case "game":
        list = [n("new_users_today", "Yeni kayıt"), n("active_subs", "Premium"),
                n("installs_today", "Kurulum bugün"), n("installs_7d", "Kurulum 7g"), u("ad_revenue_yday", "Reklam dün"),
                u("ecpm_yday", "eCPM"), u("arpdau", "ARPDAU"), u("revenue_7d", "Gelir 7g"), p("ret_d1", "D1")]
    case "web":
        list = [n("web_visitors_today", "Ziyaret bugün"), n("visitors_1h", "Son 1 saat"), n("transactions_today", "Satış bugün"),
                u("revenue_today", "Gelir bugün"), u("revenue_7d", "Gelir 7g")]
    case "infra":
        list = []
    default:
        list = [n("installs_today", "Kurulum bugün"), n("active_subs", "Abone"), u("mrr", "MRR"), u("revenue_7d", "Net gelir 7g"),
                n("trials", "Deneme"), n("subs_new_7d", "Yeni abone 7g")]
    }
    return Array(list.compactMap { $0 }.prefix(4))
}

struct CardView: View {
    let card: Card
    let rank: Int?
    @State private var hover = false

    var body: some View {
        let tint = Color(hex: card.color)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                AppIcon(card: card, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if let rank {
                            Text("\(rank)").font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(.black).frame(width: 17, height: 17)
                                .background(Circle().fill(tint))
                        }
                        Text(card.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        if card.openAlerts > 0 {
                            Circle().fill(card.worst == "critical" ? Theme.bad : card.worst == "warning" ? Theme.warn : Theme.good)
                                .frame(width: 8, height: 8)
                        }
                    }
                    if let site = card.site { SiteTag(site: site) }
                    HealthRow(health: card.health)
                }
                Spacer(minLength: 8)
                if let h = card.hero {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(h.unit == "usd" ? Fmt.usd(h.value) : Fmt.num(h.value))
                            .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText())
                            .moneyBlur(h.unit == "usd")
                        Text(h.label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.dim)
                        if let l = h.subLabel, let v = h.subValue {
                            Text("\(l) \(Fmt.num(v))").font(.system(size: 11)).foregroundStyle(Theme.faint).monospacedDigit()
                        }
                    }
                }
            }
            let ms = cardMetrics(card)
            if !ms.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(ms) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .moneyBlur(m.money)
                            Text(m.label).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let n = card.note, n.key != "quiet" { BuddyNote(note: n) }
            if card.spark.users.compactMap({ $0 }).count > 2 {
                MiniBars(values: card.spark.users, tint: tint).frame(height: 30)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(hover ? Theme.cardHover : Theme.card)
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(card.worst == "critical" ? Theme.bad.opacity(0.7) : Theme.stroke))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct CompactCard: View {
    let card: Card
    @State private var hover = false
    var body: some View {
        let missing = card.sources.filter { $0.status == "missing" || $0.status == "error" }.map(\.label)
        HStack(spacing: 12) {
            AppIcon(card: card, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(card.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let site = card.site { SiteTag(site: site) }
                }
                if card.segment == "infra" || missing.isEmpty {
                    HealthRow(health: card.health)
                } else {
                    Text("Bağlanınca dolacak: " + Array(Set(missing)).sorted().joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(Theme.warn.opacity(0.85)).lineLimit(1)
                }
            }
            Spacer()
            if card.segment != "infra", !card.health.isEmpty {
                HStack(spacing: 4) {
                    ForEach(card.health, id: \.self) { h in
                        Circle().fill(h.ok ? Theme.good : Theme.bad).frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hover ? Theme.cardHover : Color.white.opacity(0.045)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct SiteTag: View {
    let site: String
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "globe").font(.system(size: 9))
            Text(site).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(Theme.faint)
    }
}

struct HealthRow: View {
    let health: [Health]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(health, id: \.self) { h in
                HStack(spacing: 4) {
                    Circle().fill(h.ok ? Theme.good : Theme.bad).frame(width: 7, height: 7)
                    Text(h.name).font(.system(size: 11.5)).foregroundStyle(h.ok ? Theme.dim : Theme.bad)
                }
            }
        }
    }
}

struct MiniBars: View {
    let values: [Double?]
    let tint: Color
    var money = false
    @State private var hover: Int?

    private func dayLabel(_ i: Int) -> String {
        let back = values.count - 1 - i
        if back == 0 { return "bugün" }
        if back == 1 { return "dün" }
        let d = Calendar.current.date(byAdding: .day, value: -back, to: Date()) ?? Date()
        let f = DateFormatter(); f.locale = Loc.numberLocale; f.dateFormat = "d MMM"
        return f.string(from: d)
    }

    var body: some View {
        GeometryReader { g in
            let mx = max(values.compactMap { $0 }.max() ?? 1, 1)
            let w = g.size.width / CGFloat(max(values.count, 1))
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(values.indices, id: \.self) { i in
                    let v = values[i] ?? 0
                    let lit = hover.map { $0 == i } ?? (i == values.count - 1)
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(lit ? tint : tint.opacity(0.45))
                        .frame(width: max(w - 3, 2), height: max(g.size.height * CGFloat(v / mx), values[i] == nil ? 0 : 2))
                        .frame(width: w, alignment: .center)
                }
            }
            .frame(height: g.size.height, alignment: .bottom)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = min(max(Int(p.x / w), 0), values.count - 1)
                case .ended: hover = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let i = hover {
                    let text = (values[i].map { money ? Fmt.usd($0) : Fmt.num($0) } ?? "veri yok") + " · " + dayLabel(i)
                    Text(text)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                        .moneyBlur(money)

                        .alignmentGuide(.leading) { d in
                            let x = (CGFloat(i) + 0.5) * w - d.width / 2
                            return -min(max(x, 0), max(g.size.width - d.width, 0))
                        }
                        .alignmentGuide(.top) { d in d.height + 3 }
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

struct BuddyNote: View {
    let note: Note
    var compact = false
    var body: some View {
        let (icon, color): (String, Color) = switch note.mood {
        case "critical": ("exclamationmark.octagon.fill", Theme.bad)
        case "bad": ("hand.thumbsdown.fill", Theme.warn)
        case "fire": ("flame.fill", Color.orange)
        case "good": ("hand.thumbsup.fill", Theme.good)
        default: ("bubble.left.fill", Color.white.opacity(0.6))
        }
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                MText(note.headline).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if !compact {
                    ForEach(note.lines, id: \.self) { l in
                        MText(l).font(.system(size: 12.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(color.opacity(0.35)))
    }
}

struct AlertsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let alerts = store.snap?.alerts ?? []
        VStack(spacing: 0) {
            HStack {
                Text("\(alerts.filter { $0.acked == 0 }.count) okunmamış").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dim)
                Spacer()
                Button("Hepsini okundu say") { Task { await store.ack(nil) } }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(.blue)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if alerts.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(Theme.good)
                            Text("Son 3 günde uyarı yok").font(.system(size: 14)).foregroundStyle(Theme.dim)
                        }.padding(.top, 50)
                    }
                    ForEach(alerts) { a in AlertRow(alert: a) }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
    }
}

struct AlertRow: View {
    @EnvironmentObject var store: Store
    let alert: Alert
    var body: some View {
        let color: Color = switch alert.severity {
        case "critical": Theme.bad
        case "warning": Theme.warn
        case "good": Theme.good
        default: .blue
        }
        let card = store.snap?.cards.first { $0.id == alert.app }
        HStack(alignment: .top, spacing: 12) {
            if let card { AppIcon(card: card, size: 34) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    MText(alert.title).font(.system(size: 13.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                if let b = alert.body, !b.isEmpty {
                    MText(b).font(.system(size: 12.5)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                Text(Fmt.ago(alert.ts) + " önce").font(.system(size: 11)).foregroundStyle(Theme.faint)
            }
            Spacer()
            if alert.acked == 0 {
                IconButton(icon: "checkmark", help: "Okundu") { Task { await store.ack(alert.id) } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(alert.acked == 0 ? 0.08 : 0.035)))
        .opacity(alert.acked == 0 ? 1 : 0.6)
    }
}

struct ReviewsBlock: View {
    @EnvironmentObject var store: Store
    let reviews: [Review]
    let cards: [Card]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(reviews, id: \.self) { r in
                let card = cards.first { $0.id == r.app }
                HStack(alignment: .top, spacing: 10) {
                    if let card { AppIcon(card: card, size: 30) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(String(repeating: "★", count: r.rating) + String(repeating: "☆", count: max(0, 5 - r.rating)))
                                .font(.system(size: 12)).foregroundStyle(r.rating <= 2 ? Theme.bad : .yellow)
                            Spacer()
                            Text("\(r.territory ?? "") · \(Fmt.ago(r.ts))").font(.system(size: 11)).foregroundStyle(Theme.faint)
                        }
                        if let t = r.title, !t.isEmpty { Text(t).font(.system(size: 13, weight: .semibold)).lineLimit(1) }
                        if let b = r.body { Text(b).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(2) }
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
            }
        }
    }
}
