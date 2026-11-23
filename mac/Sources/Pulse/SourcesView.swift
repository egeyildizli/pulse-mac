import SwiftUI

struct SourcesBrief: Decodable {
    struct Top: Decodable { let src: String; let n: Int }
    let total: Int
    let cfTotal: Int?
    let top: [Top]
    let sites: Int
}

struct SourcesOverview: Decodable {
    struct Src: Decodable { let src: String; let n: Int; let apps: [String: Int] }
    struct AppN: Decodable { let app: String; let n: Int; let cf: Int? }
    struct Land: Decodable { let app: String; let src: String; let page: String; let n: Int }
    struct Ref: Decodable { let app: String; let host: String; let src: String?; let n: Int }
    struct Channel: Decodable { let total: Int; let bySrc: [Src]; let byApp: [AppN]; let from: String; let to: String }
    struct Web: Decodable {
        let total: Int; let bySrc: [Src]; let byApp: [AppN]; let from: String; let to: String
        let cfTotal: Int?; let landings: [Land]; let refs: [Ref]; let since: String?
    }
    let days: Int
    let web: Web
    let ios: Channel?
    let android: Channel?
}

extension Store {
    func sources(days: Int) async -> SourcesOverview? {
        guard let d = try? await fetchData("/v1/sources?days=\(days)") else { return nil }
        do { return try JSONDecoder().decode(SourcesOverview.self, from: d) } catch { print("sources decode", error); return nil }
    }
}

struct SourcesStrip: View {
    let s: SourcesBrief
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.teal)
                    Text("NEREDEN GELİYORLAR · BUGÜN").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.dim)
                    Spacer()
                    Text("\(Fmt.num(Double(s.total))) gerçek ziyaret").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                if s.top.isEmpty {
                    Text("Bugün henüz sayaca düşen ziyaret yok.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(s.top, id: \.src) { t in
                            let (n, icon) = AcquisitionView.webName(t.src)
                            HStack(spacing: 4) {
                                Image(systemName: icon).font(.system(size: 9))
                                Text(short(n)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(Fmt.num(Double(t.n))).font(.system(size: 11, weight: .bold)).monospacedDigit()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                        }
                    }
                }
                if let cf = s.cfTotal {
                    Text("Cloudflare \(Fmt.num(Double(cf))) sayıyor, botlar dahil · \(s.sites) siteden")
                        .font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.10 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private func short(_ n: String) -> String {
        n.replacingOccurrences(of: " (adres yazan, yer imi)", with: "")
    }
}

struct SourcesDetailView: View {
    @EnvironmentObject var store: Store
    let onBack: () -> Void
    @AppStorage("sourcesDays") private var days = 1
    @State private var app = ""
    @State private var data: SourcesOverview?
    @State private var loading = true

    private var cards: [Card] { store.snap?.cards ?? [] }
    private func card(_ id: String) -> Card? { cards.first { $0.id == id } }
    private func name(_ id: String) -> String { card(id)?.name ?? id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
                Image(systemName: "arrow.triangle.branch").font(.system(size: 18)).foregroundStyle(.teal)
                Text("Nereden geliyorlar").font(.system(size: 20, weight: .bold))
                Spacer()
                Picker("", selection: $days) {
                    Text("Bugün").tag(1)
                    Text("7").tag(7)
                    Text("30").tag(30)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }.padding(16)
            Divider().opacity(0.3)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading && data == nil { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20) }
                    if let d = data {
                        filter(d)
                        webSection(d.web)
                        if let i = d.ios, has(i) { storeSection("App Store", "apple.logo", i, unit: "ilk indirme", name: AcquisitionView.iosName) }
                        if let a = d.android, has(a) { storeSection("Google Play", "play.fill", a, unit: "edinme", name: AcquisitionView.androidName) }
                    } else if !loading {
                        Text("Veri yüklenemedi.").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .padding(12)
            }
        }
        .task(id: "\(days)#\(store.refreshTick)") {
            loading = true
            if let r = await store.sources(days: days) { data = r }
            loading = false
        }
    }

    private func has(_ c: SourcesOverview.Channel) -> Bool { app.isEmpty || c.byApp.contains { $0.app == app } }

    private func filter(_ d: SourcesOverview) -> some View {
        var ids: [String] = []
        for x in d.web.byApp + (d.ios?.byApp ?? []) + (d.android?.byApp ?? []) where !ids.contains(x.app) { ids.append(x.app) }
        return FlowLayout(spacing: 6) {
            chip("", "Tümü")
            ForEach(ids, id: \.self) { chip($0, name($0)) }
        }
    }

    private func chip(_ id: String, _ label: String) -> some View {
        let on = app == id
        return Button { withAnimation(.snappy(duration: 0.2)) { app = id } } label: {
            HStack(spacing: 5) {
                if let c = card(id) { AppIcon(card: c, size: 16) }
                Text(label).font(.system(size: 12, weight: on ? .semibold : .medium)).lineLimit(1)
            }
            .foregroundStyle(on ? Color.black : Color.white.opacity(0.85))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func webSection(_ w: SourcesOverview.Web) -> some View {
        let sites = app.isEmpty ? w.byApp : w.byApp.filter { $0.app == app }
        let real = sites.reduce(0) { $0 + $1.n }
        let cf = sites.compactMap(\.cf).reduce(0, +)
        let rows = srcRows(w.bySrc)
        if !sites.isEmpty || app.isEmpty {
            SectionLabel(text: "Web siteleri")
            box {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.num(Double(real))).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    Text("gerçek ziyaret · \(period(w.from, w.to))").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                Text(cf > 0
                     ? "Cloudflare aynı sürede \(Fmt.num(Double(cf))) tekil ziyaretçi sayıyor. Aradaki fark büyük ölçüde botlar, tarayıcısız istekler ve güvenlik taramaları. Gerçek ziyaret, sayfayı tarayıcıda açan kişilerin oturum sayısı."
                     : "Gerçek ziyaret, sayfayı tarayıcıda açan kişilerin oturum sayısı.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                if let s = w.since, days > 1, s > w.from {
                    Text("Sayaç \(AcquisitionView.trDay(s)) tarihinde kuruldu, öncesi boş.").font(.system(size: 11)).foregroundStyle(Theme.warn)
                }
                bars(rows.map { ($0.0, $0.1) }, name: AcquisitionView.webName, tint: .teal)
            }
            if app.isEmpty && sites.count > 1 {
                SectionLabel(text: "Site site")
                box {
                    HStack {
                        Text("Site").frame(maxWidth: .infinity, alignment: .leading)
                        Text("gerçek").frame(width: 60, alignment: .trailing)
                        Text("Cloudflare").frame(width: 76, alignment: .trailing)
                    }.font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                    ForEach(sites, id: \.app) { s in
                        Button { withAnimation(.snappy(duration: 0.2)) { app = s.app } } label: {
                            HStack(spacing: 8) {
                                if let c = card(s.app) { AppIcon(card: c, size: 18) }
                                Text(name(s.app)).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Text(Fmt.num(Double(s.n))).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 60, alignment: .trailing)
                                    .foregroundStyle(s.n == 0 ? Theme.faint : .white)
                                Text(s.cf.map { Fmt.num(Double($0)) } ?? "-").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: 76, alignment: .trailing)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            let land = landings(w.landings)
            if !land.isEmpty {
                SectionLabel(text: "İlk açılan sayfa")
                box {
                    ForEach(Array(land.enumerated()), id: \.offset) { _, l in
                        HStack(spacing: 8) {
                            if app.isEmpty, let c = card(l.app) { AppIcon(card: c, size: 14) }
                            Text(l.page).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.num(Double(l.n))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
            }
            let refs = w.refs.filter { app.isEmpty || $0.app == app }.prefix(8)
            if !refs.isEmpty {
                SectionLabel(text: "Yönlendiren siteler · tüm zamanlar")
                box {
                    ForEach(Array(refs.enumerated()), id: \.offset) { _, r in
                        HStack(spacing: 8) {
                            if app.isEmpty, let c = card(r.app) { AppIcon(card: c, size: 14) }
                            Text(r.host).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(Fmt.num(Double(r.n))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func landings(_ ls: [SourcesOverview.Land]) -> [(app: String, page: String, n: Int)] {
        var m: [String: (app: String, page: String, n: Int)] = [:]
        var order: [String] = []
        for l in ls where app.isEmpty || l.app == app {
            let k = l.app + "|" + l.page
            if m[k] == nil { order.append(k); m[k] = (l.app, l.page, 0) }
            m[k]!.n += l.n
        }
        return order.compactMap { m[$0] }.sorted { $0.n > $1.n }.prefix(8).map { $0 }
    }

    @ViewBuilder
    private func storeSection(_ title: String, _ icon: String, _ c: SourcesOverview.Channel, unit: String, name: @escaping (String) -> (String, String)) -> some View {
        let rows = srcRows(c.bySrc)
        let total = rows.reduce(0) { $0 + $1.1 }
        let age = AcquisitionView.daysAgo(c.to) ?? 0
        SectionLabel(text: title)
        box {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Theme.dim)
                Text(Fmt.num(Double(total))).font(.system(size: 24, weight: .bold)).monospacedDigit()
                Text("\(unit) · \(period(c.from, c.to))").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            Text(age > 3
                 ? "Son rapor \(AcquisitionView.trDay(c.to)) tarihli, \(age) gün eski. Mağaza raporu gelmiyor olabilir."
                 : "Mağaza raporu 1-3 gün gecikmeli gelir, bu yüzden son gelen günü gösteriyor.")
                .font(.system(size: 11)).foregroundStyle(age > 3 ? Theme.warn : Theme.dim).fixedSize(horizontal: false, vertical: true)
            bars(rows, name: name, tint: .cyan)
            if app.isEmpty && c.byApp.count > 1 {
                Divider().opacity(0.2)
                ForEach(c.byApp, id: \.app) { a in
                    HStack(spacing: 8) {
                        if let cd = card(a.app) { AppIcon(card: cd, size: 16) }
                        Text(self.name(a.app)).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(Fmt.num(Double(a.n))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    }
                }
            }
        }
    }

    private func srcRows(_ xs: [SourcesOverview.Src]) -> [(String, Int)] {
        xs.map { ($0.src, app.isEmpty ? $0.n : ($0.apps[app] ?? 0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    private func bars(_ rows: [(String, Int)], name: @escaping (String) -> (String, String), tint: Color) -> some View {
        let total = max(1, rows.reduce(0) { $0 + $1.1 })
        let top = max(1, rows.first?.1 ?? 1)
        return VStack(alignment: .leading, spacing: 7) {
            if rows.isEmpty {
                Text("Bu aralıkta kayıt yok.").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            ForEach(rows, id: \.0) { r in
                let (n, icon) = name(r.0)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.dim).frame(width: 14)
                        Text(n).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(Fmt.num(Double(r.1))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Text("%\(Int((Double(r.1) / Double(total) * 100).rounded()))").font(.system(size: 11)).foregroundStyle(Theme.faint).monospacedDigit().frame(width: 34, alignment: .trailing)
                    }
                    GeometryReader { g in
                        Capsule().fill(tint.opacity(0.75)).frame(width: max(3, g.size.width * CGFloat(r.1) / CGFloat(top)))
                    }.frame(height: 4)
                }
            }
        }
    }

    private func period(_ from: String, _ to: String) -> String {
        if from == to { return AcquisitionView.daysAgo(to) == 0 ? "bugün" : AcquisitionView.trDay(to) }
        return "\(AcquisitionView.trDay(from)) - \(AcquisitionView.trDay(to))"
    }

    private func box<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { c() }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
