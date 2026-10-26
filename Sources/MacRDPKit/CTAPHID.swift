import Foundation

/// The USB HID transport of a FIDO security key (CTAP2 §11.2): reassembles
/// requests from 64-byte reports, runs one CBOR transaction at a time, sends
/// keep-alives while the user is asked to touch the key, and fragments replies.
public actor CTAPHIDServer {
    public static let reportSize = 64

    enum Command: UInt8 {
        case ping = 0x01, msg = 0x03, lock = 0x04, initialize = 0x06, wink = 0x08
        case cbor = 0x10, cancel = 0x11, keepalive = 0x3B, error = 0x3F
    }

    enum ErrorCode: UInt8 {
        case invalidCommand = 0x01, invalidLength = 0x03, invalidSequence = 0x04
        case channelBusy = 0x06, invalidChannel = 0x0B
    }

    static let broadcast: UInt32 = 0xFFFF_FFFF
    /// 57 bytes in the first report plus 128 continuations of 59.
    static let maxMessage = 57 + 128 * 59
    /// Keep-alive status: waiting for the user (CTAP2 §11.2.9.2.1).
    static let upNeeded: UInt8 = 2
    /// CTAP2_ERR_KEEPALIVE_CANCEL.
    static let cancelled: UInt8 = 0x2D

    private struct Partial {
        var cid: UInt32
        var command: UInt8
        var length: Int
        var data: Data
        var sequence: UInt8
    }

    private let handle: @Sendable (Data) async -> Data
    private let outbox: AsyncStream<Data>.Continuation
    private let pump: Task<Void, Never>
    private var nextChannel: UInt32 = 1
    private var partial: Partial?
    private var busy: (cid: UInt32, task: Task<Void, Never>)?

    /// - Parameters:
    ///   - send: delivers one 64-byte input report to the host, in order.
    ///   - handle: runs a CTAP2 request (command byte + CBOR) and returns status byte + CBOR.
    public init(send: @escaping @Sendable (Data) async -> Void,
                handle: @escaping @Sendable (Data) async -> Data) {
        self.handle = handle
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        outbox = continuation
        pump = Task {
            for await report in stream { await send(report) }
        }
    }

    deinit {
        outbox.finish()
        busy?.task.cancel()
    }

    /// Handles one output report from the host.
    public func receive(_ report: Data) {
        var bytes = [UInt8](report)
        // Hosts may prefix the (unused) report ID.
        if bytes.count == Self.reportSize + 1 && bytes[0] == 0 { bytes.removeFirst() }
        guard bytes.count >= 7 else { return }
        let cid = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])

        if bytes[4] & 0x80 != 0 {
            let command = bytes[4] & 0x7F
            let length = Int(bytes[5]) << 8 | Int(bytes[6])
            if command == Command.cancel.rawValue {
                cancelTransaction(on: cid)
                return
            }
            if let p = partial, p.cid != cid {
                return fail(cid, .channelBusy)
            }
            guard length <= Self.maxMessage else { return fail(cid, .invalidLength) }
            let first = Data(bytes[7..<min(bytes.count, 7 + length)])
            if first.count == length {
                partial = nil
                process(cid, command, first)
            } else {
                partial = Partial(cid: cid, command: command, length: length, data: first, sequence: 0)
            }
        } else {
            guard var p = partial, p.cid == cid else { return }
            guard bytes[4] == p.sequence else {
                partial = nil
                return fail(cid, .invalidSequence)
            }
            p.data.append(contentsOf: bytes[5..<min(bytes.count, 5 + p.length - p.data.count)])
            p.sequence += 1
            if p.data.count == p.length {
                partial = nil
                process(p.cid, p.command, p.data)
            } else {
                partial = p
            }
        }
    }

    private func process(_ cid: UInt32, _ command: UInt8, _ payload: Data) {
        switch Command(rawValue: command) {
        case .initialize:
            guard payload.count == 8 else { return fail(cid, .invalidLength) }
            if cid != Self.broadcast { cancelTransaction(on: cid, reply: false) }
            let channel = cid == Self.broadcast ? allocateChannel() : cid
            var reply = payload
            reply.append(contentsOf: Self.bigEndian(channel))
            // CTAPHID protocol 2, device version 0.1.0, capabilities WINK | CBOR | NMSG (no CTAP1).
            reply.append(contentsOf: [2, 0, 1, 0, 0x01 | 0x04 | 0x08])
            write(cid, .initialize, reply)
        case .ping:
            write(cid, .ping, payload)
        case .wink, .lock:
            write(cid, Command(rawValue: command)!, Data())
        case .cbor:
            guard cid != Self.broadcast else { return fail(cid, .invalidChannel) }
            guard busy == nil else { return fail(cid, .channelBusy) }
            guard !payload.isEmpty else { return fail(cid, .invalidLength) }
            let handle = self.handle
            busy = (cid, Task {
                let keepAlive = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard self.sendKeepAlive(cid) else { return }
                    }
                }
                let response = await handle(payload)
                keepAlive.cancel()
                self.finish(cid, response)
            })
        default:
            fail(cid, .invalidCommand)
        }
    }

    private func sendKeepAlive(_ cid: UInt32) -> Bool {
        guard busy?.cid == cid else { return false }
        write(cid, .keepalive, Data([Self.upNeeded]))
        return true
    }

    private func finish(_ cid: UInt32, _ response: Data) {
        guard busy?.cid == cid else { return } // cancelled meanwhile
        busy = nil
        write(cid, .cbor, response)
    }

    private func cancelTransaction(on cid: UInt32, reply: Bool = true) {
        guard let current = busy, current.cid == cid else { return }
        busy = nil
        current.task.cancel()
        if reply { write(cid, .cbor, Data([Self.cancelled])) }
    }

    private func allocateChannel() -> UInt32 {
        defer { nextChannel = nextChannel % 0xFFFF_FFFE + 1 }
        return nextChannel
    }

    private func fail(_ cid: UInt32, _ code: ErrorCode) {
        write(cid, .error, Data([code.rawValue]))
    }

    /// Frames are queued synchronously, so one message's reports never interleave with another's.
    private func write(_ cid: UInt32, _ command: Command, _ payload: Data) {
        for report in Self.reports(cid: cid, command: command.rawValue, payload: payload) {
            outbox.yield(report)
        }
    }

    /// Splits a message into an initialization report and continuation reports.
    static func reports(cid: UInt32, command: UInt8, payload: Data) -> [Data] {
        let bytes = [UInt8](payload)
        var first = bigEndian(cid) + [0x80 | command, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)]
        first += bytes.prefix(57)
        var reports = [padded(first)]
        var offset = min(57, bytes.count), sequence: UInt8 = 0
        while offset < bytes.count {
            let chunk = bytes[offset..<min(offset + 59, bytes.count)]
            reports.append(padded(bigEndian(cid) + [sequence] + chunk))
            offset += chunk.count
            sequence += 1
        }
        return reports
    }

    private static func padded(_ bytes: [UInt8]) -> Data {
        Data(bytes + [UInt8](repeating: 0, count: reportSize - bytes.count))
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    /// HID report descriptor of a FIDO authenticator: 64-byte input and output reports.
    public static let reportDescriptor = Data([
        0x06, 0xD0, 0xF1, // Usage Page (FIDO Alliance)
        0x09, 0x01, //       Usage (CTAPHID)
        0xA1, 0x01, //       Collection (Application)
        0x09, 0x20, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02, // Input, 64 bytes
        0x09, 0x21, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02, // Output, 64 bytes
        0xC0, //             End Collection
    ])
}

/// Answers a browser's CTAP2 requests for the virtual security key: describes
/// the authenticator itself, and forwards registration and sign-in to the
/// Windows client, whose own security keys and Windows Hello do the work.
public struct CTAPBridge: Sendable {
    /// Sends an MS-RDPEWA request message and returns the client's response message.
    public typealias Forward = @Sendable (Data) async throws -> Data

    enum Status: UInt8 {
        case ok = 0x00, invalidCommand = 0x01, invalidLength = 0x03, invalidCBOR = 0x12
        case operationDenied = 0x27, noCredentials = 0x2E, actionTimeout = 0x2F
        case notAllowed = 0x30, other = 0x7F
    }

    private let forward: Forward
    private let timeout: UInt32

    public init(timeoutMilliseconds: UInt32 = 120_000, forward: @escaping Forward) {
        self.forward = forward
        timeout = timeoutMilliseconds
    }

    /// authenticatorGetInfo (CTAP2 §6.4). The Windows side handles PINs and
    /// biometrics itself, so the key presents built-in user verification and
    /// no clientPin: browsers then never start a PIN protocol with us.
    public static let info = CBOR.map([
        1: ["FIDO_2_0"],
        3: .bytes(Data(count: 16)),
        4: ["plat": false, "rk": true, "up": true, "uv": true],
        5: 1200,
    ]).encoded

    public func handle(_ request: Data) async -> Data {
        guard let command = request.first else { return Data([Status.invalidLength.rawValue]) }
        let parameters = Data(request.dropFirst())
        switch command {
        case 0x04: // authenticatorGetInfo
            return Data([Status.ok.rawValue]) + Self.info
        case 0x01, 0x02: // authenticatorMakeCredential, authenticatorGetAssertion
            let ctap = RDPEWA.CTAPCommand(rawValue: command)!
            guard let decoded = try? CBOR.decode(parameters) else { return Data([Status.invalidCBOR.rawValue]) }
            let message = RDPEWA.webAuthnRequest(ctap, parameters: parameters,
                                                 flags: RDPEWA.flags(forCTAPParameters: decoded, command: ctap),
                                                 timeout: timeout, transactionID: RDPEWA.newTransactionID())
            do {
                let result = try RDPEWA.parseWebAuthnResponse(try await forward(message))
                guard result.hresult == 0 else { return Data([Self.status(for: result.hresult).rawValue]) }
                return Data([result.ctapStatus]) + result.ctapResponse
            } catch is CancellationError {
                return Data([CTAPHIDServer.cancelled])
            } catch {
                return Data([Status.other.rawValue])
            }
        case 0x08: // authenticatorGetNextAssertion: Windows already had the user pick one credential
            return Data([Status.notAllowed.rawValue])
        case 0x07: // authenticatorReset is never forwarded
            return Data([Status.operationDenied.rawValue])
        default:
            return Data([Status.invalidCommand.rawValue])
        }
    }

    static func status(for hresult: UInt32) -> Status {
        switch hresult {
        case 0x8007_05B4: .actionTimeout // ERROR_TIMEOUT
        case 0x8009_0011: .noCredentials // NTE_NOT_FOUND
        default: .operationDenied // cancelled in the Windows dialog, or refused
        }
    }
}
