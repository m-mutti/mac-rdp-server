import Foundation

/// Messages of Remote Desktop's WebAuthn channel (MS-RDPEWA): the Mac sends
/// CTAP2 requests, and the Windows client answers them with its own security
/// keys and Windows Hello.
public enum RDPEWA {
    public enum Command: UInt64, Sendable {
        case webAuthn = 5
        case isPlatformAuthenticatorAvailable = 6
        case cancel = 7
        case apiVersion = 8
    }

    /// The CTAP2 commands the channel carries (first byte of a webAuthn request).
    public enum CTAPCommand: UInt8, Sendable {
        case makeCredential = 0x01
        case getAssertion = 0x02
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }

        public static let u2f = Flags(rawValue: 0x0002_0000)
        public static let clientPINRequired = Flags(rawValue: 0x0010_0000)
        public static let uvRequired = Flags(rawValue: 0x0040_0000)
        public static let uvPreferred = Flags(rawValue: 0x0080_0000)
        public static let uvNotRequired = Flags(rawValue: 0x0100_0000)
        public static let hmacSecret = Flags(rawValue: 0x0400_0000)
    }

    public enum ParseError: Error, Equatable {
        case tooShort
        case notAMap
        case missingResponse
    }

    // MARK: Requests

    /// A request message (MS-RDPEWA 2.2.1).
    public static func request(_ command: Command, flags: Flags = [], payload: Data? = nil,
                               timeout: UInt32 = 0, transactionID: Data) -> Data {
        var map: [CBOR: CBOR] = [
            "command": .unsigned(command.rawValue),
            "flags": .unsigned(flags.rawValue),
            "timeout": .unsigned(UInt64(timeout)),
            "transactionId": .bytes(transactionID),
        ]
        if let payload { map["request"] = .bytes(payload) }
        return CBOR.map(map).encoded
    }

    /// Wraps a CTAP2 command and its parameter map for the Windows client.
    public static func webAuthnRequest(_ ctap: CTAPCommand, parameters: Data, flags: Flags,
                                       timeout: UInt32, transactionID: Data) -> Data {
        request(.webAuthn, flags: flags, payload: Data([ctap.rawValue]) + parameters,
                timeout: timeout, transactionID: transactionID)
    }

    /// Request flags implied by a CTAP2 makeCredential/getAssertion parameter map.
    /// A browser only sets the `uv` option when the relying party wants user
    /// verification, so its absence means touch is enough.
    public static func flags(forCTAPParameters parameters: CBOR, command: CTAPCommand) -> Flags {
        let optionsKey = command == .makeCredential ? 7 : 5
        let uv = parameters[optionsKey]?["uv"]?.boolValue ?? false
        return uv ? .uvRequired : .uvNotRequired
    }

    public static func newTransactionID() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    // MARK: Responses

    /// The outcome of a webAuthn request (MS-RDPEWA 2.2.2.1).
    public struct WebAuthnResult: Sendable, Equatable {
        public let hresult: UInt32
        /// CTAP status: 0 is success, see CTAP2 §6.3 for the rest.
        public let ctapStatus: UInt8
        /// The authenticator's CTAP2 response map, encoded.
        public let ctapResponse: Data
        public let device: DeviceInfo?

        public var succeeded: Bool { hresult == 0 && ctapStatus == 0 }
    }

    /// Which authenticator on Windows answered.
    public struct DeviceInfo: Sendable, Equatable {
        public let manufacturer: String?
        public let product: String?
        public let providerType: String?
        public let aaguid: Data?

        public var displayName: String {
            let name = [manufacturer, product].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
            if !name.isEmpty { return name }
            return providerType == "Platform" ? "Windows Hello" : "Security key"
        }
    }

    /// Splits a response message into its HRESULT and command-specific payload.
    public static func split(_ message: Data) throws -> (hresult: UInt32, payload: Data) {
        guard message.count >= 4 else { throw ParseError.tooShort }
        let bytes = [UInt8](message.prefix(4))
        let hresult = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return (hresult, message.dropFirst(4))
    }

    public static func parseWebAuthnResponse(_ message: Data) throws -> WebAuthnResult {
        let (hresult, payload) = try split(message)
        // Failures may carry nothing but the HRESULT.
        guard !payload.isEmpty else {
            return WebAuthnResult(hresult: hresult, ctapStatus: 0x7F, ctapResponse: Data(), device: nil)
        }
        let map = try CBOR.decode(Data(payload))
        guard map.mapValue != nil else { throw ParseError.notAMap }

        let device = map.value(forCaseInsensitiveKey: "deviceInfo").map { info in
            DeviceInfo(manufacturer: info.value(forCaseInsensitiveKey: "manufacturer")?.string,
                       product: info.value(forCaseInsensitiveKey: "product")?.string,
                       providerType: info.value(forCaseInsensitiveKey: "providerType")?.string,
                       aaguid: info.value(forCaseInsensitiveKey: "aaGuid")?.data)
        }
        guard let response = map.value(forCaseInsensitiveKey: "response")?.data, let status = response.first else {
            if hresult != 0 {
                return WebAuthnResult(hresult: hresult, ctapStatus: 0x7F, ctapResponse: Data(), device: device)
            }
            throw ParseError.missingResponse
        }
        return WebAuthnResult(hresult: hresult, ctapStatus: status, ctapResponse: Data(response.dropFirst()),
                              device: device)
    }
}
