import CRDPServer
import Foundation
import OpenConnectKit

public struct HostError: Error, CustomStringConvertible {
    public let description: String

    init(_ buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        description = String(decoding: bytes, as: UTF8.self)
    }
}

/// The RDP server: accepts one client at a time and turns it into a
/// `HostSession`. FreeRDP calls in from its own threads; anything touching
/// displays or input hops to the main actor.
@MainActor
public final class RDPHost {
    public struct Options: Sendable {
        public var port: UInt16 = 3389
        /// Listen on one address only (e.g. "127.0.0.1"); nil means every interface.
        public var bindAddress: String?
        public var configDirectory = RDPHost.defaultConfigDirectory
        public var scaling = ScalingPolicy.matchClient
        public var physical = PhysicalDisplayPolicy.mirror
        public var modifierStyle = ModifierStyle.mac
        public var h264Profile = H264Encoder.Settings.Profile.constrainedHigh

        public init() {}
    }

    public nonisolated static let defaultConfigDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenConnect", isDirectory: true)

    /// Creates the config directory and a TLS certificate on first use.
    public nonisolated static func prepare(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var error = [CChar](repeating: 0, count: 256)
        guard oc_ensure_certificate(directory.path, &error, error.count) == 0 else { throw HostError(error) }
    }

    public nonisolated static func setPassword(_ password: String, user: String, directory: URL) throws {
        try prepare(directory: directory)
        var error = [CChar](repeating: 0, count: 256)
        guard oc_write_credentials(directory.path, user, password, &error, error.count) == 0 else {
            throw HostError(error)
        }
    }

    public nonisolated static func hasPassword(directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("users.sam").path)
    }

    nonisolated let options: Options
    private nonisolated let live = LiveSession()
    private var server: OpaquePointer?
    private var session: HostSession?

    public init(options: Options) {
        self.options = options
    }

    public func start() throws {
        var config = oc_server_config()
        config.port = options.port
        var callbacks = makeCallbacks()
        var error = [CChar](repeating: 0, count: 256)
        let bind = options.bindAddress.map { strdup($0) } ?? nil
        defer { free(bind) }
        config.bind_address = UnsafePointer(bind)
        let started = options.configDirectory.path.withCString { path in
            config.config_dir = path
            return oc_server_start(&config, &callbacks, &error, error.count)
        }
        guard let started else { throw HostError(error) }
        server = started
    }

    public func stop() {
        session?.link.close()
        oc_server_stop(server)
        server = nil
    }

    // MARK: Session lifecycle (FreeRDP threads)

    nonisolated func sessionStarted(_ handle: OpaquePointer, specs: [MonitorSpec], client: String) -> Bool {
        let layout: MonitorLayout
        do {
            layout = try MonitorLayout(specs)
        } catch {
            log("refused \(client): unusable monitor layout (\(error))")
            return false
        }
        let link = SessionLink(handle)
        let streams = StreamSet()
        guard live.claim(link, streams: streams) else {
            log("refused \(client): another session is active")
            return false
        }
        link.setMonitorCount(layout.monitors.count)
        log("session from \(client) with \(layout.monitors.count) monitor(s)")
        let options = self.options
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let session = HostSession(link: link, layout: layout, options: options, streams: streams)
                self.session = session
                Task { await session.begin() }
            }
        }
        return true
    }

    nonisolated func sessionEnded(_ id: Int) {
        guard let link = live.release(id) else { return }
        link.detach()
        onSession(id) { host, session in
            host.session = nil
            Task { await session.end() }
        }
    }

    /// Runs `body` on the main actor if `id` is still the active session.
    nonisolated func onSession(_ id: Int, _ body: @escaping @Sendable @MainActor (RDPHost, HostSession) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let session = self.session, session.link.id == id else { return }
                body(self, session)
            }
        }
    }

    nonisolated func deliver(_ events: [RDPInputEvent], to id: Int) {
        guard !events.isEmpty, live.streams(of: id) != nil else { return }
        onSession(id) { _, session in
            for event in events { session.injector.apply(event) }
        }
    }

    nonisolated func streams(of id: Int) -> StreamSet? {
        live.streams(of: id)
    }

    // nonisolated: FreeRDP invokes these from its own threads.
    private nonisolated func makeCallbacks() -> oc_callbacks {
        var cb = oc_callbacks()
        cb.user = Unmanaged.passUnretained(self).toOpaque()
        cb.session_started = { user, session, client, monitors, count in
            guard let session, let monitors else { return -1 }
            let specs = (0..<Int(count)).map { MonitorSpec(monitors[$0]) }
            let name = client.map { String(cString: $0) } ?? "client"
            return RDPHost.from(user).sessionStarted(session, specs: specs, client: name) ? 0 : -1
        }
        cb.graphics_ready = { user, session in
            RDPHost.from(user).onSession(Int(bitPattern: session)) { _, s in
                Task { await s.graphicsDidBecomeReady() }
            }
        }
        cb.layout_requested = { user, session, monitors, count in
            guard let monitors,
                  let layout = try? MonitorLayout((0..<Int(count)).map { MonitorSpec(monitors[$0]) })
            else { return }
            RDPHost.from(user).onSession(Int(bitPattern: session)) { _, s in
                Task { await s.requestLayout(layout) }
            }
        }
        cb.frames_acked = { user, session in
            RDPHost.from(user).streams(of: Int(bitPattern: session))?.forEach { $0.pump() }
        }
        cb.refresh_requested = { user, session in
            RDPHost.from(user).streams(of: Int(bitPattern: session))?.forEach { $0.refresh() }
        }
        cb.keyboard = { user, session, flags, code in
            guard let event = RDPInputEvent.keyboard(flags: flags, scancode: code) else { return }
            RDPHost.from(user).deliver([event], to: Int(bitPattern: session))
        }
        cb.unicode = { user, session, flags, code in
            RDPHost.from(user).deliver([RDPInputEvent.unicode(flags: flags, code: code)], to: Int(bitPattern: session))
        }
        cb.mouse = { user, session, flags, x, y in
            RDPHost.from(user).deliver(RDPInputEvent.mouse(flags: flags, x: x, y: y), to: Int(bitPattern: session))
        }
        cb.extended_mouse = { user, session, flags, x, y in
            RDPHost.from(user).deliver(RDPInputEvent.extendedMouse(flags: flags, x: x, y: y),
                                       to: Int(bitPattern: session))
        }
        cb.session_ended = { user, session in
            RDPHost.from(user).sessionEnded(Int(bitPattern: session))
            log("session ended")
        }
        return cb
    }

    private nonisolated static func from(_ user: UnsafeMutableRawPointer?) -> RDPHost {
        Unmanaged<RDPHost>.fromOpaque(user!).takeUnretainedValue()
    }
}

/// Which session is active, readable from any thread.
final class LiveSession: @unchecked Sendable {
    private let lock = NSLock()
    private var link: SessionLink?
    private var streams: StreamSet?

    func claim(_ link: SessionLink, streams: StreamSet) -> Bool {
        lock.withLock {
            guard self.link == nil else { return false }
            self.link = link
            self.streams = streams
            return true
        }
    }

    func release(_ id: Int) -> SessionLink? {
        lock.withLock {
            guard let link, link.id == id else { return nil }
            defer {
                self.link = nil
                streams = nil
            }
            return link
        }
    }

    func streams(of id: Int) -> StreamSet? {
        lock.withLock { link?.id == id ? streams : nil }
    }
}
