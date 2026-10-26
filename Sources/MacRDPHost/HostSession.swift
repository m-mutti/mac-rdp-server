import Foundation
import MacRDPKit

/// The monitor streams of one session, reachable from FreeRDP threads
/// (frame acknowledgements arrive there and must not wait for the main thread).
final class StreamSet: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [MonitorStream] = []

    var isEmpty: Bool { lock.withLock { streams.isEmpty } }

    func replace(with new: [MonitorStream]) -> [MonitorStream] {
        lock.withLock {
            defer { streams = new }
            return streams
        }
    }

    func forEach(_ body: (MonitorStream) -> Void) {
        lock.withLock { streams }.forEach(body)
    }
}

/// Everything the Mac does for one connected client: virtual displays that
/// match its monitors, a video stream per display, its cursor and input, and
/// its devices.
@MainActor
final class HostSession {
    let link: SessionLink
    let streams: StreamSet
    let webAuthn: WebAuthnRelay
    let injector: InputInjector
    private(set) var layout: MonitorLayout
    private let options: RDPHost.Options
    private let displays = VirtualDisplayManager()
    private var monitors: [VirtualMonitor] = []
    private var cursor: CursorMirror?
    private var generation: UInt32 = 0
    private var graphicsReady = false
    private var displaysReady = false
    /// Display changes are serialized; requests arriving meanwhile coalesce here.
    private var reconfiguring = false
    private var queuedLayout: MonitorLayout?
    private var ended = false
    /// Reports why a session had to be closed, for display in the app.
    var onProblem: (String) -> Void = { _ in }
    /// A `VirtualSecurityKey` (macOS 15+) while one exists.
    private var virtualKey: AnyObject?

    init(link: SessionLink, layout: MonitorLayout, options: RDPHost.Options, streams: StreamSet,
         webAuthn: WebAuthnRelay) {
        self.link = link
        self.layout = layout
        self.options = options
        self.streams = streams
        self.webAuthn = webAuthn
        injector = InputInjector(modifierStyle: options.modifierStyle)
    }

    func begin() async {
        reconfiguring = true
        do {
            monitors = try await displays.apply(layout, scaling: options.scaling, physical: options.physical)
        } catch {
            fail("cannot create virtual displays: \(error)")
            reconfiguring = false
            return
        }
        guard !ended else { return displays.teardown() }
        injector.target(layout: layout, monitors: monitors)
        describeDisplays()
        displaysReady = true
        await startStreamsIfReady()
        await drainLayoutQueue()
    }

    func graphicsDidBecomeReady() async {
        graphicsReady = true
        await startStreamsIfReady()
    }

    /// The client resized its window or changed monitors.
    func requestLayout(_ new: MonitorLayout) async {
        guard new != layout || queuedLayout != nil else { return }
        queuedLayout = new
        guard !reconfiguring else { return }
        reconfiguring = true
        await drainLayoutQueue()
    }

    func end() async {
        ended = true
        webAuthn.close()
        virtualKey = nil
        await stopStreams()
        injector.releaseAll()
        displays.teardown()
        log("virtual displays removed")
    }

    // MARK: Security keys

    /// The client accepted or refused WebAuthn redirection. When accepted, its
    /// security keys and Windows Hello become a USB security key on the Mac.
    func webAuthnAvailabilityChanged(_ available: Bool) async {
        guard !ended else { return }
        guard available else {
            log("Windows does not forward security keys (WebAuthn redirection is off in Remote Desktop Connection)")
            return
        }
        await checkWebAuthnChannel()
        guard #available(macOS 15, *) else {
            log("security keys from Windows need macOS 15 or later on the Mac")
            return
        }
        let relay = webAuthn
        do {
            let key = try await VirtualSecurityKey(forward: { try await relay.exchange($0) })
            guard !ended else { return }
            virtualKey = key
            log("security keys from Windows are available to Mac apps")
        } catch VirtualSecurityKey.Failure.needsApproval {
            log("security keys reach the Mac, but macOS won't create the virtual key without Apple's HID Virtual Device entitlement")
        } catch {
            log("could not create the virtual security key: \(error)")
        }
    }

    /// Asks the client for its WebAuthn API version: proves the channel answers,
    /// without involving the user.
    private func checkWebAuthnChannel() async {
        let request = RDPEWA.request(.apiVersion, transactionID: RDPEWA.newTransactionID())
        do {
            let (hresult, payload) = try RDPEWA.split(try await webAuthn.exchange(request))
            let version = payload.prefix(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            log(hresult == 0 ? "Windows WebAuthn API version \(version)" : "Windows WebAuthn check failed (HRESULT 0x\(String(hresult, radix: 16)))")
        } catch {
            log("Windows WebAuthn check failed: \(error)")
        }
    }

    private func drainLayoutQueue() async {
        while let next = queuedLayout, !ended {
            queuedLayout = nil
            if next != layout { await apply(next) }
        }
        reconfiguring = false
    }

    private func apply(_ new: MonitorLayout) async {
        log("client layout changed")
        await stopStreams()
        do {
            monitors = try await displays.apply(new, scaling: options.scaling, physical: options.physical)
        } catch {
            fail("cannot create virtual displays: \(error)")
            return
        }
        layout = new
        generation &+= 1
        link.resetLayout(new, generation: generation)
        injector.target(layout: new, monitors: monitors)
        describeDisplays()
        await startStreamsIfReady()
    }

    private func startStreamsIfReady() async {
        guard graphicsReady, displaysReady, !ended, streams.isEmpty else { return }
        var started: [MonitorStream] = []
        do {
            for monitor in monitors {
                let stream = try MonitorStream(index: monitor.index, monitor: monitor,
                                               spec: layout.monitors[monitor.index],
                                               generation: generation, link: link,
                                               profile: options.h264Profile)
                try await stream.start()
                started.append(stream)
            }
        } catch {
            for stream in started { await stream.stop() }
            fail("cannot capture the screen: \(error.localizedDescription)"
                + " — allow mac-rdp-server under System Settings › Privacy & Security › Screen & System Audio Recording")
            return
        }
        guard !ended else {
            for stream in started { await stream.stop() }
            return
        }
        _ = streams.replace(with: started)

        let primary = layout.monitors[layout.primaryIndex]
        let mode = layout.displayMode(for: layout.primaryIndex, policy: options.scaling)
        let cursor = CursorMirror(link: link, pixelsPerPoint: Double(primary.width) / Double(mode.pointWidth))
        cursor.start()
        self.cursor = cursor
        log("streaming \(started.count) monitor(s)")
    }

    private func stopStreams() async {
        cursor?.stop()
        cursor = nil
        for stream in streams.replace(with: []) {
            await stream.stop()
        }
    }

    private func fail(_ message: String) {
        log(message)
        onProblem(message)
        link.close()
    }

    private func describeDisplays() {
        for m in monitors {
            let spec = layout.monitors[m.index]
            log("  monitor \(m.index + 1)\(spec.isPrimary ? " (primary)" : ""): \(spec.width)x\(spec.height) @\(spec.scalePercent)%"
                + " -> Mac display \(m.displayID), looks like \(m.mode.pointWidth)x\(m.mode.pointHeight)\(m.mode.hiDPI ? " HiDPI" : "")")
        }
    }
}
