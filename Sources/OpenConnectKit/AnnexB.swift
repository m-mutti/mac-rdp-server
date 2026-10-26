import CoreMedia
import Foundation

/// Converts between VideoToolbox's length-prefixed (AVCC) H.264 samples and
/// the start-code delimited Annex B stream that RDP's AVC420 codec carries.
public enum AnnexB {
    public static let startCode: [UInt8] = [0, 0, 0, 1]

    public enum NALType: UInt8 {
        case slice = 1
        case idr = 5
        case sei = 6
        case sps = 7
        case pps = 8
    }

    /// One encoded frame as Annex B. Keyframes are prefixed with SPS/PPS so a
    /// decoder can start from any of them.
    public static func accessUnit(from sample: CMSampleBuffer) -> (data: Data, isKeyframe: Bool)? {
        guard let block = sample.dataBuffer,
              let format = sample.formatDescription else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var headerLength: Int32 = 4
        var parameterSetCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: &headerLength)

        var out = Data()
        if isKeyframe {
            for ps in parameterSets(of: format) {
                out.append(contentsOf: startCode)
                out.append(ps)
            }
        }

        var avcc = Data(count: block.dataLength)
        let copied = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: block.dataLength,
                                       destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var offset = 0
        let length = Int(headerLength)
        while offset + length <= avcc.count {
            var nalSize = 0
            for i in 0..<length {
                nalSize = (nalSize << 8) | Int(avcc[avcc.startIndex + offset + i])
            }
            offset += length
            guard nalSize > 0, offset + nalSize <= avcc.count else { return nil }
            out.append(contentsOf: startCode)
            out.append(avcc[(avcc.startIndex + offset)..<(avcc.startIndex + offset + nalSize)])
            offset += nalSize
        }
        return (out, isKeyframe)
    }

    public static func parameterSets(of format: CMFormatDescription) -> [Data] {
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return (0..<count).compactMap { i in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }

    /// Splits an Annex B stream into NAL units (without start codes).
    /// Accepts both 3- and 4-byte start codes.
    public static func nalUnits(in stream: Data) -> [Data] {
        let bytes = [UInt8](stream)
        var starts: [(code: Int, payload: Int)] = []
        var i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let code = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                starts.append((code, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.indices.map { n in
            let end = n + 1 < starts.count ? starts[n + 1].code : bytes.count
            return Data(bytes[starts[n].payload..<end])
        }
    }

    public static func type(of nal: Data) -> NALType? {
        nal.first.flatMap { NALType(rawValue: $0 & 0x1F) }
    }
}
