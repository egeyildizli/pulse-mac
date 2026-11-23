import Foundation
import Security

extension Notification.Name {
    static let pulseOpenSetup = Notification.Name("pulseOpenSetup")
}

@MainActor func openConnections(_ focus: String? = nil) {
    NotificationCenter.default.post(name: .pulseOpenSetup, object: focus)
}

enum Secrets {
    private static let service = "Pulse"
    private static let account = "connections"

    #if PULSE_DEV
    private static let memoryOnly = ProcessInfo.processInfo.environment["PULSE_NO_KEYCHAIN"] != nil
    #else
    private static let memoryOnly = false
    #endif
    private static var memory: [String: String] = [:]

    static func load() -> [String: String] {
        if memoryOnly { return memory }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return dict
    }

    @discardableResult
    static func merge(_ changes: [String: String?]) -> [String: String] {
        var cur = load()
        for (k, v) in changes {
            if let v, !v.isEmpty { cur[k] = v } else { cur.removeValue(forKey: k) }
        }
        save(cur)
        return cur
    }

    static func save(_ dict: [String: String]) {
        if memoryOnly { memory = dict; return }
        let data = (try? JSONEncoder().encode(dict)) ?? Data()
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let upd: [String: Any] = [kSecValueData as String: data,
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(base as CFDictionary, upd as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func wipe() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

@MainActor
final class Engine {
    static let shared = Engine()
    private(set) var base: String?
    let token = UUID().uuidString + UUID().uuidString
    private var proc: Process?
    private var input: FileHandle?
    private var buffer = ""
    private var restarts = 0

    static var home: URL {
        #if PULSE_DEV
        if let h = ProcessInfo.processInfo.environment["PULSE_HOME"] {
            try? FileManager.default.createDirectory(atPath: h, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return URL(fileURLWithPath: h)
        }
        #endif
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pulse")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    private var binary: URL? {
        #if PULSE_DEV
        if let p = ProcessInfo.processInfo.environment["PULSE_ENGINE"] { return URL(fileURLWithPath: p) }
        #endif
        return Bundle.main.url(forAuxiliaryExecutable: "pulse-engine")
    }

    func start() {
        guard proc == nil, let bin = binary else { return }
        #if PULSE_DEV

        if let f = ProcessInfo.processInfo.environment["PULSE_TEST_SECRETS"],
           let d = FileManager.default.contents(atPath: f),
           let dict = try? JSONDecoder().decode([String: String].self, from: d) {
            Secrets.merge(dict.mapValues { Optional($0) })
        }
        #endif
        let p = Process()
        p.executableURL = bin

        p.environment = ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "TZ": TimeZone.current.identifier]
        p.currentDirectoryURL = Self.home
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(s) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.crashed() }
        }
        do { try p.run() } catch { NSLog("engine start: \(error)"); return }
        proc = p
        input = inPipe.fileHandleForWriting
        send(["token": token, "home": Self.home.path, "lang": Loc.isTurkish ? "tr" : "en", "secrets": Secrets.load()])
    }

    private func consume(_ s: String) {
        buffer += s
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if line.hasPrefix("READY "), let port = Int(line.dropFirst(6)) {
                base = "http://127.0.0.1:\(port)"
                restarts = 0
            }
        }
    }

    private func crashed() {
        proc = nil
        base = nil
        input = nil
        guard restarts < 5 else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in MainActor.assumeIsolated { self?.start() } }
    }

    private func send(_ obj: [String: Any]) {
        guard let input, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        input.write(d + Data("\n".utf8))
    }

    func pushSecrets(_ changes: [String: String?]) {
        send(["secrets": changes.mapValues { $0 ?? "" }])
    }

    func ready() async -> String? {
        for _ in 0..<100 {
            if let base { return base }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return base
    }

    func request(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Data {
        guard let b = await ready(), let url = URL(string: b + path) else { throw URLError(.cannotConnectToHost) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 90
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    func json(_ path: String, method: String = "GET", body: Any? = nil) async -> [String: Any] {
        do {
            let d = try await request(path, method: method, body: body)
            return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        } catch {
            return ["ok": false, "error": "Yerel motora ulaşılamadı. Uygulamayı kapatıp yeniden aç."]
        }
    }

    func stop() {
        try? input?.close()
        proc?.terminate()
    }
}
