import Foundation
import SwiftUI

enum Loc {
    static let isTurkish: Bool = {
        if let o = ProcessInfo.processInfo.environment["PULSE_LANG"] { return o.hasPrefix("tr") }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("tr")
    }()

    private struct Template { let re: NSRegularExpression; let en: String; let weight: Int }
    private static var exact: [String: String] = [:]
    private static var templates: [Template] = []
    private static var cache: [String: String] = [:]
    private static let lock = NSLock()
    private static var missLog: FileHandle? = {
        guard let p = ProcessInfo.processInfo.environment["PULSE_I18N_LOG"] else { return nil }
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    private static var logged = Set<String>()

    private static let loaded: Bool = {
        guard !isTurkish else { return true }
        let url = Bundle.main.url(forResource: "en", withExtension: "json")
            ?? ProcessInfo.processInfo.environment["PULSE_I18N_FILE"].map { URL(fileURLWithPath: $0) }
        guard let url, let d = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: d) else { return false }
        for (tr, en) in map {
            if tr.contains("{}") {
                let parts = tr.components(separatedBy: "{}").map(NSRegularExpression.escapedPattern(for:))
                let pattern = "^" + parts.joined(separator: "(.+?)") + "$"
                if let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) {
                    templates.append(Template(re: re, en: en, weight: tr.replacingOccurrences(of: "{}", with: "").count))
                }
            } else {
                exact[tr] = en

                exact[tr.uppercased()] = en.uppercased()
                exact[tr.uppercased(with: Locale(identifier: "tr_TR"))] = en.uppercased()
            }
        }

        templates.sort { $0.weight > $1.weight }
        return true
    }()

    static func t(_ s: String) -> String {
        if isTurkish || s.isEmpty { return s }
        _ = loaded
        lock.lock(); defer { lock.unlock() }
        if let c = cache[s] { return c }
        var r = translate(s, depth: 0)
        if r == s, s.hasPrefix("%") { r = number(s) }
        cache[s] = r
        if r == s, hasTurkish(s) || ProcessInfo.processInfo.environment["PULSE_I18N_ALL"] != nil { logMiss(s) }
        return r
    }

    private static func translate(_ s: String, depth: Int) -> String {
        if let e = exact[s] { return e }

        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed != s, let e = exact[trimmed] { return s.replacingOccurrences(of: trimmed, with: e) }
        let ns = s as NSString
        for t in templates {
            guard let m = t.re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            var out = t.en
            for i in 1..<m.numberOfRanges {
                var g = ns.substring(with: m.range(at: i))
                g = depth < 3 ? translate(g, depth: depth + 1) : g
                g = number(g)
                if let r = out.range(of: "{}") { out.replaceSubrange(r, with: g) }
            }
            return out
        }

        if depth < 2, s.contains(" · ") {
            let parts = s.components(separatedBy: " · ")
            let tr = parts.map { translate($0, depth: depth + 1) }
            if tr != parts { return tr.joined(separator: " · ") }
        }
        return s
    }

    private static func number(_ g: String) -> String {
        if g.hasPrefix("%"), Double(g.dropFirst().replacingOccurrences(of: ",", with: ".")) != nil {
            return g.dropFirst().replacingOccurrences(of: ",", with: ".") + "%"
        }

        if g.range(of: #"^[-$]?\d+,\d{1,2}$"#, options: .regularExpression) != nil { return g.replacingOccurrences(of: ",", with: ".") }
        return g
    }

    private static func hasTurkish(_ s: String) -> Bool {
        s.range(of: "[çğıöşüÇĞİÖŞÜ]", options: .regularExpression) != nil
    }

    private static func logMiss(_ s: String) {
        guard let h = missLog, !logged.contains(s) else { return }
        logged.insert(s)
        h.write(Data((s.replacingOccurrences(of: "\n", with: "\\n") + "\n").utf8))
    }

    static var months: [String] {
        isTurkish ? ["Oca", "Şub", "Mar", "Nis", "May", "Haz", "Tem", "Ağu", "Eyl", "Eki", "Kas", "Ara"]
                  : ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    }

    static var numberLocale: Locale { Locale(identifier: isTurkish ? "tr_TR" : "en_US") }
}

extension Text {
    init<S: StringProtocol>(_ content: S) { self.init(verbatim: Loc.t(String(content))) }
}

extension Label where Title == Text, Icon == Image {
    init<S: StringProtocol>(_ title: S, systemImage name: String) {
        self.init { Text(verbatim: Loc.t(String(title))) } icon: { Image(systemName: name) }
    }
}

extension Button where Label == Text {
    init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { Text(verbatim: Loc.t(String(title))) }
    }
}

extension TextField where Label == Text {
    init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.init(text: text, prompt: Text(verbatim: Loc.t(String(title)))) { Text(verbatim: Loc.t(String(title))) }
    }
}

extension SecureField where Label == Text {
    init<S: StringProtocol>(_ title: S, text: Binding<String>) {
        self.init(text: text, prompt: Text(verbatim: Loc.t(String(title)))) { Text(verbatim: Loc.t(String(title))) }
    }
}

extension Picker where Label == Text {
    init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(verbatim: Loc.t(String(title))) }
    }
}

extension View {
    func help<S: StringProtocol>(_ text: S) -> some View { help(Text(verbatim: Loc.t(String(text)))) }
}

extension Toggle where Label == Text {
    init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(verbatim: Loc.t(String(title))) }
    }
}
