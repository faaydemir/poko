import AppKit
import Foundation
let home=FileManager.default.homeDirectoryForCurrentUser
let plist=home.appendingPathComponent("Library/LaunchAgents/dev.port.server.plist").path
let task=Process()
task.executableURL=URL(fileURLWithPath:"/bin/launchctl")
task.arguments=["bootstrap","gui/\(getuid())",plist]
try? task.run();task.waitUntilExit()
let start=Process();start.executableURL=URL(fileURLWithPath:"/bin/launchctl")
start.arguments=["kickstart","gui/\(getuid())/dev.port.server"]
try? start.run();start.waitUntilExit()
if start.terminationStatus != 0 {
    let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.activate(ignoringOtherApps:true)
    let alert=NSAlert();alert.messageText="Poko Server needs installation"
    alert.informativeText="Open Poko Installer.app to install the background service, then open this app again. Source builds can use npm run install:local."
    alert.runModal()
}
