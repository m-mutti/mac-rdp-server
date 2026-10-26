import AppKit
import Foundation

/// A cursor shape ready for RDP: top-down BGRA with straight alpha.
struct CursorImage: Equatable {
    var width: Int
    var height: Int
    var hotX: Int
    var hotY: Int
    var bgra: Data
}

/// Mirrors the Mac's current cursor shape to the client, which draws it
/// locally so pointer movement never waits for the network.
@MainActor
final class CursorMirror {
    /// RDP clients accept standard pointers up to 96x96.
    private static let maxSide = 96.0

    private let link: SessionLink
    private let pixelsPerPoint: Double
    private var timer: DispatchSourceTimer?
    private var last: CursorImage?

    init(link: SessionLink, pixelsPerPoint: Double) {
        self.link = link
        self.pixelsPerPoint = pixelsPerPoint
    }

    func start() {
        last = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func poll() {
        guard let cursor = NSCursor.currentSystem,
              let image = render(cursor), image != last else { return }
        last = image
        link.setPointer(image)
    }

    private func render(_ cursor: NSCursor) -> CursorImage? {
        let size = cursor.image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(pixelsPerPoint, Self.maxSide / max(size.width, size.height))
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        var rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        guard width > 0, height > 0,
              let source = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return nil }

        // CoreGraphics only draws premultiplied; RDP wants straight alpha.
        var bgra = Data(bytes: pixels, count: width * height * 4)
        bgra.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] != 0 && p[i + 3] != 255 {
                let a = UInt32(p[i + 3])
                for c in 0..<3 { p[i + c] = UInt8(min(255, UInt32(p[i + c]) * 255 / a)) }
            }
        }
        let hot = cursor.hotSpot
        return CursorImage(width: width, height: height,
                           hotX: min(Int(hot.x * scale), width - 1), hotY: min(Int(hot.y * scale), height - 1),
                           bgra: bgra)
    }
}
