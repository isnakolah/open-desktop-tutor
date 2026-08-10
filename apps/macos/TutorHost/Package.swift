// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallaTutorHost",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CallaTutorHost", targets: ["CallaTutorHost"])],
    targets: [.executableTarget(name: "CallaTutorHost")]
)
