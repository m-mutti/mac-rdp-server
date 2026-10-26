import CoreGraphics

/// One client monitor, as an RDP client reports it (TS_MONITOR_DEF + TS_MONITOR_ATTRIBUTES).
public struct MonitorSpec: Equatable, Sendable {
    /// Client virtual-desktop pixels. The client's primary monitor is at (0,0);
    /// the others can have negative origins.
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public var isPrimary: Bool
    /// Windows display scale for this monitor in percent (100, 125, 150, 200...).
    public var scalePercent: Int

    public init(x: Int, y: Int, width: Int, height: Int, isPrimary: Bool = false, scalePercent: Int = 100) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
        self.scalePercent = scalePercent
    }

    public var frame: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// How client pixels translate into Mac points on the virtual displays.
public enum ScalingPolicy: String, Sendable, CaseIterable {
    /// One Mac point per client pixel. Small text on high-DPI monitors.
    case native
    /// Mirror the Windows scale setting: a 4K monitor at 150% becomes a
    /// HiDPI display that "looks like" 2560x1440, exactly like a Retina Mac.
    case matchClient
}

/// The client's monitors normalized into RDP desktop space: the bounding box's
/// top-left corner is (0,0), which is what RDP input coordinates are relative to.
public struct MonitorLayout: Equatable, Sendable {
    public let monitors: [MonitorSpec]
    public let primaryIndex: Int

    /// Errors describe layouts the client should never send but a buggy or hostile one could.
    public enum Invalid: Error, Equatable {
        case empty
        case badSize(index: Int)
        case tooLarge
    }

    /// RDP caps the desktop at 32766 pixels per side (MS-RDPBCGR 2.2.1.3.6.1).
    static let maxDesktopSide = 32766

    public init(_ specs: [MonitorSpec]) throws {
        guard !specs.isEmpty else { throw Invalid.empty }
        for (i, m) in specs.enumerated() where m.width < 200 || m.height < 200 || m.width > 8192 || m.height > 8192 {
            throw Invalid.badSize(index: i)
        }
        let minX = specs.map(\.x).min()!
        let minY = specs.map(\.y).min()!
        monitors = specs.map { m in
            var n = m
            n.x -= minX
            n.y -= minY
            n.scalePercent = min(max(m.scalePercent, 100), 500)
            return n
        }
        primaryIndex = monitors.firstIndex(where: \.isPrimary) ?? 0
        let size = desktopSize
        if size.width > Self.maxDesktopSide || size.height > Self.maxDesktopSide { throw Invalid.tooLarge }
    }

    /// A single monitor filling the whole desktop (client did not enable multimon).
    public static func single(width: Int, height: Int, scalePercent: Int = 100) throws -> MonitorLayout {
        try MonitorLayout([MonitorSpec(x: 0, y: 0, width: width, height: height, isPrimary: true, scalePercent: scalePercent)])
    }

    public var desktopSize: (width: Int, height: Int) {
        (monitors.map { $0.x + $0.width }.max()!, monitors.map { $0.y + $0.height }.max()!)
    }

    /// Index of the monitor under a desktop-space point, falling back to the
    /// nearest one so points in gaps between monitors still land somewhere.
    public func monitorIndex(at point: CGPoint) -> Int {
        if let hit = monitors.firstIndex(where: { $0.frame.contains(point) }) {
            return hit
        }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + dy * dy
        }
        return monitors.indices.min { distance(monitors[$0].frame) < distance(monitors[$1].frame) }!
    }

    /// The virtual display mode to create for a monitor.
    public func displayMode(for index: Int, policy: ScalingPolicy) -> VirtualDisplayMode {
        let m = monitors[index]
        switch policy {
        case .native:
            return VirtualDisplayMode(pointWidth: m.width, pointHeight: m.height, hiDPI: false)
        case .matchClient where m.scalePercent > 100:
            return VirtualDisplayMode(
                pointWidth: m.width * 100 / m.scalePercent,
                pointHeight: m.height * 100 / m.scalePercent,
                hiDPI: true)
        case .matchClient:
            return VirtualDisplayMode(pointWidth: m.width, pointHeight: m.height, hiDPI: false)
        }
    }

    /// Where each virtual display should sit in Mac global coordinates (points),
    /// with the client's primary monitor becoming the Mac main display at (0,0).
    public func macOrigins(policy: ScalingPolicy) -> [CGPoint] {
        let primary = monitors[primaryIndex]
        return monitors.indices.map { i in
            let m = monitors[i]
            let mode = displayMode(for: i, policy: policy)
            let pointsPerPixel = CGFloat(mode.pointWidth) / CGFloat(m.width)
            return CGPoint(x: CGFloat(m.x - primary.x) * pointsPerPixel,
                           y: CGFloat(m.y - primary.y) * pointsPerPixel)
        }
    }
}

public struct VirtualDisplayMode: Equatable, Sendable {
    public var pointWidth: Int
    public var pointHeight: Int
    public var hiDPI: Bool

    public var pixelWidth: Int { hiDPI ? pointWidth * 2 : pointWidth }
    public var pixelHeight: Int { hiDPI ? pointHeight * 2 : pointHeight }
}
