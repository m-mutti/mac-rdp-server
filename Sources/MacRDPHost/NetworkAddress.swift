import Darwin
import Foundation

/// An IPv4 address Windows can use to reach this Mac.
public struct NetworkAddress: Hashable, Sendable {
    public enum Kind: Int, Sendable, Comparable {
        case local, tailscale, other

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public let interface: String
    public let address: String
    public let kind: Kind

    public var label: String {
        switch kind {
        case .local: "Local network"
        case .tailscale: "Tailscale"
        case .other: "VPN (\(interface))"
        }
    }

    /// Usable addresses, local network first.
    public static func current() -> [NetworkAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }

        var found: [NetworkAddress] = []
        for entry in sequence(first: list, next: { $0?.pointee.ifa_next }) {
            guard let ifa = entry?.pointee, let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let interface = String(cString: ifa.ifa_name)
            guard !address.hasPrefix("169.254.") else { continue } // link-local, unreachable
            found.append(NetworkAddress(interface: interface, address: address,
                                        kind: kind(of: address, interface: interface)))
        }
        return found.sorted { ($0.kind, $0.interface) < ($1.kind, $1.interface) }
    }

    private static func kind(of address: String, interface: String) -> Kind {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        // Tailscale hands out addresses from the 100.64.0.0/10 shared range.
        if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return .tailscale }
        return interface.hasPrefix("en") ? .local : .other
    }
}
