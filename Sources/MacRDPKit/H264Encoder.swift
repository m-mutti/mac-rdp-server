import CoreMedia
import Foundation
import os
import VideoToolbox

/// Hardware H.264 encoder tuned for remote desktop: low-latency rate control,
/// no B-frames (RDP decodes frames in arrival order) and keyframes only when
/// a client needs to resync.
public final class H264Encoder: @unchecked Sendable {
    public struct Settings: Sendable {
        public var bitrate: Int = 20_000_000
        public var frameRate: Int = 60
        /// Constrained High compresses best; switch to baseline if a client
        /// refuses to decode it.
        public var profile: Profile = .constrainedHigh

        public enum Profile: Sendable {
            case constrainedHigh
            case constrainedBaseline
        }

        public init() {}
    }

    public struct AccessUnit: Sendable {
        /// Annex B bitstream for one frame.
        public let data: Data
        public let isKeyframe: Bool
        public let presentationTime: CMTime
    }

    public enum Failure: Error {
        case sessionCreation(OSStatus)
        case property(String, OSStatus)
    }

    public let width: Int
    public let height: Int
    private let session: VTCompressionSession
    private let output: @Sendable (AccessUnit) -> Void
    private let onDrop: @Sendable () -> Void
    private let needsKeyframe = OSAllocatedUnfairLock(initialState: true)

    /// Every `encode` call ends in exactly one `output` or `onDrop`.
    public init(width: Int, height: Int, settings: Settings = Settings(),
                output: @escaping @Sendable (AccessUnit) -> Void,
                onDrop: @escaping @Sendable () -> Void = {}) throws {
        self.width = width
        self.height = height
        self.output = output
        self.onDrop = onDrop

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let source: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: source as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw Failure.sessionCreation(status) }
        session = created

        let profile = switch settings.profile {
        case .constrainedHigh: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel
        case .constrainedBaseline: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        }
        let properties: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_ProfileLevel, profile),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_ExpectedFrameRate, settings.frameRate),
            (kVTCompressionPropertyKey_AverageBitRate, settings.bitrate),
            // Keyframes are forced on demand; never insert them on a timer.
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
        ]
        for (key, value) in properties {
            let err = VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
            guard err == noErr else {
                VTCompressionSessionInvalidate(created)
                throw Failure.property(key as String, err)
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    /// The next frame will be a keyframe (new client, surface reset, decoder error).
    public func requestKeyframe() {
        needsKeyframe.withLock { $0 = true }
    }

    /// Called on the stream's serial encoding queue, between submissions.
    /// A failed optional retune keeps the previous working encoder settings.
    @discardableResult
    public func setBitrate(_ bitrate: Int, frameRate: Int) -> Bool {
        let rate = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                                       value: bitrate as CFNumber)
        let fps = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                      value: frameRate as CFNumber)
        return rate == noErr && fps == noErr
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let forceKeyframe = needsKeyframe.withLock { pending in
            defer { pending = false }
            return pending
        }
        let frameProperties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let output = self.output
        let onDrop = self.onDrop
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: time, duration: .invalid,
            frameProperties: frameProperties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            // A dropped frame leaves the decoder's reference behind; resync.
            guard status == noErr, let sample, let unit = AnnexB.accessUnit(from: sample) else {
                self?.requestKeyframe()
                onDrop()
                return
            }
            output(AccessUnit(data: unit.data, isKeyframe: unit.isKeyframe,
                              presentationTime: sample.presentationTimeStamp))
        }
        if status != noErr {
            requestKeyframe()
            onDrop()
        }
    }

    /// Blocks until every submitted frame has been emitted.
    public func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }
}
