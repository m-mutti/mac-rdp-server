import Foundation
import MacRDPConnectKit

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
/// match its monitors, a video stream per display, its cursor and input.
@MainActor
final class HostSession {
    let link: SessionLink
    let streams: StreamSet
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

    init(link: SessionLink, layout: MonitorLayout, options: RDPHost.Options, streams: StreamSet) {
        self.link = link
        self.layout = layout
        self.options = options
        self.streams = streams
        injector = InputInjector(modifierStyle: options.modifierStyle)
    }

    func begin() async {
        reconfiguring = true
        do {
            monitors = try await displays.apply(layout, scaling: options.scaling, physical: options.physical)
        } catch {
            log("cannot create virtual displays: \(error)")
            link.close()
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
        await stopStreams()
        injector.releaseAll()
        displays.teardown()
        log("virtual displays removed")
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
            log("cannot create virtual displays: \(error)")
            link.close()
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
            log("cannot capture the screen: \(error.localizedDescription)"
                + " — allow mac-rdp-connect under System Settings › Privacy & Security › Screen & System Audio Recording")
            for stream in started { await stream.stop() }
            link.close()
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

    private func describeDisplays() {
        for m in monitors {
            let spec = layout.monitors[m.index]
            log("  monitor \(m.index + 1)\(spec.isPrimary ? " (primary)" : ""): \(spec.width)x\(spec.height) @\(spec.scalePercent)%"
                + " -> Mac display \(m.displayID), looks like \(m.mode.pointWidth)x\(m.mode.pointHeight)\(m.mode.hiDPI ? " HiDPI" : "")")
        }
    }
}
