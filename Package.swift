// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ServerBackup", platforms: [.macOS(.v14)], products: [.executable(name: "ServerBackup", targets: ["ServerBackup"])], dependencies: [.package(path: "vendor/SwiftTerm")], targets: [.executableTarget(name: "ServerBackup", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.copy("Resources")], swiftSettings: [.swiftLanguageMode(.v5)])])
