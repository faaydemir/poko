import SwiftUI
import AppKit

/// Synthetic view captures: never contacts the daemon or reads user configuration.
@MainActor enum DemoScreenshots {
    static func render(to directory: String) throws {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = Store(); store.demo = true
        let listener = Listener(pid: 4242, command: "node", port: 4200, projectPath: "/Projects/demo/docs", displayName: "Documentation", suggestedName: "docs", isWeb: true, health: Health(status: "healthy", path: "/", statusCode: 200), healthPath: "/", url: nil)
        func service(_ name: String, _ port: Int, running: Bool, accepted: Bool = true) -> Service {
            Service(id: name, name: name, group: "demo", hostname: name, status: running ? "running" : "stopped", projectPath: "/Projects/demo/" + name, port: port, health: Health(status: running ? "healthy" : "unreachable", path: "/health", statusCode: running ? 200 : nil), healthPath: "/health", url: "http://" + name, startScript: "npm run dev -- --port $PORT", iconUrl: nil, healthUrl: "/health", accepted: accepted, processes: running ? [listener] : [], domainReady: true)
        }
        let worker = service("studio-worker", 4102, running: false)
        store.snapshot = Snapshot(apps: [service("studio-web", 4100, running: true), service("studio-api", 4101, running: true), worker], discovered: [listener], proxyPort: 47832, proxyError: nil, domainRoutingReady: true)
        func capture<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat? = nil) throws {
            let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            hosting.appearance = NSAppearance(named: .darkAqua)
            let size = NSSize(width: width, height: height ?? hosting.fittingSize.height)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting; hosting.frame = NSRect(origin: .zero, size: size)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            hosting.layoutSubtreeIfNeeded()
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        try capture("01-dashboard", Panel(store: store).frame(height: 620), width: 480, height: 620)
        try capture("02-add-app", AddForm(store: store, name: "studio-sdk", group: "studio", folder: "/Projects/demo/studio-web"), width: 448)
        try capture("03-edit-app", AppSettings(store: store, target: .mapped(worker)), width: 460)
        try capture("04-import-listener", AppSettings(store: store, target: .unmapped(listener)), width: 460)
        try capture("05-agents", AgentSetup(demo: true), width: 468)
        try capture("06-activate-reservation", AppSettings(store: store, target: .mapped(service("preview", 4120, running: false, accepted: false))), width: 460)
        store.snapshot = Snapshot(apps: [], discovered: [], proxyPort: 47832, proxyError: nil, domainRoutingReady: false)
        try capture("07-empty-and-domain-setup", Panel(store: store).frame(height: 620), width: 480, height: 620)
        store.snapshot = nil; store.error = "Poko Server is not running. Open Poko Server to reconnect."
        try capture("08-server-offline", Panel(store: store).frame(height: 620), width: 480, height: 620)
        for (name, title, message, action) in [
            ("09-remove-confirmation", "Remove studio-web?", "Removes the mapping and reservation. The app process keeps running.", "Remove"),
            ("10-shutdown-confirmation", "Stop process?", "Sends SIGTERM to this process. All apps and ports served by the same process will stop.", "Shut down")
        ] {
            let alert = NSAlert(); alert.window.appearance = NSAppearance(named: .darkAqua)
            alert.icon = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Port.icns"))
            alert.messageText = title; alert.informativeText = message
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: action); alert.layout()
            let view = alert.window.contentView!
            view.wantsLayer = true; view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        }
        print("Rendered 10 synthetic demo screens to \(directory)")
    }
}
