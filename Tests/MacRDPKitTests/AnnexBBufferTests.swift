import CoreMedia
import Foundation
import Testing
@testable import MacRDPKit

struct AnnexBBufferTests {
    @Test func convertsAllAVCCHeaderSizesWithoutChangingPayloads() throws {
        for header in [1, 2, 4] {
            let first = Array(repeating: UInt8(0), count: header - 1) + [3, 0x65, 0xAB, 0xCD]
            let second = Array(repeating: UInt8(0), count: header - 1) + [2, 0x61, 0xEF]
            let source = try block(Data(first + second))
            #expect(AnnexB.byteStream(from: source, nalHeaderLength: header) ==
                    Data([0, 0, 0, 1, 0x65, 0xAB, 0xCD, 0, 0, 0, 1, 0x61, 0xEF]))
        }
    }

    @Test func fragmentedBuffersMatchTheContiguousPath() throws {
        let bytes = Data([0, 0, 0, 3, 0x65, 0xAB, 0xCD])
        var fragmented: CMBlockBuffer?
        #expect(CMBlockBufferCreateEmpty(allocator: nil, capacity: 2, flags: 0,
                                        blockBufferOut: &fragmented) == noErr)
        let joined = try #require(fragmented)
        let first = try block(Data(bytes.prefix(2)))
        let second = try block(Data(bytes.dropFirst(2)))
        #expect(CMBlockBufferAppendBufferReference(joined, targetBBuf: first, offsetToData: 0,
                                                  dataLength: first.dataLength, flags: 0) == noErr)
        #expect(CMBlockBufferAppendBufferReference(joined, targetBBuf: second, offsetToData: 0,
                                                  dataLength: second.dataLength, flags: 0) == noErr)
        #expect(!CMBlockBufferIsRangeContiguous(joined, atOffset: 0, length: joined.dataLength))
        let contiguous = try block(bytes)
        #expect(AnnexB.byteStream(from: joined, nalHeaderLength: 4) ==
                AnnexB.byteStream(from: contiguous, nalHeaderLength: 4))
    }

    @Test func rejectsTruncatedHeadersPayloadsAndEmptyNALs() throws {
        for bytes: [UInt8] in [[0, 0], [0, 0, 0, 5, 0x65], [0, 0, 0, 0], [0, 0, 0, 1, 0x65, 0]] {
            let source = try block(Data(bytes))
            #expect(AnnexB.byteStream(from: source, nalHeaderLength: 4) == nil)
        }
    }

    @Test func prefixesParameterSetsBeforeTheEncodedNAL() throws {
        let source = try block(Data([0, 0, 0, 1, 0x65]))
        #expect(AnnexB.byteStream(from: source, nalHeaderLength: 4,
                                 parameterSets: [Data([0x67]), Data([0x68])]) ==
                Data([0, 0, 0, 1, 0x67, 0, 0, 0, 1, 0x68, 0, 0, 0, 1, 0x65]))
    }

    private func block(_ bytes: Data) throws -> CMBlockBuffer {
        var result: CMBlockBuffer?
        #expect(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil,
            blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &result) == noErr)
        let buffer = try #require(result)
        #expect(bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: buffer,
                                           offsetIntoDestination: 0, dataLength: bytes.count)
        } == noErr)
        return buffer
    }
}
