import AppKit

@main struct ScrollerTextureTests {
    static let pixels = 800
    static let firstOrigin = NSPoint(x: 10, y: 10)
    static let secondOrigin = NSPoint(x: 31, y: 73)

    static func render(_ scroller: TavernScroller, origin: NSPoint, slot: Bool = false,
                       clip: NSRect? = nil) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        bitmap.size = NSSize(width: pixels / 2, height: pixels / 2)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.clear(NSRect(origin: .zero, size: bitmap.size))
        context.translateBy(x: origin.x, y: origin.y)
        if let clip { context.clip(to: clip) }
        if slot { scroller.drawKnobSlot(in: scroller.rect(for: .knobSlot), highlight: false) }
        else { scroller.drawKnob() }
        return bitmap
    }

    static func unchanged(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, rect: NSRect,
                          first: NSPoint = firstOrigin, second: NSPoint = secondOrigin,
                          scenario: String, tolerance: Int = 0) {
        let left = a.bitmapData!, right = b.bitmapData!
        var error = 0
        for y in Int(ceil(rect.minY * 2))..<Int(floor(rect.maxY * 2)) {
            for x in Int(ceil(rect.minX * 2))..<Int(floor(rect.maxX * 2)) {
                let p = (pixels - 1 - y - Int((first.y * 2).rounded())) * a.bytesPerRow
                    + (x + Int((first.x * 2).rounded())) * 4
                let q = (pixels - 1 - y - Int((second.y * 2).rounded())) * b.bytesPerRow
                    + (x + Int((second.x * 2).rounded())) * 4
                for channel in 0..<4 { error = max(error, abs(Int(left[p + channel]) - Int(right[q + channel]))) }
            }
        }
        precondition(error <= tolerance, "\(scenario): фактура сместилась, ошибка канала \(error)")
    }

    static func main() {
        _ = NSApplication.shared
        for style in [NSScroller.Style.legacy, .overlay] {
            for horizontal in [false, true] {
                let label = "\(style == .legacy ? "legacy" : "overlay") / \(horizontal ? "горизонтальный" : "вертикальный")"
                let scroller = TavernScroller(frame: NSRect(x: 0, y: 0,
                    width: horizontal ? 240 : 14, height: horizontal ? 14 : 240))
                scroller.controlSize = .small; scroller.scrollerStyle = style
                scroller.knobProportion = 0.4; scroller.doubleValue = 0.3
                let knob = scroller.rect(for: .knob)
                let sample = knob.insetBy(dx: horizontal ? 4 : 1, dy: horizontal ? 1 : 4)
                precondition(sample.width >= 2 && sample.height >= 2, "Нет внутренности ползунка: \(label)")
                let normal = render(scroller, origin: firstOrigin)
                unchanged(normal, render(scroller, origin: secondOrigin), rect: sample,
                          scenario: "\(label), повторная отрисовка")
                let point = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                scroller.mouseEntered(with: event)
                unchanged(render(scroller, origin: firstOrigin), render(scroller, origin: secondOrigin),
                          rect: sample, scenario: "\(label), наведение")
                scroller.mouseExited(with: event)
                let partial = horizontal ? NSRect(x: sample.midX, y: sample.minY, width: sample.width / 2, height: sample.height)
                                         : NSRect(x: sample.minX, y: sample.midY, width: sample.width, height: sample.height / 2)
                // При иной clip-области CoreGraphics округляет смешивание на 1
                // в 8-битном канале, как и в MaterialsTests. Полные кадры — точно.
                unchanged(normal, render(scroller, origin: secondOrigin, clip: partial), rect: partial,
                          scenario: "\(label), частичная перерисовка", tolerance: 1)
                let slot = scroller.rect(for: .knobSlot).insetBy(dx: 1, dy: 1)
                unchanged(render(scroller, origin: firstOrigin, slot: true),
                          render(scroller, origin: secondOrigin, slot: true), rect: slot,
                          scenario: "\(label), деревянный паз")
                scroller.doubleValue = 0.6
                let moved = scroller.rect(for: .knob)
                let movedOrigin = NSPoint(x: firstOrigin.x + moved.minX - knob.minX,
                                          y: firstOrigin.y + moved.minY - knob.minY)
                unchanged(normal, render(scroller, origin: firstOrigin), rect: sample,
                          second: movedOrigin, scenario: "\(label), перемещение")
                print("PASS: \(label) — покой, наведение, частичный кадр, паз, перемещение")
            }
        }
    }
}
