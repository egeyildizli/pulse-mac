import AppKit
import ServiceManagement
import SwiftUI

@main
struct PulseMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class EdgePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    private lazy var toast = BigToast(store: store)
    private var panel: EdgePanel!
    private var status: NSStatusItem!
    private var watcher: Timer?
    private var edgeSince: Date?
    private var outsideSince: Date?
    private var shown = false
    private let width: CGFloat = 500

    func applicationDidFinishLaunching(_ notification: Notification) {
        Engine.shared.start()
        #if PULSE_DEV
        if SelfTest.input != nil && !devArgs.contains("--show") {
            Task { await SelfTest.run(store: store) }
            return
        }
        if Renderer.outDir != nil {
            Task { await Renderer.run(store: store) }
            return
        }
        #endif
        buildPanel()
        buildStatusItem()

        AboutWindow.shared.onWiped = { [weak self] in
            self?.store.snap = nil
            self?.hide(force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                MainActor.assumeIsolated {
                    Engine.shared.start()
                    SetupWindow.shared.show(manage: false)
                }
            }
        }
        SetupWindow.shared.onFinish = { [weak self] in
            Task { await self?.store.refresh() }
            self?.openPinned()
        }

        UpdateChecker.shared.checkIfDue()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.checkIfDue() }
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.checkIfDue() }
        }
        NotificationCenter.default.addObserver(forName: .pulseOpenSetup, object: nil, queue: .main) { n in
            let focus = n.object as? String
            MainActor.assumeIsolated { SetupWindow.shared.show(manage: true, focus: focus) }
        }

        #if PULSE_DEV
        let selfTest = SelfTest.input != nil
        #else
        let selfTest = false
        #endif
        if selfTest {
            #if PULSE_DEV
            Task { await SelfTest.run(store: store) }
            #endif
        } else { Task {
            let st = await Engine.shared.json("/v1/local/state")
            let empty = (st["apps"] as? [Any])?.isEmpty ?? true
            if devArgs.contains("--setup") { SetupWindow.shared.show(manage: !empty) }
            else if empty { SetupWindow.shared.show(manage: false) }
        } }
        store.onBigAlert = { [weak self] a, c in self?.toast.push(a, c) }
        toast.onOpen = { [weak self] _ in self?.openPinned() }
        store.start()
        if devArgs.contains("--toast-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let s = self.store.snap, let c = s.cards.first else { return }
                let a = Alert(id: -1, app: c.id, metric: "note", kind: c.note?.key, severity: c.note?.mood == "fire" ? "good" : "warning",
                              title: "\(c.name): \(c.note?.headline ?? "Test bildirimi")", body: c.note?.lines.first, ts: Int(Date().timeIntervalSince1970), acked: 0)
                self.toast.push(a, c)
            }
        }
        if devArgs.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openPinned() }
        }

        watcher = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusTitle() }
        }
    }

    private func buildPanel() {
        panel = EdgePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true

        let host = NSHostingView(rootView: PanelView(onClose: { [weak self] in self?.hide(force: true) }).environmentObject(store))
        host.translatesAutoresizingMaskIntoConstraints = false

        host.sizingOptions = []
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
    }

    private func buildStatusItem() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.button?.title = "◉ Pulse"
        let menu = NSMenu()
        menu.addItem(withTitle: Loc.t("Paneli aç"), action: #selector(openPinned), keyEquivalent: "p").target = self
        menu.addItem(withTitle: Loc.t("Şimdi yenile"), action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: Loc.t("Bağlantılar…"), action: #selector(openSetup), keyEquivalent: ",").target = self
        menu.addItem(withTitle: Loc.t("Hakkında ve gizlilik…"), action: #selector(openAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = NSMenuItem(title: Loc.t("Girişte başlat"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: Loc.t("Çıkış"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }

    private func updateStatusTitle() {
        guard let s = store.snap else { return }
        let t = s.totals
        var parts = ["◉ \(Fmt.num(t.liveUsers ?? t.usersToday))"]
        if let subs = t.activeSubs { parts.append(Loc.t("\(Fmt.num(subs)) abone")) }
        let open = s.alerts.filter { $0.acked == 0 && ($0.severity == "critical" || $0.severity == "warning") }.count
        if t.servicesDown > 0 || open > 0 { parts.append("⚠︎\(t.servicesDown + open)") }
        status.button?.title = parts.joined(separator: "  ")
    }

    private var homeScreen: NSScreen? { NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX } }

    private func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
    }

    private func tick() {
        let p = NSEvent.mouseLocation
        guard let screen = screenUnderMouse() else { return }
        let atEdge = screen == homeScreen && p.x >= screen.frame.maxX - 2
        if !shown {
            if atEdge && NSEvent.pressedMouseButtons == 0 {
                if edgeSince == nil { edgeSince = Date() }
                if Date().timeIntervalSince(edgeSince!) > 0.18 { show(on: screen) }
            } else {
                edgeSince = nil
            }
            return
        }
        guard !store.pinned else { return }
        let inside = NSMouseInRect(p, panel.frame.insetBy(dx: -24, dy: -24), false)
        if inside {
            outsideSince = nil
        } else {
            if outsideSince == nil { outsideSince = Date() }
            if Date().timeIntervalSince(outsideSince!) > 0.45 { hide() }
        }
    }

    private func targetFrame(_ screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        return NSRect(x: v.maxX - width - 8, y: v.minY + 8, width: width, height: v.height - 16)
    }

    func show(on screen: NSScreen) {
        shown = true
        edgeSince = nil
        outsideSince = nil
        let target = targetFrame(screen)
        panel.setFrame(target.offsetBy(dx: width + 20, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        Task { await store.refresh() }
    }

    func hide(force: Bool = false) {
        if force { store.pinned = false }
        guard shown else { return }
        shown = false
        let f = panel.frame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(f.offsetBy(dx: width + 20, dy: 0), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.shown == false { self?.panel.orderOut(nil) }
            }
        })
    }

    @objc func openPinned() {
        store.pinned = true
        if let s = homeScreen ?? NSScreen.main { show(on: s) }
    }

    @objc private func refreshNow() { Task { await store.manualRefresh() } }

    @objc private func openSetup() { SetupWindow.shared.show(manage: true) }

    @objc private func openAbout() { AboutWindow.shared.show() }

    func applicationWillTerminate(_ notification: Notification) { Engine.shared.stop() }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                item.state = .off
            } else {
                try SMAppService.mainApp.register()
                item.state = .on
            }
        } catch {
            NSLog("login item: \(error)")
        }
    }
}
