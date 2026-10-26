import CoreGraphics
import Testing
@testable import OpenConnectKit

struct RDPInputEventTests {
    @Test func keyboardFlags() {
        #expect(RDPInputEvent.keyboard(flags: 0, scancode: 0x1E) == .key(scancode: 0x1E, extended: false, down: true))
        #expect(RDPInputEvent.keyboard(flags: 0x8100, scancode: 0x48) == .key(scancode: 0x48, extended: true, down: false))
        // Pause/Break arrives as EXTENDED1 + 0x1D and must not press Control.
        #expect(RDPInputEvent.keyboard(flags: 0x0200, scancode: 0x1D) == nil)
    }

    @Test func wheelRotationIsSigned() {
        // One notch down: WHEEL | NEGATIVE | 0x88  ->  0x188 - 0x200 = -120
        #expect(RDPInputEvent.mouse(flags: 0x0200 | 0x0188, x: 5, y: 5) == [.wheel(vertical: -120, horizontal: 0)])
        #expect(RDPInputEvent.mouse(flags: 0x0200 | 0x0078, x: 0, y: 0) == [.wheel(vertical: 120, horizontal: 0)])
        #expect(RDPInputEvent.mouse(flags: 0x0400 | 0x0078, x: 0, y: 0) == [.wheel(vertical: 0, horizontal: 120)])
    }

    @Test func buttonsAndMoves() {
        let p = CGPoint(x: 100, y: 200)
        #expect(RDPInputEvent.mouse(flags: 0x0800, x: 100, y: 200) == [.move(p)])
        #expect(RDPInputEvent.mouse(flags: 0x8000 | 0x1000, x: 100, y: 200) == [.button(.left, down: true, at: p)])
        #expect(RDPInputEvent.mouse(flags: 0x2000, x: 100, y: 200) == [.button(.right, down: false, at: p)])
        #expect(RDPInputEvent.extendedMouse(flags: 0x8000 | 0x0002, x: 100, y: 200) == [.button(.forward, down: true, at: p)])
    }
}
