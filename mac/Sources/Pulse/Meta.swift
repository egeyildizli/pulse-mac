import Charts
import SwiftUI

struct MetaWin: Decodable {
    let spend: Double
    let impressions: Double
    let clicks: Double
    let ctr: Double?
    let cpm: Double?
    let metaInstalls: Double
    let metaCpi: Double?
    let totalInstalls: Double?
    let blendedCpi: Double?
    let trials: Double?
    let costPerTrial: Double?
    let subs: Double?
    let costPerSub: Double?
    let revenue: Double?
    let metaTrials: Double?
    let metaSubs: Double?
    let metaValue: Double?
    let roas: Double?
}

struct MetaDayPt: Decodable, Identifiable {
    let day: String
    let spend: Double
    let metaInstalls: Double
    let totalInstalls: Double?
    var id: String { day }
}

struct MetaCampaign: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let effective: String
    let budget: Double?
    let spendToday: Double
    let spend7d: Double
    let installsToday: Double
    let installs7d: Double
}

struct MetaAd: Decodable, Identifiable {
    let id: String
    let name: String
    let campaign: String
    let effective: String
    let spendToday: Double
    let installsToday: Double
    let spend: Double
    let impressions: Double
    let clicks: Double
    let ctr: Double?
    let installs: Double
    let cpi: Double?
}

struct MetaPair: Decodable { let before: Double; let after: Double }
struct MetaLift: Decodable {
    let start: String
    let days: Int
    let reliable: Bool
    let spend: Double
    let installsPerDay: MetaPair?
    let extraInstalls: Double?
    let trialsPerDay: MetaPair
    let subsPerDay: MetaPair
    let revenuePerDay: MetaPair
    let extraTrials: Double
    let extraSubs: Double
    let extraRevenue: Double
    let costPerExtraTrial: Double?
    let roas: Double?
}

struct MetaAccount: Decodable { let id: String; let name: String; let currency: String }

struct MetaOut: Decodable {
    let account: MetaAccount?
    let measured: Bool
    let today: MetaWin
    let d7: MetaWin
    let d30: MetaWin
    let days: [MetaDayPt]
    let campaigns: [MetaCampaign]
    let ads: [MetaAd]?
    let lift: MetaLift?
    let ts: Int
}

private func usd2(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0) } ?? "–" }

struct MetaView: View {
    let m: MetaOut
    @State private var win = 1

    private var w: MetaWin { win == 0 ? m.today : win == 1 ? m.d7 : m.d30 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !m.measured { note }
            windowPicker
            kpis
            liftCard
            chart
            campaigns
            adsList
            Text("ROAS, deneme başı ve abone başı yalnız Meta'nın reklama atfettiği olaylardan hesaplanır (RevenueCat satışları Meta'ya gider); organik kullanıcılar reklama yazılmaz. * Tüm kurulum ve tüm gelir organik dahil her şeydir, reklam başarısı olarak okunmaz. Veri yalnız okunur, kampanyalara dokunulmaz.")
                .font(.system(size: 10)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func head(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11))
            Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8)
        }.foregroundStyle(Theme.faint).padding(.top, 4)
    }

    private func card<V: View>(@ViewBuilder _ c: () -> V) -> some View {
        c().padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke))
    }

    private func cell(_ label: String, _ value: String, _ color: Color = .white, money: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.faint).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(color).moneyBlur(money)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "megaphone.fill").font(.system(size: 12)).foregroundStyle(.blue)
            Text(m.account.map { "\($0.name) · \($0.currency)" } ?? "Meta Reklam").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("\(Fmt.ago(m.ts)) önce").font(.system(size: 10)).foregroundStyle(Theme.faint)
        }
    }

    private var note: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.warn).font(.system(size: 13))
            Text("Meta kurulum ölçümü yeni sürümle başlar. O zamana kadar Meta kurulum maliyeti gösterilmez; karma maliyet harcama olunca hesaplanır.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warn.opacity(0.12)))
    }

    private var windowPicker: some View {
        TabStrip(tab: $win, items: [(0, "Bugün"), (1, "7 gün"), (2, "30 gün")])
    }

    private var kpis: some View {
        card {
            VStack(spacing: 10) {
                HStack {
                    cell("Harcama", usd2(w.spend), .white, money: true)
                    cell("Gösterim", Fmt.num(w.impressions))
                    cell("Tıklama", Fmt.num(w.clicks))
                    cell("TO (CTR)", w.ctr.map { String(format: "%%%.2f", $0) } ?? "–")
                }
                HStack {
                    cell("Meta kurulum", m.measured ? Fmt.num(w.metaInstalls) : "–")
                    cell("Meta CPI", m.measured ? usd2(w.metaCpi) : "–", money: true)
                    cell("BGBM (CPM)", usd2(w.cpm), money: true)
                }
                HStack {
                    cell("Meta deneme", Fmt.num(w.metaTrials ?? 0))
                    cell("Deneme başı", usd2(w.costPerTrial), money: true)
                    cell("Abone başı", usd2(w.costPerSub), money: true)
                    cell("ROAS (Meta, alt sınır)", w.roas.map { String(format: "%.2fx", $0) } ?? "–", (w.roas ?? 0) >= 1 ? Theme.good : .white, money: true)
                }
                HStack {
                    cell("Meta satış", usd2(w.metaValue ?? 0), money: true)
                    cell("Tüm kurulum*", Fmt.num(w.totalInstalls))
                    cell("Tüm gelir*", usd2(w.revenue), money: true)
                    cell("Meta abone", Fmt.num(w.metaSubs ?? 0))
                }
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            head("Günlük harcama ve kurulum", "chart.bar.xaxis")
            card {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Harcama ($)").font(.system(size: 10)).foregroundStyle(Theme.faint)
                    Chart(m.days) { d in
                        BarMark(x: .value("Gün", d.day), y: .value("Harcama", d.spend)).foregroundStyle(Color.blue.gradient)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: 7)) { v in
                        AxisValueLabel { if let s = v.as(String.self) { Text(String(s.dropFirst(5))).font(.system(size: 9)) } }
                    } }
                    .chartYScale(domain: 0...max(1, m.days.map(\.spend).max() ?? 1))
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let n = v.as(Double.self) { Text(Fmt.num(n)).moneyBlur() }
                        }
                    } }
                    .frame(height: 90)
                    HStack(spacing: 10) {
                        Text("Kurulum").font(.system(size: 10)).foregroundStyle(Theme.faint)
                        Label("Meta", systemImage: "square.fill").font(.system(size: 9)).foregroundStyle(.blue)
                        Label("Toplam", systemImage: "minus").font(.system(size: 9)).foregroundStyle(.cyan)
                    }
                    Chart {
                        ForEach(m.days) { d in
                            BarMark(x: .value("Gün", d.day), y: .value("Meta", d.metaInstalls)).foregroundStyle(Color.blue.gradient)
                            if let t = d.totalInstalls {
                                LineMark(x: .value("Gün", d.day), y: .value("Toplam", t)).foregroundStyle(.cyan).interpolationMethod(.monotone)
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: 7)) { v in
                        AxisValueLabel { if let s = v.as(String.self) { Text(String(s.dropFirst(5))).font(.system(size: 9)) } }
                    } }
                    .frame(height: 90)
                }
            }
        }
    }

    private var campaigns: some View {
        VStack(alignment: .leading, spacing: 6) {
            head("Kampanyalar", "list.bullet.rectangle")
            card {
                if m.campaigns.isEmpty {
                    Text("Henüz kampanya yok. İlk kampanya açılınca durumu, bütçesi ve harcaması burada görünür.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 8) {
                        ForEach(m.campaigns) { c in
                            let st = Self.status(c.effective)
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(st.1).frame(width: 7, height: 7).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                    Text("\(st.0)" + (c.budget.map { " · günlük bütçe \(usd2($0))" } ?? ""))
                                        .font(.system(size: 10)).foregroundStyle(Theme.faint)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(usd2(c.spendToday)) bugün").font(.system(size: 11, weight: .semibold, design: .rounded)).moneyBlur()
                                    Text("7g \(usd2(c.spend7d)) · \(Fmt.num(c.installs7d)) kurulum").font(.system(size: 10)).foregroundStyle(Theme.faint).moneyBlur()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var liftCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            head("Reklamdan önce / sonra", "arrow.left.arrow.right")
            card {
                if let l = m.lift, l.days == 0 {
                    Text("Reklam \(l.start) başladı. İlk tam gün bitince (yarın) burada reklamdan önceki 14 günle kıyas görünür; yarım günle kıyas yanıltır.")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                } else if let l = m.lift {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l.days == 0 ? "Reklam \(l.start) başladı, henüz tam gün yok (bugünle tahmin, güvenilmez)."
                             : "Reklam \(l.start) başladı · \(l.days) tam gün" + (l.reliable ? "" : " · 7 günden az, sayılar oynak"))
                            .font(.system(size: 10)).foregroundStyle(l.reliable ? Theme.faint : Theme.warn)
                        HStack {
                            cell("Kurulum / gün", l.installsPerDay.map { String(format: "%.0f → %.0f", $0.before, $0.after) } ?? "–")
                            cell("Ek kurulum", l.extraInstalls.map { String(format: "%+.0f", $0) } ?? "–", (l.extraInstalls ?? 0) > 0 ? Theme.good : .white)
                            cell("Ek kurulum başı", (l.extraInstalls ?? 0) > 0 ? usd2(l.spend / l.extraInstalls!) : "–", money: true)
                        }
                        HStack {
                            cell("Deneme / gün", String(format: "%.1f → %.1f", l.trialsPerDay.before, l.trialsPerDay.after))
                            cell("Abone / gün", String(format: "%.1f → %.1f", l.subsPerDay.before, l.subsPerDay.after))
                            cell("Gelir / gün", "\(usd2(l.revenuePerDay.before)) → \(usd2(l.revenuePerDay.after))", money: true)
                        }
                        HStack {
                            cell("Ek deneme", String(format: "%+.0f", l.extraTrials), l.extraTrials > 0 ? Theme.good : .white)
                            cell("Ek deneme başı", usd2(l.costPerExtraTrial), money: true)
                            cell("Ek gelir", usd2(l.extraRevenue), money: true)
                            cell("ROAS (önce/sonra)", l.roas.map { String(format: "%.2fx", $0) } ?? "–", (l.roas ?? 0) >= 1 ? Theme.good : .white, money: true)
                        }
                        Text("Taban: reklamdan önceki 14 günün ortanca günü (tek günlük sıçramalar bozmaz). Kaynak RevenueCat, iPhone takip izninden bağımsız. Deneme 3 gün sonra ücretliye döndüğü için gelir birkaç gün geriden gelir.")
                            .font(.system(size: 10)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Reklam harcaması başlayınca burada önce/sonra kıyası görünür.").font(.system(size: 11)).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    private var adsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            head("Reklamlar · 30 gün", "rectangle.stack")
            card {
                if (m.ads ?? []).isEmpty {
                    Text("Reklam verisi bir sonraki güncellemede gelir (15 dakikada bir).")
                        .font(.system(size: 11)).foregroundStyle(Theme.dim)
                } else {
                    VStack(spacing: 10) {
                        ForEach(m.ads ?? []) { a in
                            let st = Self.status(a.effective)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .top, spacing: 8) {
                                    Circle().fill(st.1).frame(width: 7, height: 7).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(a.name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                        Text(a.campaign).font(.system(size: 10)).foregroundStyle(Theme.faint).lineLimit(1)
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text("\(Fmt.num(a.installs)) kurulum").font(.system(size: 12, weight: .semibold, design: .rounded))
                                        Text(a.cpi.map { "\(usd2($0)) / kurulum" } ?? "kurulum yok").font(.system(size: 10)).foregroundStyle(Theme.faint).moneyBlur()
                                    }
                                }
                                Text("\(usd2(a.spend)) · \(Fmt.num(a.impressions)) gösterim · \(Fmt.num(a.clicks)) tık · CTR \(a.ctr.map { String(format: "%%%.1f", $0) } ?? "–") · bugün \(usd2(a.spendToday)), \(Fmt.num(a.installsToday)) kurulum")
                                    .font(.system(size: 10)).foregroundStyle(Theme.dim).moneyBlur()
                                    .padding(.leading, 15).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    static func status(_ s: String) -> (String, Color) {
        switch s {
        case "ACTIVE": return ("Aktif", Theme.good)
        case "PAUSED", "CAMPAIGN_PAUSED", "ADSET_PAUSED": return ("Duraklatıldı", Theme.warn)
        case "PENDING_REVIEW", "IN_PROCESS": return ("İncelemede", Theme.warn)
        case "DISAPPROVED": return ("Reddedildi", Theme.bad)
        case "WITH_ISSUES": return ("Sorunlu", Theme.bad)
        case "ARCHIVED", "DELETED": return ("Arşivde", Theme.faint)
        default: return (s.capitalized, Theme.dim)
        }
    }
}

struct AdSpendStrip: View {
    let spend: Double
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "megaphone.fill").font(.system(size: 11)).foregroundStyle(.blue)
                Text("REKLAM HARCAMASI · BUGÜN").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Theme.dim)
                Spacer()
                Text(usd2(spend)).font(.system(size: 12, weight: .semibold)).monospacedDigit().moneyBlur()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hover ? 0.10 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

enum DetailNav { static var tab: Int? }
