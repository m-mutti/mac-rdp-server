// swift-tools-version: 6.0
import PackageDescription

// Built by scripts/bootstrap.sh.
let prefix = "\(Context.packageDirectory)/third_party/prefix"

let package = Package(
    name: "OpenConnect",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "openconnect-host", targets: ["openconnect-host"]),
    ],
    targets: [
        // Declarations for CoreGraphics' private virtual display classes.
        .target(name: "CVirtualDisplay"),
        .target(
            name: "OpenConnectKit",
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
            name: "OpenConnectServer",
            dependencies: ["OpenConnectKit", "CRDPServer"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .executableTarget(name: "openconnect-host", dependencies: ["OpenConnectKit", "OpenConnectServer"]),
        .testTarget(name: "OpenConnectKitTests", dependencies: ["OpenConnectKit"]),
    ]
)
