import CoreGraphics
import CVirtualDisplay
import Foundation

/// A Mac display standing in for one client monitor.
public struct VirtualMonitor: Sendable, Equatable {
    /// Index into `MonitorLayout.monitors`.
    public let index: Int
    public let displayID: CGDirectDisplayID
    public let mode: VirtualDisplayMode

    /// Current position in Mac global coordinates (points). macOS may nudge
    /// displays after we arrange them, so always read it live.
    public var bounds: CGRect { CGDisplayBounds(displayID) }
}

/// What to do with the Mac's own screens while a client is connected.
public enum PhysicalDisplayPolicy: String, Sendable, CaseIterable {
    /// Physical screens show the client's primary monitor, so no window can
    /// end up somewhere the remote user cannot see.
    case mirror
    /// Leave physical screens as extra desktop space to the right.
    case extend
}

/// Creates one virtual display per client monitor and arranges them like the
/// client's desk. Configuration is applied "for app only", so macOS reverts it
/// if the host process dies; `teardown()` reverts it explicitly.
@MainActor
public final class VirtualDisplayManager {
    public enum Failure: Error, CustomStringConvertible {
        case createFailed(monitor: Int)
        case settingsRejected(monitor: Int)
        case didNotAppear(CGDirectDisplayID)
        case configuration(CGError)

        public var description: String {
            switch self {
            case .createFailed(let i): "macOS refused to create a virtual display for monitor \(i + 1)"
            case .settingsRejected(let i): "macOS rejected the display mode for monitor \(i + 1)"
            case .didNotAppear(let id): "virtual display \(id) never came online"
            case .configuration(let err): "display configuration failed (CGError \(err.rawValue))"
            }
        }
    }

    /// Vendor ID macOS uses (with product/serial) to remember arrangement per display.
    private static let vendorID: UInt32 = 0x4D52 // "MR"

    private var displays: [CGVirtualDisplay] = []
    public private(set) var monitors: [VirtualMonitor] = []
    /// Which session the current displays belong to.
    public private(set) var owner: Int?

    public init() {}

    /// Replaces any existing virtual displays, whoever they belong to, with
    /// ones matching `layout`, owned by `owner`.
    public func apply(_ layout: MonitorLayout,
                      scaling: ScalingPolicy,
                      physical: PhysicalDisplayPolicy,
                      owner: Int? = nil) async throws -> [VirtualMonitor] {
        await removeAll()
        self.owner = owner
        let physicalIDs = Self.onlineDisplays()

        var created: [VirtualMonitor] = []
        for index in layout.monitors.indices {
            let mode = layout.displayMode(for: index, policy: scaling)
            let display = try makeDisplay(index: index, mode: mode, spec: layout.monitors[index])
            displays.append(display)
            created.append(VirtualMonitor(index: index, displayID: display.displayID, mode: mode))
        }

        for monitor in created {
            try await waitUntilOnline(monitor.displayID)
        }

        try configure(created,
                      origins: layout.macOrigins(policy: scaling),
                      primary: created[layout.primaryIndex].displayID,
                      physicalIDs: physicalIDs,
                      physical: physical)
        monitors = created
        return created
    }

    /// Removes the virtual displays if `owner` still owns them (nil: whoever
    /// does); macOS restores the physical arrangement. Returns whether any were removed.
    @discardableResult
    public func teardown(owner: Int? = nil) -> Bool {
        guard !displays.isEmpty, owner == nil || owner == self.owner else { return false }
        let virtualIDs = Set(displays.map(\.displayID))
        var config: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&config) == .success {
            for id in Self.onlineDisplays() where !virtualIDs.contains(id) && CGDisplayIsInMirrorSet(id) != 0 {
                CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            }
            CGCompleteDisplayConfiguration(config, .forAppOnly)
        }
        displays.removeAll()
        monitors.removeAll()
        self.owner = nil
        return true
    }

    /// Removes every display and waits until macOS has let go of them: until
    /// then, displays with the same identity can't be created, and leftovers
    /// would be mistaken for physical screens.
    public func removeAll() async {
        let removed = Set(displays.map(\.displayID))
        guard teardown() else { return }
        for _ in 0..<40 where Self.onlineDisplays().contains(where: removed.contains) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func makeDisplay(index: Int, mode: VirtualDisplayMode, spec: MonitorSpec) throws -> CGVirtualDisplay {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "mac-rdp-server display \(index + 1)"
        descriptor.vendorID = Self.vendorID
        descriptor.productID = 1
        descriptor.serialNum = UInt32(index + 1)
        descriptor.maxPixelsWide = UInt32(mode.pixelWidth)
        descriptor.maxPixelsHigh = UInt32(mode.pixelHeight)
        // Physical size drives the DPI macOS reports; derive it from the
        // Windows scale (100% is 96 DPI) so apps that size by DPI behave.
        let dpi = 96.0 * Double(spec.scalePercent) / 100.0
        descriptor.sizeInMillimeters = CGSize(width: Double(spec.width) / dpi * 25.4,
                                              height: Double(spec.height) / dpi * 25.4)
        descriptor.terminationHandler = { _, _ in }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw Failure.createFailed(monitor: index)
        }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = mode.hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(mode.pointWidth),
                                               height: UInt(mode.pointHeight),
                                               refreshRate: 60)]
        guard display.apply(settings) else {
            throw Failure.settingsRejected(monitor: index)
        }
        return display
    }

    private func waitUntilOnline(_ id: CGDirectDisplayID) async throws {
        for _ in 0..<60 {
            if Self.onlineDisplays().contains(id) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.didNotAppear(id)
    }

    private func configure(_ monitors: [VirtualMonitor],
                           origins: [CGPoint],
                           primary: CGDirectDisplayID,
                           physicalIDs: [CGDirectDisplayID],
                           physical: PhysicalDisplayPolicy) throws {
        var config: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&config)
        guard err == .success else { throw Failure.configuration(err) }

        for (monitor, origin) in zip(monitors, origins) {
            CGConfigureDisplayOrigin(config, monitor.displayID, Int32(origin.x), Int32(origin.y))
        }
        switch physical {
        case .mirror:
            for id in physicalIDs {
                CGConfigureDisplayMirrorOfDisplay(config, id, primary)
            }
        case .extend:
            // Park the physical screens past the right edge of the virtual desk.
            var x = monitors.indices.map { i in
                origins[i].x + CGFloat(monitors[i].mode.pointWidth)
            }.max() ?? 0
            for id in physicalIDs {
                CGConfigureDisplayOrigin(config, id, Int32(x), 0)
                x += CGDisplayBounds(id).width
            }
        }

        err = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard err == .success else { throw Failure.configuration(err) }
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }
}
