import AppKit
import Foundation

let fm = FileManager.default
let app = NSApplication.shared
// `--yes` is used by install.sh: no dialogs, errors go to stderr.
let silent = CommandLine.arguments.contains("--yes")
if !silent { app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true) }
let alert = NSAlert()
alert.messageText = "Install Poko"
alert.informativeText = "Install Poko and its bundled runtime in your user account, then start the background service. Existing mappings are preserved. Connect agents and enable app domains from Poko."
alert.addButton(withTitle: "Install"); alert.addButton(withTitle: "Cancel")
guard silent || alert.runModal() == .alertFirstButtonReturn else { exit(0) }
func run(_ executable: String, _ arguments: [String], required: Bool = true) throws {
    let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
    try task.run(); task.waitUntilExit()
    if required && task.terminationStatus != 0 { throw NSError(domain: "PokoInstaller", code: Int(task.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Command failed: \(executable)"]) }
}
do {
    let home = fm.homeDirectoryForCurrentUser
    let support = home.appendingPathComponent("Library/Application Support/Port")
    let applications = home.appendingPathComponent("Applications")
    let launch = home.appendingPathComponent("Library/LaunchAgents/dev.port.server.plist")
    let payload = Bundle.main.resourceURL!.appendingPathComponent("payload")
    for dir in [support, applications, launch.deletingLastPathComponent()] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path)
    for (name, identifier) in [("Poko", "dev.port.ui"), ("Poko Server", "dev.port.server-app")] {
        let target = applications.appendingPathComponent(name + ".app")
        if fm.fileExists(atPath: target.path) {
            let data = try Data(contentsOf: target.appendingPathComponent("Contents/Info.plist"))
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard info?["CFBundleIdentifier"] as? String == identifier else { throw NSError(domain: "PokoInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing to replace unrelated \(target.path)"]) }
        }
    }
    let staging = support.appendingPathComponent("runtime-" + UUID().uuidString)
    try fm.copyItem(at: payload.appendingPathComponent("runtime"), to: staging)
    defer { try? fm.removeItem(at: staging) }
    let runtime = support.appendingPathComponent("runtime")
    let node = runtime.appendingPathComponent("bin/node").path
    try JSONSerialization.data(withJSONObject: ["node": node]).write(to: staging.appendingPathComponent("agent-config.json"))
    try run("/bin/launchctl", ["bootout", "gui/\(getuid())", launch.path], required: false)
    try run("/usr/bin/osascript", ["-e", "tell application id \"dev.port.ui\" to quit"], required: false)
    let backup = support.appendingPathComponent("runtime-previous")
    if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
    if fm.fileExists(atPath: runtime.path) { try fm.moveItem(at: runtime, to: backup) }
    try fm.moveItem(at: staging, to: runtime)
    for name in ["Poko", "Poko Server"] {
        let target = applications.appendingPathComponent(name + ".app")
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: payload.appendingPathComponent(name + ".app"), to: target)
    }
    let config: [String: Any] = ["Label": "dev.port.server", "ProgramArguments": [node, runtime.appendingPathComponent("server/daemon.mjs").path], "WorkingDirectory": runtime.path, "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 5, "StandardOutPath": support.appendingPathComponent("server.log").path, "StandardErrorPath": support.appendingPathComponent("server.error.log").path, "EnvironmentVariables": ["PORT_DATA_DIR": support.path]]
    try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: launch, options: .atomic)
    try run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", launch.path])
    try run("/usr/bin/open", [applications.appendingPathComponent("Poko.app").path])
} catch {
    if silent { FileHandle.standardError.write(Data("Installation failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    let failure = NSAlert(); failure.messageText = "Installation failed"; failure.informativeText = error.localizedDescription; failure.runModal(); exit(1)
}
