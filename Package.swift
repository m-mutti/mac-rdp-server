// swift-tools-version: 6.0
import PackageDescription

// Built by scripts/bootstrap.sh.
let prefix = "\(Context.packageDirectory)/third_party/prefix"

let package = Package(
    name: "mac-rdp-connect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac-rdp-connect", targets: ["mac-rdp-connect"]),
    ],
    targets: [
        // Declarations for CoreGraphics' private virtual display classes.
        .target(name: "CVirtualDisplay"),
        .target(
            name: "MacRDPConnectKit",
            dependencies: ["CVirtualDisplay"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        // RDP protocol core on top of FreeRDP's static server libraries.
        .target(
            name: "CRDPServer",
            cSettings: [
                .unsafeFlags([
                    "-I\(prefix)/include/freerdp3",
                    "-I\(prefix)/include/winpr3",
                    "-std=c11",
                    // FreeRDP's own headers use APIs they deprecate.
                    "-Wno-deprecated-declarations",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(prefix)/lib",
                    "-lfreerdp-server3", "-lfreerdp3", "-lwinpr-tools3", "-lwinpr3",
                    "-lssl", "-lcrypto", "-lz",
                ]),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(
            name: "MacRDPConnectServer",
            dependencies: ["MacRDPConnectKit", "CRDPServer"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // Menu bar app: onboarding, permission checks, sign-in and settings.
        .target(
            name: "MacRDPConnectUI",
            dependencies: ["MacRDPConnectKit", "MacRDPConnectServer"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .executableTarget(
            name: "mac-rdp-connect",
            dependencies: ["MacRDPConnectKit", "MacRDPConnectServer", "MacRDPConnectUI"]
        ),
        .testTarget(name: "MacRDPConnectKitTests", dependencies: ["MacRDPConnectKit"]),
    ]
)
