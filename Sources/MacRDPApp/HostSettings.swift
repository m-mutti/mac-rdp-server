import ApplicationServices
import CoreGraphics
import Foundation
import MacRDPKit
import MacRDPHost

/// Server options the app remembers between launches.
struct HostSettings: Equatable {
    var port: UInt16 = 3389
    var keys = ModifierStyle.mac
    var scaling = ScalingPolicy.matchClient
    var physical = PhysicalDisplayPolicy.mirror
    /// Baseline H.264 for clients that can't decode the default profile.
    var compatibilityVideo = false

    private enum Key {
        static let port = "port", keys = "keys", scaling = "scaling", physical = "physical"
        static let compatibilityVideo = "compatibilityVideo"
    }

    static func load(from defaults: UserDefaults = .standard) -> HostSettings {
        var s = HostSettings()
        if let port = defaults.object(forKey: Key.port) as? Int, let value = UInt16(exactly: port), value > 0 {
            s.port = value
        }
        s.keys = defaults.string(forKey: Key.keys).flatMap(ModifierStyle.init) ?? s.keys
        s.scaling = defaults.string(forKey: Key.scaling).flatMap(ScalingPolicy.init) ?? s.scaling
        s.physical = defaults.string(forKey: Key.physical).flatMap(PhysicalDisplayPolicy.init) ?? s.physical
        s.compatibilityVideo = defaults.bool(forKey: Key.compatibilityVideo)
        return s
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(port), forKey: Key.port)
        defaults.set(keys.rawValue, forKey: Key.keys)
        defaults.set(scaling.rawValue, forKey: Key.scaling)
        defaults.set(physical.rawValue, forKey: Key.physical)
        defaults.set(compatibilityVideo, forKey: Key.compatibilityVideo)
    }

    var options: RDPHost.Options {
        var o = RDPHost.Options()
        o.port = port
        o.modifierStyle = keys
        o.scaling = scaling
        o.physical = physical
        o.h264Profile = compatibilityVideo ? .constrainedBaseline : .constrainedHigh
        return o
    }
}

/// The macOS privacy permissions the server needs.
struct Permissions: Equatable {
    /// Windows sees the screen.
    var screenRecording: Bool
    /// Windows' keyboard and mouse control the Mac.
    var accessibility: Bool

    var allGranted: Bool { screenRecording && accessibility }

    static func current() -> Permissions {
        Permissions(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }
}

enum PrivacyPane: String {
    case screenRecording = "Privacy_ScreenCapture"
    case accessibility = "Privacy_Accessibility"

    var url: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
    }
}
