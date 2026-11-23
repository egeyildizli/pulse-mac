import Charts
import SwiftUI

struct DetailView: View {
    @EnvironmentObject var store: Store
    let card: Card
    let onBack: () -> Void
    @State private var detail: Detail?
    @State private var loading = true

    @State private var tab: Int = {
        let a = devArgs
        if let t = DetailNav.tab { DetailNav.tab = nil; return t }
        if let i = a.firstIndex(of: "--tab"), i + 1 < a.count { return Int(a[i + 1]) ?? 0 }
        return 0
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                AppIcon(card: card, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.name).font(.system(size: 22, weight: .bold))
                    Text(segmentTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
                    HealthRow(health: card.health)
                }
                Spacer()
            }.padding(16)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TabStrip(tab: $tab, items: [(0, "Teşhis"), (1, "Rakamlar"), (2, "Kullanıcılar"), (3, "Geçmiş")]
                             + (detail?.meta != nil ? [(6, "Reklam")] : []))
                    if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }
                    switch tab {
                    case 0:
                        if let n = card.note { BuddyNote(note: n) }
                        if let g = detail?.diagnosis { DiagnosisView(dx: g) }
                        if let d = detail, !d.insights.isEmpty { insights(d) }
                    case 1:
                        keyNumbers
                        if let d = detail {
                            charts(d)
                            if let c = d.countries, !c.isEmpty { countries(c) }
                        }
                    case 2:
                        if let d = detail {
                            if let ss = d.siteSources {
                                section("Nereden geliyorlar", "arrow.triangle.branch")
                                box { SiteSourcesView(s: ss, color: Color(hex: card.color)) }
                            } else if let aq = d.acquisition {
                                section("Nereden geliyorlar", "arrow.triangle.branch")
                                box { AcquisitionView(a: aq, color: Color(hex: card.color)) }
                            }
                            if let r = d.retention { retention(r) }
                            if let s = d.liveScreens, !s.isEmpty { liveScreens(s) }
                            if let s = d.screens, !s.isEmpty { stuckScreens(s) }
                            if let e = d.events, !e.isEmpty { events(e) }
                            if !d.reviews.isEmpty {
                                section("Yorumlar", "star.bubble")
                                ReviewsBlock(reviews: d.reviews, cards: [card])
                            }
                            if d.retention == nil && (d.screens ?? []).isEmpty && d.reviews.isEmpty && d.siteSources == nil && d.acquisition == nil {
                                Text("Kullanıcı davranışı verisi yok. Firebase Analytics bağlanınca ekran ekran takılma ve geri dönüş oranı burada görünür.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    case 6:
                        if let m = detail?.meta { MetaView(m: m) }
                    default:
                        sourcesSection
                        if let d = detail, !d.alerts.isEmpty {
                            section("Uyarı geçmişi")
                            ForEach(d.alerts.prefix(30)) { AlertRow(alert: $0) }
                        }
                    }
                }.padding(12)

                .containerRelativeFrame(.horizontal)
            }
        }
        .task(id: "\(card.id)#\(store.refreshTick)") {
            loading = detail == nil
            detail = await store.detail(card.id)
            loading = false
        }
    }

    private var segmentTitle: String {
        switch card.segment {
        case "game": "Oyun"
        case "web": "Web"
        case "social": "Sosyal medya"
        case "infra": "Altyapı"
        default: "Uygulama"
        }
    }

    private func section(_ t: String, _ icon: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11)) }
            Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
        }.foregroundStyle(Theme.faint).padding(.top, 6)
    }

    private func box<V: View>(@ViewBuilder _ c: () -> V) -> some View {
        c().padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    private func insights(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Analist notu", "sparkles")
            box {
                VStack(alignment: .leading, spacing: 6) {
                    MText(d.insights[0].text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    Text(Fmt.ago(d.insights[0].ts) + " önce").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private static let chartMetrics: [(String, String, Bool)] = [
        ("users", "Günlük aktif kullanıcı", false), ("installs", "Kurulum", false),
        ("revenue_usd", "Net gelir ($)", true), ("revenue_gross_usd", "Brüt gelir ($)", true), ("subs_new", "Yeni abone", false),
        ("trials_new", "Yeni deneme", false), ("active_subs", "Aktif abone", false),
        ("web_visitors", "Site ziyaretçisi", false), ("ios_downloads", "iOS indirme", false), ("android_installs", "Android kurulum", false),
        ("ios_proceeds_usd", "App Store net gelir ($)", true), ("android_proceeds_usd", "Google Play net gelir, tahmini ($)", true),
        ("android_active_devices", "Aktif cihaz (Google Play)", false),
        ("ad_revenue_usd", "Reklam geliri ($)", true), ("avg_session_s", "Ort. oturum (sn)", false),
    ]

    private static let allNumbers: [(String, String, String)] = [
        ("rt_users", "Şu an", "n"), ("users_today", "Bugün aktif", "n"), ("users_yday", "Dün aktif", "n"),
        ("installs_today", "Kurulum bugün", "n"), ("installs_yday", "Kurulum dün", "n"), ("installs_7d", "Kurulum 7g", "n"),
        ("revenue_yday", "Net gelir dün", "u"), ("gross_yday", "Brüt gelir dün", "u"), ("revenue_today", "Net gelir bugün", "u"),
        ("revenue_7d", "Net gelir 7g", "u"), ("gross_7d", "Brüt gelir 7g", "u"), ("revenue_28d", "Brüt gelir 28g", "u"), ("mrr", "MRR", "u"), ("active_subs", "Abone", "n"),
        ("trials", "Deneme", "n"), ("subs_new_7d", "Yeni abone 7g", "n"), ("churned_7d", "Kaybedilen 7g", "n"),
        ("paywall_views_7d", "Paywall gören 7g", "n"), ("paywall_conv_7d", "Paywall dönüşüm", "p"), ("refunds_7d", "İade 7g", "u"),
        ("arpdau", "ARPDAU", "u"), ("ad_revenue_yday", "Reklam dün", "u"), ("ecpm_yday", "eCPM", "u"),
        ("impressions_per_dau", "Gösterim/DAU", "n"), ("ret_d1", "D1 geri dönüş", "p"), ("ret_d7", "D7 geri dönüş", "p"),
        ("roas_7d", "ROAS 7g", "x"),
        ("new_users_today", "Yeni kayıt bugün", "n"), ("web_visitors_today", "Ziyaret bugün", "n"), ("visitors_1h", "Son 1 saat", "n"),
        ("ios_downloads_yday", "iOS indirme (son)", "n"), ("android_installs_yday", "Android kurulum (son)", "n"),
        ("android_uninstalls_7d", "Android kaldırma 7g", "n"), ("android_active_devices", "Aktif cihaz (Google Play)", "n"),
    ]

    @ViewBuilder private var keyNumbers: some View {
        let rows = Self.allNumbers.compactMap { k, label, unit -> (String, String, String, Bool)? in
            guard let v = card.m(k) else { return nil }
            let txt = unit == "u" ? Fmt.usd(v) : unit == "p" ? Fmt.pct(v) : unit == "x" ? String(format: "%.2fx", v) : Fmt.num(v)
            return (k, label, txt, unit == "u" || unit == "x")
        }
        if !rows.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(rows, id: \.0) { _, label, txt, money in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(txt).font(.system(size: 19, weight: .bold, design: .rounded)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .moneyBlur(money)
                        Text(label).font(.system(size: 11)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                }
            }
        }
    }

    @ViewBuilder private var sourcesSection: some View {
        if !card.sources.isEmpty {
            section("Veri kaynakları", "point.3.connected.trianglepath.dotted")
            box {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(card.sources, id: \.self) { s in
                        HStack(spacing: 8) {
                            Circle().fill(s.status == "ok" ? Theme.good : s.status == "waiting" ? Color.blue : s.status == "error" ? Theme.bad : Theme.warn)
                                .frame(width: 8, height: 8)
                            Text(s.label).font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text(s.status == "ok" ? "bağlı" : s.status == "waiting" ? "ilk veri bekleniyor" : s.status == "error" ? (s.err ?? "hata") : "bağlı değil")
                                .font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
                            if s.status == "error" || s.status == "missing" {
                                Button("Düzelt") { openConnections(Self.focusFor(s.source)) }.buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }
        }

        let have = Set(card.sources.map(\.source))
        let missing: [(String, String)] = [
            have.contains("revenuecat_charts") ? nil : ("RevenueCat", "revenuecat"),
            have.contains("ga4") ? nil : ("Analytics", "ga4"),
            detail?.meta != nil ? nil : ("Meta reklam", "meta"),
            have.contains("stripe") ? nil : ("Stripe", "stripe"),
            card.site != nil ? nil : ("Site", "site"),
        ].compactMap { $0 }
        if !missing.isEmpty {
            section("Ekleyebileceklerin", "plus.circle")
            box {
                VStack(alignment: .leading, spacing: 8) {
                    Text("İsteğe bağlı. Bağlarsan bu ürün için daha fazla veri görürsün.").font(.system(size: 11.5)).foregroundStyle(Theme.dim)
                    HStack(spacing: 6) {
                        ForEach(missing, id: \.1) { m in
                            Button { openConnections(m.1) } label: {
                                Label(m.0, systemImage: "plus").font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.08)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    static func focusFor(_ source: String) -> String? {
        switch source {
        case "revenuecat", "revenuecat_charts", "revenuecat_live": "revenuecat"
        case "stripe": "stripe"
        case "cloudflare", "health": "site"
        case "ga4": "ga4"
        case "meta_ads": "meta"
        default: nil
        }
    }

    @ViewBuilder private func charts(_ d: Detail) -> some View {
        let present = Self.chartMetrics.filter { (d.series[$0.0]?.count ?? 0) > 1 }
        if !present.isEmpty {
            section("Son 30 gün", "chart.xyaxis.line")
            ForEach(present, id: \.0) { key, label, money in
                let pts = d.series[key] ?? []
                box {
                    TrendChart(pts: pts, label: label, money: money, color: Color(hex: card.color))
                }
            }
        }
    }

    private func retention(_ r: Retention) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Geri dönüş (son 14 gün, \(Fmt.num(r.cohortUsers)) yeni kullanıcı)", "arrow.uturn.backward")
            box {
                Chart(Array(r.curve.enumerated()), id: \.offset) { i, v in
                    BarMark(x: .value("Gün", "G\(i)"), y: .value("%", v))
                        .foregroundStyle(i == 1 || i == 7 ? Color(hex: card.color) : Color.white.opacity(0.25))
                        .annotation(position: .top) {
                            if i > 0 { Text(String(format: "%.0f", v)).font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                }
                .chartYAxis(.hidden)
                .frame(height: 90)
            }
        }
    }

    private func liveScreens(_ s: [LiveScreen]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Şu an hangi ekranda", "eye")
            box {
                VStack(spacing: 6) {
                    ForEach(s, id: \.self) { r in
                        HStack {
                            Text(r.screen.isEmpty ? "(adsız)" : r.screen).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text(Fmt.num(r.users)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func stuckScreens(_ s: [ScreenRow]) -> some View {
        let top = s.first?.users ?? 1
        let medianSec = s.map(\.secPerUser).sorted()[s.count / 2]
        return VStack(alignment: .leading, spacing: 8) {
            section("Ekranlar (7 gün): nerede kalıyorlar", "hand.raised")
            box {
                VStack(spacing: 7) {
                    ForEach(s.prefix(12), id: \.self) { r in
                        let weak = r.users > top * 0.15 && r.secPerUser < max(medianSec * 0.4, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.screen.isEmpty ? "(adsız)" : r.screen).font(.system(size: 11)).lineLimit(1)
                                if weak {
                                    Text("hızlı çıkış").font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.red.opacity(0.7)))
                                }
                                Spacer()
                                Text("\(Fmt.num(r.users)) kişi · \(Int(r.secPerUser)) sn").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            GeometryReader { g in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(weak ? Color.red.opacity(0.8) : Color(hex: card.color).opacity(0.8))
                                    .frame(width: g.size.width * CGFloat(r.users / top))
                            }.frame(height: 4)
                        }
                    }
                }
            }
        }
    }

    private func events(_ e: [EventRow]) -> some View {
        let base = e.first(where: { $0.event == "first_open" })?.users ?? e.first?.users ?? 1
        return VStack(alignment: .leading, spacing: 8) {
            section("Olaylar (7 gün, kişi)", "list.bullet.rectangle")
            box {
                VStack(spacing: 5) {
                    ForEach(e.prefix(15), id: \.self) { r in
                        HStack {
                            Text(r.event).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Text(Fmt.num(r.users)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            Text(String(format: "%%%.0f", r.users / base * 100)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func countries(_ c: [String: Double]) -> some View {
        let top = c.sorted { $0.value > $1.value }.prefix(8)
        return VStack(alignment: .leading, spacing: 8) {
            section("Dünkü indirmeler, ülke", "globe")
            box {
                HStack(spacing: 10) {
                    ForEach(Array(top), id: \.key) { k, v in
                        VStack(spacing: 2) {
                            Text(flag(k)).font(.system(size: 18))
                            Text(Fmt.num(v)).font(.system(size: 10, weight: .semibold))
                        }
                    }
                }
            }
        }
    }

    private func flag(_ code: String) -> String {
        code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }.map(String.init).joined()
    }
}

struct DiagnosisView: View {
    let dx: Diagnosis

    private var scoreColor: Color { dx.score >= 75 ? Theme.good : dx.score >= 50 ? Theme.warn : Theme.bad }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 6)
                    Circle().trim(from: 0, to: CGFloat(dx.score) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(dx.score)").font(.system(size: 20, weight: .bold, design: .rounded))
                }.frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    Text(dx.verdict).font(.system(size: 18, weight: .bold)).foregroundStyle(scoreColor)
                    Text("Son 7 gün (\(dx.window)), önceki 7 günle kıyas").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    Text("\(dx.issues.count) sorun · \(dx.wins.count) iyi giden").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
                }
                Spacer()
            }

            if !dx.funnel.isEmpty {
                head("Huni: nerede kaybediyorsun", "line.3.horizontal.decrease")
                VStack(spacing: 0) {
                    ForEach(Array(dx.funnel.enumerated()), id: \.offset) { i, f in
                        funnelRow(f, width: barWidth(f))
                        if i < dx.funnel.count - 1 { Divider().opacity(0.15) }
                    }
                }.padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }

            if !dx.issues.isEmpty {
                head("Neden aksıyor", "exclamationmark.triangle")
                ForEach(dx.issues, id: \.self) { FindingCard(f: $0) }
            }
            if !dx.wins.isEmpty {
                head("İyi giden", "hand.thumbsup")
                ForEach(dx.wins, id: \.self) { FindingCard(f: $0) }
            }
            if !dx.gaps.isEmpty {
                head("Göremediğim yerler", "eye.slash")
                ForEach(dx.gaps, id: \.self) { g in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(g.title).font(.system(size: 12, weight: .semibold))
                        Text(g.how).font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
            }
        }
    }

    private func head(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
        }.foregroundStyle(Theme.faint).padding(.top, 4)
    }

    private func barWidth(_ f: FunnelStep) -> CGFloat {
        guard f.money != true, let top = dx.funnel.first(where: { $0.money != true })?.now, top > 0, f.now > 0 else { return 0 }
        return CGFloat(max(0.03, log10(f.now + 1) / log10(top + 1)))
    }

    private func funnelRow(_ f: FunnelStep, width: CGFloat) -> some View {
        let val = f.money == true ? Fmt.usd(f.now) : Fmt.num(f.now)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(f.label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(val).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                    .moneyBlur(f.money == true)
                if let p = f.prev { change(f.now, p) }
            }
            if f.money != true {
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06))
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(f.ok == false ? Theme.bad.opacity(0.7) : Theme.good.opacity(0.6))
                                .frame(width: g.size.width * width)
                        }
                }.frame(height: 5)
            }
            if let r = f.rateTxt {
                HStack(spacing: 6) {
                    MText(r).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(f.ok == nil ? Theme.dim : f.ok! ? Theme.good : Theme.bad)
                    if let t = f.targetTxt { Text("(\(t))").font(.system(size: 10)).foregroundStyle(Theme.faint) }
                }
            }
        }.padding(.vertical, 8)
    }

    @ViewBuilder private func change(_ now: Double, _ prev: Double) -> some View {
        if prev > 0 {
            let c = (now - prev) / prev * 100
            Text(String(format: "%@%%%.0f", c >= 0 ? "▲" : "▼", abs(c)))
                .font(.system(size: 10, weight: .bold)).foregroundStyle(c >= 0 ? Theme.good : Theme.bad)
                .frame(minWidth: 44, alignment: .trailing)
        } else {
            Text("önceki 0").font(.system(size: 10)).foregroundStyle(Theme.faint).frame(minWidth: 44, alignment: .trailing)
        }
    }
}

struct FindingCard: View {
    let f: Finding
    @State private var open = true
    @State private var hover = false
    @AppStorage(hideMoneyKey) private var hide = true
    private func m(_ t: String) -> String { !hide || hover ? t : maskMoney(t) }

    private var color: Color {
        switch f.sev {
        case "critical": Theme.bad
        case "bad": Color(red: 1.0, green: 0.5, blue: 0.4)
        case "meh": Theme.warn
        default: Theme.good
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text(f.area.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.18))).foregroundStyle(color)
                Text(m(f.title)).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.faint)
            }
            if open {
                label("Neden", f.why, "questionmark.circle")
                label(f.sev == "good" ? "Devam" : "Ne yap", f.fix, "wrench.and.screwdriver")
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(color.opacity(0.07)))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 8) }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
        .onHover { hover = $0 }
    }

    private func label(_ k: String, _ v: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.faint).frame(width: 14).padding(.top, 2)
            (Text(k + ": ").font(.system(size: 11, weight: .semibold)).foregroundColor(.white.opacity(0.75))
                + Text(m(v)).font(.system(size: 11)).foregroundColor(.white.opacity(0.62)))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TabStrip: View {
    @Binding var tab: Int
    let items: [(Int, String)]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { id, title in
                Button { withAnimation(.snappy(duration: 0.2)) { tab = id } } label: {
                    Text(title)
                        .font(.system(size: 12, weight: tab == id ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tab == id ? Color.white.opacity(0.18) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
    }
}
