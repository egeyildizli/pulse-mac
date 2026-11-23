import SwiftUI

struct AcquisitionView: View {
    let a: Acquisition
    let color: Color
    @AppStorage("srcWindow") private var month = false
    @State private var channel = 0

    private var channels: [(Int, String)] {
        var c: [(Int, String)] = []
        if a.web != nil { c.append((0, "Web sitesi")) }
        if a.ios != nil { c.append((1, "App Store")) }
        if a.android != nil { c.append((2, "Google Play")) }
        return c
    }

    static func daysAgo(_ day: String) -> Int? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: day) else { return nil }
        return Int(Date().timeIntervalSince(d) / 86400)
    }
    static func trDay(_ day: String) -> String {
        let m = Loc.months
        let p = day.split(separator: "-")
        guard p.count == 3, let mo = Int(p[1]), let g = Int(p[2]), (1...12).contains(mo) else { return day }
        return "\(g) \(m[mo - 1])"
    }

    static func iosName(_ s: String) -> (String, String) {
        let again = s.hasSuffix("|yeniden")
        let base = again ? String(s.dropLast(8)) : s
        let (n, i): (String, String) = switch base {
        case "App Store search": ("App Store araması", "magnifyingglass")
        case "App Store browse": ("App Store gezinme (öne çıkan, kategori)", "square.grid.2x2")
        case "App referrer": ("Başka uygulamadan (Instagram, TikTok…)", "app.badge")
        case "Web referrer": ("Web sitesinden", "globe")
        case "Institutional purchase": ("Kurumsal alım", "building.2")
        case "Unavailable": ("Bilinmiyor", "questionmark.circle")
        default: (base, "arrow.turn.down.right")
        }
        return (again ? "\(n) · yeniden indirme" : n, i)
    }

    static func androidName(_ s: String) -> (String, String) {
        switch s {
        case "Google Play search": ("Play araması", "magnifyingglass")
        case "Google Play explore": ("Play keşfet (öneriler, listeler)", "square.grid.2x2")
        case "Ads and referrals": ("Reklam ve yönlendirme", "megaphone")
        case "Other": ("Diğer (doğrudan link vb.)", "link")
        default: (s, "arrow.turn.down.right")
        }
    }

    static func webName(_ s: String) -> (String, String) {
        if s.hasPrefix("ref:") { return (String(s.dropFirst(4)), "arrow.turn.down.right") }
        if s.hasPrefix("utm:") { return ("Kampanya: \(s.dropFirst(4))", "megaphone") }
        return SiteSourcesView.name(s)
    }

    var body: some View {
        let ch = channels.contains { $0.0 == channel } ? channel : (channels.first?.0 ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            if channels.count > 1 { TabStrip(tab: $channel, items: channels) }
            switch ch {
            case 0: if let w = a.web { web(w) }
            case 1: if let s = a.ios { store(s, unit: "ilk indirme", name: Self.iosName, note: "App Store raporu, 1-2 gün gecikmeli.") }
            default: if let s = a.android { store(s, unit: "edinim", name: Self.androidName, note: "Play mağaza sayfası edinimleri, Google birkaç gün gecikmeli verir.") }
            }
        }
        .onAppear { channel = ch }
    }

    private func header(_ total: Double, _ unit: String) -> some View {
        HStack {
            Text("\(Fmt.num(total)) \(unit)").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            TabStrip(tab: Binding(get: { month ? 1 : 0 }, set: { month = $0 == 1 }), items: [(0, "7 gün"), (1, "30 gün")])
                .frame(width: 130)
        }
    }

    private func list(_ rows: [Acquisition.Row], since: String?, name: @escaping (String) -> (String, String)) -> some View {
        let rs = rows.filter { (month ? $0.v30 : $0.v7) > 0 }.sorted { (month ? $0.v30 : $0.v7) > (month ? $1.v30 : $1.v7) }
        let total = rs.reduce(0) { $0 + (month ? $1.v30 : $1.v7) }
        return VStack(alignment: .leading, spacing: 8) {
            header(total, "")

            if let f = since, let d = Self.daysAgo(f), d < 29 {
                Text("Veri \(Self.trDay(f)) tarihinden beri var, 30 gün henüz dolmadı.")
                    .font(.system(size: 10)).foregroundStyle(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
            if rs.isEmpty { Text("Bu aralıkta veri yok.").font(.system(size: 12)).foregroundStyle(Theme.dim) }
            ForEach(rs, id: \.self) { r in
                let v = month ? r.v30 : r.v7
                let (label, icon) = name(r.src)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 10)).frame(width: 14).foregroundStyle(color)
                        Text(label).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Fmt.num(v)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Text(total > 0 ? String(format: "%%%.0f", v / total * 100) : "").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.75))
                            .frame(width: total > 0 ? g.size.width * CGFloat(v / total) : 0)
                    }.frame(height: 4)
                }
            }
        }
    }

    private func store(_ s: Acquisition.Store, unit: String, name: @escaping (String) -> (String, String), note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            list(s.rows, since: s.firstDay, name: name)
            Text(note + (s.lastDay.map { " Son veri: \(Self.trDay($0))." } ?? "") + " Sayılar \(unit).")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func web(_ w: Acquisition.Web) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            list(w.rows, since: a.webFirstDay, name: Self.webName)
            if !w.landings.isEmpty {
                Text("İLK AÇILAN SAYFALAR (30 GÜN)").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.faint).padding(.top, 4)
                ForEach(w.landings.prefix(6), id: \.self) { l in
                    HStack {
                        Text(l.page).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Text("← \(Self.webName(l.src).0)").font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
                        Spacer()
                        Text(Fmt.num(l.n)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            if !w.refs.isEmpty {
                Text("GÖNDEREN SİTELER").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.faint).padding(.top, 4)
                ForEach(w.refs.prefix(6), id: \.self) { r in
                    HStack {
                        Text(r.host).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(Fmt.num(r.n)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            Text("Pulse sayacı: çerezsiz, IP ve kişisel veri tutulmaz. Oturumun ilk sayfası 1 ziyaret sayılır.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
