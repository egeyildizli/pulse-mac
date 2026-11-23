import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SetupWindow {
    static let shared = SetupWindow()
    private var window: NSWindow?
    private var model: SetupModel?
    var onFinish: (() -> Void)?

    func show(model: SetupModel) {
        self.model = model
        model.onClose = { [weak self] openPanel in
            self?.window?.close()
            self?.window = nil
            if openPanel { self?.onFinish?() }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: SetupView(model: model))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(manage: Bool, focus: String? = nil) {
        if let w = window {
            if let focus, let m = model { m.focus = focus; m.step = .extras }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let model = SetupModel(manage: manage)
        if let focus { model.focus = focus; model.step = .extras }
        self.model = model
        model.onClose = { [weak self] openPanel in
            self?.window?.close()
            self?.window = nil
            if openPanel { self?.onFinish?() }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: SetupView(model: model))
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil; self?.model = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct DraftApp: Identifiable, Hashable {
    var id: String
    var appId: String?
    var name: String
    var kind: String
    var ascId: String?
    var playPackage: String?
    var bundleId: String?
    var icon: URL?
    var include = true
    var rcProject: String?
    var rcKey: String?
    var stripeKey: String?
    var site: String?
    var ga4Property: String?
    var metaAccount: String?

    var payload: [String: Any] {
        var d: [String: Any] = ["name": name, "kind": kind]
        if let appId { d["id"] = appId }
        if let ascId { d["ascId"] = ascId }
        if let playPackage { d["playPackage"] = playPackage }
        if let bundleId { d["bundleId"] = bundleId }
        if let rcProject, let rcKey { d["rc"] = ["project": rcProject, "key": rcKey] }
        if let stripeKey { d["stripeKey"] = stripeKey }
        if let site, !site.isEmpty { d["site"] = site }
        if let ga4Property, !ga4Property.isEmpty { d["ga4Property"] = ga4Property }
        if let metaAccount, !metaAccount.isEmpty { d["metaAccount"] = metaAccount }
        return d
    }
}

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, apple, play, apps, extras, done }

    let manage: Bool
    var onClose: ((Bool) -> Void)?
    @Published var step: Step
    @Published var busy = false
    @Published var error: String?

    @Published var p8 = ""
    @Published var p8Name = ""
    @Published var keyId = ""
    @Published var issuerId = ""
    @Published var vendor = ""
    @Published var appleApps: [[String: Any]] = []
    @Published var appleConnected = false
    @Published var vendorNote: String?

    @Published var saJSON = ""
    @Published var saEmail = ""
    @Published var console = ""
    @Published var playApps: [String] = []
    @Published var playConnected = false
    @Published var playPending = false

    @Published var drafts: [DraftApp] = []

    @Published var rcKey = ""
    @Published var rcNote: String?
    @Published var stripeKey = ""
    @Published var stripeTarget = ""
    @Published var stripeNote: String?
    @Published var cfToken = ""
    @Published var zones: [String] = []
    @Published var cfConnected = false
    @Published var metaToken = ""
    @Published var metaAccounts: [(id: String, name: String)] = []
    @Published var metaConnected = false
    @Published var gaProps: [(id: String, name: String)] = []
    @Published var gaEmail = ""
    @Published var aiKey = ""
    @Published var aiConnected = false
    @Published var aiProvider = "anthropic"
    @Published var aiModel = ""
    @Published var aiURL = ""
    @Published var aiLabel = ""
    @Published var focus: String?

    @Published var hookSecret = ""
    @Published var hookURL = ""
    @Published var hookPort = 47870
    @Published var hookOK = false

    init(manage: Bool) {
        self.manage = manage
        step = manage ? .apps : .welcome

        let args = devArgs
        if let i = args.firstIndex(of: "--setup-step"), i + 1 < args.count, let n = Int(args[i + 1]), let s = Step(rawValue: n) { step = s }
        Task {
            await loadState()
            if step == .apps && drafts.isEmpty { await loadCatalog() }
        }
    }

    private var engine: Engine { Engine.shared }

    func loadState() async {
        let st = await engine.json("/v1/local/state")
        let c = st["connected"] as? [String: Any] ?? [:]
        appleConnected = c["apple"] as? Bool ?? false
        playConnected = c["play"] as? Bool ?? false
        cfConnected = c["cloudflare"] as? Bool ?? false
        metaConnected = c["meta"] as? Bool ?? false
        if let ai = c["ai"] as? [String: Any] {
            aiConnected = true
            aiProvider = ai["provider"] as? String ?? "anthropic"
            aiLabel = "\(Self.providerName(aiProvider)) · \(ai["model"] as? String ?? "")"
        }
        if let h = c["webhook"] as? [String: Any] {
            hookSecret = Secrets.load()["WEBHOOK_SECRET"] ?? ""
            hookURL = h["url"] as? String ?? ""
            hookPort = h["port"] as? Int ?? 47870
        }
        saEmail = c["playEmail"] as? String ?? ""
        if manage { await loadCatalog(existing: st["apps"] as? [[String: Any]] ?? []) }
    }

    func loadP8(_ url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { error = "Dosya okunamadı."; return }
        p8 = s
        p8Name = url.lastPathComponent

        if let r = url.lastPathComponent.range(of: #"AuthKey_([A-Z0-9]+)\.p8"#, options: .regularExpression) {
            keyId = String(url.lastPathComponent[r]).replacingOccurrences(of: "AuthKey_", with: "").replacingOccurrences(of: ".p8", with: "")
        }
        error = nil
    }

    func connectApple() async {
        busy = true; error = nil; defer { busy = false }
        let r = await engine.json("/v1/local/apple/check", method: "POST",
                                  body: ["keyId": keyId, "issuerId": issuerId, "p8": p8, "vendor": vendor])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        appleApps = r["apps"] as? [[String: Any]] ?? []
        appleConnected = true
        let vOk = r["vendorOk"] as? Bool
        vendorNote = vendor.isEmpty ? "Satıcı numarası girilmedi: indirme ve gelir sayıları gelmez, yorumlar ve kullanım verisi gelir." : (vOk == false ? "Satıcı numarası doğrulanamadı; satış raporu atlandı. Sonra Bağlantılar'dan düzeltebilirsin." : nil)
        Secrets.merge(["ASC_KEY_ID": keyId.trimmed, "ASC_ISSUER_ID": issuerId.trimmed, "ASC_P8": p8,
                       "ASC_VENDOR": vOk == true ? vendor.trimmed : nil])
    }

    func loadSA(_ url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let email = j["client_email"] as? String else {
            error = "Bu bir servis hesabı anahtar dosyası değil. Google Cloud'da servis hesabının Anahtarlar sekmesinden JSON indir."
            return
        }
        saJSON = s
        saEmail = email
        error = nil
    }

    func connectPlay() async {
        busy = true; error = nil; defer { busy = false }
        let r = await engine.json("/v1/local/play/check", method: "POST", body: ["sa": saJSON, "console": console])
        if r["ok"] as? Bool == true {
            playApps = (r["apps"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            playConnected = true
            playPending = false
            Secrets.merge(["GOOGLE_SA": saJSON, "PLAY_BUCKET": r["bucket"] as? String])
            return
        }
        error = r["error"] as? String
        if r["pending"] as? Bool == true {
            playPending = true
            Secrets.merge(["GOOGLE_SA": saJSON, "PLAY_BUCKET": r["bucket"] as? String])
        }
    }

    func loadCatalog(existing: [[String: Any]]? = nil) async {
        busy = true; defer { busy = false }
        var ex = existing
        if ex == nil { ex = (await engine.json("/v1/local/state"))["apps"] as? [[String: Any]] }
        let cat = await engine.json("/v1/local/catalog")
        let items = cat["items"] as? [[String: Any]] ?? []
        let saved = ex ?? []
        let rcKeys = (Secrets.load()["RC_KEYS"]).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: [String: String]] } ?? [:]
        let stKeys = (Secrets.load()["STRIPE_KEYS"]).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] } ?? [:]
        func savedMatch(_ asc: String?, _ pkg: String?) -> [String: Any]? {
            saved.first { s in (asc != nil && s["ascId"] as? String == asc) || (pkg != nil && s["playPackage"] as? String == pkg) }
        }
        var out: [DraftApp] = items.map { it in
            let asc = it["ascId"] as? String, pkg = it["playPackage"] as? String
            let s = savedMatch(asc, pkg)
            let sid = s?["id"] as? String
            let lowered = ((it["name"] as? String) ?? "").lowercased()
            var d = DraftApp(id: (it["key"] as? String) ?? UUID().uuidString, appId: sid,
                             name: (s?["name"] as? String) ?? Self.shortName(it["name"] as? String ?? ""),
                             kind: (s?["kind"] as? String) ?? (lowered.contains("game") || lowered.contains("puzzle") ? "game" : "app"),
                             ascId: asc, playPackage: pkg, bundleId: it["bundleId"] as? String,
                             icon: (it["icon"] as? String).flatMap(URL.init(string:)),
                             include: saved.isEmpty ? true : s != nil)
            if let sid, let rc = rcKeys[sid] { d.rcProject = rc["project"]; d.rcKey = rc["key"] }
            if let sid { d.stripeKey = stKeys[sid] }
            d.site = s?["cfZone"] as? String
            d.ga4Property = s?["ga4Property"] as? String
            d.metaAccount = s?["metaAccount"] as? String
            return d
        }

        for s in saved where s["ascId"] == nil && s["playPackage"] == nil {
            guard let sid = s["id"] as? String else { continue }
            var d = DraftApp(id: "site:\(sid)", appId: sid, name: s["name"] as? String ?? sid, kind: "web", site: s["cfZone"] as? String)
            d.stripeKey = stKeys[sid]
            out.append(d)
        }
        drafts = out
    }

    static func shortName(_ s: String) -> String {
        let cut = s.split(whereSeparator: { ":–-|".contains($0) }).first.map(String.init) ?? s
        return cut.trimmingCharacters(in: .whitespaces).isEmpty ? s : cut.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    func saveApps() async -> Bool {
        busy = true; error = nil; defer { busy = false }
        let list = drafts.filter(\.include).map(\.payload)
        let r = await engine.json("/v1/local/apps", method: "POST", body: ["apps": list])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String ?? "Kaydedilemedi."; return false }

        let saved = r["apps"] as? [[String: Any]] ?? []
        for i in drafts.indices where drafts[i].include {
            if let m = saved.first(where: { s in
                (drafts[i].ascId != nil && s["ascId"] as? String == drafts[i].ascId) ||
                (drafts[i].playPackage != nil && s["playPackage"] as? String == drafts[i].playPackage) ||
                (drafts[i].ascId == nil && drafts[i].playPackage == nil && s["cfZone"] as? String == drafts[i].site)
            }) { drafts[i].appId = m["id"] as? String }
        }
        let sec = r["secrets"] as? [String: String] ?? [:]
        Secrets.merge(["RC_KEYS": sec["RC_KEYS"], "STRIPE_KEYS": sec["STRIPE_KEYS"]])
        return true
    }

    func connectRC() async {
        busy = true; error = nil; rcNote = nil; defer { busy = false }
        let key = rcKey.trimmed
        let r = await engine.json("/v1/local/revenuecat/check", method: "POST", body: ["key": key])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        var matched: [String] = []
        for p in r["projects"] as? [[String: Any]] ?? [] {
            let bundles = Set(p["bundles"] as? [String] ?? [])
            let proj = p["project"] as? String
            for i in drafts.indices where drafts[i].include {
                let ids = [drafts[i].bundleId, drafts[i].playPackage].compactMap { $0 }
                if ids.contains(where: bundles.contains) {
                    drafts[i].rcProject = proj
                    drafts[i].rcKey = key
                    matched.append(drafts[i].name)
                }
            }
        }
        if matched.isEmpty {
            error = "Anahtar çalışıyor ama bu projedeki uygulamalar seçtiğin ürünlerle eşleşmedi (paket adları farklı)."
            return
        }
        rcKey = ""
        rcNote = "Bağlandı: \(matched.joined(separator: ", ")). Başka bir RevenueCat projen varsa onun anahtarını da ekleyebilirsin."
        await saveApps()
    }

    func connectStripe() async {
        busy = true; error = nil; stripeNote = nil; defer { busy = false }
        guard let i = drafts.firstIndex(where: { $0.id == stripeTarget }) else { error = "Stripe'ı hangi ürüne bağlayacağını seç."; return }
        let r = await engine.json("/v1/local/stripe/check", method: "POST", body: ["key": stripeKey.trimmed])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        drafts[i].stripeKey = stripeKey.trimmed
        stripeKey = ""
        stripeNote = "Stripe, \(drafts[i].name) ürününe bağlandı."
        await saveApps()
    }

    func connectCF() async {
        busy = true; error = nil; defer { busy = false }
        let r = await engine.json("/v1/local/cloudflare/check", method: "POST", body: ["token": cfToken.trimmed])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        zones = r["zones"] as? [String] ?? []
        cfConnected = true
        Secrets.merge(["CF_API_TOKEN": cfToken.trimmed, "CF_ACCOUNT_ID": r["accountId"] as? String])
        cfToken = ""

        for z in zones {
            let root = z.split(separator: ".").first.map(String.init)?.lowercased() ?? z
            if let i = drafts.firstIndex(where: { $0.include && $0.site == nil && $0.name.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(root) }) {
                drafts[i].site = z
            } else if !drafts.contains(where: { $0.site == z }) {
                drafts.append(DraftApp(id: "site:\(z)", name: z, kind: "web", include: false, site: z))
            }
        }
        await saveApps()
    }

    func connectMeta() async {
        busy = true; error = nil; defer { busy = false }
        let r = await engine.json("/v1/local/meta/check", method: "POST", body: ["token": metaToken.trimmed])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        metaAccounts = (r["accounts"] as? [[String: Any]] ?? []).compactMap { a in
            guard let id = a["id"] as? String else { return nil }
            return (id, "\(a["name"] as? String ?? id)\((a["active"] as? Bool ?? true) ? "" : " (kapalı)")")
        }
        metaConnected = true
        Secrets.merge(["META_TOKEN": metaToken.trimmed])
        metaToken = ""

        if metaAccounts.count == 1, drafts.filter(\.include).count == 1, let i = drafts.firstIndex(where: \.include) { drafts[i].metaAccount = metaAccounts[0].id }
    }

    func loadGA() async {
        busy = true; error = nil; defer { busy = false }
        let r = await engine.json("/v1/local/ga4/check", method: "POST", body: [:])
        gaEmail = r["email"] as? String ?? gaEmail
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        gaProps = (r["properties"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return (id, "\(p["name"] as? String ?? id) · \(p["account"] as? String ?? "")")
        }
    }

    static func providerName(_ p: String) -> String {
        ["anthropic": "Claude", "openai": "ChatGPT", "gemini": "Gemini", "ollama": "Yerel model"][p] ?? p
    }

    func connectAI() async {
        busy = true; error = nil; defer { busy = false }
        let r = await engine.json("/v1/local/ai/check", method: "POST",
                                  body: ["provider": aiProvider, "key": aiKey.trimmed, "model": aiModel.trimmed, "url": aiURL.trimmed])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        let model = r["model"] as? String ?? aiModel
        Secrets.merge(["AI_PROVIDER": aiProvider, "AI_KEY": aiProvider == "ollama" ? nil : aiKey.trimmed, "AI_MODEL": model,
                       "AI_URL": aiProvider == "ollama" ? (aiURL.trimmed.isEmpty ? nil : aiURL.trimmed) : nil, "ANTHROPIC_API_KEY": nil])
        aiKey = ""
        aiConnected = true
        aiLabel = "\(Self.providerName(aiProvider)) · \(model)"
    }

    func removeAI() async {
        _ = await engine.json("/v1/local/ai/remove", method: "POST", body: [:])
        Secrets.merge(["AI_PROVIDER": nil, "AI_KEY": nil, "AI_MODEL": nil, "AI_URL": nil, "ANTHROPIC_API_KEY": nil])
        aiConnected = false
        aiLabel = ""
    }

    func enableHook() async {
        busy = true; error = nil; defer { busy = false }
        let r = await engine.json("/v1/local/webhook/enable", method: "POST", body: ["url": hookURL.trimmed])
        guard r["ok"] as? Bool == true else { error = r["error"] as? String; return }
        hookSecret = r["secret"] as? String ?? ""
        hookPort = r["port"] as? Int ?? hookPort
        if r["listening"] as? Bool == false { error = "Yerel port \(hookPort) açılamadı. Başka bir uygulama kullanıyor olabilir." }
        Secrets.merge(["WEBHOOK_SECRET": hookSecret, "WEBHOOK_URL": hookURL.trimmed.isEmpty ? nil : hookURL.trimmed])
    }

    func testHook() async {
        await enableHook()
        guard error == nil else { return }
        busy = true; defer { busy = false }
        let r = await engine.json("/v1/local/webhook/test", method: "POST", body: [:])
        hookOK = r["ok"] as? Bool == true
        if !hookOK { error = r["error"] as? String }
    }

    func disableHook() async {
        _ = await engine.json("/v1/local/webhook/disable", method: "POST", body: [:])
        Secrets.merge(["WEBHOOK_SECRET": nil, "WEBHOOK_URL": nil])
        hookSecret = ""; hookURL = ""; hookOK = false
    }

    func finish() async {
        if await saveApps() { step = .done }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private enum S {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let card = Color.white.opacity(0.05)
    static let line = Color.white.opacity(0.09)
    static let dim = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.42)
    static let accent = Color(red: 0.31, green: 0.55, blue: 1.0)
    static let ok = Color(red: 0.18, green: 0.83, blue: 0.63)
    static let warn = Color(red: 1.0, green: 0.62, blue: 0.26)
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var height: CGFloat = 620

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(S.line)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .frame(width: 760, height: height)
        .background(S.bg)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(S.accent).frame(width: 9, height: 9)
                Text("PULSE").font(.system(size: 13, weight: .bold)).tracking(2)
            }
            .padding(.bottom, 22).padding(.top, 26)
            ForEach(SetupModel.Step.allCases.filter { $0 != .welcome || !model.manage }, id: \.self) { s in
                let cur = s == model.step
                let past = s.rawValue < model.step.rawValue

                let done = past && (s == .apple ? model.appleConnected : s == .play ? (model.playConnected || model.playPending) : true)
                Button { if past || model.manage { model.error = nil; model.step = s } } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(cur ? S.accent : done ? S.ok.opacity(0.25) : Color.white.opacity(0.08)).frame(width: 22, height: 22)
                            if done && !cur { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(S.ok) }
                            else { Text("\(s.rawValue + (model.manage ? 0 : 1))").font(.system(size: 11, weight: .bold)) }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stepTitle(s)).font(.system(size: 13, weight: cur ? .semibold : .regular)).foregroundStyle(cur ? .white : S.dim)
                            if let r = requirement(s) {
                                Text(r).font(.system(size: 10, weight: .medium)).foregroundStyle(r.hasPrefix("Zorunlu") ? S.warn.opacity(0.9) : S.faint)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(cur ? Color.white.opacity(0.06) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(S.ok)
                Text("Anahtarların bu Mac'in Keychain'inde durur. Veriler yalnız bağladığın servislerden bu Mac'e gelir; yayıncıya hiçbir şey gitmez.")
                    .font(.system(size: 10.5)).foregroundStyle(S.faint).fixedSize(horizontal: false, vertical: true)
            }
            Button("Gizlilik ayrıntıları") { AboutWindow.shared.show() }
                .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(S.accent)
                .padding(.leading, 16).padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
        .frame(width: 200)
        .background(Color.black.opacity(0.25))
    }

    private func requirement(_ s: SetupModel.Step) -> String? {
        switch s {
        case .apple, .play: "Zorunlu · en az biri"
        case .apps: "Zorunlu"
        case .extras: "İsteğe bağlı"
        default: nil
        }
    }

    private func stepTitle(_ s: SetupModel.Step) -> String {
        switch s {
        case .welcome: "Hoş geldin"
        case .apple: "App Store"
        case .play: "Google Play"
        case .apps: "Ürünlerin"
        case .extras: "Daha fazlası"
        case .done: "Hazır"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .apple: AppleStep(model: model)
        case .play: PlayStep(model: model)
        case .apps: AppsStep(model: model)
        case .extras: ExtrasStep(model: model)
        case .done: DoneStep()
        }
        if let e = model.error {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(S.warn)
                Text(e).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(S.warn.opacity(0.12)))
        }
    }

    private var footer: some View {
        HStack {
            if model.step != .welcome && model.step != .done && !(model.manage && model.step == .apps) {
                Button("Geri") { model.error = nil; model.step = SetupModel.Step(rawValue: model.step.rawValue - 1) ?? .welcome }
                    .buttonStyle(GhostButton())
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small).padding(.trailing, 8) }
            switch model.step {
            case .welcome:
                Button("Başla") { model.step = .apple }.buttonStyle(PrimaryButton())
            case .apple:
                if !model.appleConnected { Button("Bu adımı atla") { model.error = nil; model.step = .play }.buttonStyle(GhostButton()) }
                Button(model.appleConnected ? "Devam" : "Bağla") {
                    if model.appleConnected { model.error = nil; model.step = .play } else { Task { await model.connectApple() } }
                }
                .buttonStyle(PrimaryButton()).disabled(model.busy || (!model.appleConnected && (model.p8.isEmpty || model.keyId.isEmpty || model.issuerId.isEmpty)))
            case .play:
                if !model.playConnected { Button("Bu adımı atla") { model.error = nil; Task { await model.loadCatalog(); model.step = .apps } }.buttonStyle(GhostButton()) }
                Button(model.playConnected ? "Devam" : "Bağla") {
                    if model.playConnected { model.error = nil; Task { await model.loadCatalog(); model.step = .apps } } else { Task { await model.connectPlay() } }
                }
                .buttonStyle(PrimaryButton()).disabled(model.busy || (!model.playConnected && (model.saJSON.isEmpty || model.console.isEmpty)))
            case .apps:
                Button("Kaydet ve devam") { Task { if await model.saveApps() { model.step = .extras } } }
                    .buttonStyle(PrimaryButton()).disabled(model.busy || !model.drafts.contains(where: \.include))
            case .extras:
                Text("Bağlamadıklarını sonra eklersin").font(.system(size: 11.5)).foregroundStyle(S.faint).padding(.trailing, 6)
                Button("Bitir") { Task { await model.finish() } }.buttonStyle(PrimaryButton()).disabled(model.busy)
            case .done:
                Button("Paneli aç") { model.onClose?(true) }.buttonStyle(PrimaryButton())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .overlay(Rectangle().fill(S.line).frame(height: 1), alignment: .top)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tüm uygulamaların tek panelde").font(.system(size: 26, weight: .bold))
            Text("Pulse, App Store ve Google Play hesaplarına bağlanır. İndirmeleri, geliri, yorumları ve sorunları ekranının sağ kenarında, her an bir bakışta gösterir.")
                .font(.system(size: 14)).foregroundStyle(S.dim).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Bullet(icon: "applelogo", title: "App Store Connect", text: "İndirme, satış, yorum ve kullanım istatistikleri.")
                Bullet(icon: "play.fill", title: "Google Play", text: "Kurulum, kaldırma, aktif cihaz ve yorumlar.")
                Bullet(icon: "plus.circle", title: "İstersen daha fazlası", text: "RevenueCat, Stripe ve web siten için ziyaretçi sayısı.")
                Bullet(icon: "lock.shield", title: "Tamamen senin Mac'inde", text: UpdateChecker.official
                    ? "Anahtarlar Keychain'de durur, veriler bu bilgisayarda saklanır. Pulse yalnız senin bağladığın servislerle (Apple, Google, RevenueCat...) konuşur. Pulse'ın verilerini tutan bir sunucu yok; bağladığın hesaplardan hiçbir veri bize gelmez. Yalnız günde bir kez yeni sürüm olup olmadığına bakılır."
                    : "Anahtarlar Keychain'de durur, veriler bu bilgisayarda saklanır. Pulse yalnız senin bağladığın servislerle (Apple, Google, RevenueCat...) konuşur. Pulse'ın verilerini tutan bir sunucu yok; bağladığın hesaplardan hiçbir veri bize gelmez.")
            }
            .padding(.top, 6)
            Text("Kurulum yaklaşık 10 dakika sürer. Her adımda ne yapacağın tek tek gösterilir.")
                .font(.system(size: 12.5)).foregroundStyle(S.faint).padding(.top, 4)
        }
    }
}

private struct AppleStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "App Store Connect'i bağla", sub: "Apple, okuma için bir API anahtarı istiyor. Bir kez oluşturman yeterli.")
            RequiredNote()
            if model.appleConnected && !model.appleApps.isEmpty {
                Connected(text: "\(model.appleApps.count) uygulama bulundu")
                AppChips(names: model.appleApps.compactMap { $0["name"] as? String }, icons: model.appleApps.map { ($0["icon"] as? String).flatMap(URL.init(string:)) })
                if let n = model.vendorNote { SetupNote(text: n) }
            } else if model.appleConnected {
                Connected(text: "Apple hesabı bağlı. Yeni anahtar girmek istersen aşağıyı doldur.")
            }
            if !model.appleConnected || model.appleApps.isEmpty {
                Instruction(n: 1, text: "App Store Connect'te Kullanıcılar ve Erişim > Entegrasyonlar > App Store Connect API sayfasını aç.",
                            link: ("Sayfayı aç", "https://appstoreconnect.apple.com/access/integrations/api"))
                Instruction(n: 2, text: "Ekip Anahtarları (Team Keys) sekmesinde + ile yeni anahtar oluştur ve erişim seç. Admin: her şey gelir (kullanım istatistiklerini açmak için Apple bunu istiyor). Daha dar yetki istersen Finance ya da Sales seç; indirme ve gelir yine gelir, kullanım istatistikleri ve bazı yorumlar gelmeyebilir. Pulse anahtarla yalnız okur; anahtar yalnız bu Mac'te durur.")
                Instruction(n: 3, text: "Anahtarın yanındaki İndir'e bas. Dosya (AuthKey_XXXX.p8) yalnız bir kez inebilir, kaybetme.")
                Instruction(n: 4, text: "Dosyayı aşağıya sürükle. Key ID dosya adından otomatik dolar. Issuer ID aynı sayfanın üstünde yazar.")
                FileDrop(title: model.p8Name.isEmpty ? "AuthKey_XXXX.p8 dosyasını buraya sürükle" : model.p8Name, done: !model.p8.isEmpty,
                         types: ["p8"]) { model.loadP8($0) }
                HStack(spacing: 10) {
                    Field(label: "Key ID", text: $model.keyId, placeholder: "ABC123DEFG")
                    Field(label: "Issuer ID", text: $model.issuerId, placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")
                }
                Field(label: "Satıcı numarası (önerilir)", text: $model.vendor, placeholder: "8xxxxxxx",
                      hint: "İndirme ve gelir için gerekli. Ödemeler ve Finansal Raporlar sayfasında, sol üstte, şirket adının yanında yazar.",
                      link: ("Sayfayı aç", "https://appstoreconnect.apple.com/itc/payments_and_financial_reports"))
            }
        }
    }
}

private struct PlayStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Google Play'i bağla", sub: "Google'da kendi hesabına ait bir okuma anahtarı (servis hesabı) oluşturacaksın. Bir kerelik, yaklaşık 5 dakika.")
            RequiredNote()
            if model.playConnected {
                Connected(text: model.playApps.isEmpty ? "Google Play bağlı." : "\(model.playApps.count) uygulama bulundu")
                if !model.playApps.isEmpty { AppChips(names: model.playApps, icons: model.playApps.map { _ in nil }) }
            } else {
                Instruction(n: 1, text: "Google Cloud'da yeni bir proje oluştur (adı önemli değil, örneğin \"pulse\").",
                            link: ("Proje oluştur", "https://console.cloud.google.com/projectcreate"))
                Instruction(n: 2, text: "Bu projede iki servisi aç. Her linkte Etkinleştir'e bas.",
                            link: ("Play Android Developer API", "https://console.cloud.google.com/apis/library/androidpublisher.googleapis.com"),
                            link2: ("Play Reporting API", "https://console.cloud.google.com/apis/library/playdeveloperreporting.googleapis.com"))
                Instruction(n: 3, text: "Servis hesabı oluştur. Rol vermene gerek yok. Sonra hesabın Anahtarlar sekmesinde Anahtar ekle > JSON seç ve inen dosyayı aşağıya sürükle.",
                            link: ("Servis hesabı oluştur", "https://console.cloud.google.com/iam-admin/serviceaccounts/create"))
                FileDrop(title: model.saEmail.isEmpty ? "Servis hesabı JSON dosyasını buraya sürükle" : "Anahtar yüklendi", done: !model.saJSON.isEmpty, types: ["json"]) { model.loadSA($0) }
                if !model.saEmail.isEmpty {
                    Instruction(n: 4, text: "Play Console'da Kullanıcılar ve izinler > Yeni kullanıcı davet et. Şu e-postayı yapıştır, Hesap izinleri'nde \"Uygulama bilgilerini görüntüleme ve toplu rapor indirme\" ile \"Finansal verileri görüntüleme\"yi işaretle.",
                                link: ("Play Console'u aç", "https://play.google.com/console/users-and-permissions"))
                    CopyRow(text: model.saEmail)
                    Instruction(n: 5, text: "Play Console'un herhangi bir sayfasındayken tarayıcının adres çubuğundaki adresi kopyala ve buraya yapıştır. Pulse rapor deposunu bu adresten bulur.")
                    Field(label: "Play Console adresi", text: $model.console, placeholder: "https://play.google.com/console/u/0/developers/…")
                }
                if model.playPending {
                    SetupNote(text: "Anahtar kaydedildi. Google izni tanıyınca (24 saate kadar) Play verisi kendiliğinden gelmeye başlar. İstersen şimdi devam et.")
                }
            }
        }
    }
}

private struct AppsStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "Hangi ürünleri izleyelim?", sub: "Aynı paket adına sahip App Store ve Play uygulamaları tek ürün olarak birleştirildi. Adı kısaltabilir, oyun olanları işaretleyebilirsin.")
            if model.drafts.isEmpty && !model.busy {
                SetupNote(text: "Devam etmek için App Store ya da Google Play'den en az birini bağlamalısın. Geri dönüp birini bağla; ikisi de olur.")
            }
            VStack(spacing: 0) {
                ForEach($model.drafts) { $d in
                    HStack(spacing: 12) {
                        Toggle("", isOn: $d.include).toggleStyle(.checkbox).labelsHidden()
                        SetupAppIcon(url: d.icon, kind: d.kind)
                        VStack(alignment: .leading, spacing: 3) {
                            TextField("Ad", text: $d.name).textFieldStyle(.plain).font(.system(size: 13.5, weight: .semibold))
                            HStack(spacing: 6) {
                                if d.ascId != nil { Badge(text: "App Store") }
                                if d.playPackage != nil { Badge(text: "Google Play") }
                                if let s = d.site { Badge(text: s) }
                                if d.rcKey != nil { Badge(text: "RevenueCat") }
                                if d.stripeKey != nil { Badge(text: "Stripe") }
                            }
                        }
                        Spacer()
                        if d.kind != "web" {
                            Picker("", selection: $d.kind) {
                                Text("Uygulama").tag("app")
                                Text("Oyun").tag("game")
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                        } else {
                            Text("Site").font(.system(size: 12)).foregroundStyle(S.faint)
                        }
                    }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .opacity(d.include ? 1 : 0.5)
                    Divider().overlay(S.line)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(S.card))
        }
    }
}

private struct ExtrasStep: View {
    @ObservedObject var model: SetupModel
    private var f: String? { model.focus }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle(title: "İstersen daha fazlasını bağla", sub: "Bu adımdaki her şey isteğe bağlı. Hiçbirini bağlamadan Bitir diyebilirsin; panel App Store ve Google Play verisiyle çalışır. Sonradan panelin dişli simgesinden ya da boş kutulardaki Bağla düğmelerinden buraya dönersin.")

            GroupLabel(text: "ÖNERİLEN", sub: "En çok fark yaratanlar")
            ExtraCard(id: "revenuecat", focus: f, icon: "creditcard.and.123", title: "RevenueCat", badge: "İsteğe bağlı",
                      sub: "Anlık abone, deneme, MRR ve gelir. Mağaza raporlarından çok daha hızlı.",
                      connected: model.drafts.filter { $0.rcKey != nil }.map(\.name)) {
                Instruction(n: 1, text: "RevenueCat'te projeyi aç > Project settings > API keys > + New secret API key. Sürüm v2, izinler: Charts metrics ve Project configuration için Read only.",
                            link: ("RevenueCat'i aç", "https://app.revenuecat.com/"))
                HStack { SecureField("sk_…", text: $model.rcKey).textFieldStyle(DarkField()); Button("Bağla") { Task { await model.connectRC() } }.buttonStyle(PrimaryButton()).disabled(model.rcKey.isEmpty || model.busy) }
                if let n = model.rcNote { SetupNote(text: n) }
            }
            ExtraCard(id: "ga4", focus: f, icon: "chart.xyaxis.line", title: "Google Analytics / Firebase", badge: "İsteğe bağlı",
                      sub: "Günlük ve anlık aktif kullanıcı, en çok kullanılan ekranlar, geri dönüş oranı.",
                      connected: model.drafts.filter { $0.ga4Property != nil }.map(\.name)) {
                Instruction(n: 1, text: "Google Play adımındaki Google Cloud projesinde iki servisi aç.",
                            link: ("Analytics Data API", "https://console.cloud.google.com/apis/library/analyticsdata.googleapis.com"),
                            link2: ("Analytics Admin API", "https://console.cloud.google.com/apis/library/analyticsadmin.googleapis.com"))
                Instruction(n: 2, text: "Google Analytics'te Yönetici > Mülk erişim yönetimi'nden servis hesabı e-postasını Görüntüleyici olarak ekle. Firebase kullanıyorsan mülk Analytics'te zaten var.",
                            link: ("Analytics'i aç", "https://analytics.google.com/analytics/web/#/admin"))
                if !model.gaEmail.isEmpty || !model.saEmail.isEmpty { CopyRow(text: model.gaEmail.isEmpty ? model.saEmail : model.gaEmail) }
                Button("Mülkleri getir") { Task { await model.loadGA() } }.buttonStyle(PrimaryButton()).disabled(model.busy)
                if !model.gaProps.isEmpty {
                    AssignRows(model: model, options: model.gaProps.map { ($0.id, $0.name) }, empty: "Bağlama", key: \.ga4Property, skipWeb: true)
                }
            }

            GroupLabel(text: "İSTEĞE BAĞLI", sub: "Kullanıyorsan")
            ExtraCard(id: "meta", focus: f, icon: "megaphone", title: "Meta reklamları", badge: "İsteğe bağlı",
                      sub: "Facebook/Instagram reklam harcaması, kurulum başı maliyet, reklam bazında sonuçlar. Yalnız okur.",
                      connected: model.drafts.filter { $0.metaAccount != nil }.map(\.name)) {
                if model.metaAccounts.isEmpty {
                    Instruction(n: 1, text: "Meta İşletme Ayarları > Sistem Kullanıcıları'nda bir sistem kullanıcısı oluştur, reklam hesabını ona ata, sonra Token oluştur de ve yalnız ads_read iznini seç.",
                                link: ("İşletme Ayarları'nı aç", "https://business.facebook.com/settings/system-users"))
                    HStack { SecureField("Meta token", text: $model.metaToken).textFieldStyle(DarkField()); Button("Bağla") { Task { await model.connectMeta() } }.buttonStyle(PrimaryButton()).disabled(model.metaToken.isEmpty || model.busy) }
                    if model.metaConnected { SetupNote(text: "Meta bağlı. Hesap eşlemesini değiştirmek için token'ı yeniden gir.") }
                } else {
                    AssignRows(model: model, options: model.metaAccounts.map { ($0.id, $0.name) }, empty: "Reklam yok", key: \.metaAccount, skipWeb: false)
                }
            }
            ExtraCard(id: "stripe", focus: f, icon: "dollarsign.circle", title: "Stripe", badge: "İsteğe bağlı",
                      sub: "Web satışların varsa günlük gelir ve satış sayısı.",
                      connected: model.drafts.filter { $0.stripeKey != nil }.map(\.name)) {
                Instruction(n: 1, text: "Stripe'ta Geliştiriciler > API anahtarları > Kısıtlı anahtar oluştur. Balance ve Charges için Read ver.",
                            link: ("Stripe'ı aç", "https://dashboard.stripe.com/apikeys"))
                HStack {
                    Picker("Ürün", selection: $model.stripeTarget) {
                        Text("Ürün seç").tag("")
                        ForEach(model.drafts.filter(\.include)) { d in Text(d.name).tag(d.id) }
                    }
                    .frame(width: 180)
                    SecureField("rk_live_…", text: $model.stripeKey).textFieldStyle(DarkField())
                    Button("Bağla") { Task { await model.connectStripe() } }.buttonStyle(PrimaryButton()).disabled(model.stripeKey.isEmpty || model.busy)
                }
                if let n = model.stripeNote { SetupNote(text: n) }
            }
            ExtraCard(id: "site", focus: f, icon: "globe", title: "Web sitesi (Cloudflare)", badge: "İsteğe bağlı",
                      sub: "Siten Cloudflare'deyse günlük ziyaretçi ve sitenin açık olup olmadığı.",
                      connected: model.cfConnected ? model.drafts.compactMap(\.site) : []) {
                if !model.cfConnected {
                    Instruction(n: 1, text: "Cloudflare'de My Profile > API Tokens > Create Token > Custom token. İzinler: Zone > Zone > Read ve Zone > Analytics > Read.",
                                link: ("Cloudflare'i aç", "https://dash.cloudflare.com/profile/api-tokens"))
                    HStack { SecureField("Cloudflare API token", text: $model.cfToken).textFieldStyle(DarkField()); Button("Bağla") { Task { await model.connectCF() } }.buttonStyle(PrimaryButton()).disabled(model.cfToken.isEmpty || model.busy) }
                } else {
                    Text("Bir uygulamaya bağlanmayan siteleri ayrı ürün olarak eklemek için Ürünlerin adımında işaretle.")
                        .font(.system(size: 12)).foregroundStyle(S.faint)
                }
            }
            ExtraCard(id: "ai", focus: f, icon: "sparkles", title: "AI analiz notu", badge: "İsteğe bağlı",
                      sub: "Her sabah her ürün için kısa not: ne oldu, neden olabilir, bugün ne denemeli. Claude, ChatGPT, Gemini ya da bilgisayarındaki yerel model.",
                      connected: model.aiConnected ? [model.aiLabel] : []) {
                Picker("", selection: $model.aiProvider) {
                    Text("Claude").tag("anthropic")
                    Text("ChatGPT").tag("openai")
                    Text("Gemini").tag("gemini")
                    Text("Yerel (Ollama)").tag("ollama")
                }
                .pickerStyle(.segmented).labelsHidden()
                AIProviderHelp(provider: model.aiProvider)
                if model.aiProvider != "ollama" {
                    SecureField("API anahtarı", text: $model.aiKey).textFieldStyle(DarkField())
                } else {
                    TextField("Ollama adresi (boş: http://127.0.0.1:11434)", text: $model.aiURL).textFieldStyle(DarkField())
                }
                HStack {
                    TextField("Model (boş: \(Self.defaultModel(model.aiProvider)))", text: $model.aiModel).textFieldStyle(DarkField())
                    Button("Bağla") { Task { await model.connectAI() } }.buttonStyle(PrimaryButton())
                        .disabled(model.busy || (model.aiProvider != "ollama" && model.aiKey.isEmpty))
                }
                if model.aiConnected { Button("AI'ı kaldır") { Task { await model.removeAI() } }.buttonStyle(GhostButton()) }
            }

            GroupLabel(text: "İLERİ DÜZEY", sub: "Gerekmezse hiç dokunma")
            ExtraCard(id: "webhook", focus: f, icon: "bolt.horizontal", title: "Anlık satış bildirimi (RevenueCat webhook)", badge: "İleri düzey",
                      sub: "Satış, deneme ve iptali saniyesinde görürsün. Olmadan da RevenueCat verisi 5 dakikada bir gelir.",
                      connected: model.hookOK ? ["çalışıyor"] : []) {
                SetupNote(text: "RevenueCat olayları internetten gönderir; Mac'in buna doğrudan açık değildir. Bunun için kendi tünelini (Cloudflare Tunnel ya da ngrok) kurman gerekir. Tünel yalnız Pulse'ın bu iş için açtığı portu dışarı açar, gizli anahtarı bilmeyen hiçbir şey gönderemez.")
                Instruction(n: 1, text: "Gizli anahtarı oluştur. Pulse bilgisayarında \(model.hookPort) portunda dinlemeye başlar.")
                if model.hookSecret.isEmpty {
                    Button("Gizli anahtar oluştur") { Task { await model.enableHook() } }.buttonStyle(PrimaryButton()).disabled(model.busy)
                } else {
                    Instruction(n: 2, text: "Terminalde tüneli başlat. Kalıcı adres için Cloudflare'de adlandırılmış tünel kurmanı öneririz; hızlı tünelin adresi her açılışta değişir.",
                                link: ("cloudflared kurulumu", "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/"))
                    CopyRow(text: "cloudflared tunnel --url http://127.0.0.1:\(model.hookPort)")
                    Instruction(n: 3, text: "Tünelin verdiği https adresini yapıştır ve dene.")
                    HStack {
                        TextField("https://…trycloudflare.com", text: $model.hookURL).textFieldStyle(DarkField())
                        Button("Dene") { Task { await model.testHook() } }.buttonStyle(PrimaryButton()).disabled(model.hookURL.isEmpty || model.busy)
                    }
                    if model.hookOK {
                        Instruction(n: 4, text: "RevenueCat'te her proje için Integrations > Webhooks > Add. URL ve Authorization alanına aşağıdakileri yapıştır.",
                                    link: ("RevenueCat'i aç", "https://app.revenuecat.com/"))
                        ForEach(model.drafts.filter { $0.include && $0.rcKey != nil }) { d in
                            Text(d.name).font(.system(size: 12, weight: .semibold)).padding(.leading, 34)
                            CopyRow(text: "\(model.hookURL.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/rc/\(d.appId ?? d.id)")
                        }
                        if !model.drafts.contains(where: { $0.include && $0.rcKey != nil }) {
                            SetupNote(text: "Önce yukarıdan RevenueCat'i bağla; webhook adresi ürün başına oluşur.")
                        }
                        Text("Authorization").font(.system(size: 12, weight: .semibold)).padding(.leading, 34)
                        CopyRow(text: "Bearer \(model.hookSecret)")
                    }
                    Button("Webhook'u kapat") { Task { await model.disableHook() } }.buttonStyle(GhostButton())
                }
            }
        }
    }

    static func defaultModel(_ p: String) -> String {
        ["anthropic": "claude-sonnet-5-5", "openai": "gpt-5-mini", "gemini": "gemini-2.5-flash", "ollama": "llama3.1"][p] ?? ""
    }
}

private struct GroupLabel: View {
    let text: String, sub: String
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(S.dim)
            Text(sub).font(.system(size: 11)).foregroundStyle(S.faint)
        }
        .padding(.top, 6)
    }
}

private struct AssignRows: View {
    @ObservedObject var model: SetupModel
    let options: [(String, String)]
    let empty: String
    let key: WritableKeyPath<DraftApp, String?>
    let skipWeb: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($model.drafts) { $d in
                if d.include && !(skipWeb && d.kind == "web") {
                    HStack {
                        Text(d.name).font(.system(size: 12.5)).frame(width: 140, alignment: .leading)
                        Picker("", selection: Binding(get: { d[keyPath: key] ?? "" }, set: { d[keyPath: key] = $0.isEmpty ? nil : $0 })) {
                            Text(empty).tag("")
                            ForEach(options, id: \.0) { o in Text(o.1).tag(o.0) }
                        }.labelsHidden()
                    }
                }
            }
            Button("Kaydet") { Task { await model.saveApps() } }.buttonStyle(GhostButton())
        }
    }
}

private struct AIProviderHelp: View {
    let provider: String
    var body: some View {
        switch provider {
        case "openai":
            Instruction(n: 1, text: "OpenAI Platform'da API keys bölümünden anahtar oluştur. Rakamların ve yorum metinlerin analiz için OpenAI'a gider, ücreti senin hesabından düşer.",
                        link: ("OpenAI'ı aç", "https://platform.openai.com/api-keys"))
        case "gemini":
            Instruction(n: 1, text: "Google AI Studio'da Get API key ile anahtar oluştur. Rakamların ve yorum metinlerin analiz için Google'a gider.",
                        link: ("AI Studio'yu aç", "https://aistudio.google.com/app/apikey"))
        case "ollama":
            Instruction(n: 1, text: "Ollama'yı kur, aç ve terminalde \"ollama pull llama3.1\" çalıştır. Ücretsiz; Ollama bu Mac'te çalıştığı sürece hiçbir veri dışarı çıkmaz. Not kalitesi bulut modellerinden düşük olabilir.",
                        link: ("Ollama'yı indir", "https://ollama.com/download"))
        default:
            Instruction(n: 1, text: "Anthropic Console'da API Keys bölümünden anahtar oluştur. Rakamların ve yorum metinlerin analiz için Anthropic'e gider, ücreti senin hesabından düşer.",
                        link: ("Console'u aç", "https://console.anthropic.com/settings/keys"))
        }
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(S.ok)
            Text("Hazır").font(.system(size: 26, weight: .bold))
            Text("Fareyi ekranının sağ kenarına götür, panel açılır. Menü çubuğundaki Pulse simgesinden de açabilirsin.")
                .font(.system(size: 14)).foregroundStyle(S.dim).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Bullet(icon: "clock", title: "Veriler gecikmeli gelir", text: "Apple satış raporu 1 gün, Google Play kurulum raporu 2-5 gün gecikmeli yayınlar. Yorumlar hemen gelir.")
                Bullet(icon: "dollarsign.circle", title: "Gelir nasıl hesaplanır", text: "App Store geliri Apple'ın net rakamıdır. Google Play geliri satış raporundan, Google'ın %15 payı düşülerek tahmini hesaplanır. RevenueCat bağlarsan ikisi de anlık ve kesin olur.")
                Bullet(icon: "chart.bar", title: "Kullanım istatistikleri 1-2 gün sonra", text: "Apple ilk analiz raporunu hazırlarken bekletir. Pulse raporu senin için açtı, kendisi takip eder.")
                Bullet(icon: "plus.circle", title: "Sonradan eklemek", text: "Panelin üst barındaki dişli simgesinden Bağlantılar'ı açabilirsin. Boş kutulardaki ve ürün detayındaki Bağla düğmeleri de seni doğrudan ilgili yere götürür.")
            }
        }
    }
}

private struct RequiredNote: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("ZORUNLU").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(S.warn)
            Text("App Store ya da Google Play'den en az biri. Uygulaman yalnız bir mağazadaysa diğerini atla.").font(.system(size: 11.5)).foregroundStyle(S.dim)
        }
    }
}

private struct StepTitle: View {
    let title: String
    let sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(sub).font(.system(size: 13)).foregroundStyle(S.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Bullet: View {
    let icon: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(S.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.system(size: 12.5)).foregroundStyle(S.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Instruction: View {
    let n: Int
    let text: String
    var link: (String, String)? = nil
    var link2: (String, String)? = nil
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let link { LinkButton(title: link.0, url: link.1) }
                    if let link2 { LinkButton(title: link2.0, url: link2.1) }
                }
            }
        }
    }
}

private struct LinkButton: View {
    let title: String, url: String
    var body: some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 4) { Text(title); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)) }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(S.accent)
        }
        .buttonStyle(.plain)
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var hint: String? = nil
    var link: (String, String)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(S.dim)
            TextField(placeholder, text: $text).textFieldStyle(DarkField())
            if let hint {
                HStack(spacing: 6) {
                    Text(hint).font(.system(size: 11)).foregroundStyle(S.faint).fixedSize(horizontal: false, vertical: true)
                    if let link { LinkButton(title: link.0, url: link.1) }
                }
            }
        }
    }
}

private struct DarkField: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(S.line))
    }
}

private struct FileDrop: View {
    let title: String
    let done: Bool
    let types: [String]
    let onFile: (URL) -> Void
    @State private var over = false
    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "arrow.down.doc").font(.system(size: 18)).foregroundStyle(done ? S.ok : S.accent)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("ya da seç").font(.system(size: 12)).foregroundStyle(S.faint)
            }
            .padding(16).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(over ? S.accent.opacity(0.15) : S.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])).foregroundStyle(over ? S.accent : S.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $over) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { onFile(url) } }
            }
            return true
        }
    }
    private func pick() {
        let o = NSOpenPanel()
        o.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        o.allowsMultipleSelection = false
        if o.runModal() == .OK, let u = o.url { onFile(u) }
    }
}

private struct CopyRow: View {
    let text: String
    @State private var copied = false
    var body: some View {
        HStack {
            Text(text).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Button(copied ? "Kopyalandı" : "Kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            }
            .buttonStyle(GhostButton())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(S.card))
        .padding(.leading, 34)
    }
}

private struct Connected: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(S.ok)
    }
}

private struct SetupNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(S.dim)
            Text(text).font(.system(size: 12)).foregroundStyle(S.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(S.card))
    }
}

private struct AppChips: View {
    let names: [String]
    let icons: [URL?]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, n in
                HStack(spacing: 10) {
                    SetupAppIcon(url: i < icons.count ? icons[i] : nil, kind: "app", size: 24)
                    Text(n).font(.system(size: 12.5))
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(S.card))
    }
}

private struct SetupAppIcon: View {
    let url: URL?
    let kind: String
    var size: CGFloat = 34
    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { img in img.resizable() } placeholder: { placeholder }
            } else { placeholder }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(Color.white.opacity(0.08))
            .overlay(Image(systemName: kind == "game" ? "gamecontroller" : kind == "web" ? "globe" : "app").font(.system(size: size * 0.4)).foregroundStyle(S.faint))
    }
}

private struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(S.dim)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
}

private struct ExtraCard<Content: View>: View {
    let id: String
    let focus: String?
    let icon: String, title: String
    var badge: String = "İsteğe bağlı"
    let sub: String
    let connected: [String]
    @ViewBuilder let content: Content
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: icon).font(.system(size: 16)).foregroundStyle(S.accent).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title).font(.system(size: 14, weight: .semibold))
                            Badge(text: badge)
                        }
                        Text(connected.isEmpty ? sub : "Bağlı: \(connected.joined(separator: ", "))").font(.system(size: 12))
                            .foregroundStyle(connected.isEmpty ? S.dim : S.ok).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(S.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(S.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == id ? S.accent : .clear, lineWidth: 1.5))
        .onAppear { if focus == id { open = true } }
        .onChange(of: focus) { _, v in if v == id { withAnimation(.snappy) { open = true } } }
    }
}

private struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(S.accent.opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)))
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.6))
    }
}

private struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
    }
}
