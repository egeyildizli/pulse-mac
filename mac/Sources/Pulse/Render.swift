#if PULSE_DEV
import AppKit
import SwiftUI

@MainActor
enum Renderer {
    static var outDir: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--render"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func run(store: Store) async {
        guard let dir = outDir else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = await Engine.shared.ready()

        for _ in 0..<60 {
            let st = await Engine.shared.json("/v1/local/state")
            if st["syncing"] as? Bool == false { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let names = ["1-karsilama", "2-app-store", "3-google-play", "4-urunler", "5-daha-fazlasi", "6-hazir"]
        for s in SetupModel.Step.allCases {
            let m = SetupModel(manage: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            m.step = s
            if s == .apps { await m.loadCatalog() }
            await snap(SetupView(model: m), size: NSSize(width: 760, height: 620), to: "\(dir)/\(names[s.rawValue]).png")
        }

        for f in ["ai", "webhook"] {
            let m = SetupModel(manage: true)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            m.focus = f
            m.step = .extras
            await snap(SetupView(model: m, height: 1500), size: NSSize(width: 760, height: 1500), to: "\(dir)/5-odak-\(f).png")
        }
        await snap(AboutView(onWipe: {}), size: NSSize(width: 560, height: 640), to: "\(dir)/8-hakkinda.png")
        UpdateChecker.shared.checkIfDue()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await store.refresh()
        let panel = ZStack { Color(red: 0.16, green: 0.16, blue: 0.18); PanelView(onClose: {}).environmentObject(store) }
        await snap(panel, size: NSSize(width: 500, height: 1500), to: "\(dir)/7-panel.png")
        NSApp.terminate(nil)
    }

    private static func snap<V: View>(_ v: V, size: NSSize, to path: String) async {
        let host = NSHostingView(rootView: v)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.orderFrontRegardless()

        try? await Task.sleep(nanoseconds: 4_000_000_000)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        w.orderOut(nil)
    }
}

#endif
