// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CallaTutorHost",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CallaTutorHost", targets: ["CallaTutorHost"])],
    dependencies: [.package(path: "../../../packages/swift/TutorKit")],
    targets: [
        .executableTarget(
            name: "CallaTutorHost",
            dependencies: [.product(name: "TutorProtocol", package: "TutorKit")])
    ]
)
