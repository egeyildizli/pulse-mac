import Foundation
import SwiftUI
import UserNotifications

struct Snapshot: Decodable {
    let generatedAt: Int
    let day: String
    let spotlight: Spotlight?
    let series: Series?
    let changes: Changes?
    let today: TodayCounts?
    let sources: SourcesBrief?
    let totals: Totals
    let cards: [Card]
    let alerts: [Alert]
    let reviews: [Review]
}

struct Spotlight: Decodable { let app: String; let name: String; let mood: String; let headline: String }
struct Series: Decodable { let appUsers: [Double?]; let web: [Double?]; let installs: [Double?]; let revenue: [Double?] }
struct Changes: Decodable { let appUsers: Double?; let web: Double?; let installs: Double?; let revenue7d: Double?; let sameHour: [String: SameHourVal]? }

struct SameHourVal: Decodable { let now: Double?; let then: Double?; let pct: Double?; let estimated: Bool?; let label: String?; let days: Int? }
struct TodayCounts: Decodable { let newSubs: Int; let newSubsYday: Double?; let trials: Int?; let renewals: Int?; let cancels: Int?; let liveGross: Double?; let liveConnected: Bool?; let sales: Int; let lowReviews: Int; let reviews: Int; let problems: Int; let hot: Int; let byApp: [String: [String]]? }

struct Totals: Decodable {
    let visitors1h: Double?
    let liveUsers: Double?
    let usersToday: Double?
    let usersYday: Double?
    let webVisitorsToday: Double?
    let webVisitorsYday: Double?
    let installsToday: Double?
    let installsYday: Double?
    let revenueToday: Double?
    let revenueYday: Double?
    let revenue7d: Double?
    let gross7d: Double?
    let grossYday: Double?
    let grossToday: Double?
    let activeSubs: Double?
    let trials: Double?
    let mrr: Double?
    let subsNewToday: Double?
    let adSpendToday: Double?

    let installsLast: Double?
    let installsLastDay: String?
    let activeDevices: Double?
    let ratingAvg: Double?
    let ratingCount: Int?
    let servicesDown: Int
    let servicesTotal: Int
}

struct Hero: Decodable {
    let label: String
    let value: Double
    let unit: String
    let subLabel: String?
    let subValue: Double?
}

struct Note: Decodable, Hashable {
    let mood: String
    let headline: String
    let lines: [String]
    let key: String
}

struct SourceInfo: Decodable, Hashable {
    let source: String
    let label: String
    let status: String
    let err: String?
}

struct Card: Decodable, Identifiable {
    let id: String
    let name: String
    let segment: String
    let color: String
    let icon: String?
    let ascId: String?
    let site: String?
    let score: Double
    let hero: Hero?
    let note: Note?
    let metrics: [String: Double?]
    let sources: [SourceInfo]
    let spark: Spark
    let health: [Health]
    let openAlerts: Int
    let worst: String?

    func m(_ k: String) -> Double? { metrics[k] ?? nil }
}

struct Spark: Decodable {
    let live: [Double]
    let users: [Double?]
    let installs: [Double?]
    let revenue: [Double?]
}

struct Health: Decodable, Hashable {
    let name: String
    let ok: Bool
    let code: Int
    let ms: Int
    let since: Int
}

struct Alert: Decodable, Identifiable, Hashable {
    let id: Int
    let app: String?
    let metric: String?
    let kind: String?
    let severity: String
    let title: String
    let body: String?
    let ts: Int
    let acked: Int
}

struct Review: Decodable, Hashable {
    let app: String?
    let rating: Int
    let title: String?
    let body: String?
    let ts: Int
    let territory: String?
}

struct DayValue: Decodable, Hashable {
    let day: String
    let value: Double
}

struct Detail: Decodable {
    let diagnosis: Diagnosis?
    let siteSources: SiteSources?
    let acquisition: Acquisition?
    let meta: MetaOut?
    let id: String
    let name: String
    let segment: String
    let series: [String: [DayValue]]
    let retention: Retention?
    let screens: [ScreenRow]?
    let liveScreens: [LiveScreen]?
    let events: [EventRow]?
    let countries: [String: Double]?
    let insights: [Insight]
    let reviews: [Review]
    let alerts: [Alert]
}

struct Diagnosis: Decodable {
    let score: Int
    let verdict: String
    let window: String
    let funnel: [FunnelStep]
    let issues: [Finding]
    let wins: [Finding]
    let gaps: [Gap]
}
struct FunnelStep: Decodable, Hashable {
    let label: String
    let now: Double
    let prev: Double?
    let money: Bool?
    let rateTxt: String?
    let targetTxt: String?
    let ok: Bool?
}
struct Finding: Decodable, Hashable { let sev: String; let area: String; let title: String; let why: String; let fix: String }
struct Gap: Decodable, Hashable { let title: String; let how: String }

struct Retention: Decodable { let cohortUsers: Double; let curve: [Double] }
struct ScreenRow: Decodable, Hashable { let screen: String; let users: Double; let views: Double; let secPerUser: Double }
struct LiveScreen: Decodable, Hashable { let screen: String; let users: Double }
struct EventRow: Decodable, Hashable { let event: String; let users: Double; let count: Double }
struct Insight: Decodable, Hashable { let ts: Int; let text: String }

@MainActor
final class Store: ObservableObject {
    @Published var snap: Snapshot?
    @Published var error: String?
    @Published var lastFetch: Date?
    @Published var appIcons: [String: URL] = [:]
    @Published var pinned = false

    @Published var refreshTick = 0
    @Published var refreshing = false
    var onBigAlert: ((Alert, Card?) -> Void)?

    private var timer: Timer?
    private var seenAlertIds: Set<Int> = []
    private var firstLoad = true

    func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    private func fetch(_ path: String, method: String = "GET") async throws -> Data {
        try await Engine.shared.request(path, method: method)
    }

    func fetchData(_ path: String) async throws -> Data { try await fetch(path) }

    func refresh() async {
        do {
            let d = try await fetch("/v1/snapshot")
            let s = try JSONDecoder().decode(Snapshot.self, from: d)
            withAnimation(.spring(duration: 0.5)) { snap = s }
            error = nil
            lastFetch = Date()
            notifyNew(s.alerts)
            await resolveIcons(s.cards)
        } catch {
            self.error = Engine.shared.base == nil ? "Yerel motor başlıyor…" : "Veri okunamadı: \(error.localizedDescription)"
        }
    }

    func manualRefresh() async {
        guard !refreshing else { return }
        refreshing = true
        _ = try? await fetch("/v1/run?job=refresh", method: "POST")
        await refresh()
        refreshTick += 1
        refreshing = false
    }

    func detail(_ id: String) async -> Detail? {
        guard let d = try? await fetch("/v1/app/\(id)") else { return nil }
        do { return try JSONDecoder().decode(Detail.self, from: d) } catch {
            print("detail decode", error)
            return nil
        }
    }

    func ack(_ id: Int?) async {
        _ = try? await fetch(id.map { "/v1/alerts/\($0)/ack" } ?? "/v1/alerts/ack-all", method: "POST")
        await refresh()
    }

    private func notifyNew(_ alerts: [Alert]) {
        let fresh = alerts.filter { !seenAlertIds.contains($0.id) && $0.acked == 0 }
        seenAlertIds.formUnion(alerts.map(\.id))
        if firstLoad { firstLoad = false; return }
        for a in fresh where a.severity != "info" {
            onBigAlert?(a, snap?.cards.first { $0.id == a.app })
            let c = UNMutableNotificationContent()
            c.title = Loc.t(a.title)
            c.body = Loc.t(a.body ?? "")
            c.sound = a.severity == "critical" ? .defaultCritical : .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pulse-\(a.id)", content: c, trigger: nil))
        }
    }

    private func resolveIcons(_ cards: [Card]) async {
        let missing = cards.compactMap { $0.ascId }.filter { id in !appIcons.keys.contains(id) }
        guard !missing.isEmpty else { return }
        for country in ["tr", "us"] {
            let ids = missing.filter { !appIcons.keys.contains($0) }
            if ids.isEmpty { break }
            guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(ids.joined(separator: ","))&country=\(country)"),
                  let (d, _) = try? await URLSession.shared.data(from: url),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let results = j["results"] as? [[String: Any]] else { continue }
            for r in results {
                if let id = r["trackId"] as? Int, let s = (r["artworkUrl512"] ?? r["artworkUrl100"]) as? String, let u = URL(string: s) {
                    appIcons[String(id)] = u
                }
            }
        }
    }

    func iconURL(_ c: Card) -> URL? {
        if let a = c.ascId, let u = appIcons[a] { return u }
        return c.icon.flatMap(URL.init(string:))
    }
}

enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Loc.numberLocale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()
    static func num(_ v: Double?) -> String {
        guard let v else { return "–" }
        if abs(v) >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if abs(v) >= 100_000 { return String(format: "%.0fK", v / 1000) }
        return grouped.string(from: NSNumber(value: v)) ?? String(v)
    }
    static func usd(_ v: Double?) -> String {
        guard let v else { return "–" }
        if abs(v) >= 100_000 { return String(format: "$%.0fK", v / 1000) }
        if abs(v) >= 100 || v == v.rounded() { return "$" + (grouped.string(from: NSNumber(value: v.rounded())) ?? "") }
        return String(format: "$%.2f", v)
    }

    static func shortDay(_ d: String) -> String {
        let p = d.split(separator: "-")
        guard p.count == 3, let mo = Int(p[1]), let dd = Int(p[2]) else { return d }
        let names = Loc.months
        return "\(dd) \(names[(mo - 1) % 12])"
    }
    static func pct(_ v: Double?) -> String { v.map { Loc.isTurkish ? String(format: "%%%.0f", $0) : String(format: "%.0f%%", $0) } ?? "–" }
    static func ago(_ ts: Int) -> String {
        let s = Int(Date().timeIntervalSince1970) - ts
        if s < 60 { return "şimdi" }
        if s < 3600 { return "\(s / 60) dk" }
        if s < 86400 { return "\(s / 3600) sa" }
        return "\(s / 86400) g"
    }
}

extension Color {
    init(hex: String) {
        var v: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

struct SiteSources: Decodable {
    struct Row: Decodable, Hashable { let src: String; let v7: Double; let v30: Double; let s30: Double; let buyers: Double }
    struct Landing: Decodable, Hashable { let src: String; let page: String; let n: Double }
    struct Ref: Decodable, Hashable { let host: String; let n: Double; let src: String }
    let ts: Int
    let days: [DayValueTotal]
    let rows: [Row]
    let landings: [Landing]
    let refs: [Ref]
}
struct DayValueTotal: Decodable, Hashable { let day: String; let total: Double }

struct Acquisition: Decodable {
    struct Row: Decodable, Hashable { let src: String; let v7: Double; let v30: Double }
    struct Web: Decodable { let rows: [Row]; let landings: [SiteSources.Landing]; let refs: [SiteSources.Ref] }
    struct Store: Decodable { let rows: [Row]; let lastDay: String?; let firstDay: String? }
    let web: Web?
    let ios: Store?
    let android: Store?
    let webFirstDay: String?
}
