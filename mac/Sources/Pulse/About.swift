import AppKit
import SwiftUI

@MainActor
final class AboutWindow {
    static let shared = AboutWindow()
    private var window: NSWindow?
    var onWiped: (() -> Void)?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: AboutView(onWipe: { [weak self] in self?.wipe() }))
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.window = nil }
        }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func wipe() {
        let a = NSAlert()
        a.messageText = Loc.t("Bütün bağlantılar ve veriler silinsin mi?")
        a.informativeText = Loc.t("Bu Mac'teki bütün anahtarlar (Keychain) ve Pulse'ın topladığı bütün veriler silinir. Bağladığın hesaplarda (Apple, Google, RevenueCat...) hiçbir şey değişmez; oralarda oluşturduğun anahtarları istersen kendin iptal edebilirsin. Bu işlem geri alınamaz.")
        a.alertStyle = .critical
        a.addButton(withTitle: Loc.t("Hepsini sil"))
        a.addButton(withTitle: Loc.t("Vazgeç"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Engine.shared.stop()
        Secrets.wipe()
        try? FileManager.default.removeItem(at: Engine.home)
        window?.close()
        window = nil
        onWiped?()
    }
}

struct AboutView: View {
    let onWipe: () -> Void
    @State private var updateOn = UpdateChecker.enabled
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Circle().fill(Color(red: 0.31, green: 0.55, blue: 1)).frame(width: 10, height: 10)
                    Text("PULSE").font(.system(size: 15, weight: .bold)).tracking(2)
                    Text("v\(version)").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("© 2026 Appxiom Spark LLC").font(.system(size: 12)).foregroundStyle(.secondary)

                section("Verilerin nerede")
                item("internaldrive", "Bütün veriler bu Mac'te, Pulse'ın veri klasöründe saklanır. Bağlantı anahtarların bu Mac'in Keychain'inde durur.")
                item("person.crop.circle.badge.xmark", "Pulse'ın verilerini tutan bir sunucu yok. Kullanım verisi, hata raporu ya da bağladığın hesaplardan hiçbir bilgi yayıncıya (Appxiom Spark) gönderilmez.")

                section("Pulse kimlerle konuşur")
                item("link", "Yalnız senin bağladığın servisler: App Store Connect, Google Play, Google Analytics, RevenueCat, Stripe, Cloudflare, Meta. İstekler doğrudan bu Mac'ten o servislere gider.")
                item("app.badge", "Uygulama ikonları için Apple'ın herkese açık arama servisi (itunes.apple.com): yalnız uygulamalarının mağaza kimlikleri gönderilir.")
                item("dollarsign.arrow.circlepath", "Farklı para birimlerini dolara çevirmek için günde bir kez herkese açık döviz kuru servisi (open.er-api.com). Bu istekte senin hiçbir verin yoktur.")
                item("sparkles", "AI notunu açtıysan: ürünlerinin rakamları ve yorum metinleri, seçtiğin AI şirketine (Anthropic, OpenAI ya da Google) senin hesabınla gider. Yerel model (Ollama) seçtiysen bu Mac'ten çıkmaz.")
                item("bolt.horizontal", "Anlık bildirimi (webhook) açtıysan: RevenueCat senin kurduğun tünel üzerinden bu Mac'e olay gönderir.")

                if UpdateChecker.official {
                section("Güncellemeler")
                item("arrow.down.circle", "Pulse günde en fazla bir kez egeyildizli.com'dan en son sürüm numarasını okur. Bu istekte senin hiçbir verin yoktur; her internet isteğinde olduğu gibi sunucu yalnız IP adresini görür. Yeni sürüm varsa panelin üstünde haber verir, kendiliğinden hiçbir şey indirmez.")
                Toggle("Yeni sürümleri denetle", isOn: Binding(
                    get: { updateOn },
                    set: { updateOn = $0; UpdateChecker.shared.setEnabled($0) }
                )).toggleStyle(.switch).controlSize(.small)
                }

                section("Lisanslar")
                Button("Üçüncü taraf lisanslarını aç") {
                    if let u = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md", subdirectory: "Licenses") { NSWorkspace.shared.open(u) }
                }

                section("Veriler")
                HStack {
                    Button("Veri klasörünü göster") { NSWorkspace.shared.activateFileViewerSelecting([Engine.home]) }
                    Spacer()
                    Button(role: .destructive, action: onWipe) {
                        Text("Bütün bağlantıları ve verileri sil").foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 640)
        .background(Color(red: 0.07, green: 0.07, blue: 0.09))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .bold)).padding(.top, 6)
    }
    private func item(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(Color(red: 0.31, green: 0.55, blue: 1))
            Text(text).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
