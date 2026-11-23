#if PULSE_DEV
import AppKit
import Foundation

@MainActor
enum SelfTest {
    static var input: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--selftest"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    private static var fails = 0
    private static func check(_ ok: Bool, _ name: String, _ detail: String = "") {
        print(ok ? "GEÇTİ " : "KALDI ", name, detail.isEmpty ? "" : "· \(detail)")
        if !ok { fails += 1 }
    }

    static func run(store: Store) async {
        guard let path = input, let d = FileManager.default.contents(atPath: path),
              let cfg = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { print("KALDI girdi okunamadı"); exit(2) }
        _ = await Engine.shared.ready()
        check(Engine.shared.base != nil, "motor başladı")
        guard Engine.shared.base != nil else { print("SONUÇ: motor başlamadı"); fflush(stdout); exit(1) }

        let show = CommandLine.arguments.contains("--show")
        let m = SetupModel(manage: false)
        if show { SetupWindow.shared.show(model: m) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        func step(_ s: SetupModel.Step, _ wait: Double = 2.5) async {
            m.step = s
            if show { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        await step(.welcome, 3)
        await step(.apple)

        m.p8 = "bozuk"; m.keyId = "X"; m.issuerId = "Y"
        await m.connectApple()
        check(m.error != nil && !m.appleConnected, "Apple yanlış anahtarı reddediyor", m.error ?? "")
        m.p8 = cfg["p8"] ?? ""; m.keyId = cfg["keyId"] ?? ""; m.issuerId = cfg["issuerId"] ?? ""; m.vendor = cfg["vendor"] ?? ""
        await m.connectApple()
        check(m.appleConnected && !m.appleApps.isEmpty, "Apple bağlandı", "\(m.appleApps.count) uygulama, satıcı notu: \(m.vendorNote ?? "yok")")
        check(Secrets.load()["ASC_KEY_ID"] == m.keyId, "Apple anahtarı saklandı")

        if show { try? await Task.sleep(nanoseconds: 2_500_000_000) }

        await step(.play, 1.5)
        m.saJSON = cfg["sa"] ?? ""; m.console = cfg["console"] ?? ""
        await m.connectPlay()
        check(m.playConnected && !m.playApps.isEmpty, "Play bağlandı", "\(m.playApps.count) paket")

        if show { try? await Task.sleep(nanoseconds: 2_500_000_000) }

        await m.loadCatalog()
        await step(.apps, 3)
        let merged = m.drafts.filter { $0.ascId != nil && $0.playPackage != nil }.count
        check(!m.drafts.isEmpty, "ürün listesi geldi", "\(m.drafts.count) ürün, \(merged) tanesi iki mağazada birleşti")
        for i in m.drafts.indices { m.drafts[i].include = i < 3 }
        let saved = await m.saveApps()
        check(saved && m.drafts.prefix(3).allSatisfy { $0.appId != nil }, "seçim kaydedildi")

        await step(.extras, 1)
        m.focus = "meta"

        if let t = cfg["metaToken"] {
            m.metaToken = t
            await m.connectMeta()
            check(m.metaConnected && !m.metaAccounts.isEmpty, "Meta bağlandı", "\(m.metaAccounts.count) hesap")
            if let acc = m.metaAccounts.first?.id, let i = m.drafts.firstIndex(where: \.include) { m.drafts[i].metaAccount = acc }
            _ = await m.saveApps()
        }

        if show { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        m.focus = "ai"

        m.aiProvider = "openai"; m.aiKey = "sk-yanlis"
        await m.connectAI()
        check(m.error != nil && !m.aiConnected, "AI yanlış anahtarı reddediyor", m.error ?? "")
        if show { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        m.error = nil
        m.focus = "webhook"

        m.hookURL = "http://127.0.0.1:\(m.hookPort)"
        await m.testHook()
        check(m.hookOK && !m.hookSecret.isEmpty, "webhook açıldı ve kendine ulaştı", m.error ?? "")
        if show { try? await Task.sleep(nanoseconds: 2_500_000_000) }
        await m.disableHook()
        check(m.hookSecret.isEmpty && Secrets.load()["WEBHOOK_SECRET"] == nil, "webhook kapandı")

        await m.finish()
        check(m.step == .done, "kurulum bitti")
        if show { try? await Task.sleep(nanoseconds: 3_000_000_000) }

        for _ in 0..<90 {
            let st = await Engine.shared.json("/v1/local/state")
            if st["syncing"] as? Bool == false { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        await store.refresh()
        check(store.snap != nil && store.error == nil, "panel verisi okundu", store.error ?? "")
        let cards = store.snap?.cards ?? []
        check(cards.count == 3, "panelde 3 ürün kartı", cards.map(\.name).joined(separator: ", "))
        let t = store.snap?.totals
        print("      üst kutular: kurulum(son)=\(t?.installsLast.map { String($0) } ?? "-") gelir7g=\(t?.revenue7d.map { String($0) } ?? "-") puan=\(t?.ratingAvg.map { String($0) } ?? "-") reklam=\(t?.adSpendToday.map { String($0) } ?? "-")")
        for c in cards {
            let det = await store.detail(c.id)
            check(det != nil, "detay çözüldü: \(c.name)", c.sources.map { "\($0.source)=\($0.status)" }.joined(separator: " "))
        }

        for k in ["users", "web", "installs", "net", "mrr", "devices"] {
            let r = await store.metric(k, days: 30)
            let filled = r?.series.filter { !$0.byApp.isEmpty }.count ?? 0
            check(r != nil, "üst kutu ayrıntısı: \(MetricInfo.all[k]?.title ?? k)", "\(filled) günde veri")
        }
        let h = await store.todayHistory(days: 30)
        check(h != nil, "Bugün kutusu > günlük geçmiş", "\(h?.days.count ?? 0) gün")
        for n in [1, 7, 30] { check(await store.sources(days: n) != nil, "Nereden geliyorlar (\(n) gün)") }
        check(!(store.snap?.reviews ?? []).isEmpty, "Puan kutusu > yorumlar", "\(store.snap?.reviews.count ?? 0) yorum")
        await store.manualRefresh()
        check(store.error == nil, "Yenile düğmesi")
        await store.ack(nil)
        let open = store.snap?.alerts.filter { $0.acked == 0 }.count ?? -1
        check(open == 0, "Uyarıları okundu yap")

        for c in cards {
            guard let det = await store.detail(c.id) else { continue }
            let tabs = [det.diagnosis != nil ? "Teşhis" : nil, det.series.isEmpty ? nil : "Rakamlar(\(det.series.count) seri)",
                        (det.reviews.isEmpty && det.acquisition == nil) ? nil : "Kullanıcılar", "Geçmiş", det.meta != nil ? "Reklam" : nil].compactMap { $0 }
            check(det.diagnosis != nil && !det.series.isEmpty, "detay sekmeleri dolu: \(c.name)", tabs.joined(separator: ", "))
        }
        if cfg["metaToken"] != nil {
            var anyMeta = false
            for c in cards { if await store.detail(c.id)?.meta != nil { anyMeta = true } }
            check(anyMeta, "Meta bağlanınca Reklam sekmesi geliyor")
        }
        print(fails == 0 ? "SONUÇ: hepsi geçti" : "SONUÇ: \(fails) kontrol kaldı")
        fflush(stdout)
        if show {
            m.onClose?(true)
            return
        }
        exit(fails == 0 ? 0 : 1)
    }
}

#endif
