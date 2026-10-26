import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MacRDPKit

struct WindowsClipboardTests {
    @Test func unicodeTextRoundTrips() {
        let text = "Hello, 세계 👋"
        let data = WindowsClipboard.unicode(from: text)
        #expect(data.suffix(2) == Data([0, 0]))
        #expect(WindowsClipboard.text(fromUnicode: data) == text)
        // Windows often sends trailing garbage after the terminator.
        #expect(WindowsClipboard.text(fromUnicode: data + Data([0x41, 0x00])) == text)
    }

    @Test func htmlFormatOffsetsPointAtTheContent() throws {
        let html = "<b>bold</b> and <i>ünïcode</i>"
        let data = WindowsClipboard.htmlFormat(from: html)
        let text = String(decoding: data, as: UTF8.self)
        func offset(_ key: String) throws -> Int {
            let line = try #require(text.split(separator: "\r\n").first { $0.hasPrefix(key + ":") })
            return try #require(Int(line.dropFirst(key.count + 1)))
        }
        let bytes = [UInt8](data)
        let start = try offset("StartFragment"), end = try offset("EndFragment")
        #expect(String(decoding: bytes[start..<end], as: UTF8.self) == html)
        #expect(try offset("EndHTML") == bytes.count)
        #expect(WindowsClipboard.html(fromHTMLFormat: data)?.contains(html) == true)
    }

    @Test func parsesHTMLFormatFromWindows() {
        // As Chrome on Windows writes it, with -1 for an absent document.
        let fragment = "<p>pasted</p>"
        let body = "<html><body><!--StartFragment-->\(fragment)<!--EndFragment--></body></html>"
        let header = "Version:0.9\r\nStartHTML:-1\r\nEndHTML:-1\r\nStartFragment:0000000075\r\nEndFragment:0000000088\r\n"
        let data = Data((header + body).utf8)
        let start = header.utf8.count + "<html><body><!--StartFragment-->".utf8.count
        let fixed = header.replacingOccurrences(of: "0000000075", with: String(format: "%010d", start))
            .replacingOccurrences(of: "0000000088", with: String(format: "%010d", start + fragment.utf8.count))
        #expect(WindowsClipboard.html(fromHTMLFormat: Data((fixed + body).utf8)) == fragment)
        #expect(WindowsClipboard.html(fromHTMLFormat: data) != nil)
    }

    @Test func imagesSurviveTheTripThroughWindowsBitmaps() throws {
        let png = try #require(makePNG(width: 3, height: 2, rgb: (200, 30, 60)))
        let dib = try #require(WindowsClipboard.dib(fromImage: png))
        #expect(dib.count == 40 + 3 * 2 * 4)
        let back = try #require(WindowsClipboard.png(fromDIB: dib))
        let pixel = try #require(firstPixel(of: back))
        #expect(pixel.a == 255)
        #expect(abs(Int(pixel.r) - 200) <= 2 && abs(Int(pixel.g) - 30) <= 2 && abs(Int(pixel.b) - 60) <= 2)
    }

    @Test func zeroAlphaInWindowsBitmapsStaysVisible() throws {
        // 32-bit BI_RGB, 1x1, blue pixel with the unused fourth byte set to 0.
        var dib = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { dib.append(contentsOf: $0) } }
        put(UInt32(40)); put(Int32(1)); put(Int32(1)); put(UInt16(1)); put(UInt16(32)); put(UInt32(0))
        put(UInt32(4)); put(Int32(0)); put(Int32(0)); put(UInt32(0)); put(UInt32(0))
        dib.append(contentsOf: [255, 0, 0, 0]) // B, G, R, unused
        let png = try #require(WindowsClipboard.png(fromDIB: dib))
        let pixel = try #require(firstPixel(of: png))
        #expect(pixel.a == 255 && pixel.b > 250 && pixel.r < 5)
    }

    // MARK: helpers

    private func makePNG(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) -> Data? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                                     blue: CGFloat(rgb.2) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private func firstPixel(of png: Data) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2], pixel[3])
    }
}
