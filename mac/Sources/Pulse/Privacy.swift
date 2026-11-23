import SwiftUI

private let moneyRegex = try! NSRegularExpression(pattern: #"[-+]?\$\s?[0-9][0-9.,]*[KkM]?"#)

func maskMoney(_ s: String) -> String {
    let r = NSRange(s.startIndex..., in: s)
    return moneyRegex.stringByReplacingMatches(in: s, range: r, withTemplate: "\\$•••")
}

func hasMoney(_ s: String) -> Bool {
    moneyRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

let hideMoneyKey = "hideMoney"

struct MoneyToggle: View {
    @AppStorage(hideMoneyKey) private var hide = true
    var body: some View {
        IconButton(icon: hide ? "eye.slash" : "eye", help: hide ? "Para değerlerini göster" : "Para değerlerini gizle") {
            withAnimation(.easeOut(duration: 0.2)) { hide.toggle() }
        }
    }
}

struct MoneyBlur: ViewModifier {
    let on: Bool
    @AppStorage(hideMoneyKey) private var hide = true
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .blur(radius: hide && on && !hover ? 7 : 0)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.15), value: hover)
    }
}

extension View {
    func moneyBlur(_ on: Bool = true) -> some View { modifier(MoneyBlur(on: on)) }
}

struct MText: View {
    let s: String
    @AppStorage(hideMoneyKey) private var hide = true
    @State private var hover = false
    init(_ s: String) { self.s = s }
    var body: some View {
        Text(!hide || hover || !hasMoney(s) ? s : maskMoney(s))
            .onHover { hover = $0 }
    }
}
