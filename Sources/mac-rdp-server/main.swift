import AppKit
import CoreGraphics
import Foundation
import MacRDPKit
import MacRDPHost
import MacRDPApp

let usage = """
usage: mac-rdp-server [<command> [options]]

Without a command (e.g. opened from Finder) it runs as a menu bar app.

commands:
  serve [options]             run the RDP server (connect with Windows Remote Desktop)
  set-password [--user U]     set the password Windows signs in with (default user: you)
  rdp-file [--out F]          write a Remote Desktop file for Windows (default: mac-rdp-server.rdp)
  doctor                      check permissions and list displays
  displays [options]          create virtual displays for a client layout, hold, then remove them
  record [options] --out F    create virtual displays, capture + H.264-encode the primary one to F

options:
  --port N       RDP port                      (default 3389)
  --bind A       listen only on address A      (default: all interfaces)
  --keys K       mac | windowsShortcuts        (default mac: Win key = Command)
  --scaling S    native | matchClient          (default matchClient)
  --physical P   mirror | extend               (default mirror)
  --h264 P       high | baseline               (default high; try baseline if Windows shows black)
  --address A    address Windows connects to   (default: this Mac's LAN address)
  --config DIR   settings directory            (default ~/Library/Application Support/mac-rdp-server)
  --layout L     comma-separated monitors, first is primary: WxH[@scale%][+X+Y]
                 e.g. 2560x1440,1920x1080+2560+0  or  3840x2160@150   (default 1920x1080)
  --seconds N    how long to hold              (default 10)
"""

struct Options {
    var command = ""
    var layout = "1920x1080"
    var scaling = ScalingPolicy.matchClient
    var physical = PhysicalDisplayPolicy.mirror
    var seconds = 10.0
    var out: String?
    var port: UInt16 = 3389
    var keys = ModifierStyle.mac
    var user = NSUserName()
    var address: String?
    var bind: String?
    var h264 = H264Encoder.Settings.Profile.constrainedHigh
    var config = RDPHost.defaultConfigDirectory
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func require<T>(_ value: T?, _ message: @autoclosure () -> String) -> T {
    guard let value else { fail(message()) }
    return value
}

func parseOptions(_ args: [String]) -> Options {
    var options = Options()
    var it = args.makeIterator()
    guard let command = it.next() else { fail(usage) }
    options.command = command
    while let arg = it.next() {
        func value() -> String { require(it.next(), "\(arg) needs a value") }
        switch arg {
        case "--layout": options.layout = value()
        case "--scaling": options.scaling = require(ScalingPolicy(rawValue: value()), "bad --scaling")
        case "--physical": options.physical = require(PhysicalDisplayPolicy(rawValue: value()), "bad --physical")
        case "--seconds": options.seconds = require(Double(value()), "bad --seconds")
        case "--out": options.out = value()
        case "--port": options.port = require(UInt16(value()), "bad --port")
        case "--keys": options.keys = require(ModifierStyle(rawValue: value()), "bad --keys")
        case "--user": options.user = value()
        case "--address": options.address = value()
        case "--bind": options.bind = value()
        case "--h264":
            switch value() {
            case "high": options.h264 = .constrainedHigh
            case "baseline": options.h264 = .constrainedBaseline
            default: fail("bad --h264")
            }
        case "--config": options.config = URL(fileURLWithPath: value(), isDirectory: true)
        default: fail("unknown option \(arg)\n\n\(usage)")
        }
    }
    return options
}

/// Parses "WxH[@scale][+X+Y]" monitors; monitors without a position are placed left to right.
func parseLayout(_ text: String) throws -> MonitorLayout {
    let pattern = /^(\d+)x(\d+)(?:@(\d+))?(?:\+(-?\d+)\+(-?\d+))?$/
    var nextX = 0
    let specs = try text.split(separator: ",").enumerated().map { i, part -> MonitorSpec in
        guard let m = try pattern.wholeMatch(in: String(part)) else { fail("bad monitor '\(part)'") }
        let width = Int(m.1)!, height = Int(m.2)!
        let x = m.4.map { Int($0)! } ?? nextX
        let y = m.5.map { Int($0)! } ?? 0
        nextX = x + width
        return MonitorSpec(x: x, y: y, width: width, height: height, isPrimary: i == 0,
                           scalePercent: m.3.map { Int($0)! } ?? 100)
    }
    return try MonitorLayout(specs)
}

func describe(_ monitors: [VirtualMonitor], layout: MonitorLayout) {
    for m in monitors {
        let spec = layout.monitors[m.index]
        let b = m.bounds
        print("  monitor \(m.index + 1)\(spec.isPrimary ? " (primary)" : ""): client \(spec.width)x\(spec.height)@\(spec.scalePercent)%"
              + " -> display \(m.displayID), looks like \(m.mode.pointWidth)x\(m.mode.pointHeight)"
              + "\(m.mode.hiDPI ? " HiDPI" : "") at (\(Int(b.minX)),\(Int(b.minY)))")
    }
}

func doctor() {
    let screen = CGPreflightScreenCaptureAccess()
    let accessibility = InputInjector.isTrusted(prompt: false)
    print("Screen Recording: \(screen ? "granted" : "NOT granted (needed to stream the screen)")")
    print("Accessibility:    \(accessibility ? "granted" : "NOT granted (needed for keyboard/mouse)")")
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    print("Displays:")
    for id in ids {
        let b = CGDisplayBounds(id)
        print("  \(id): \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id)) px at (\(Int(b.minX)),\(Int(b.minY)))"
              + "\(CGDisplayIsMain(id) != 0 ? " main" : "")\(CGDisplayIsBuiltin(id) != 0 ? " built-in" : "")")
    }
}

func lanAddress() -> String? {
    NetworkAddress.current().first?.address
}

func readPassword(_ prompt: String) -> String {
    if isatty(STDIN_FILENO) == 0 {
        return require(readLine(strippingNewline: true), "no password on stdin")
    }
    var buffer = [CChar](repeating: 0, count: 256)
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { fail("cannot read password") }
    defer { buffer.withUnsafeMutableBufferPointer { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Holds for `seconds` while letting the main run loop service display callbacks.
func hold(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}

// Line-buffer stdout so messages reach the log file when launched via `open`.
setvbuf(stdout, nil, _IOLBF, 0)

/// Ctrl-C / kill handlers for `serve`; global so they live as long as the process.
var signalSources: [DispatchSourceSignal] = []

// Finder and `open` launch the app without a command (older macOS adds -psn_…).
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }
if arguments.isEmpty || arguments.first == "--show" {
    MacRDPServerApp.run(showing: arguments.dropFirst().first)
}

let options = parseOptions(Array(arguments))
switch options.command {
case "doctor":
    doctor()

case "displays":
    let layout = try parseLayout(options.layout)
    let manager = VirtualDisplayManager()
    let monitors = try await manager.apply(layout, scaling: options.scaling, physical: options.physical)
    print("created \(monitors.count) virtual display(s):")
    describe(monitors, layout: layout)
    await hold(options.seconds)
    manager.teardown()
    print("removed")

case "record":
    guard let path = options.out else { fail("record needs --out FILE") }
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        fail("Screen Recording permission is required; grant it in System Settings › Privacy & Security")
    }
    let layout = try parseLayout(options.layout)
    let manager = VirtualDisplayManager()
    let monitors = try await manager.apply(layout, scaling: options.scaling, physical: options.physical)
    describe(monitors, layout: layout)

    let primary = monitors[layout.primaryIndex]
    let spec = layout.monitors[layout.primaryIndex]
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let file = FileHandle(forWritingAtPath: path) else { fail("cannot write \(path)") }
    let stats = Stats()
    let encoder = try H264Encoder(width: spec.width, height: spec.height) { unit in
        file.write(unit.data)
        stats.add(bytes: unit.data.count, keyframe: unit.isKeyframe)
    }
    // Capture at the client's pixel size; for HiDPI modes ScreenCaptureKit
    // downsamples the 2x backing store, exactly like a scaled Retina mode.
    let capture = DisplayCapture(displayID: primary.displayID, pixelWidth: spec.width, pixelHeight: spec.height,
                                 onFrame: { encoder.encode($0.pixelBuffer, at: $0.time) })
    try await capture.start()
    print("recording display \(primary.displayID) for \(Int(options.seconds))s -> \(path)")
    await hold(options.seconds)
    await capture.stop()
    encoder.flush()
    try file.close()
    manager.teardown()
    print(stats.summary(seconds: options.seconds))

case "set-password":
    let password = readPassword("Password for \(options.user) when connecting from Windows: ")
    if isatty(STDIN_FILENO) != 0, readPassword("Again: ") != password { fail("passwords did not match") }
    try CredentialStore.save(user: options.user, password: password, directory: options.config)
    print("saved. Windows signs in as user \"\(options.user)\" with this password.")

case "rdp-file":
    let address = require(options.address ?? lanAddress(), "cannot find this Mac's network address; pass --address")
    let path = options.out ?? "mac-rdp-server.rdp"
    try RemoteDesktopFile.contents(address: address, port: options.port, user: options.user)
        .write(toFile: path, atomically: true, encoding: .utf8)
    print("wrote \(path) for \(address) — copy it to the Windows PC and double-click it")

case "serve":
    guard CredentialStore.hasPassword(directory: options.config) else {
        fail("set the sign-in password first: mac-rdp-server set-password")
    }
    try RDPHost.prepare(directory: options.config)
    // A window-server connection is needed to read the cursor shape.
    NSApplication.shared.setActivationPolicy(.accessory)
    // Permissions belong to whichever app launched us; only ask macOS for
    // them when that is mac-rdp-server.app, not a terminal.
    let isApp = Bundle.main.bundleIdentifier != nil
    if !CGPreflightScreenCaptureAccess() {
        if isApp { _ = CGRequestScreenCaptureAccess() }
        print("warning: Screen Recording is not allowed yet — Windows will connect but see nothing."
              + " Allow mac-rdp-server in System Settings › Privacy & Security › Screen & System Audio Recording, then restart.")
    }
    if !InputInjector.isTrusted(prompt: isApp) {
        print("warning: Accessibility is not allowed yet — keyboard and mouse from Windows will be ignored."
              + " Allow mac-rdp-server in System Settings › Privacy & Security › Accessibility.")
    }

    var hostOptions = RDPHost.Options()
    hostOptions.port = options.port
    hostOptions.bindAddress = options.bind
    hostOptions.configDirectory = options.config
    hostOptions.scaling = options.scaling
    hostOptions.physical = options.physical
    hostOptions.modifierStyle = options.keys
    hostOptions.h264Profile = options.h264
    let host = RDPHost(options: hostOptions)
    try host.start()
    print("ready — on Windows, connect Remote Desktop to \(options.address ?? lanAddress() ?? "this Mac")"
          + "\(options.port == 3389 ? "" : ":\(options.port)") as \"\(options.user)\"")

    signalSources = [SIGINT, SIGTERM].map { sig in
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { host.stop() }
            exit(0)
        }
        source.resume()
        return source
    }
    // Run AppKit's event loop: once NSApplication exists, CoreGraphics delivers
    // display changes through it, and without it new virtual displays never
    // appear online to this process.
    NSApplication.shared.run()

default:
    fail(usage)
}

final class Stats: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, keyframes = 0, bytes = 0

    func add(bytes count: Int, keyframe: Bool) {
        lock.withLock {
            frames += 1
            bytes += count
            if keyframe { keyframes += 1 }
        }
    }

    func summary(seconds: Double) -> String {
        lock.withLock {
            let mbps = Double(bytes) * 8 / seconds / 1_000_000
            return "\(frames) frames (\(keyframes) keyframes), \(bytes / 1024) KiB, avg \(String(format: "%.2f", mbps)) Mbit/s"
        }
    }
}
