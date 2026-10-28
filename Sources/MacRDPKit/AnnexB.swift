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

        guard let data = byteStream(from: block, nalHeaderLength: Int(headerLength),
                                    parameterSets: isKeyframe ? parameterSets(of: format) : []) else { return nil }
        return (data, isKeyframe)
    }

    /// CoreMedia normally supplies a contiguous encoded block. Read it in
    /// place while the block is retained; copy only for fragmented buffers.
    static func byteStream(from block: CMBlockBuffer, nalHeaderLength: Int,
                           parameterSets: [Data] = []) -> Data? {
        guard (1...4).contains(nalHeaderLength), block.dataLength > 0 else { return nil }
        var pointer: UnsafeMutablePointer<Int8>?
        var contiguous = 0, total = 0
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous,
                                                totalLengthOut: &total, dataPointerOut: &pointer)
        if status == kCMBlockBufferNoErr, contiguous >= block.dataLength, let pointer {
            return convert(UnsafeRawBufferPointer(start: pointer, count: block.dataLength),
                           headerLength: nalHeaderLength, parameterSets: parameterSets)
        }
        var copied = Data(count: block.dataLength)
        let copiedStatus = copied.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: block.dataLength,
                                       destination: raw.baseAddress!)
        }
        guard copiedStatus == kCMBlockBufferNoErr else { return nil }
        return copied.withUnsafeBytes { convert($0, headerLength: nalHeaderLength, parameterSets: parameterSets) }
    }

    private static func convert(_ raw: UnsafeRawBufferPointer, headerLength: Int,
                                parameterSets: [Data]) -> Data? {
        let bytes = raw.bindMemory(to: UInt8.self)
        func nalSize(at offset: Int) -> Int {
            var size = 0
            for i in 0..<headerLength { size = size << 8 | Int(bytes[offset + i]) }
            return size
        }
        // Validate first and reserve exactly once, including short AVCC headers
        // that expand to four-byte start codes. No per-NAL Data slices are made.
        var outputSize = parameterSets.reduce(0) { $0 + 4 + $1.count }
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= headerLength else { return nil }
            let size = nalSize(at: offset)
            offset += headerLength
            guard size > 0, size <= bytes.count - offset else { return nil }
            outputSize += 4 + size
            offset += size
        }
        var out = Data()
        out.reserveCapacity(outputSize)
        for ps in parameterSets {
            out.append(contentsOf: startCode)
            out.append(ps)
        }
        offset = 0
        while offset < bytes.count {
            let size = nalSize(at: offset)
            offset += headerLength
            out.append(contentsOf: startCode)
            out.append(bytes.baseAddress!.advanced(by: offset), count: size)
            offset += size
        }
        return out
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
