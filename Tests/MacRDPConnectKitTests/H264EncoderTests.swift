import CoreMedia
import Foundation
import os
import Testing
import VideoToolbox
@testable import MacRDPConnectKit

struct H264EncoderTests {
    /// 1080 is not a multiple of 16, which is the common case a remote desktop must handle.
    let width = 1920, height = 1080

    @Test func emitsDecodableAnnexB() throws {
        let units = try encode(frames: 8, keyframeAt: [5])

        #expect(units.count == 8)
        #expect(units.map(\.isKeyframe) == [true, false, false, false, false, true, false, false])

        let first = AnnexB.nalUnits(in: units[0].data).compactMap(AnnexB.type(of:))
        #expect(first.starts(with: [.sps, .pps]))
        #expect(first.contains(.idr))
        for unit in units where !unit.isKeyframe {
            let types = AnnexB.nalUnits(in: unit.data).compactMap(AnnexB.type(of:))
            #expect(types.contains(.slice) && !types.contains(.sps))
        }

        let decoded = try decode(units)
        #expect(decoded.count == 8)
        #expect(decoded.allSatisfy { $0 == (width, height) })
    }

    @Test func splitsThreeAndFourByteStartCodes() {
        let stream = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65])
        let nals = AnnexB.nalUnits(in: stream)
        #expect(nals == [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65])])
    }

    // MARK: helpers

    private func encode(frames: Int, keyframeAt: Set<Int>) throws -> [H264Encoder.AccessUnit] {
        let collected = OSAllocatedUnfairLock(initialState: [H264Encoder.AccessUnit]())
        let encoder = try H264Encoder(width: width, height: height) { unit in
            collected.withLock { $0.append(unit) }
        }
        for i in 0..<frames {
            if keyframeAt.contains(i) { encoder.requestKeyframe() }
            encoder.encode(try syntheticFrame(shift: i * 24), at: CMTime(value: CMTimeValue(i), timescale: 60))
            encoder.flush()
        }
        return collected.withLock { $0 }
    }

    /// NV12 frame with a moving diagonal gradient so every frame differs.
    private func syntheticFrame(shift: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &buffer)
        let pb = try #require(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for y in 0..<height {
            for x in 0..<width {
                luma[y * lumaStride + x] = UInt8(16 + (x + y + shift) % 220)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
        return pb
    }

    /// Rebuilds AVCC samples from our Annex B output and decodes them, proving
    /// a standard decoder (as on the Windows side) accepts the stream.
    private func decode(_ units: [H264Encoder.AccessUnit]) throws -> [(Int, Int)] {
        let firstNALs = AnnexB.nalUnits(in: units[0].data)
        let sps = try #require(firstNALs.first { AnnexB.type(of: $0) == .sps })
        let pps = try #require(firstNALs.first { AnnexB.type(of: $0) == .pps })

        var format: CMFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                p.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [sps.count, pps.count]
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                #expect(status == noErr)
            }
        }
        let fmt = try #require(format)

        var session: VTDecompressionSession?
        #expect(VTDecompressionSessionCreate(allocator: nil, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil,
                                             decompressionSessionOut: &session) == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }

        let sizes = OSAllocatedUnfairLock(initialState: [(Int, Int)]())
        for unit in units {
            var avcc = Data()
            for nal in AnnexB.nalUnits(in: unit.data) where ![.sps, .pps].contains(AnnexB.type(of: nal)) {
                var length = UInt32(nal.count).bigEndian
                avcc.append(Data(bytes: &length, count: 4))
                avcc.append(nal)
            }
            let sample = try makeSample(avcc, format: fmt)
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [],
                                                           infoFlagsOut: nil) { status, _, image, _, _ in
                guard status == noErr, let image else { return }
                let size = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
                sizes.withLock { $0.append(size) }
            }
            #expect(status == noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return sizes.withLock { $0 }
    }

    private func makeSample(_ data: Data, format: CMFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        let bb = try #require(block)
        _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb,
                                                                 offsetIntoDestination: 0, dataLength: data.count) }
        var sample: CMSampleBuffer?
        var size = data.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return try #require(sample)
    }
}
