// swift-tools-version: 6.0
import PackageDescription

// Built by scripts/bootstrap.sh.
let prefix = "\(Context.packageDirectory)/third_party/prefix"

let package = Package(
    name: "mac-rdp-server",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "mac-rdp-server", targets: ["mac-rdp-server"]),
    ],
    targets: [
        // Declarations for CoreGraphics' private virtual display classes.
        .target(name: "CVirtualDisplay"),
        .target(
            name: "MacRDPKit",
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
            name: "MacRDPHost",
            dependencies: ["MacRDPKit", "CRDPServer"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                // Virtual security key (macOS 15+); weak so the app still runs on macOS 14.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "CoreHID"]),
            ]
        ),
        // Menu bar app: onboarding, permission checks, sign-in and settings.
        .target(
            name: "MacRDPApp",
            dependencies: ["MacRDPKit", "MacRDPHost"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]
        ),
        .executableTarget(
            name: "mac-rdp-server",
            dependencies: ["MacRDPKit", "MacRDPHost", "MacRDPApp"]
        ),
        .testTarget(name: "MacRDPKitTests", dependencies: ["MacRDPKit"]),
        .testTarget(name: "MacRDPHostTests", dependencies: ["MacRDPHost", "MacRDPApp"]),
    ]
)
