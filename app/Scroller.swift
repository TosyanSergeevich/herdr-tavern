import AppKit

// Меняется только рисунок. Геометрия, доступность, захват и прокрутка — NSScroller.
final class TavernScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    private static let bronze = try! TavernMaterials.bundled.get().scrollerBronze
    private static let wood = try! TavernMaterials.bundled.get().boardWood
    private static let recess = NSColor.black.withAlphaComponent(0.78)
    private static let slotEdge = rgb(0x38291d)
    private static let edges = [rgb(0x8c7049), rgb(0xb49460), rgb(0xd2b17a)]
    private static let groove = rgb(0x251b13).cgColor
    private static let grooveLight = rgb(0xa48a60).cgColor
    private static let finishes: [NSGradient] = [
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.36),
                            NSColor.white.withAlphaComponent(0.05), NSColor.black.withAlphaComponent(0.30)])!,
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.22),
                            NSColor.white.withAlphaComponent(0.12), NSColor.black.withAlphaComponent(0.24)])!,
        NSGradient(colors: [NSColor.black.withAlphaComponent(0.30),
                            NSColor.white.withAlphaComponent(0.16), NSColor.black.withAlphaComponent(0.36)])!
    ]
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var pressed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area); hoverArea = area
    }
    private func updateHover(at point: NSPoint) {
        let next = rect(for: .knob).contains(point)
        if hovered != next { hovered = next; needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        pressed = testPart(convert(event.locationInWindow, from: nil)) == .knob
        needsDisplay = true; displayIfNeeded()
        defer {
            pressed = false
            if let window { updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
            needsDisplay = true
        }
        super.mouseDown(with: event)
    }

    private func inset(_ rect: NSRect, cross: CGFloat, along: CGFloat) -> NSRect {
        bounds.height >= bounds.width ? rect.insetBy(dx: cross, dy: along) : rect.insetBy(dx: along, dy: cross)
    }
    private func outline(_ rect: NSRect) -> NSBezierPath {
        let cut = min(2, min(rect.width, rect.height) * 0.25)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + cut, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - cut, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY + cut))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - cut))
        path.line(to: NSPoint(x: rect.maxX - cut, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX + cut, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - cut))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + cut))
        path.close()
        return path
    }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        let slot = inset(slotRect, cross: -1, along: 1)
        guard slot.width > 0, slot.height > 0 else { return }
        let path = NSBezierPath(roundedRect: slot, xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        TavernMaterials.drawTiled(Self.wood, from: NSRect(origin: .zero, size: Self.wood.size),
                                  in: slot, scale: 1)
        Self.recess.setFill(); slot.fill()
        NSGraphicsContext.restoreGraphicsState()
        Self.slotEdge.setStroke(); path.lineWidth = 0.75; path.stroke()
    }
    override func drawKnob() {
        // AppKit уже сужает rect(.knob), особенно в overlay-режиме.
        // Запас внутри штатной hit-area даёт читаемую фаску без смены геометрии.
        let knob = inset(rect(for: .knob), cross: -0.5, along: 1)
        guard knob.width > 0, knob.height > 0 else { return }
        let state = pressed ? 2 : (hovered ? 1 : 0)
        let path = outline(knob)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // Явные координаты тайлов не зависят от device-space phase,
        // которую AppKit меняет при перерисовке состояния контрола.
        TavernMaterials.drawTiled(Self.bronze, from: NSRect(origin: .zero, size: Self.bronze.size),
                                  in: knob, scale: 1)
        Self.finishes[state].draw(in: knob, angle: bounds.height >= bounds.width ? 0 : 90)
        NSGraphicsContext.restoreGraphicsState()
        Self.edges[state].setStroke(); path.lineWidth = 0.8; path.stroke()
        let inner = outline(knob.insetBy(dx: 1, dy: 1))
        Self.slotEdge.setStroke(); inner.lineWidth = 0.5; inner.stroke()
        drawGrip(in: knob)
    }
    private func drawGrip(in knob: NSRect) {
        let vertical = bounds.height >= bounds.width
        guard (vertical ? knob.height : knob.width) >= 20,
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setLineWidth(1)
        for offset in -1...1 {
            let step = CGFloat(offset) * 3
            let start = vertical ? NSPoint(x: knob.minX + 2, y: knob.midY + step)
                                 : NSPoint(x: knob.midX + step, y: knob.minY + 2)
            let end = vertical ? NSPoint(x: knob.maxX - 2, y: start.y)
                               : NSPoint(x: start.x, y: knob.maxY - 2)
            context.setStrokeColor(Self.groove)
            context.move(to: start); context.addLine(to: end); context.strokePath()
            let shift = vertical ? NSPoint(x: 0, y: 1) : NSPoint(x: 1, y: 0)
            context.setStrokeColor(Self.grooveLight)
            context.move(to: NSPoint(x: start.x + shift.x, y: start.y + shift.y))
            context.addLine(to: NSPoint(x: end.x + shift.x, y: end.y + shift.y)); context.strokePath()
        }
    }
}
