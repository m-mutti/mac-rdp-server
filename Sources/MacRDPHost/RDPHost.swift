import CRDPServer
import Foundation
import MacRDPKit

public struct HostError: Error, CustomStringConvertible {
    public let description: String

    init(_ buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        description = String(decoding: bytes, as: UTF8.self)
    }
}

/// What the server reports to the app.
public enum HostEvent: Sendable, Equatable {
    case connected(client: String, monitors: Int)
    case disconnected
    /// A client was refused or a session had to close.
    case problem(String)
}

/// The RDP server: serves one client at a time and turns it into a
/// `HostSession`. A new client that signs in replaces the current one.
/// FreeRDP calls in from its own threads; anything touching displays or
/// input hops to the main actor.
@MainActor
public final class RDPHost {
    public struct Options: Sendable {
        public var port: UInt16 = 3389
        /// Listen on one address only (e.g. "127.0.0.1"); nil means every interface.
        public var bindAddress: String?
        public var configDirectory = RDPHost.defaultConfigDirectory
        public var scaling = ScalingPolicy.matchClient
        public var physical = PhysicalDisplayPolicy.off
        public var modifierStyle = ModifierStyle.mac
        public var h264Profile = H264Encoder.Settings.Profile.constrainedHigh

        public init() {}
    }

    public nonisolated static let defaultConfigDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("mac-rdp-server", isDirectory: true)

    /// Creates the config directory and a TLS certificate on first use.
    public nonisolated static func prepare(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var error = [CChar](repeating: 0, count: 256)
        guard mrs_ensure_certificate(directory.path, &error, error.count) == 0 else { throw HostError(error) }
    }

    nonisolated let options: Options
    /// Session changes and problems, delivered on the main actor.
    public var onEvent: (HostEvent) -> Void = { _ in }
    nonisolated let live = LiveSession()
    private var server: OpaquePointer?
    private var session: HostSession?
    private let displays = VirtualDisplayManager()

    public init(options: Options) {
        self.options = options
    }

    public func start() throws {
        var config = mrs_server_config()
        config.port = options.port
        var callbacks = makeCallbacks()
        var error = [CChar](repeating: 0, count: 256)
        let bind = options.bindAddress.map { strdup($0) } ?? nil
        defer { free(bind) }
        config.bind_address = UnsafePointer(bind)
        let started = options.configDirectory.path.withCString { path in
            config.config_dir = path
            return mrs_server_start(&config, &callbacks, &error, error.count)
        }
        guard let started else { throw HostError(error) }
        server = started
    }

    public func stop() {
        session?.link.close()
        mrs_server_stop(server)
        server = nil
    }

    /// Ends the current session, if any; the server keeps listening.
    public func disconnectClient() {
        session?.link.close()
    }


    // MARK: Session lifecycle (FreeRDP threads)

    nonisolated func sessionStarted(_ handle: OpaquePointer, specs: [MonitorSpec], client: String) -> Bool {
        let layout: MonitorLayout
        do {
            layout = try MonitorLayout(specs)
        } catch {
            refuse("refused \(client): unusable monitor layout (\(error))")
            return false
        }
        let entry = LiveSession.Entry(link: SessionLink(handle))
        // Only a client that has already signed in gets here, so a failed
        // login can never knock the current user off.
        if let previous = live.claim(entry) {
            log("disconnecting the previous session for the new one from \(client)")
            previous.link.close()
        }
        entry.link.setMonitorCount(layout.monitors.count)
        log("session from \(client) with \(layout.monitors.count) monitor(s)")
        let options = self.options
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let session = HostSession(link: entry.link, layout: layout, options: options,
                                          streams: entry.streams, webAuthn: entry.webAuthn,
                                          clipboard: entry.clipboard, displays: self.displays)
                session.onProblem = { [weak self] in self?.onEvent(.problem($0)) }
                let previous = self.session
                self.session = session
                self.onEvent(.connected(client: client, monitors: layout.monitors.count))
                Task {
                    // The new displays replace the old ones only after those are gone.
                    await previous?.end()
                    await session.begin()
                }
            }
        }
        return true
    }

    nonisolated func sessionEnded(_ id: Int) {
        guard let entry = live.release(id) else { return }
        entry.link.detach()
        entry.webAuthn.close()
        entry.clipboard.close()
        onSession(id) { host, session in
            host.session = nil
            host.onEvent(.disconnected)
            Task {
                await session.end()
                // The Mac's own screens are back on; light them up for whoever is at the
                // Mac, unless another client just took over.
                if host.session == nil, host.options.physical == .off {
                    ScreenWake.wake(reason: "Remote Desktop session ended")
                }
            }
        }
    }

    nonisolated func refuse(_ message: String) {
        log(message)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onEvent(.problem(message)) }
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
        guard !events.isEmpty, live.isCurrent(id) else { return }
        onSession(id) { _, session in
            for event in events { session.injector.apply(event) }
        }
    }

    nonisolated func streams(of id: Int) -> StreamSet? {
        live.streams(of: id)
    }

    // nonisolated: FreeRDP invokes these from its own threads.
    private nonisolated func makeCallbacks() -> mrs_callbacks {
        var cb = mrs_callbacks()
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
        cb.webauthn_available = { user, session, available in
            RDPHost.from(user).onSession(Int(bitPattern: session)) { _, s in
                Task { await s.webAuthnAvailabilityChanged(available != 0) }
            }
        }
        cb.webauthn_response = { user, session, data, length in
            guard let data else { return }
            RDPHost.from(user).live.webAuthn(of: Int(bitPattern: session))?.deliver(Data(bytes: data, count: length))
        }
        cb.clipboard_ready = { user, session in
            RDPHost.from(user).onSession(Int(bitPattern: session)) { _, s in s.clipboard.start() }
        }
        cb.clipboard_offer = { user, session, formats, count in
            let offered = (0..<Int(count)).map { i in
                (id: formats![i].id, name: formats![i].name.map { String(cString: $0) })
            }
            RDPHost.from(user).onSession(Int(bitPattern: session)) { _, s in s.clipboard.windowsOffered(offered) }
        }
        // Requests and answers stay off the main thread: a Mac app waiting
        // for Windows' clipboard blocks it.
        cb.clipboard_request = { user, session, id in
            RDPHost.from(user).live.clipboard(of: Int(bitPattern: session))?.handleRequest(id)
        }
        cb.clipboard_data = { user, session, data, length in
            RDPHost.from(user).live.clipboard(of: Int(bitPattern: session))?
                .deliver(data.map { Data(bytes: $0, count: length) })
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

/// The live sessions, readable from any thread. A replaced session stays
/// here until FreeRDP has finished closing it.
final class LiveSession: @unchecked Sendable {
    struct Entry {
        let link: SessionLink
        let streams = StreamSet()
        let webAuthn: WebAuthnRelay
        let clipboard: ClipboardChannel

        init(link: SessionLink) {
            self.link = link
            webAuthn = WebAuthnRelay(link: link)
            clipboard = ClipboardChannel(link: link)
        }
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var current: Int?

    /// Makes `entry` the active session; returns the one it replaces.
    func claim(_ entry: Entry) -> Entry? {
        lock.withLock {
            let previous = current.flatMap { entries[$0] }
            entries[entry.link.id] = entry
            current = entry.link.id
            return previous
        }
    }

    func release(_ id: Int) -> Entry? {
        lock.withLock {
            if current == id { current = nil }
            return entries.removeValue(forKey: id)
        }
    }

    func isCurrent(_ id: Int) -> Bool {
        lock.withLock { current == id }
    }

    func streams(of id: Int) -> StreamSet? {
        lock.withLock { entries[id]?.streams }
    }

    func webAuthn(of id: Int) -> WebAuthnRelay? {
        lock.withLock { entries[id]?.webAuthn }
    }

    func clipboard(of id: Int) -> ClipboardChannel? {
        lock.withLock { entries[id]?.clipboard }
    }
}
