import Foundation
import os
import Testing
@testable import MacRDPKit

struct CBORTests {
    @Test func roundTripsCTAPStyleValues() throws {
        let value: CBOR = [
            1: .bytes(Data([1, 2, 3])),
            2: ["id": "example.com", "name": "Example"],
            4: [["alg": -7, "type": "public-key"]],
            7: ["rk": false, "uv": true],
        ]
        #expect(try CBOR.decode(value.encoded) == value)
        #expect(CBOR(-7).encoded == Data([0x26]))
        #expect(CBOR(-257).encoded == Data([0x39, 0x01, 0x00]))
        #expect(CBOR(1200).encoded == Data([0x19, 0x04, 0xB0]))
    }

    @Test func sortsMapKeysCanonically() {
        // CTAP2 canonical order: shorter encodings first, then bytewise.
        let encoded = CBOR.map(["up": true, "rk": true, "plat": false, 3: 0, 1: 0]).encoded
        #expect(encoded == Data([0xA5, 0x01, 0x00, 0x03, 0x00, 0x62, 0x72, 0x6B, 0xF5,
                                 0x62, 0x75, 0x70, 0xF5, 0x64, 0x70, 0x6C, 0x61, 0x74, 0xF4]))
    }

    @Test func rejectsMalformedInput() {
        #expect(throws: CBOR.DecodingError.truncated) { try CBOR.decode(Data([0x58, 0x05, 0x01])) }
        #expect(throws: CBOR.DecodingError.trailingBytes) { try CBOR.decode(Data([0x01, 0x02])) }
        #expect(throws: CBOR.DecodingError.tooDeep) { try CBOR.decode(Data(repeating: 0x81, count: 40) + [0x00]) }
        // A huge declared array must not allocate before failing.
        #expect(throws: CBOR.DecodingError.truncated) { try CBOR.decode(Data([0x9B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])) }
    }
}

struct RDPEWATests {
    @Test func decodesTheSpecMakeCredentialRequest() throws {
        let message = try CBOR.decode(RDPEWAFixtures.makeCredentialRequest)
        #expect(message["command"]?.uint == 5)
        #expect(message["timeout"]?.uint == 300_000)
        let request = try #require(message["request"]?.data)
        #expect(request.first == RDPEWA.CTAPCommand.makeCredential.rawValue)
        let parameters = try CBOR.decode(request.dropFirst())
        #expect(parameters[2]?["id"]?.string == "ctap.dev")
        #expect(RDPEWA.flags(forCTAPParameters: parameters, command: .makeCredential) == .uvNotRequired)
    }

    @Test func buildsRequestsTheClientCanRead() throws {
        let parameters: CBOR = [1: "ctap.dev", 2: .bytes(Data(count: 32)), 5: ["uv": true]]
        let id = RDPEWA.newTransactionID()
        let message = try CBOR.decode(RDPEWA.webAuthnRequest(
            .getAssertion, parameters: parameters.encoded,
            flags: RDPEWA.flags(forCTAPParameters: parameters, command: .getAssertion),
            timeout: 60_000, transactionID: id))
        #expect(message["command"]?.uint == 5)
        #expect(message["flags"]?.uint == RDPEWA.Flags.uvRequired.rawValue)
        #expect(message["transactionId"]?.data == id)
        #expect(message["request"]?.data == Data([0x02]) + parameters.encoded)
    }

    @Test func parsesTheSpecMakeCredentialResponse() throws {
        let result = try RDPEWA.parseWebAuthnResponse(Data(count: 4) + RDPEWAFixtures.makeCredentialResponsePayload)
        #expect(result.succeeded)
        #expect(result.device?.manufacturer == "Yubico")
        #expect(result.device?.displayName == "Yubico YubiKey FIDO")
        let response = try CBOR.decode(result.ctapResponse)
        #expect(response[1]?.string == "packed")
        #expect(response[2]?.data?.count == 0xD9) // authenticator data
    }

    @Test func reportsFailuresWithoutPayload() throws {
        let cancelled = Data([0xC7, 0x04, 0x07, 0x80]) // HRESULT 0x800704C7, little-endian
        let result = try RDPEWA.parseWebAuthnResponse(cancelled)
        #expect(result.hresult == 0x8007_04C7 && !result.succeeded)
        #expect(throws: RDPEWA.ParseError.tooShort) { try RDPEWA.parseWebAuthnResponse(Data([0, 0])) }
    }
}

struct CTAPHIDTests {
    /// Collects the reports the server sends to the host.
    final class Host: @unchecked Sendable {
        private let reports = OSAllocatedUnfairLock(initialState: [Data]())
        func record(_ report: Data) { reports.withLock { $0.append(report) } }
        var all: [Data] { reports.withLock { $0 } }

        /// Waits for a complete reply to `command` on `cid`, reassembling continuations.
        func reply(cid: UInt32, command: UInt8, timeout: Duration = .seconds(2)) async throws -> Data {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let data = assemble(cid: cid, command: command) { return data }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CancellationError()
        }

        private func assemble(cid: UInt32, command: UInt8) -> Data? {
            let mine = all.filter { $0.prefix(4) == Data(Self.be(cid)) }
            guard let start = mine.firstIndex(where: { $0[4] == 0x80 | command }) else { return nil }
            let length = Int(mine[start][5]) << 8 | Int(mine[start][6])
            var data = Data(mine[start][7..<min(64, 7 + length)])
            for report in mine[(start + 1)...] where report[4] & 0x80 == 0 && data.count < length {
                data.append(report[5..<min(64, 5 + length - data.count)])
            }
            return data.count == length ? data : nil
        }

        static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    }

    private func send(_ server: CTAPHIDServer, cid: UInt32, command: UInt8, payload: Data) async {
        for report in CTAPHIDServer.reports(cid: cid, command: command, payload: payload) {
            await server.receive(report)
        }
    }

    private func openChannel(_ server: CTAPHIDServer, _ host: Host) async throws -> UInt32 {
        let nonce = Data([1, 2, 3, 4, 5, 6, 7, 8])
        await send(server, cid: 0xFFFF_FFFF, command: 0x06, payload: nonce)
        let reply = try await host.reply(cid: 0xFFFF_FFFF, command: 0x06)
        #expect(reply.prefix(8) == nonce)
        #expect(reply[16] & 0x04 != 0) // CBOR capability
        return reply[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
    }

    @Test func fragmentsAndReassemblesLongMessages() async throws {
        let host = Host()
        let server = CTAPHIDServer(send: { host.record($0) }, handle: { _ in Data([0]) })
        let cid = try await openChannel(server, host)
        let payload = Data((0..<300).map { UInt8($0 & 0xFF) }) // init + 5 continuations
        await send(server, cid: cid, command: 0x01, payload: payload)
        #expect(try await host.reply(cid: cid, command: 0x01) == payload)
    }

    @Test func runsCBORRequestsThroughTheBridge() async throws {
        let host = Host()
        let bridge = CTAPBridge(forward: { _ in throw CancellationError() })
        let server = CTAPHIDServer(send: { host.record($0) }, handle: { await bridge.handle($0) })
        let cid = try await openChannel(server, host)
        await send(server, cid: cid, command: 0x10, payload: Data([0x04]))
        let reply = try await host.reply(cid: cid, command: 0x10)
        #expect(reply.first == 0)
        let info = try CBOR.decode(reply.dropFirst())
        #expect(info[1] == ["FIDO_2_0"])
        #expect(info[4]?["uv"] == true && info[4]?["clientPin"] == nil)
    }

    @Test func keepsAliveThenCancels() async throws {
        let host = Host()
        let server = CTAPHIDServer(send: { host.record($0) }, handle: { _ in
            try? await Task.sleep(for: .seconds(10))
            return Data([0])
        })
        let cid = try await openChannel(server, host)
        await send(server, cid: cid, command: 0x10, payload: Data([0x02, 0xA0]))
        _ = try await host.reply(cid: cid, command: 0x3B) // keep-alive while waiting for a touch

        // Another channel can't start a transaction meanwhile.
        await send(server, cid: cid + 1, command: 0x10, payload: Data([0x04]))
        #expect(try await host.reply(cid: cid + 1, command: 0x3F) == Data([0x06]))

        await send(server, cid: cid, command: 0x11, payload: Data())
        #expect(try await host.reply(cid: cid, command: 0x10) == Data([0x2D]))
    }
}

struct CTAPBridgeTests {
    @Test func forwardsRegistrationToWindows() async throws {
        let sent = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let bridge = CTAPBridge { message in
            sent.withLock { $0 = message }
            return Data(count: 4) + RDPEWAFixtures.makeCredentialResponsePayload
        }
        let parameters: CBOR = [1: .bytes(Data(count: 32)), 2: ["id": "example.com"],
                                3: ["id": .bytes(Data([1]))], 4: [["alg": -7, "type": "public-key"]]]
        let reply = await bridge.handle(Data([0x01]) + parameters.encoded)

        #expect(reply.first == 0)
        #expect(try CBOR.decode(reply.dropFirst())[1]?.string == "packed")
        let request = try CBOR.decode(try #require(sent.withLock { $0 }))
        #expect(request["request"]?.data == Data([0x01]) + parameters.encoded)
        #expect(request["flags"]?.uint == RDPEWA.Flags.uvNotRequired.rawValue)
    }

    @Test func mapsWindowsFailures() async {
        let cancelled = CTAPBridge { _ in Data([0xC7, 0x04, 0x07, 0x80]) }
        #expect(await cancelled.handle(Data([0x02]) + CBOR.map([1: "x"]).encoded) == Data([0x27]))
        #expect(await cancelled.handle(Data([0x02, 0xFF])) == Data([0x12]))
        #expect(await cancelled.handle(Data([0x06])) == Data([0x01])) // clientPIN isn't offered
    }
}
