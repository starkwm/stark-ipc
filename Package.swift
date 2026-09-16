// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "StarkIPC",
  platforms: [.macOS(.v26)],
  products: [.library(name: "StarkIPC", targets: ["StarkIPC"])],
  targets: [
    .target(name: "StarkIPC"),
    .testTarget(name: "StarkIPCTests", dependencies: ["StarkIPC"]),
  ]
)
