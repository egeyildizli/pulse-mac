import AppKit
import Foundation
import SwiftUI

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var available: (version: String, url: URL)?

    static let enabledKey = "updateCheckEnabled"
    private let lastKey = "updateLastCheck"
    private let latestKey = "updateLatest"
    private let latestURLKey = "updateLatestURL"
    private let dismissedKey = "updateDismissed"
    private let feed = URL(string: "https://egeyildizli.com/pulse/version.json")!
    private let allowedHost = "egeyildizli.com"

    static var official: Bool {
        #if PULSE_OFFICIAL || PULSE_DEV
        return true
        #else
        return false
        #endif
    }

    static var enabled: Bool {
        official && (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true)
    }

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() { restore() }

    func checkIfDue() {
        guard Self.enabled else { available = nil; return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        if Date().timeIntervalSince1970 - last < 24 * 3600 { restore(); return }
        Task { await check() }
    }

    func dismiss() {
        if let v = available?.version { UserDefaults.standard.set(v, forKey: dismissedKey) }
        available = nil
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            UserDefaults.standard.removeObject(forKey: lastKey)
            checkIfDue()
        } else {
            available = nil
        }
    }

    private func check() async {
        var url = feed
        #if PULSE_DEV
        if let o = ProcessInfo.processInfo.environment["PULSE_UPDATE_FEED"], let u = URL(string: o) { url = u }
        #endif
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        cfg.httpAdditionalHeaders = ["User-Agent": "Pulse"]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count < 16_384,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["version"] as? String, Self.isVersion(v),
              let s = obj["url"] as? String, let link = URL(string: s), isAllowed(link)
        else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        UserDefaults.standard.set(v, forKey: latestKey)
        UserDefaults.standard.set(link.absoluteString, forKey: latestURLKey)
        restore()
    }

    private func restore() {
        let d = UserDefaults.standard
        guard Self.enabled, let v = d.string(forKey: latestKey), let s = d.string(forKey: latestURLKey),
              let link = URL(string: s), isAllowed(link),
              Self.isNewer(v, than: Self.current), d.string(forKey: dismissedKey) != v
        else { available = nil; return }
        available = (v, link)
    }

    private func isAllowed(_ u: URL) -> Bool {
        guard u.scheme == "https", let h = u.host?.lowercased() else { return false }
        #if PULSE_DEV
        #endif
        return h == allowedHost || h.hasSuffix("." + allowedHost)
    }

    static func isVersion(_ s: String) -> Bool {
        s.count <= 20 && s.range(of: #"^\d+(\.\d+){0,3}$"#, options: .regularExpression) != nil
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateBanner: View {
    @ObservedObject var updater = UpdateChecker.shared
    var body: some View {
        if let a = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 16)).foregroundStyle(Theme.good)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pulse \(a.version) çıktı").font(.system(size: 12.5, weight: .semibold))
                    Text("Şu an \(UpdateChecker.current) kullanıyorsun. Yeni sürümü indirip kurman yeterli, bağlantıların ve verilerin kalır.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("İndir") { NSWorkspace.shared.open(a.url) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button { updater.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).help("Bu sürüm için gizle")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.good.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.good.opacity(0.45), lineWidth: 1))
        }
    }
}
