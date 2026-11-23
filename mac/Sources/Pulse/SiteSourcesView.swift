import SwiftUI

struct SiteSourcesView: View {
    let s: SiteSources
    let color: Color
    @AppStorage("srcWindow") private var month = false

    static func name(_ src: String) -> (String, String) {
        switch src {
        case "direct": ("Doğrudan (adres yazan, yer imi)", "link")
        case "google": ("Google arama", "magnifyingglass")
        case "bing": ("Bing", "magnifyingglass")
        case "duckduckgo": ("DuckDuckGo", "magnifyingglass")
        case "yandex": ("Yandex", "magnifyingglass")
        case "yahoo", "baidu", "naver", "search-other": (src == "search-other" ? "Diğer arama motorları" : src.capitalized, "magnifyingglass")
        case "chatgpt": ("ChatGPT", "sparkles")
        case "claude": ("Claude", "sparkles")
        case "perplexity": ("Perplexity", "sparkles")
        case "gemini": ("Gemini", "sparkles")
        case "copilot": ("Copilot", "sparkles")
        case "ai-other": ("Diğer yapay zekâlar", "sparkles")
        case "reddit": ("Reddit", "bubble.left.and.bubble.right")
        case "youtube": ("YouTube", "play.rectangle")
        case "x": ("X (Twitter)", "bubble.left")
        case "meta": ("Instagram / Facebook", "camera")
        case "linkedin": ("LinkedIn", "briefcase")
        case "github": ("GitHub", "chevron.left.forwardslash.chevron.right")
        case "stackoverflow": ("Stack Overflow", "questionmark.bubble")
        case "producthunt": ("Product Hunt", "flame")
        case "apple": ("Apple", "apple.logo")
        case "bilinmiyor": ("Bilinmiyor", "questionmark.circle")
        case "takip öncesi": ("Sayaç kurulmadan önce", "clock.arrow.circlepath")
        default: (src, "arrow.turn.down.right")
        }
    }

    private var rows: [SiteSources.Row] {
        s.rows.filter { (month ? $0.v30 : $0.v7) > 0 || $0.s30 > 0 || $0.buyers > 0 }
            .sorted { (month ? $0.v30 : $0.v7) > (month ? $1.v30 : $1.v7) }
    }

    var body: some View {
        let total = rows.reduce(0) { $0 + (month ? $1.v30 : $1.v7) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(Fmt.num(total)) ziyaret").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                TabStrip(tab: Binding(get: { month ? 1 : 0 }, set: { month = $0 == 1 }), items: [(0, "7 gün"), (1, "30 gün")])
                    .frame(width: 130)
            }
            if rows.isEmpty {
                Text("Bu aralıkta kaynak verisi yok.").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            ForEach(rows, id: \.self) { r in
                let v = month ? r.v30 : r.v7
                let (label, icon) = Self.name(r.src)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: icon).font(.system(size: 10)).frame(width: 14).foregroundStyle(color)
                        Text(label).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 4)
                        if r.s30 > 0 { Text("\(Fmt.num(r.s30)) kayıt").font(.system(size: 10)).foregroundStyle(Theme.good) }
                        if r.buyers > 0 { Text("\(Fmt.num(r.buyers)) alıcı").font(.system(size: 10, weight: .semibold)).foregroundStyle(.yellow) }
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
            if !s.landings.isEmpty {
                Text("İLK AÇILAN SAYFALAR (30 GÜN)").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.faint).padding(.top, 4)
                ForEach(s.landings.prefix(6), id: \.self) { l in
                    HStack {
                        Text("/\(l.page == "home" ? "" : l.page)").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        Text("← \(Self.name(l.src).0)").font(.system(size: 10)).foregroundStyle(Theme.dim).lineLimit(1)
                        Spacer()
                        Text(Fmt.num(l.n)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            if !s.refs.isEmpty {
                Text("GÖNDEREN SİTELER (TÜM ZAMANLAR)").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.faint).padding(.top, 4)
                ForEach(s.refs.prefix(6), id: \.self) { r in
                    HStack {
                        Text(r.host).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(Fmt.num(r.n)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                }
            }
            Text("Sitenin kendi sayacı: çerezsiz, kişisel veri yok. Kayıt ve alıcı, kişinin siteye ilk geldiği kaynağa yazılır.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
