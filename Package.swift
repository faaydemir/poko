// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Port", platforms: [.macOS(.v13)], products: [.executable(name: "PortUI", targets: ["PortUI"])], targets: [.executableTarget(name: "PortUI", exclude: ["Resources"])])
