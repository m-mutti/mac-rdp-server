import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Streams one display's pixels with ScreenCaptureKit. Frames arrive only
/// when something on screen changes, so an idle desktop costs nothing.
public final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public struct Frame: @unchecked Sendable {
        /// NV12 (420v), BT.709 — the encoder's native input, no conversion.
        public let pixelBuffer: CVPixelBuffer
        public let time: CMTime
        /// Changed areas in pixels. Empty means "assume everything changed".
        public let dirtyRects: [CGRect]
    }

    public enum Failure: Error, CustomStringConvertible {
        case displayNotShareable(CGDirectDisplayID)

        public var description: String {
            switch self {
            case .displayNotShareable(let id):
                "display \(id) is not available to ScreenCaptureKit (is Screen Recording allowed?)"
            }
        }
    }

    public let displayID: CGDirectDisplayID
    public let pixelWidth: Int
    public let pixelHeight: Int
    private let maxFrameRate: Int
    private let onFrame: @Sendable (Frame) -> Void
    private let onStop: @Sendable (Error?) -> Void
    private let queue = DispatchQueue(label: "mac-rdp-server.capture", qos: .userInteractive)
    private var stream: SCStream?

    public init(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int, maxFrameRate: Int = 60,
                onFrame: @escaping @Sendable (Frame) -> Void,
                onStop: @escaping @Sendable (Error?) -> Void = { _ in }) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.maxFrameRate = maxFrameRate
        self.onFrame = onFrame
        self.onStop = onStop
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayNotShareable(displayID)
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(maxFrameRate))
        config.queueDepth = 6
        // The client draws the pointer locally from shape updates, which hides
        // network latency; baking it into the video would show it twice.
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sample.imageBuffer
        else { return }

        let dirty = (info[.dirtyRects] as? [NSDictionary] ?? []).compactMap { dict -> CGRect? in
            CGRect(dictionaryRepresentation: dict)
        }
        onFrame(Frame(pixelBuffer: pixelBuffer, time: sample.presentationTimeStamp, dirtyRects: dirty))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop(error)
    }
}
