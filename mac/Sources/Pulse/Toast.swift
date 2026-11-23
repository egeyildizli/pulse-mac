import AppKit
import SwiftUI

@MainActor
final class BigToast {
    private var panel: NSPanel?
    private var queue: [(Alert, Card?)] = []
    private var showing = false
    private let store: Store
    var onOpen: ((String?) -> Void)?

    init(store: Store) { self.store = store }

    func push(_ alert: Alert, _ card: Card?) {
        queue.append((alert, card))
        if !showing { next() }
    }

    private func next() {
        guard !queue.isEmpty else { showing = false; return }
        showing = true
        let (alert, card) = queue.removeFirst()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let size = NSSize(width: 580, height: 150)
        let v = screen.visibleFrame
        let target = NSRect(x: v.midX - size.width / 2, y: v.maxY - size.height - 14, width: size.width, height: size.height)

        let p = NSPanel(contentRect: target, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        let view = ToastView(alert: alert, card: card,
                             onClose: { [weak self] in self?.dismiss() },
                             onOpen: { [weak self] in self?.onOpen?(alert.app); self?.dismiss() })
            .environmentObject(store)
        p.contentView = NSHostingView(rootView: view)
        p.setFrame(target.offsetBy(dx: 0, dy: 40), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(target, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
        NSSound(named: alert.severity == "critical" ? "Sosumi" : alert.severity == "good" ? "Glass" : "Ping")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak p] in
            if let p, self?.panel === p { self?.dismiss() }
        }
    }

    private func dismiss() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                p.orderOut(nil)
                self?.next()
            }
        })
    }
}

struct ToastView: View {
    let alert: Alert
    let card: Card?
    let onClose: () -> Void
    let onOpen: () -> Void
    @State private var hover = false

    var body: some View {
        let color: Color = switch alert.severity {
        case "critical": Theme.bad
        case "warning": Theme.warn
        case "good": Theme.good
        default: .blue
        }
        HStack(alignment: .center, spacing: 16) {
            if let card { AppIcon(card: card, size: 72) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(card?.name.uppercased() ?? "PULSE").font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(color)
                }
                MText(stripName(alert.title)).font(.system(size: 18, weight: .bold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                if let b = alert.body, !b.isEmpty {
                    MText(b).font(.system(size: 13.5)).foregroundStyle(Color.white.opacity(0.7)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack {
                IconButton(icon: "xmark", help: "Kapat", action: onClose)
                Spacer()
            }
        }
        .padding(18)
        .frame(width: 580, height: 150)
        .background(
            ZStack {
                VisualEffect()
                Color.black.opacity(0.45)
                LinearGradient(colors: [color.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(color.opacity(0.7), lineWidth: 1.5))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .scaleEffect(hover ? 1.01 : 1)
        .onHover { hover = $0 }
        .onTapGesture(perform: onOpen)
    }

    private func stripName(_ t: String) -> String {
        guard let card, t.hasPrefix(card.name + ": ") else { return t }
        return String(t.dropFirst(card.name.count + 2))
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
