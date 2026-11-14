// swift-tools-version: 6.0
// DroidDrive core packages. One SwiftPM package, one library target per layer
// (see docs/plan.md §2), so `swift test` in this folder runs every layer's tests.
import PackageDescription

let package = Package(
    name: "DroidKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DroidCore", targets: ["DroidCore"]),
        .library(name: "AdbKit", targets: ["AdbKit"]),
        .library(name: "ItemStore", targets: ["ItemStore"]),
        .library(name: "UsbKit", targets: ["UsbKit"]),
        .library(name: "MtpKit", targets: ["MtpKit"]),
        .library(name: "AdbPairing", targets: ["AdbPairing"]),
        .library(name: "DeviceService", targets: ["DeviceService"]),
        .executable(name: "droiddrive-cli", targets: ["DroidDriveCLI"]),
        .executable(name: "droiddrive-usb", targets: ["DroidDriveUSBCLI"]),
        .executable(name: "droiddrive-wifi", targets: ["DroidDriveWiFiCLI"]),
    ],
    targets: [
        .target(name: "DroidCore"),
        .target(name: "AdbKit", dependencies: ["DroidCore"]),
        .target(
            name: "ItemStore",
            dependencies: ["DroidCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "DroidDriveCLI", dependencies: ["DroidCore", "AdbKit"]),

        // USB and MTP (plan P1-03, phase 2).
        .target(
            name: "UsbKit",
            dependencies: ["DroidCore", "AdbKit"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]
        ),
        .target(name: "MtpKit", dependencies: ["DroidCore", "UsbKit"]),
        .executableTarget(name: "DroidDriveUSBCLI", dependencies: ["DroidCore", "AdbKit", "UsbKit", "MtpKit"]),

        // Wi-Fi pairing and TLS (phase 3).
        .target(name: "CSpake2", publicHeadersPath: "include"),
        .target(name: "AdbPairing", dependencies: ["DroidCore", "AdbKit", "CSpake2"]),
        .executableTarget(name: "DroidDriveWiFiCLI", dependencies: ["DroidCore", "AdbKit", "AdbPairing"]),

        // Device sessions, transfer log, XPC contract shared by app and extension (P1-11, phase 4).
        .target(name: "DeviceService", dependencies: ["DroidCore", "AdbKit", "ItemStore"]),
        .testTarget(name: "DroidCoreTests", dependencies: ["DroidCore"]),
        .testTarget(name: "AdbKitTests", dependencies: ["AdbKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ItemStoreTests", dependencies: ["ItemStore"]),
        .testTarget(name: "UsbKitTests", dependencies: ["UsbKit"]),
        .testTarget(name: "MtpKitTests", dependencies: ["MtpKit"]),
        .testTarget(name: "AdbPairingTests", dependencies: ["AdbPairing"]),
        .testTarget(name: "DeviceServiceTests", dependencies: ["DeviceService"]),
        .testTarget(name: "IntegrationTests", dependencies: ["AdbKit", "DroidCore"], resources: [.copy("malicious-names.bin")]),
    ]
)
