import CoreHID
import Foundation
import MacRDPKit

/// The security key browsers on the Mac see: a virtual USB FIDO device whose
/// requests are answered by the Windows client's security keys and Windows Hello.
///
/// Creating virtual HID devices needs Apple's `com.apple.developer.hid.virtual.device`
/// entitlement; without it macOS refuses and `init` throws `.needsApproval`.
@available(macOS 15, *)
final class VirtualSecurityKey: Sendable {
    enum Failure: Error {
        case needsApproval
    }

    private let device: HIDVirtualDevice
    private let transport: CTAPHIDServer

    init(forward: @escaping CTAPBridge.Forward) async throws {
        let properties = HIDVirtualDevice.Properties(
            descriptor: CTAPHIDServer.reportDescriptor,
            vendorID: 0x1209, productID: 0x0001, // pid.codes test IDs
            transport: .usb,
            product: "mac-rdp-server Security Key",
            manufacturer: "mac-rdp-server",
            serialNumber: "MRS-0001")
        guard let device = HIDVirtualDevice(properties: properties) else { throw Failure.needsApproval }
        let bridge = CTAPBridge(forward: forward)
        let transport = CTAPHIDServer(
            send: { report in try? await device.dispatchInputReport(data: report, timestamp: .now) },
            handle: { await bridge.handle($0) })
        await device.activate(delegate: ReportForwarder(transport: transport))
        self.device = device
        self.transport = transport
    }

    private struct ReportForwarder: HIDVirtualDeviceDelegate {
        let transport: CTAPHIDServer

        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                              id: HIDReportID?, data: Data) async throws {
            guard type == .output else { return }
            await transport.receive(data)
        }

        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                              id: HIDReportID?, maxSize: Int) async throws -> Data {
            Data()
        }
    }
}
