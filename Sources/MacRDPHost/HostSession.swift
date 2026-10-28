import Foundation
import MacRDPKit

/// The monitor streams of one session, reachable from FreeRDP threads
/// (frame acknowledgements arrive there and must not wait for the main thread).
final class StreamSet: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [MonitorStream] = []
    private let queue = DispatchQueue(label: "mac-rdp-server.video", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var turn = 0

    var isEmpty: Bool { lock.withLock { streams.isEmpty } }

    func replace(with new: [MonitorStream]) -> [MonitorStream] {
        lock.withLock {
            timer?.cancel()
            timer = nil
            if !new.isEmpty {
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.pump() }
                timer.resume()
                self.timer = timer
            }
            defer { streams = new }
            return streams
        }
    }

    deinit { timer?.cancel() }

    /// All encoder submissions use one queue; rotate priority across monitors.
    func requestPump() {
        queue.async { [weak self] in self?.pump() }
    }

    private func pump() {
        let ordered: [MonitorStream] = lock.withLock {
            guard !streams.isEmpty else { return [] }
            turn = (turn + 1) % streams.count
            return Array(streams[turn...] + streams[..<turn])
        }
        ordered.forEach { $0.pump() }
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
    let clipboard: ClipboardSync
    let injector: InputInjector
    private(set) var layout: MonitorLayout
    private let options: RDPHost.Options
    /// Shared by all sessions: a new session replaces the previous one's displays.
    private let displays: VirtualDisplayManager
    private var monitors: [VirtualMonitor] = []
    private var cursor: CursorMirror?
    private var generation: UInt32 = 0
    private var graphicsReady = false
    private var startingStreams = false
    private var streamRevision: UInt64 = 0
    private var displaysReady = false
    /// Display changes are serialized; requests arriving meanwhile coalesce here.
    private var reconfiguring = false
    private var queuedLayout: MonitorLayout?
    private var ended = false
    /// Reports why a session had to be closed, for display in the app.
    var onProblem: (String) -> Void = { _ in }
    /// A `VirtualSecurityKey` (macOS 15+) while one exists.
    private var virtualKey: AnyObject?
    /// Keeps displays awake: macOS won't rearrange or remove them while they sleep.
    private var screenWake: ScreenWake?

    init(link: SessionLink, layout: MonitorLayout, options: RDPHost.Options, streams: StreamSet,
         webAuthn: WebAuthnRelay, clipboard: ClipboardChannel, displays: VirtualDisplayManager) {
        self.link = link
        self.displays = displays
        self.clipboard = ClipboardSync(channel: clipboard)
        self.layout = layout
        self.options = options
        self.streams = streams
        self.webAuthn = webAuthn
        injector = InputInjector(modifierStyle: options.modifierStyle)
    }

    func begin() async {
        guard !ended else { return }
        reconfiguring = true
        screenWake = ScreenWake(reason: "Windows is connected to mac-rdp-server")
        if await ScreenWake.waitUntilAwake() { log("woke the Mac's screen") }
        do {
            monitors = try await displays.apply(layout, scaling: options.scaling, physical: options.physical,
                                                owner: link.id)
        } catch {
            fail("cannot create virtual displays: \(error)")
            reconfiguring = false
            return
        }
        guard !ended else {
            displays.teardown(owner: link.id)
            return
        }
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
        clipboard.stop()
        webAuthn.close()
        virtualKey = nil
        await stopStreams()
        injector.releaseAll()
        // While the screens are still kept on, or macOS would keep the displays.
        if await displays.remove(owner: link.id) { log("virtual displays removed") }
        screenWake?.release()
        screenWake = nil
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
        displaysReady = false
        await stopStreams()
        do {
            monitors = try await displays.apply(new, scaling: options.scaling, physical: options.physical,
                                                owner: link.id)
        } catch {
            fail("cannot create virtual displays: \(error)")
            return
        }
        layout = new
        displaysReady = true
        generation &+= 1
        link.resetLayout(new, generation: generation)
        injector.target(layout: new, monitors: monitors)
        describeDisplays()
        await startStreamsIfReady()
    }

    private func startStreamsIfReady() async {
        guard graphicsReady, displaysReady, !ended, !startingStreams, streams.isEmpty else { return }
        startingStreams = true
        defer { startingStreams = false }
        let revision = streamRevision
        let monitors = self.monitors
        let specs = layout.monitors
        let generation = self.generation
        var started: [MonitorStream] = []
        var failure: Error?
        do {
            for monitor in monitors {
                let stream = try MonitorStream(index: monitor.index, monitor: monitor,
                                               spec: specs[monitor.index],
                                               generation: generation, link: link,
                                               profile: options.h264Profile)
                try await stream.start()
                started.append(stream)
            }
        } catch {
            failure = error
        }
        guard !ended, revision == streamRevision else {
            for stream in started { await stream.stop() }
            startingStreams = false
            if !ended { await startStreamsIfReady() }
            return
        }
        if let failure {
            for stream in started { await stream.stop() }
            fail("cannot capture the screen: \(failure.localizedDescription)"
                + " — allow mac-rdp-server under System Settings › Privacy & Security › Screen & System Audio Recording")
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
        streamRevision &+= 1
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
        if let problem = displays.arrangementProblem {
            log("couldn't arrange the Mac displays like the Windows monitors (\(problem)); macOS placed them instead")
        }
    }
}
