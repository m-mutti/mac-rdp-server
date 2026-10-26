import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Conversions between Mac clipboard data and the Windows clipboard formats
/// Remote Desktop carries (MS-RDPECLIP).
public enum WindowsClipboard {
    /// What the Mac and Windows clipboards can exchange.
    public enum Kind: Sendable, Equatable {
        case text, html, rtf, png, bitmap
    }

    /// Standard Windows format IDs.
    public static let unicodeText: UInt32 = 13 // CF_UNICODETEXT
    public static let dib: UInt32 = 8 // CF_DIB
    public static let dibV5: UInt32 = 17 // CF_DIBV5

    /// Registered format names, as Windows apps announce them.
    public static let htmlName = "HTML Format"
    public static let rtfName = "Rich Text Format"
    public static let pngName = "PNG"

    // MARK: Text

    /// Windows text is UTF-16LE, ending at the first NUL.
    public static func text(fromUnicode data: Data) -> String? {
        var units = [UInt16]()
        units.reserveCapacity(data.count / 2)
        for i in stride(from: data.startIndex, to: data.endIndex - 1, by: 2) {
            let unit = UInt16(data[i]) | UInt16(data[i + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }

    public static func unicode(from text: String) -> Data {
        var data = Data(capacity: text.utf16.count * 2 + 2)
        for unit in text.utf16 { data.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        data.append(contentsOf: [0, 0])
        return data
    }

    // MARK: HTML

    /// Wraps HTML in the "HTML Format" header, whose byte offsets tell Windows
    /// apps where the document and the copied fragment are.
    public static func htmlFormat(from html: String) -> Data {
        let prefix = "<html><body>\r\n<!--StartFragment-->"
        let suffix = "<!--EndFragment-->\r\n</body>\r\n</html>"
        func header(_ startHTML: Int, _ endHTML: Int, _ startFragment: Int, _ endFragment: Int) -> String {
            func n(_ v: Int) -> String { String(format: "%010d", v) }
            return "Version:0.9\r\nStartHTML:\(n(startHTML))\r\nEndHTML:\(n(endHTML))\r\n"
                + "StartFragment:\(n(startFragment))\r\nEndFragment:\(n(endFragment))\r\n"
        }
        let headerLength = header(0, 0, 0, 0).utf8.count
        let startFragment = headerLength + prefix.utf8.count
        let endFragment = startFragment + html.utf8.count
        let endHTML = endFragment + suffix.utf8.count
        return Data((header(headerLength, endHTML, startFragment, endFragment) + prefix + html + suffix).utf8)
    }

    /// The HTML inside "HTML Format" data: the whole document when its offsets
    /// are valid, otherwise the fragment.
    public static func html(fromHTMLFormat data: Data) -> String? {
        let bytes = [UInt8](data.prefix { $0 != 0 })
        guard let headerEnd = bytes.firstIndex(of: UInt8(ascii: "<")) else { return nil }
        var offsets: [String: Int] = [:]
        for line in String(decoding: bytes[..<headerEnd], as: UTF8.self).split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                offsets[String(parts[0])] = value
            }
        }
        for (start, end) in [("StartHTML", "EndHTML"), ("StartFragment", "EndFragment")] {
            if let s = offsets[start], let e = offsets[end], 0 <= s, s < e, e <= bytes.count {
                return String(decoding: bytes[s..<e], as: UTF8.self)
            }
        }
        return String(decoding: bytes[headerEnd...], as: UTF8.self)
    }

    // MARK: Images

    /// A Windows device-independent bitmap (CF_DIB/CF_DIBV5) as PNG.
    public static func png(fromDIB dib: Data) -> Data? {
        let bytes = [UInt8](dib)
        guard bytes.count >= 40 else { return nil }
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        let headerSize = u32(0), bitCount = Int(bytes[14]) | Int(bytes[15]) << 8
        let compression = u32(16), colorsUsed = u32(32)
        guard headerSize >= 40, headerSize < bytes.count else { return nil }
        // Pixels follow the header, the BI_BITFIELDS masks of a plain
        // BITMAPINFOHEADER, and any color table.
        let masks = headerSize == 40 ? (compression == 3 ? 12 : compression == 6 ? 16 : 0) : 0
        let colors = colorsUsed != 0 ? colorsUsed : (bitCount <= 8 ? 1 << bitCount : 0)
        let pixelOffset = 14 + headerSize + masks + colors * 4
        let fileSize = 14 + bytes.count
        // BITMAPFILEHEADER: "BM", file size, two reserved 16-bit words, pixel offset.
        var file = Data([0x42, 0x4D])
        for v in [UInt32(fileSize), 0, UInt32(pixelOffset)] { withUnsafeBytes(of: v.littleEndian) { file.append(contentsOf: $0) } }
        file.append(dib)
        guard let source = CGImageSourceCreateWithData(file as CFData, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        // In 32-bit BI_RGB bitmaps the fourth byte is unused, often zero: treat
        // the image as opaque rather than invisible.
        if bitCount == 32, compression == 0, let opaque = opaqueCopy(of: image) { image = opaque }
        return encode(image, as: .png)
    }

    /// A PNG or TIFF image as a 32-bit Windows DIB (BITMAPINFOHEADER), flattened
    /// onto white because many Windows apps ignore the alpha byte.
    public static func dib(fromImage data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let pixels = context.data else { return nil }

        var out = Data(capacity: 40 + width * height * 4)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put(UInt32(40)); put(Int32(width)); put(Int32(height)) // positive height: bottom-up rows
        put(UInt16(1)); put(UInt16(32)); put(UInt32(0)) // planes, bits, BI_RGB
        put(UInt32(width * height * 4)); put(Int32(2835)); put(Int32(2835)) // size, 72 dpi
        put(UInt32(0)); put(UInt32(0))
        // CGContext memory is top-down; DIB rows run bottom-up.
        let rowBytes = width * 4
        for row in (0..<height).reversed() {
            out.append(Data(bytes: pixels + row * rowBytes, count: rowBytes))
        }
        return out
    }

    /// Re-encodes TIFF (or anything ImageIO reads) as PNG.
    public static func png(fromImage data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encode(image, as: .png)
    }

    private static func encode(_ image: CGImage, as type: UTType) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private static func opaqueCopy(of image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
