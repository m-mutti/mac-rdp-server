import CRDPServer
import Foundation
import LocalAuthentication
import Security

/// The user name and password Windows signs in with.
public struct Credentials: Equatable, Sendable {
    public var user: String
    /// nil when the password can't be shown (it was set before the Keychain copy existed).
    public var password: String?

    public init(user: String, password: String?) {
        self.user = user
        self.password = password
    }
}

public enum CredentialError: LocalizedError {
    case invalidUser
    case passwordTooShort

    public var errorDescription: String? {
        switch self {
        case .invalidUser: "The user name can't be empty or contain “:”."
        case .passwordTooShort: "Use at least \(CredentialStore.minimumPasswordLength) characters."
        }
    }
}

/// Stores sign-in credentials. The server only needs the password's NT hash
/// (users.sam, which NTLM sign-in checks against); the password itself is
/// also kept in the login Keychain so the app can show it again.
public enum CredentialStore {
    public static let minimumPasswordLength = 8
    private static let keychainService = "io.github.m-mutti.mac-rdp-server"

    public static func hasPassword(directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: samFile(in: directory).path)
    }

    public static func load(directory: URL, includePassword: Bool = true) -> Credentials? {
        guard let contents = try? String(contentsOf: samFile(in: directory), encoding: .utf8),
              let user = contents.split(separator: ":", omittingEmptySubsequences: false).first,
              !user.isEmpty
        else { return nil }
        return Credentials(user: String(user), password: includePassword ? keychainPassword(user: String(user)) : nil)
    }

    public static func save(user: String, password: String, directory: URL) throws {
        guard !user.isEmpty, !user.contains(":"), !user.contains("\n") else { throw CredentialError.invalidUser }
        guard password.count >= minimumPasswordLength else { throw CredentialError.passwordTooShort }
        try RDPHost.prepare(directory: directory)
        var error = [CChar](repeating: 0, count: 256)
        guard mrs_write_credentials(directory.path, user, password, &error, error.count) == 0 else {
            throw HostError(error)
        }
        // Sign-in works from users.sam alone; the Keychain copy only lets the app show it.
        if let failure = storeInKeychain(password, user: user) {
            log("could not keep the password in the Keychain (\(failure)); it will not be viewable")
        }
    }

    /// A random password without look-alike characters, easy to type on Windows.
    public static func generatePassword(length: Int = 14) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    private static func samFile(in directory: URL) -> URL {
        directory.appendingPathComponent("users.sam")
    }

    private static func storeInKeychain(_ password: String, user: String) -> OSStatus? {
        // One sign-in at a time: drop the previous user's entry too.
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService] as CFDictionary)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: user,
            kSecAttrLabel: "mac-rdp-server sign-in",
            kSecValueData: Data(password.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        return status == errSecSuccess ? nil : status
    }

    private static func keychainPassword(user: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: user,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            // Showing a saved password is optional. Never hold startup or
            // remote input waiting for a Keychain authentication dialog.
            kSecUseAuthenticationContext: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
