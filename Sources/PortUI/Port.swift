import SwiftUI
import AppKit
import ServiceManagement

struct Listener: Codable, Identifiable {
    let pid: Int
    let command: String
    let port: Int
    let projectPath: String?
    let displayName: String?
    let suggestedName: String?
    let isWeb: Bool?
    let health: Health?
    let healthPath: String?
    let url: String?
    var id: String { "\(pid)-\(port)" }
}
struct Service: Codable, Identifiable {
    let id, name, group, hostname, status: String
    let projectPath: String?
    let port: Int
    let health: Health?
    let healthPath: String?
    let url: String?
    let startScript: String?
    let iconUrl: String?
    let healthUrl: String?
    let accepted: Bool
    let processes: [Listener]
    let domainReady: Bool?
}
struct Snapshot: Codable {
    let apps: [Service]
    let discovered: [Listener]
    let proxyPort: Int?
    let proxyError: String?
    let domainRoutingReady: Bool?
}
struct Connection: Codable { let controlPort: Int }
@MainActor final class Store: ObservableObject {
    var demo = false
    @Published var snapshot: Snapshot?
    @Published var error: String?
    @Published var busy = false
    @Published var search = ""
    @Published var launchAtLogin = false
    // Set positions (slot index) per item, persisted for apps; unmapped rows are session-only.
    @Published var appOrder: [String: Int] = [:]
    @Published var sessionOrder: [String: Int] = [:]
    var combinedOrder: [String: Int] { appOrder.merging(sessionOrder) { current, _ in current } }
    init() { loadOrder() }
    struct OrderedRow<T> { let item: T; let slot: Int }
    func loadOrder() {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("order.json")),
              let stored = try? JSONDecoder().decode([String: Int].self, from: data) else { appOrder = [:]; return }
        appOrder = stored.filter { $0.value >= 0 }
    }
    func saveOrder() {
        let file = support.appendingPathComponent("order.json")
        let temporary = support.appendingPathComponent("order.json.tmp")
        do {
            try JSONEncoder().encode(appOrder).write(to: temporary)
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch { self.error = error.localizedDescription }
    }
    func pruneOrder() {
        guard !demo else { return }
        let live = Set((snapshot?.apps.map(\.id) ?? []))
        let kept = appOrder.filter { live.contains($0.key) }
        if kept.count != appOrder.count { appOrder = kept; saveOrder() }
    }
    // Pinned items keep their stored slot; everything else fills the free slots in current order.
    func orderedRows<T>(_ items: [T], key: (T) -> String, pin: [String: Int]) -> [OrderedRow<T>] {
        let count = items.count
        guard !pin.isEmpty else { return (0..<count).map { OrderedRow(item: items[$0], slot: $0) } }
        var slots = [OrderedRow<T>?](repeating: nil, count: count)
        for item in items { if let pos = pin[key(item)], pos < count, slots[pos] == nil { slots[pos] = OrderedRow(item: item, slot: pos) } }
        let placed = Set(slots.compactMap { $0.map { key($0.item) } })
        var remaining = items.filter { !placed.contains(key($0)) }.makeIterator()
        var rows: [OrderedRow<T>] = []
        for index in 0..<count {
            if let occupied = slots[index] { rows.append(occupied) }
            else if let item = remaining.next() { rows.append(OrderedRow(item: item, slot: index)) }
        }
        return rows
    }
    func setAppOrder(_ app: Service, _ slot: Int) {
        appOrder[app.id] = slot
        if !demo { saveOrder() }
    }
    func moveRow<T>(_ items: [T], key: (T) -> String, id: String, step: Int, pin: [String: Int], set: (String, Int) -> Void) {
        let rendered = orderedRows(items, key: key, pin: pin)
        guard let current = rendered.firstIndex(where: { key($0.item) == id }) else { return }
        let target = current + step
        guard rendered.indices.contains(target) else { return }
        // Adjacent swap: the neighbor takes my slot, I take the neighbor's slot. No dead clicks —
        // every row can always move while it has a neighbor in that direction.
        set(key(rendered[target].item), rendered[current].slot)
        set(id, rendered[target].slot)
    }
    func moveApp(_ app: Service, _ step: Int) {
        guard let apps = snapshot?.apps else { return }
        moveRow(apps, key: \.id, id: app.id, step: step, pin: combinedOrder) { key, slot in
            if let moved = apps.first(where: { $0.id == key }) { setAppOrder(moved, slot) }
        }
    }
    func moveListener(_ listener: Listener, _ step: Int) {
        guard let listeners = snapshot?.discovered else { return }
        moveRow(listeners, key: { String($0.port) }, id: String(listener.port), step: step, pin: combinedOrder) { key, slot in
            sessionOrder[key] = slot
        }
    }
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Port")
    func request(_ endpoint: String, body: [String: Any]? = nil) async throws -> Data {
        if demo { throw NSError(domain:"PokoDemo",code:1,userInfo:[NSLocalizedDescriptionKey:"Demo mode does not execute actions"]) }
        let connection = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: support.appendingPathComponent("connection.json")))
        let token = try String(contentsOf: support.appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(connection.controlPort)/v1/\(endpoint)")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"] ?? "Server request failed"
            throw NSError(domain: "Port", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }
    func refresh() async {
        guard !demo, !busy else { return }
        busy = true; defer { busy = false }
        do { snapshot = try JSONDecoder().decode(Snapshot.self, from: await request("status")); error = nil; pruneOrder() }
        catch { self.error = error.localizedDescription; snapshot = nil }
        refreshLaunchState()
    }
    // Login-item state straight from the system, refreshed on every status poll.
    func refreshLaunchState() {
        if demo { launchAtLogin = true; return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
    func setLaunchAtLogin(_ on: Bool) {
        guard !demo else { launchAtLogin = on; return }
        guard on == false || Bundle.main.bundlePath.hasSuffix(".app") else {
            // SMAppService can only register a bundled app; a bare debug binary rejects with "invalid argument".
            error = "Run on login needs the packaged Poko app. Build with scripts/build.sh, then install with scripts/install.sh."
            return
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch { self.error = error.localizedDescription }
        refreshLaunchState()
    }
    func mutate(_ endpoint: String, _ body: [String: Any]) async -> Bool {
        do { _ = try await request(endpoint, body: body); await refresh(); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func add(name: String, group: String, folder: String, port: Int?, url: String, healthUrl: String, iconUrl: String, startScript: String) async -> Bool {
        do {
            var body: [String: Any] = ["name": name]
            if !group.isEmpty { body["group"] = group }
            if !folder.isEmpty { body["projectPath"] = folder }
            if let port { body["port"] = port }
            let data = try await request("request", body: body)
            let app = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let id = app["id"] as! String
            if await mutate("accept", ["id": id]) {
                var settings: [String: Any] = ["id": id]
                if !url.isEmpty { settings["url"] = url }
                if !healthUrl.isEmpty { settings["healthUrl"] = healthUrl }
                if !iconUrl.isEmpty { settings["iconUrl"] = iconUrl }
                if !startScript.isEmpty { settings["startScript"] = startScript }
                if settings.count > 1 { return await mutate("configure", settings) }
                return true
            }
            return false
        } catch { self.error = error.localizedDescription; return false }
    }
    func setupDomains() { runDomainScript(enable: true) }
    func disableDomains() { runDomainScript(enable: false) }
    private func runDomainScript(enable: Bool) {
        guard !demo else { return }
        let runtime=support.appendingPathComponent("runtime")
        Task {
            let result: String? = await Task.detached {
                let temp=FileManager.default.temporaryDirectory.appendingPathComponent("port-domains-" + UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
                    defer { try? FileManager.default.removeItem(at:temp) }
                    for file in ["setup-domains.py","domain-router.py"] { try FileManager.default.copyItem(at:runtime.appendingPathComponent(file),to:temp.appendingPathComponent(file)) }
                    func quote(_ value:String)->String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
                    let args = enable
                        ? quote(temp.appendingPathComponent("domain-router.py").path) + " " + quote(runtime.deletingLastPathComponent().path) + " " + String(getuid())
                        : "--disable " + String(getuid())
                    let command="/usr/bin/python3 " + quote(temp.appendingPathComponent("setup-domains.py").path) + " " + args
                    let escaped=command.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
                    let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/bin/osascript");task.arguments=["-e","do shell script \"" + escaped + "\" with administrator privileges"]
                    let pipe=Pipe();task.standardError=pipe;try task.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
                    return task.terminationStatus == 0 ? nil : String(data:data,encoding:.utf8)
                } catch { return error.localizedDescription }
            }.value
            if let result { error=result } else { try? await Task.sleep(nanoseconds: enable ? 2_000_000_000 : 300_000_000); await refresh() }
        }
    }
    func start() {
        guard !demo else { return }
        let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Poko Server.app")
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.error = error.localizedDescription } }
        }
        Task { try? await Task.sleep(nanoseconds: 1_000_000_000); await refresh() }
    }
}
func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
func browse(_ text: String?) { if let text, let url = URL(string: text) { NSWorkspace.shared.open(url) } }
func openFolder(_ path: String?) { if let path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
@MainActor func pointCursor(_ hovering: Bool, enabled: Bool = true) { if !enabled { return }; if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() } }

// Slug the same way the daemon does, so live validation matches the server's rules exactly.
func slug(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        .replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
    return normalized.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil ? normalized : nil
}
enum Availability: Equatable {
    case idle, checking
    case valid(host: String, port: Int)
    case problem(String)
}
// POSIX bind probe mirroring the daemon's freePort check across both loopback stacks.
func portBindable(_ port: Int) -> Bool {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    for host in ["127.0.0.1", "::1"] {
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let address = info else { return false }
        defer { freeaddrinfo(address) }
        var bound = false
        var current: UnsafeMutablePointer<addrinfo>? = address
        while let entry = current {
            let descriptor = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            if descriptor >= 0 { bound = bind(descriptor, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0; close(descriptor) }
            current = entry.pointee.ai_next
        }
        if !bound { return false }
    }
    return true
}
func freePort(_ port: Int) async -> Bool { await Task.detached { portBindable(port) }.value }

@main struct PortApp: App {
    @NSApplicationDelegateAdaptor(PortDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
@MainActor final class PortDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    let popover=NSPopover()
    let store=Store()
    static func createMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            let xL: CGFloat = 2.7
            let xR: CGFloat = 15.3
            let y1: CGFloat = 13.5
            let y2: CGFloat = 8.0
            let y3: CGFloat = 2.5

            let dotR: CGFloat = 1.95
            let smallDotR: CGFloat = 0.75

            func drawConnection(from: NSPoint, to: NSPoint, alpha: CGFloat) {
                let dx = to.x - from.x
                let dy = to.y - from.y
                let dist = sqrt(dx * dx + dy * dy)
                let ux = dx / dist
                let uy = dy / dist

                let startDist = dotR + 1.25
                let endDist = dist - dotR - 1.25
                let span = endDist - startDist

                NSColor.black.withAlphaComponent(alpha).setFill()
                for i in 0..<3 {
                    let d = startDist + (span * CGFloat(i) / 2.0)
                    let cx = from.x + ux * d
                    let cy = from.y + uy * d
                    let r = NSRect(x: cx - smallDotR, y: cy - smallDotR, width: smallDotR * 2, height: smallDotR * 2)
                    NSBezierPath(ovalIn: r).fill()
                }
            }

            drawConnection(from: NSPoint(x: xL, y: y1), to: NSPoint(x: xR, y: y1), alpha: 0.85)
            drawConnection(from: NSPoint(x: xL, y: y2), to: NSPoint(x: xR, y: y3), alpha: 0.85)
            drawConnection(from: NSPoint(x: xL, y: y3), to: NSPoint(x: xR, y: y2), alpha: 0.85)

            NSColor.black.setFill()
            for y in [y1, y2, y3] {
                let r = NSRect(x: xL - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)
                NSBezierPath(ovalIn: r).fill()
            }

            NSColor.black.withAlphaComponent(0.45).setFill()
            for y in [y1, y2, y3] {
                let r = NSRect(x: xR - dotR, y: y - dotR, width: dotR * 2, height: dotR * 2)
                NSBezierPath(ovalIn: r).fill()
            }

            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Poko"
        return img
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index=CommandLine.arguments.firstIndex(of:"--demo-screenshots"), CommandLine.arguments.count > index+1 {
            do { try DemoScreenshots.render(to:CommandLine.arguments[index+1]); exit(0) } catch { fputs("Demo render failed: \(error)\n",stderr); exit(1) }
        }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.title=""
        item.button?.image=Self.createMenuBarIcon()
        item.button?.target=self;item.button?.action=#selector(toggle)
        popover.behavior = .transient
        popover.contentSize=NSSize(width:480,height:620)
        popover.contentViewController=NSHostingController(rootView:Panel(store:store).frame(height:620))
    }
    @objc func toggle() {
        if popover.isShown { popover.performClose(nil) }
        else if let button=item.button { popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY);popover.contentViewController?.view.window?.makeKey() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
}
struct Health: Codable { let status: String; let path: String?; let statusCode: Int? }
struct Panel: View {
    @ObservedObject var store: Store
    @State private var adding=false
    @State private var agents=false
    @State private var showAllPorts=false
    @State private var stopping: Listener?
    @State private var editing: EditorTarget?
    @State private var rowFrames: [String: CGRect] = [:]
    @State private var viewportHeight: CGFloat = 0
    @State private var pinnedMove: PinnedMove?
    @State private var overlayEntered = false
    private struct PinnedMove: Equatable {
        enum Kind: Equatable { case app, listener }
        let id: String
        let kind: Kind
        let frame: CGRect
    }
    private struct PinnedMoveInfo {
        let name: String
        let position: Int
        let canMoveUp: Bool
        let canMoveDown: Bool
        let move: (Int) -> Void
    }
    private func clearPinnedMove() {
        pinnedMove = nil
        overlayEntered = false
    }
    private func keepRowVisible(_ proxy: ScrollViewProxy, id: String) {
        DispatchQueue.main.async {
            guard let frame = rowFrames[id], viewportHeight > 0 else { return }
            if frame.minY < 0 { proxy.scrollTo(id, anchor: .top) }
            else if frame.maxY > viewportHeight { proxy.scrollTo(id, anchor: .bottom) }
        }
    }
    private func startOrContinueMove(_ proxy: ScrollViewProxy, id: String, kind: PinnedMove.Kind, commit: () -> Void) {
        if pinnedMove?.id != id, let frame = rowFrames[id] {
            overlayEntered = false
            pinnedMove = PinnedMove(id: id, kind: kind, frame: frame)
        }
        commit()
        keepRowVisible(proxy, id: id)
    }
    private func pinnedInfo(for pinned: PinnedMove) -> PinnedMoveInfo? {
        switch pinned.kind {
        case .app:
            let rows = matchingApps()
            guard let index = rows.firstIndex(where: { $0.item.id == pinned.id }) else { return nil }
            let app = rows[index].item
            return PinnedMoveInfo(
                name: app.name,
                position: index + 1,
                canMoveUp: index > 0,
                canMoveDown: index < rows.count - 1,
                move: { store.moveApp(app, $0) }
            )
        case .listener:
            let rows = matchingListeners()
            guard let index = rows.firstIndex(where: { $0.item.id == pinned.id }) else { return nil }
            let listener = rows[index].item
            return PinnedMoveInfo(
                name: listener.displayName ?? listener.command,
                position: index + 1,
                canMoveUp: index > 0,
                canMoveDown: index < rows.count - 1,
                move: { store.moveListener(listener, $0) }
            )
        }
    }
    // Matched + sorted rows for the list, split out to keep Panel's body type-checkable.
    private func matchingApps() -> [Store.OrderedRow<Service>] {
        store.orderedRows(store.snapshot?.apps ?? [], key: \.id, pin: store.combinedOrder).filter { row in
            store.search.isEmpty || "\(row.item.name) \(row.item.port) \(row.item.projectPath ?? "")".localizedCaseInsensitiveContains(store.search)
        }
    }
    private func matchingListeners() -> [Store.OrderedRow<Listener>] {
        store.orderedRows(store.snapshot?.discovered ?? [], key: { String($0.port) }, pin: store.combinedOrder).filter { row in
            (showAllPorts || row.item.isWeb == true) && (store.search.isEmpty || "\(row.item.displayName ?? row.item.command) \(row.item.port) \(row.item.projectPath ?? "")".localizedCaseInsensitiveContains(store.search))
        }
    }
    @ViewBuilder private func mappedRows(_ proxy: ScrollViewProxy) -> some View {
        let rows = matchingApps()
        ForEach(Array(rows.enumerated()), id: \.element.item.id) { index, row in
            AppRow(name:row.item.name,port:row.item.port,url:row.item.url,folder:row.item.projectPath,health:row.item.health,iconUrl:row.item.iconUrl,hostname:row.item.hostname,domainReady:row.item.domainReady ?? (store.snapshot?.domainRoutingReady == true),running:!row.item.processes.isEmpty,canStart:!(row.item.startScript ?? "").isEmpty,
                canMoveUp: index > 0, canMoveDown: index < rows.count - 1,
                isMoving: pinnedMove?.id == row.item.id,
                suppressHoverArrows: pinnedMove != nil,
                onHoverChange: { hovering in if hovering && pinnedMove != nil && !overlayEntered { clearPinnedMove() } },
                edit:{ clearPinnedMove(); editing = .mapped(row.item) },
                action:{ clearPinnedMove(); if let process=row.item.processes.first { stopping=process } else { Task { _ = await store.mutate("start",["id":row.item.id]) } } },
                move:{ step in startOrContinueMove(proxy, id: row.item.id, kind: .app) { store.moveApp(row.item,step) } },
                enableDomains: { clearPinnedMove(); store.setupDomains() })
                .trackFrame { rowFrames[row.item.id] = $0 }
            Divider().padding(.horizontal,14)
        }
    }
    @ViewBuilder private func unmappedRows(_ proxy: ScrollViewProxy) -> some View {
        let rows = matchingListeners()
        ForEach(Array(rows.enumerated()), id: \.element.item.id) { index, row in
            AppRow(name:row.item.displayName ?? row.item.command,port:row.item.port,url:nil,folder:row.item.projectPath,health:row.item.health,iconUrl:nil,hostname:nil,domainReady:true,running:true,canStart:false,
                canMoveUp: index > 0, canMoveDown: index < rows.count - 1,
                isMoving: pinnedMove?.id == row.item.id,
                suppressHoverArrows: pinnedMove != nil,
                onHoverChange: { hovering in if hovering && pinnedMove != nil && !overlayEntered { clearPinnedMove() } },
                edit:{ clearPinnedMove(); editing = .unmapped(row.item) },
                action:{ clearPinnedMove(); stopping=row.item },
                move:{ step in startOrContinueMove(proxy, id: row.item.id, kind: .listener) { store.moveListener(row.item,step) } },
                enableDomains: {})
                .trackFrame { rowFrames[row.item.id] = $0 }
            Divider().padding(.horizontal,14)
        }
    }
    @ViewBuilder private func pinnedOverlay(_ proxy: ScrollViewProxy) -> some View {
        if let pinned = pinnedMove, let info = pinnedInfo(for: pinned) {
            HStack(spacing: 3) {
                MoveArrowButtons(name: info.name, canMoveUp: info.canMoveUp, canMoveDown: info.canMoveDown) { step in
                    info.move(step)
                    keepRowVisible(proxy, id: pinned.id)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
                Text("#\(info.position)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            }
            .frame(height: pinned.frame.height, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { overlayEntered = true }
                else if overlayEntered { clearPinnedMove() }
            }
            .offset(x: 0, y: pinned.frame.minY)
        }
    }
    var body: some View {
        ZStack {
            mainContent
                .allowsHitTesting(!agents)
            if agents {
                Color.black.opacity(0.28)
                    .onTapGesture { agents = false }
                AgentSetup(onClose: { agents = false })
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
                    .padding(12)
            }
        }
        .frame(width: 480, height: 620)
        .valueChange(of: agents) { open in if open { NSApp.keyWindow?.makeFirstResponder(nil) } }
        .task { store.refreshLaunchState(); while !Task.isCancelled { await store.refresh(); try? await Task.sleep(nanoseconds:5_000_000_000) } }
        .sheet(item:$editing) { AppSettings(store:store,target:$0) }
        .sheet(isPresented:$adding) { AddForm(store:store) }
        .alert("Stop process?",isPresented:Binding(get:{stopping != nil},set:{if !$0 { stopping=nil }})) {
            Button("Cancel",role:.cancel) { stopping=nil }
            Button("Shut down",role:.destructive) { if let app=stopping { Task { _ = await store.mutate("shutdown",["port":app.port,"pid":app.pid]) } };stopping=nil }
        } message: { Text("Sends SIGTERM to this process. All apps and ports served by the same process will stop.") }
    }
    private var mainContent: some View {
        VStack(spacing:10) {
            HStack {
                Text("Poko").font(.headline)
                Text(store.snapshot == nil ? "Offline" : store.snapshot?.domainRoutingReady == true ? "Domains ready" : "Domain setup needed").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { adding=true } label: { Image(systemName:"plus") }.buttonStyle(QuietButtonStyle()).help("Add app").accessibilityLabel("Add app")
                Button { Task { await store.refresh() } } label: { Image(systemName:"arrow.clockwise") }.buttonStyle(QuietButtonStyle()).help("Refresh").accessibilityLabel("Refresh")
                Button { NSApp.keyWindow?.makeFirstResponder(nil); agents=true } label: { Image(systemName:"puzzlepiece.extension") }.buttonStyle(QuietButtonStyle()).help("Connect agents").accessibilityLabel("Connect agents")
            }.padding(.horizontal,14).padding(.top,16)
            if store.snapshot?.domainRoutingReady != true {
                HStack(spacing:6) {
                    Image(systemName:"exclamationmark.triangle.fill").font(.system(size:11)).foregroundStyle(.orange)
                    Text("Enable http://app-name domains").font(.caption)
                    Spacer()
                    Button("Enable") { store.setupDomains() }.buttonStyle(QuietButtonStyle())
                }.padding(.horizontal,14)
            }
            TextField("Search apps, ports, folders",text:$store.search).textFieldStyle(.roundedBorder).quietFocus().padding(.horizontal,14)
            if let error=store.error {
                HStack { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2); if store.snapshot == nil { Button("Start") { store.start() }.buttonStyle(QuietButtonStyle()) } }.padding(.horizontal,14)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:2) {
                        mappedRows(proxy)
                        HStack { Text("UNMAPPED").font(.system(size:9,weight:.semibold)); Spacer() }.foregroundStyle(.secondary).padding(.horizontal,14).padding(.top,4)
                        unmappedRows(proxy)
                    }
                }.coordinateSpace(name:"rows")
                .overlay(alignment: .topLeading) { pinnedOverlay(proxy) }
                .onHover { if !$0 { clearPinnedMove() } }
                .frame(minHeight:300,maxHeight:.infinity)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { viewportHeight = geo.size.height }
                        .valueChange(of: geo.size.height) { viewportHeight = $0 }
                })
                .valueChange(of: store.search) { _ in clearPinnedMove() }
                .valueChange(of: showAllPorts) { _ in clearPinnedMove() }
            }
            HStack(spacing:10) {
                Toggle("All TCP",isOn:$showAllPorts).toggleStyle(.checkbox)
                Toggle("Run on login",isOn:Binding(get:{ store.launchAtLogin }, set:{ store.setLaunchAtLogin($0) })).toggleStyle(.checkbox)
                    .help("Launch the Poko menu bar app when you log in. The Poko Server daemon has its own LaunchAgent and always starts at login.")
                Toggle("Custom domains",isOn:Binding(get:{ store.snapshot?.domainRoutingReady == true }, set:{ enable in if enable { store.setupDomains() } else { store.disableDomains() } })).toggleStyle(.checkbox)
                    .disabled(store.snapshot == nil)
                    .help("Enable or disable http://app-name local domain routing (requires administrator privileges).")
                Spacer()
                Button { NSApp.terminate(nil) } label: { Label("Quit",systemImage:"power") }.buttonStyle(QuietButtonStyle())
            }.font(.system(size:10)).padding(.horizontal,14).padding(.vertical,8)
                .background(.primary.opacity(0.045))
                .overlay(alignment:.top) { Rectangle().fill(.primary.opacity(0.08)).frame(height:1) }
        }.quietFocus().frame(width:480).background(.background)
    }
}
// Plain controls keep the compact panel free of automatic blue focus borders.
extension View {
    @ViewBuilder func quietFocus() -> some View {
        if #available(macOS 14.0,*) { self.focusEffectDisabled() } else { self }
    }
}
struct QuietButtonStyle: ButtonStyle {
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 4
    var pointsCursor: Bool = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        QuietHover(configuration: configuration, horizontalPadding: horizontalPadding, verticalPadding: verticalPadding, pointsCursor: pointsCursor, enabled: enabled).quietFocus()
    }
}
private struct QuietHover: View {
    let configuration: ButtonStyleConfiguration
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let pointsCursor: Bool
    let enabled: Bool
    @State private var hovered=false
    var body: some View {
        configuration.label
            .padding(.horizontal,horizontalPadding).padding(.vertical,verticalPadding)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0),in:RoundedRectangle(cornerRadius:5))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering in hovered=hovering; if pointsCursor { pointCursor(hovering, enabled:enabled) } }
    }
}
struct SurfaceButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        SurfaceHover(configuration: configuration, enabled: enabled).quietFocus()
    }
}
private struct SurfaceHover: View {
    let configuration: ButtonStyleConfiguration
    let enabled: Bool
    @State private var hovered=false
    var body: some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal,12).padding(.vertical,5)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:6))
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(.primary.opacity(configuration.isPressed ? 0.3 : hovered ? 0.2 : 0.14)))
            .overlay(RoundedRectangle(cornerRadius:6).fill(.primary.opacity(configuration.isPressed ? 0.08 : hovered ? 0.04 : 0)))
            .shadow(color:.black.opacity(0.05),radius:1,y:1)
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering in hovered=hovering; pointCursor(hovering, enabled:enabled) }
    }
}
struct MoveArrowButtons: View {
    let name: String
    let canMoveUp: Bool
    let canMoveDown: Bool
    let move: (Int) -> Void
    var body: some View {
        VStack(spacing:0) {
            Button { move(-1) } label: {
                Image(systemName:"chevron.up").font(.system(size:11,weight:.semibold)).frame(width:18,height:17)
            }
            .disabled(!canMoveUp)
            .help("Move app up").accessibilityLabel("Move " + name + " up")
            Button { move(1) } label: {
                Image(systemName:"chevron.down").font(.system(size:11,weight:.semibold)).frame(width:18,height:17)
            }
            .disabled(!canMoveDown)
            .help("Move app down").accessibilityLabel("Move " + name + " down")
        }
        .buttonStyle(QuietButtonStyle(horizontalPadding:2, verticalPadding:2))
        .foregroundStyle(.secondary)
    }
}
struct AppRow: View {
    let name: String
    let port: Int
    let url: String?
    let folder: String?
    let health: Health?
    let iconUrl: String?
    let hostname: String?
    let domainReady: Bool
    let running: Bool
    let canStart: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let isMoving: Bool
    let suppressHoverArrows: Bool
    let onHoverChange: (Bool) -> Void
    let edit: () -> Void
    let action: () -> Void
    let move: (Int) -> Void
    let enableDomains: () -> Void
    @State private var hovered = false
    @State private var domainPrompt = false
    var statusColor: Color {
        if !running { return .secondary }
        return health?.status == "healthy" ? .green : .orange
    }
    var statusDescription: String {
        running ? "Running · " + (health?.status ?? "Health unknown") : "Stopped"
    }
    var statusIndicator: some View {
        Image(systemName:running ? "play.fill" : "pause.fill").font(.system(size:9))
            .foregroundStyle(statusColor).help(statusDescription).accessibilityLabel(statusDescription)
    }
    var directUrl: String { "http://localhost:" + String(port) }
    // Links such as http://studio-web only resolve while Poko's domain helper is running.
    func isShortDomain(_ destination: String) -> Bool {
        guard let target = URL(string: destination)?.host?.lowercased(),
              let hostname = hostname?.lowercased() else { return false }
        return target == hostname
    }
    func open(_ destination: String) {
        if isShortDomain(destination) && !domainReady { domainPrompt = true; return }
        browse(destination)
    }
    func address(_ label: String, destination: String, value: String) -> some View {
        let blocked = isShortDomain(destination) && !domainReady
        return HStack(spacing:1.5) {
            Button { open(destination) } label: { Text(label).lineLimit(1).truncationMode(.middle) }
                .foregroundStyle(blocked ? Color.secondary : Color.teal)
                .help(blocked ? "Enable local domains to open " + destination : "Open " + destination)
            Button { copy(value) } label: { Image(systemName:"doc.on.doc").font(.system(size:9)) }
                .foregroundStyle(.secondary).help("Copy " + value).accessibilityLabel("Copy " + value)
        }.buttonStyle(QuietButtonStyle(horizontalPadding:1.5))
    }
    var showMoveArrows: Bool { hovered && !suppressHoverArrows && (canMoveUp || canMoveDown) }
    var contentRow: some View {
        HStack(spacing:0) {
            MoveArrowButtons(name:name, canMoveUp:canMoveUp, canMoveDown:canMoveDown, move:move)
                .frame(maxHeight:.infinity, alignment:.center)
                .opacity(showMoveArrows ? 1 : 0)
                .allowsHitTesting(showMoveArrows)
            HStack(spacing:10) {
            VStack(alignment:.leading,spacing:5) {
                HStack(spacing:5) {
                    statusIndicator
                    if let iconUrl, let icon=URL(string:iconUrl) {
                        AsyncImage(url:icon) { phase in
                            if let image=phase.image { image.resizable().scaledToFit().frame(width:14,height:14) }
                        }
                    }
                    Text(name).font(.system(size:12,weight:.medium)).lineLimit(1).help(name).layoutPriority(1)
                    Spacer(minLength:10)
                    if let url {
                        address(url.replacingOccurrences(of:"http://",with:""),destination:url,value:url)
                        Image(systemName:"arrow.left").font(.system(size:9)).foregroundStyle(.tertiary)
                    }
                    address(String(port),destination:directUrl,value:directUrl).monospacedDigit()
                }.font(.system(size:11))
                HStack(spacing:5) {
                    Button { openFolder(folder) } label: {
                        HStack(spacing:5) {
                            Image(systemName:"folder").font(.system(size:10))
                            Text(folder ?? "Folder unavailable").lineLimit(1).truncationMode(.middle)
                        }
                    }.buttonStyle(QuietButtonStyle(horizontalPadding:2))
                     .foregroundStyle(.secondary)
                     .disabled(folder == nil)
                     .help(folder != nil ? "Open " + folder! + " in Finder" : "Folder unavailable")
                     .accessibilityLabel(folder != nil ? "Open folder " + folder! : "Folder unavailable")
                }.font(.system(size:10)).foregroundStyle(.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
            VStack(spacing:0) {
                Button(action:edit) { Image(systemName:"pencil").frame(width:18,height:16) }
                    .help("Edit app").accessibilityLabel("Edit " + name)
                if running || canStart {
                    Button(action:action) { Image(systemName:running ? "power" : "play.fill").frame(width:18,height:16) }
                        .foregroundStyle(running ? .red : .green)
                        .help(running ? "Shut down app" : "Start app").accessibilityLabel((running ? "Shut down " : "Start ") + name)
                }
            }.frame(height:48,alignment:.top).padding(.horizontal,4).padding(.vertical,2)
                .overlay(alignment:.leading) { Rectangle().fill(.primary.opacity(0.1)).frame(width:1) }
            }.buttonStyle(QuietButtonStyle())
        }
    }
    var body: some View {
        contentRow
            .padding(.trailing,6).padding(.vertical,5)
            .background(isMoving ? Color.teal.opacity(0.08) : Color.clear)
            .overlay(alignment:.leading) {
                if isMoving { Rectangle().fill(Color.teal).frame(width:2) }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                hovered = hovering
                onHoverChange(hovering)
            }
            .alert("Local app domains are off", isPresented: $domainPrompt) {
                Button("Cancel", role: .cancel) {}
                Button("Enable Domains") { enableDomains() }
            } message: {
                Text("http://\(hostname ?? "app-name") only opens while Poko's local domain helper is running. Enabling it asks for your administrator password once, then keeps short app links working.")
            }
    }
}
// Reports the view's frame in the panel's scroll coordinate space (used to pin moved rows).
extension View {
    @ViewBuilder func valueChange<V: Equatable>(of value: V, action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0,*) { self.onChange(of: value) { _, latest in action(latest) } }
        else { self.onChange(of: value) { latest in action(latest) } }
    }
    func trackFrame(_ onChange: @escaping (CGRect) -> Void) -> some View {
        background(GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.frame(in: .named("rows"))) }
                .valueChange(of: geo.frame(in: .named("rows"))) { onChange($0) }
        })
    }
}
enum EditorTarget: Identifiable {
    case mapped(Service)
    case unmapped(Listener)
    var id: String { switch self { case .mapped(let app): return app.id; case .unmapped(let listener): return listener.id } }
    var app: Service? { if case .mapped(let app)=self { return app }; return nil }
    var listener: Listener? { if case .unmapped(let listener)=self { return listener }; return nil }
    var name: String { app?.name ?? listener?.displayName ?? listener?.command ?? "App" }
    var port: Int { app?.port ?? listener!.port }
    var initialUrl: String { app?.url ?? "http://" + (listener?.suggestedName ?? "app-\(port)") }
    var initialHealth: String { app?.healthUrl ?? app?.healthPath ?? listener?.healthPath ?? "/" }
    var initialIcon: String {
        guard let app else { return "" }
        return app.iconUrl == "http://" + app.hostname + "/favicon.ico" ? "" : app.iconUrl ?? ""
    }
    var initialFolder: String { app?.projectPath ?? listener?.projectPath ?? "" }
}
struct AddForm: View {
    @ObservedObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var name=""
    @State var group=""
    @State var folder=""
    @State var url=""
    @State var healthUrl=""
    @State var iconUrl=""
    @State var startScript=""
    @State var portText=""
    @State private var urlEdited=false
    @State private var nameEditing=false
    @State private var portEdited=false
    @State private var lastAutoPort: Int?
    @State var saving=false
    @State var availability: Availability = .idle
    var slugName: String? { slug(name) }
    var slugGroup: String? { slug(group) }
    var checkKey: String { "\(slugName ?? "")|\(url)|\(slugGroup ?? "")|\(portText)" }
    var ready: Bool { if case .valid = availability, !saving { return true }; return false }

    var nameIndicator: some View {
        Group {
            if case .valid = availability {
                Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).padding(.trailing,6).help("Name is available").accessibilityLabel("Name is available")
            } else if case .problem = availability {
                Image(systemName:"xmark.circle.fill").foregroundStyle(.red).padding(.trailing,6).help("Name is unavailable").accessibilityLabel("Name is unavailable")
            }
        }
    }
    @ViewBuilder var availabilityLine: some View {
        switch availability {
        case .idle: EmptyView()
        case .checking:
            HStack(spacing:5) { ProgressView().controlSize(.mini); Text("Checking name and ports…").foregroundStyle(.secondary) }.font(.caption)
        case .valid(let host, let port):
            HStack(spacing:5) {
                Image(systemName:"checkmark.circle.fill").foregroundStyle(.green)
                Text("http://\(host) is free · port \(port) assigned on add").foregroundStyle(.secondary)
            }.font(.caption)
        case .problem(let message):
            HStack(alignment:.top,spacing:5) {
                Image(systemName:"xmark.octagon.fill").foregroundStyle(.red)
                Text(message).foregroundStyle(.red).lineLimit(3).fixedSize(horizontal:false,vertical:true).layoutPriority(1).multilineTextAlignment(.leading)
            }.font(.caption)
        }
    }
    func urlProblem() -> Availability? {
        guard !url.isEmpty else { return nil }
        guard let address=URL(string:url), address.scheme=="http", address.port==nil, address.user==nil, address.password==nil,
              let host=address.host, host != "localhost", host != "broadcasthost", slug(host)==host else {
            return .problem("Use a plain local URL such as http://\(slugName ?? "app-name") — no port, no credentials")
        }
        if let mapped=store.snapshot?.apps.first(where:{ $0.hostname == host }) {
            return .problem("That URL is already mapped — \(mapped.name) (port \(mapped.port)) is using http://\(host)")
        }
        return nil
    }
    func check() async {
        if !store.demo {
            try? await Task.sleep(nanoseconds:250_000_000)
            guard !Task.isCancelled else { return }
        }
        await evaluate()
    }
    func checkPort(_ explicit: Int) async -> Availability? {
        let snapshot=store.snapshot
        if let proxy=snapshot?.proxyPort, proxy != 0, explicit==proxy { return .problem("Port \(explicit) is reserved for the Poko proxy. Choose another.") }
        if let taken=snapshot?.apps.first(where:{ $0.port == explicit }) {
            return .problem("This port is already registered — \(taken.name) is using port \(explicit).")
        }
        if let listener=snapshot?.discovered.first(where:{ $0.port == explicit }) {
            return .problem("This port is used — \(listener.displayName ?? listener.command) (PID \(listener.pid)) is listening on it.")
        }
        if !(await freePort(explicit)) { return .problem("This port is in use. Choose another free port.") }
        return nil
    }
    func evaluate() async {
        guard let snapshot=store.snapshot else { availability = .idle; return }
        guard let slugName else {
            availability = name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? .idle : .problem("Use 1–63 letters, numbers and hyphens. Spaces and underscores become hyphens.")
            return
        }
        if let taken=snapshot.apps.first(where:{ $0.name == slugName || $0.hostname == slugName }) {
            availability = .problem("This name is already assigned — \(taken.name) (port \(taken.port)) is using http://\(slugName)")
            return
        }
        if let failed=urlProblem() { availability=failed; return }
        let host=URL(string:url)?.host ?? slugName
        let portInput=portText.trimmingCharacters(in:.whitespacesAndNewlines)
        if !portInput.isEmpty {
            guard let explicit=Int(portInput), explicit >= 1024, explicit <= 65535 else {
                availability = .problem("Port must be a number between 1024 and 65535.")
                return
            }
            if let failed=await checkPort(explicit) { availability=failed; return }
            availability = .valid(host: host, port: explicit)
            return
        }
        guard let slugGroup=group.isEmpty ? slugName : slug(group) else {
            availability = .problem("Group needs letters, numbers and hyphens too.")
            return
        }
        var bases=[String:Int]()
        for app in snapshot.apps { bases[app.group]=min(bases[app.group] ?? Int.max, app.port) }
        let base: Int
        if let existing=bases[slugGroup] { base=existing }
        else { var candidate=4100; while bases.values.contains(candidate) { candidate+=20 }; base=candidate }
        let takenPorts=Set(snapshot.apps.map(\.port)).union(snapshot.discovered.map(\.port))
        for port in base..<base+20 where !takenPorts.contains(port) {
            if await freePort(port) {
                lastAutoPort=port
                if !portEdited { portText=String(port) }
                availability = .valid(host: host, port: port)
                return
            }
        }
        availability = .problem("All 20 ports of this group are taken. Release an unused app or pick another group.")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Assign port").font(.headline).padding(.bottom,6)
            Text("Name").font(.caption)
            TextField("App name · payment-api",text:$name){ editing in nameEditing = editing }
                .autocorrectionDisabled()
                .overlay(alignment:.trailing) { nameIndicator }
            availabilityLine
            HStack(spacing:10) {
                VStack(alignment:.leading,spacing:10) {
                    Text("Port").font(.caption)
                    TextField("Auto",text:$portText).monospacedDigit()
                        .overlay(alignment:.trailing) { nameIndicator }
                }
                VStack(alignment:.leading,spacing:10) {
                    Text("Group").font(.caption)
                    TextField("payment (optional)",text:$group).autocorrectionDisabled()
                }
            }
            Text("URL").font(.caption)
            TextField("http://app-name",text:$url)
                .autocorrectionDisabled()
            Text("Health URL").font(.caption)
            TextField("/ — home page by default",text:$healthUrl)
            Text("Icon URL").font(.caption)
            TextField("Default: /favicon.ico",text:$iconUrl)
            Button { openFolder(folder) } label: { Text("Project folder").font(.caption) }.buttonStyle(QuietButtonStyle()).disabled(folder.isEmpty)
                .help("Open this folder in Finder")
            HStack { TextField("Optional · /absolute/project/folder",text:$folder); Button("Choose") {
                let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
                if panel.runModal() == .OK { folder=panel.url?.path ?? "" }
            } }
            Text("Start script").font(.caption)
            TextField("npm run dev",text:$startScript).font(.system(size:11,design:.monospaced))
            if let error=store.error { Text(error).font(.caption).foregroundStyle(.red) }
            Divider().padding(.vertical,6)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button(saving ? "Adding" : "Add app") {
                saving=true;Task { if await store.add(name:slugName ?? name,group:group.trimmingCharacters(in:.whitespaces),folder:folder,port:Int(portText.trimmingCharacters(in:.whitespaces)),url:url,healthUrl:healthUrl,iconUrl:iconUrl,startScript:startScript) { dismiss() };saving=false }
            }.buttonStyle(.borderedProminent).tint(.teal).disabled(!ready) }
        }.buttonStyle(SurfaceButtonStyle()).quietFocus().textFieldStyle(.roundedBorder).padding(20).frame(width:420)
        .onAppear { if !urlEdited, url.isEmpty { url = slugName.map { "http://" + $0 } ?? "" } }
        .onChange(of: name, perform: { _ in if !urlEdited { url = slugName.map { "http://" + $0 } ?? "" } })
        .onChange(of: url, perform: { _ in
            if url != slugName.map({ "http://" + $0 }) ?? "" { urlEdited = true }
            // Empty-name tracking the domain: http://knowledge-base → knowledge-base
            if !nameEditing, let host=URL(string:url.trimmingCharacters(in:.whitespacesAndNewlines))?.host, !host.isEmpty { name = host }
        })
        .onChange(of: portText, perform: { _ in if portText.isEmpty { portEdited=false } else if portText != lastAutoPort.map(String.init) { portEdited=true } })
        .task(id: checkKey) { await check() }
    }
}
struct AgentState: Decodable, Identifiable {
    let id: String
    var name: String?
    var status: String?
    var mcp: String?
    var skill: String?
    var detected: Bool?
}
struct AgentRuntime: Decodable { let node: String }

struct IntegrationButton: View {
    let title: String
    let addTitle: String
    let iconName: String
    let isConfigured: Bool
    var checking: Bool = false
    let working: Bool
    let onAdd: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: {
            if isConfigured {
                onRemove()
            } else {
                onAdd()
            }
        }) {
            ZStack {
                if checking {
                    Text("Checking…")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if isConfigured {
                    if hovering {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.red)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.green)
                            Text(title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.primary)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: iconName)
                            .font(.system(size: 10, weight: .semibold))
                        Text(addTitle)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.primary)
                }
            }
            .frame(width: 78, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(!checking && isConfigured && hovering ? Color.red.opacity(0.14) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        !checking && isConfigured && hovering ? Color.red.opacity(0.4) : (!checking && isConfigured ? Color.green.opacity(0.3) : Color.primary.opacity(0.12)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(working || checking)
        .onHover { h in
            hovering = h
        }
    }
}

struct AgentSetup: View {
    var demo = false
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) var dismiss
    @State private var states: [AgentState] = []
    @State private var loading = true
    @State private var working = false
    @State private var copiedPrompt = false
    @State private var copiedJSON = false
    @State private var copiedSkill = false
    let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Port/runtime")

    // Ordered alphabetically by name (Antigravity, Claude Code, Codex, Cursor, OpenCode)
    let agents = ["antigravity", "claude", "codex", "cursor", "opencode"]

    func agentTitle(_ agent: String) -> String {
        switch agent {
        case "antigravity": return "Antigravity"
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        default: return agent.capitalized
        }
    }

    func run(_ args: [String]) async -> (Int32, String) {
        if demo { return (0, "[]") }
        let directory = runtime
        return await Task.detached {
            do {
                let settings = try JSONDecoder().decode(AgentRuntime.self, from: Data(contentsOf: directory.appendingPathComponent("agent-config.json")))
                let task = Process(); task.executableURL = URL(fileURLWithPath: settings.node)
                task.arguments = [directory.appendingPathComponent("connect-agents.mjs").path] + args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                task.environment = env
                let outPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = FileHandle.nullDevice
                try task.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
            } catch { return (1, error.localizedDescription) }
        }.value
    }

    func refresh() async {
        if states.isEmpty { loading = true }
        defer { loading = false }
        if demo {
            states = agents.map { AgentState(id: $0, name: agentTitle($0), status: "Configured", mcp: "Configured", skill: "Configured", detected: true) }
            return
        }
        let result = await run(["--status"])
        if result.0 == 0,
           let data = result.1.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let decoded = try? JSONDecoder().decode([AgentState].self, from: data) {
            states = decoded
        }
    }

    func toggleMcp(_ agent: String, remove: Bool) {
        working = true
        Task {
            let args = remove ? ["remove", agent] : [agent]
            _ = await run(args)
            await refresh()
            working = false
        }
    }

    func toggleSkill(_ agent: String, remove: Bool) {
        working = true
        Task {
            let args = remove ? ["remove", "skill", agent] : ["skill", agent]
            _ = await run(args)
            await refresh()
            working = false
        }
    }

    func icon(_ agent: String) -> some View {
        Group {
            if let file = Bundle.main.url(forResource: agent, withExtension: "png", subdirectory: "AgentIcons"),
               let image = NSImage(contentsOf: file) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(.gray)
            }
        }.frame(width: 20, height: 20).padding(4)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Connect your agents").font(.title3.bold())
                    Text("Manage MCP servers and Skills for Poko across your AI coding agents.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(QuietButtonStyle())
                .help("Refresh agent status")
            }

            VStack(spacing: 5) {
                ForEach(agents, id: \.self) { agent in
                    let state = states.first { $0.id == agent }
                    let isMcpConfigured = (state?.mcp ?? state?.status) == "Configured"
                    let isSkillConfigured = state?.skill == "Configured"
                    let isDetected = state?.detected ?? true

                    HStack(alignment: .center, spacing: 10) {
                        icon(agent)

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(agentTitle(agent)).font(.subheadline.weight(.semibold))
                            if !isDetected {
                                Text("not detected")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                        }

                        Spacer()

                        HStack(spacing: 6) {
                            IntegrationButton(
                                title: "MCP",
                                addTitle: "Add MCP",
                                iconName: "plus",
                                isConfigured: isMcpConfigured,
                                checking: loading,
                                working: working,
                                onAdd: { toggleMcp(agent, remove: false) },
                                onRemove: { toggleMcp(agent, remove: true) }
                            )

                            IntegrationButton(
                                title: "Skill",
                                addTitle: "Add Skill",
                                iconName: "plus",
                                isConfigured: isSkillConfigured,
                                checking: loading,
                                working: working,
                                onAdd: { toggleSkill(agent, remove: false) },
                                onRemove: { toggleSkill(agent, remove: true) }
                            )
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Divider()

            // Manual Setup Row using copy icons for Prompt, MCP JSON, and Skill
            HStack(spacing: 8) {
                Text("Manual Setup").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)

                // Prompt
                Button {
                    copy("Use Poko when configuring web application ports, checking available ports, resolving port conflicts, or starting local dev servers. Call request_port with app name, absolute projectPath and group, then accept_port before starting on the assigned port. Use the returned URL. All UI operations (add, edit settings, map listeners, start, stop, release) are available via MCP with matching parameters.")
                    copiedPrompt = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedPrompt = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedPrompt ? "checkmark" : "doc.on.doc")
                        Text(copiedPrompt ? "Copied!" : "Prompt")
                    }
                }
                .controlSize(.small)

                // MCP JSON - using copy icon
                Button {
                    if let data = try? Data(contentsOf: runtime.appendingPathComponent("agent-config.json")),
                       let config = try? JSONDecoder().decode(AgentRuntime.self, from: data),
                       let json = try? JSONSerialization.data(withJSONObject: ["mcpServers": ["port": ["command": config.node, "args": [runtime.appendingPathComponent("server/mcp.mjs").path]]]], options: [.prettyPrinted, .sortedKeys]),
                       let text = String(data: json, encoding: .utf8) {
                        copy(text)
                        copiedJSON = true
                        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedJSON = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedJSON ? "checkmark" : "doc.on.doc")
                        Text(copiedJSON ? "Copied!" : "MCP JSON")
                    }
                }
                .controlSize(.small)

                // Skill - using copy icon
                Button {
                    var skillText = ""
                    if let data = try? Data(contentsOf: runtime.appendingPathComponent("SKILL.md")),
                       let text = String(data: data, encoding: .utf8) {
                        skillText = text
                    }
                    if !skillText.isEmpty {
                        copy(skillText)
                        copiedSkill = true
                        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copiedSkill = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedSkill ? "checkmark" : "doc.on.doc")
                        Text(copiedSkill ? "Copied!" : "Skill")
                    }
                }
                .controlSize(.small)
            }
            .font(.system(size: 11))

            Divider()

            HStack {
                Spacer()
                Button("Close") {
                    if let onClose { onClose() } else { dismiss() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .buttonStyle(SurfaceButtonStyle())
        .quietFocus()
        .padding(onClose != nil ? 14 : 20)
        .frame(width: onClose != nil ? 456 : 480)
        .task { await refresh() }
    }
}

struct AppSettings: View {
    @ObservedObject var store: Store
    let target: EditorTarget
    @Environment(\.dismiss) var dismiss
    @State private var url=""
    @State private var healthUrl=""
    @State private var iconUrl=""
    @State private var script=""
    @State private var folder=""
    @State private var saving=false
    @State private var running=false
    @State private var removing=false
    @State private var runMessage=""
    var appID: String? { target.app?.id }
    var hasChanges: Bool {
        url != target.initialUrl || healthUrl != target.initialHealth || iconUrl != target.initialIcon ||
        script != (target.app?.startScript ?? "") || folder != target.initialFolder
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text("Edit " + target.name).font(.headline).padding(.bottom,6)
            HStack {
                Text("Port").font(.caption)
                Spacer()
                Text(String(target.port)).font(.caption).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
            }.help("Assigned port. Ports stay fixed for an existing app. (Read-only)").accessibilityElement(children:.combine).accessibilityLabel("Port " + String(target.port) + ", read-only")
            Text("URL").font(.caption)
            TextField("http://app-name",text:$url)
            Text("Health URL").font(.caption)
            TextField("/ — home page by default",text:$healthUrl)
            Text("Icon URL").font(.caption)
            TextField("Default: /favicon.ico",text:$iconUrl)
            Button { openFolder(folder) } label: { Text("Project folder").font(.caption) }.buttonStyle(QuietButtonStyle()).disabled(folder.isEmpty)
                .help("Open this folder in Finder")
            TextField("/absolute/project/folder",text:$folder)
            HStack {
                Text("Start script").font(.caption)
                Spacer()
                Button {
                    running=true;runMessage=""
                    Task {
                        if let appID, await store.mutate("start",["id":appID,"startScript":script,"projectPath":folder]) { runMessage="Script started." }
                        running=false
                    }
                } label: { HStack(spacing:5) { Text(running ? "Running" : "Run");Image(systemName:"play.fill") } }
                .disabled(running || saving || script.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || appID == nil)
                .help(appID == nil ? "Save the app mapping before running a script" : "Test this script with the current project folder")
            }
            TextField("npm run dev",text:$script).font(.system(size:11,design:.monospaced))
            if target.app == nil { Text("Saving also maps this running app to its URL.").font(.caption).foregroundStyle(.secondary) }
            if !runMessage.isEmpty { Text(runMessage).font(.caption).foregroundStyle(.secondary) }
            if let error=store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider().padding(.vertical,6)
            HStack(spacing:8) {
                if appID != nil {
                    Button("Remove",role:.destructive) { removing=true }.disabled(saving || running)
                }
                if let app=target.app, !app.accepted {
                    Button("Activate") { Task { _ = await store.mutate("accept",["id":app.id]) } }
                }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(saving || running)
                Button(saving ? "Saving" : "Save") {
                    saving=true
                    Task {
                        do {
                            if appID == nil, let listener=target.listener {
                                guard let hostname=URL(string:url)?.host else { throw NSError(domain:"Port",code:1,userInfo:[NSLocalizedDescriptionKey:"Enter an app URL"]) }
                                if await store.mutate("import",["name":hostname,"pid":listener.pid,"port":listener.port,"projectPath":folder,"url":url,"healthUrl":healthUrl,"iconUrl":iconUrl,"startScript":script]) { dismiss() }
                            } else if let appID, await store.mutate("configure",["id":appID,"url":url,"healthUrl":healthUrl,"iconUrl":iconUrl,"startScript":script,"projectPath":folder]) { dismiss() }
                        } catch { store.error=error.localizedDescription }
                        saving=false
                    }
                }.disabled(saving || running || !hasChanges)
            }
        }.buttonStyle(SurfaceButtonStyle()).quietFocus().textFieldStyle(.roundedBorder).padding(20).frame(width:420)
        .alert("Remove " + target.name + "?",isPresented:$removing) {
            Button("Cancel",role:.cancel) {}
            Button("Remove",role:.destructive) { Task { if let appID, await store.mutate("release",["id":appID]) { dismiss() } } }
        } message: { Text("Removes the mapping and reservation. The app process keeps running.") }
        .onAppear { url=target.initialUrl;healthUrl=target.initialHealth;iconUrl=target.initialIcon;script=target.app?.startScript ?? "";folder=target.initialFolder }
    }
}
