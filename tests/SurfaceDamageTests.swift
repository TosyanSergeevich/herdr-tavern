import AppKit
import CoreGraphics

#if !TAVERN_RENDER_TESTING
#error("SurfaceDamageTests requires -D TAVERN_RENDER_TESTING")
#endif

// A real window supplies backing geometry and coordinate conversion without showing
// a window, changing the user's preferences, or depending on the attached display.
private final class DamageWindow: NSWindow {
    private var fixtureScale: CGFloat
    override var backingScaleFactor: CGFloat { fixtureScale }

    init(scale: CGFloat, size: NSSize) {
        fixtureScale = scale
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    func changeBackingScale(_ scale: CGFloat) {
        fixtureScale = scale
        contentView?.viewDidChangeBackingProperties()
    }
}

@main struct SurfaceDamageTests {
    static let columns = 160, rows = 45

    static func cell(_ symbol: String = " ", style: UInt16 = 0,
                     foreground: UInt32 = 0x02e8e8e8, background: UInt32 = 0x02161628,
                     skip: Bool = false) -> TerminalCell {
        TerminalCell(symbol: symbol, foreground: foreground, background: background,
                     modifier: style, skip: skip)
    }

    static func fixture() -> [TerminalCell] {
        var cells = Array(repeating: cell(), count: columns * rows)
        for row in 0..<rows {
            let text = Array("row \(row): Tavern ASCII Привет мир 0123456789")
            for (x, character) in text.enumerated() {
                cells[row * columns + x] = cell(String(character))
            }
        }
        for (offset, style) in [UInt16(0), 1, 4, 5].enumerated() {
            let x = 5 + offset * 8
            cells[4 * columns + x] = cell("Ж", style: style)
            cells[4 * columns + x + 1] = cell("j", style: style)
            cells[4 * columns + x + 2] = cell("e\u{301}\u{308}", style: style)
        }
        cells[6 * columns + 40] = cell("\u{f07b}", style: 8 | 256)
        for x in 41...43 { cells[6 * columns + x] = cell("", skip: true) }
        cells[8 * columns + 40] = cell("👩‍💻")
        cells[8 * columns + 41] = cell("", skip: true)
        cells[8 * columns + 45] = cell("猫", style: 5)
        cells[8 * columns + 46] = cell("", skip: true)
        cells[10 * columns + 20] = cell("\u{f07b}")
        for x in 21...25 { cells[10 * columns + x] = cell() }
        cells[12 * columns + 19] = cell("\u{f07b}", style: 8 | 256)
        for x in 20...22 { cells[12 * columns + x] = cell("", skip: true) }
        for x in 23...26 { cells[12 * columns + x] = cell() }
        return cells
    }

    private enum Damage { case any, partial, full, none }

    private final class Oracle {
        let surface: SurfaceView
        let window: DamageWindow
        let scale: Int
        let canvas = NSSize(width: 1288, height: 920)
        var cells = SurfaceDamageTests.fixture()
        var revision: UInt64 = 0
        var cursor: [String: Any] = ["visible": false, "x": 70, "y": 24, "shape": 0]
        var placements: [[String: Any]] = []
        var images: [String: CGImage] = [:]
        var invalidations: [NSRect] = []
        var bitmap: NSBitmapImageRep!

        init(scale: Int, fonts: TerminalFonts) throws {
            self.scale = scale
            surface = SurfaceView(fonts: fonts)
            window = DamageWindow(scale: CGFloat(scale), size: NSSize(width: 1280, height: 900))
            window.contentView = surface
            surface.setFrameSize(NSSize(width: 1280, height: 900))
            surface.onInvalidation = { [weak self] rect in self?.invalidations.append(rect) }
            try full()
            bitmap = makeBitmap()
            draw([surface.bounds], into: bitmap)
            invalidations.removeAll()
        }

        func metadata(base: UInt64? = nil) -> [String: Any] {
            var result: [String: Any] = [
                "boot_id": "surface-damage", "projection_revision": 1,
                "surface_revision": revision, "width": columns, "height": rows,
                "cursor": cursor, "placements": placements,
                "panes": [["pane_id": "damage-pane", "focused": true,
                           "mouse_reporting": false, "content_revision": revision,
                           "inner_rect": ["x": 0, "y": 0, "width": columns, "height": rows]]]
            ]
            if let base { result["base_surface_revision"] = base }
            return result
        }

        func full() throws {
            revision += 1
            try surface.apply(metadata: metadata(), segments: [CellSegment(x: 0, y: 0, cells: cells)],
                              images: images, patch: false)
        }

        func patch(_ segments: [CellSegment] = [], cursor nextCursor: [String: Any]? = nil) throws {
            let base = revision
            revision += 1
            if let nextCursor { cursor = nextCursor }
            try surface.apply(metadata: metadata(base: base), segments: segments, images: [:], patch: true)
            for segment in segments {
                let start = segment.y * columns + segment.x
                for (offset, cell) in segment.cells.enumerated() { cells[start + offset] = cell }
            }
        }

        func patch(x: Int, y: Int, _ values: [TerminalCell]) throws {
            try patch([CellSegment(x: x, y: y, cells: values)])
        }

        func makeBitmap() -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(canvas.width) * scale, pixelsHigh: Int(canvas.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = canvas
            bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            return bitmap
        }

        func draw(_ rects: [NSRect], into target: NSBitmapImageRep) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: 0, y: canvas.height)
            context.scaleBy(x: 1, y: -1)
            for rect in rects {
                context.saveGState()
                context.clip(to: rect)
                surface.draw(rect)
                context.restoreGState()
            }
            context.flush()
        }

        func bytes(_ bitmap: NSBitmapImageRep) -> Data {
            Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }

        // Only the hook's actual rects update the existing bitmap. In particular,
        // the reference full draw is never copied back into the incremental image.
        func check(_ name: String, damage: Damage = .any, changesPixels: Bool? = true,
                   _ mutation: () throws -> Void) rethrows {
            let oldPixels = bytes(bitmap)
            invalidations.removeAll()
            try mutation()
            let captured = invalidations
            let label = "\(name), \(scale)x"
            for rect in captured {
                precondition(!rect.isEmpty && surface.bounds.contains(rect), "\(label): invalid damage \(rect)")
                for value in [rect.minX, rect.minY, rect.maxX, rect.maxY] {
                    precondition(abs(value * CGFloat(scale) - (value * CGFloat(scale)).rounded()) < 0.0001,
                                 "\(label): damage is not backing-pixel aligned: \(rect)")
                }
            }
            switch damage {
            case .any: break
            case .partial:
                precondition(!captured.isEmpty, "\(label): no damage")
                precondition(captured.allSatisfy { $0 != surface.bounds }, "\(label): full redraw for local change")
                let area = captured.reduce(CGFloat.zero) { $0 + $1.width * $1.height }
                precondition(area < surface.bounds.width * surface.bounds.height / 4,
                             "\(label): local change damaged most of the surface")
            case .full:
                precondition(captured.contains(surface.bounds), "\(label): missing full invalidation")
            case .none:
                precondition(captured.isEmpty, "\(label): unexpected invalidation \(captured)")
            }
            draw(captured, into: bitmap)
            let reference = makeBitmap()
            draw([surface.bounds], into: reference)
            let actual = bytes(bitmap), expected = bytes(reference)
            if actual != expected {
                let mismatch = actual.indices.first { actual[$0] != expected[$0] }!
                let pixelX = (mismatch % bitmap.bytesPerRow) / 4
                let pixelY = mismatch / bitmap.bytesPerRow
                preconditionFailure("\(label): incremental/full pixel mismatch at raster (\(pixelX), \(pixelY)); damage: \(captured)")
            }
            if let changesPixels {
                precondition((oldPixels != expected) == changesPixels,
                             "\(label): fixture did not exercise the intended visible change")
            }
            print("PASS: \(label)")
        }

        func mouse(_ type: NSEvent.EventType, x: Int, y: Int, clicks: Int = 1) -> NSEvent {
            let location = surface.convert(NSPoint(x: CGFloat(x) * 8 + 4, y: CGFloat(y) * 20 + 10), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: clicks, pressure: 1)!
        }

        func click(x: Int, y: Int, clicks: Int = 1) {
            surface.mouseDown(with: mouse(.leftMouseDown, x: x, y: y, clicks: clicks))
            surface.mouseUp(with: mouse(.leftMouseUp, x: x, y: y, clicks: clicks))
        }

        func select(fromX: Int, fromY: Int, toX: Int, toY: Int) {
            surface.mouseDown(with: mouse(.leftMouseDown, x: fromX, y: fromY))
            surface.mouseDragged(with: mouse(.leftMouseDragged, x: toX, y: toY))
            surface.mouseUp(with: mouse(.leftMouseUp, x: toX, y: toY))
        }

        func shiftArrow(_ code: UInt16) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
            surface.keyDown(with: event)
        }

        func mark(_ text: String) {
            surface.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    private static func glyphCases(_ h: Oracle) throws {
        try h.check("ASCII single cell", damage: .partial) { try h.patch(x: 5, y: 1, [cell("Z")]) }
        try h.check("Cyrillic single cell", damage: .partial) { try h.patch(x: 6, y: 1, [cell("Я")]) }
        for (offset, style) in [UInt16(0), 1, 4, 5].enumerated() {
            let x = 5 + offset * 8
            try h.check("old italic/bold/combining ink shrinks, style \(style)") {
                try h.patch(x: x, y: 4, [cell("i", style: style), cell(), cell(".")])
            }
            try h.check("combining ink expands, style \(style)") {
                try h.patch(x: x, y: 4, [cell("A\u{301}\u{308}\u{327}", style: style)])
            }
        }
        try h.check("wide underline/strike continuation-only patch") {
            try h.patch(x: 43, y: 6, [cell("", background: 0x02402010, skip: true)])
        }
        try h.check("wide anchor and decorations shrink") {
            try h.patch(x: 40, y: 6, [cell("i"), cell(), cell(), cell()])
        }
        try h.check("emoji fallback removed") { try h.patch(x: 40, y: 8, [cell("x"), cell()]) }
        try h.check("emoji fallback inserted") { try h.patch(x: 40, y: 8, [cell("🙂"), cell("", skip: true)]) }
        try h.check("CJK continuation background only") {
            try h.patch(x: 46, y: 8, [cell("", background: 0x02302040, skip: true)])
        }
        try h.check("disjoint ASCII changes", damage: .partial) {
            try h.patch([CellSegment(x: 3, y: 2, cells: [cell("!")]),
                         CellSegment(x: 145, y: 40, cells: [cell("?")])])
        }
    }

    private static func selectionCases(_ h: Oracle) throws {
        h.check("selection begins inside Nerd spill") { h.select(fromX: 21, fromY: 10, toX: 24, toY: 10) }
        try h.check("Nerd left of unchanged selection loses right space") {
            try h.patch(x: 21, y: 10, [cell(background: 0x02302060)])
        }
        try h.check("Nerd left of unchanged selection regains right space") {
            try h.patch(x: 21, y: 10, [cell()])
        }
        try h.check("Nerd left of unchanged selection changes ink color and style") {
            try h.patch(x: 20, y: 10, [cell("\u{f07b}", style: 5, foreground: 0x0240d080)])
        }
        h.check("clear selection by click") { h.click(x: 80, y: 30) }
        h.check("selection inside long continuation span") { h.select(fromX: 22, fromY: 12, toX: 25, toY: 12) }
        try h.check("continuation-only patch recomposites unchanged selection") {
            try h.patch(x: 20, y: 12, [cell("", background: 0x02406020, skip: true)])
        }
        h.check("selection replaced across rows") { h.select(fromX: 10, fromY: 20, toX: 30, toY: 22) }
        h.check("begin dragging the existing range", changesPixels: false) {
            h.surface.mouseDown(with: h.mouse(.leftMouseDown, x: 10, y: 20))
            h.surface.mouseDragged(with: h.mouse(.leftMouseDragged, x: 30, y: 22))
        }
        h.check("active selection shrinks") {
            h.surface.mouseDragged(with: h.mouse(.leftMouseDragged, x: 15, y: 20))
        }
        h.check("active selection reverses around anchor") {
            h.surface.mouseDragged(with: h.mouse(.leftMouseDragged, x: 3, y: 19))
        }
        h.check("mouse up retains selection", changesPixels: false) {
            h.surface.mouseUp(with: h.mouse(.leftMouseUp, x: 3, y: 19))
        }
        h.check("Shift-arrow adjusts existing selection") { h.shiftArrow(124) }
        h.check("Shift-down expands existing selection") { h.shiftArrow(125) }
        h.check("select all") { h.surface.selectAll(nil) }
        h.check("clear all selection") { h.click(x: 100, y: 28) }
        h.check("double click word selection") { h.click(x: 1, y: 15, clicks: 2) }
        try h.check("rewriting selected text clears its overlay") { try h.patch(x: 0, y: 15, [cell("X")]) }
        h.check("click without existing selection", damage: .none, changesPixels: false) { h.click(x: 100, y: 28) }
    }

    private static func cursorAndIMECases(_ h: Oracle) throws {
        for shape in 0...6 {
            try h.check("cursor shape \(shape) show/move", damage: .partial) {
                try h.patch(cursor: ["visible": true, "x": 70 + shape, "y": 24 + shape, "shape": shape])
            }
        }
        try h.check("cursor distant move stays local", damage: .partial) {
            try h.patch(cursor: ["visible": true, "x": 2, "y": 42, "shape": 0])
        }
        try h.check("cursor hide", damage: .partial) {
            try h.patch(cursor: ["visible": false, "x": 2, "y": 42, "shape": 0])
        }
        try h.check("cursor show", damage: .partial) {
            try h.patch(cursor: ["visible": true, "x": 50, "y": 25, "shape": 0])
        }
        h.check("IME long marked text") { h.mark("日本語 composition e\u{301} Привет 👩‍💻") }
        h.check("IME long to short erases old ink") { h.mark("短") }
        try h.check("cursor move relocates marked text") {
            try h.patch(cursor: ["visible": true, "x": 90, "y": 27, "shape": 3])
        }
        h.check("IME short to empty") { h.mark("") }
        h.check("IME marked text after empty") { h.mark("かな入力") }
        h.check("IME unmark erases composition") { h.surface.unmarkText() }
    }

    private static func imageCases(_ h: Oracle) throws {
        var rgba = Data()
        for y in 0..<40 { for x in 0..<64 {
            let alpha: UInt8 = [0, 80, 170, 255][(x / 8 + y / 5) % 4]
            rgba.append(contentsOf: [UInt8(x * 4), UInt8(y * 6), 180, alpha])
        } }
        h.images = ["transparent": try GraphicAssetDecoder.decode(GraphicAsset(id: "transparent", width: 64, height: 40, format: 1, data: rgba))]
        h.placements = [
            ["id": "transparent", "x": 4, "y": 16, "cols": 10, "rows": 3, "z": -2,
             "source_x": -7, "source_y": -5, "source_width": 56, "source_height": 36,
             "x_offset": 3, "y_offset": 4],
            ["id": "transparent", "x": 8, "y": 17, "cols": 9, "rows": 3, "z": 2,
             "source_x": 12, "source_y": 7, "source_width": 60, "source_height": 40,
             "x_offset": 5, "y_offset": 2]
        ]
        try h.check("full transparent cropped negative/positive-z images", damage: .full) { try h.full() }
        try h.check("glyph/background patch beneath overlapping images", damage: .partial) {
            try h.patch(x: 9, y: 18, [cell("Ж", style: 5, background: 0x02604020), cell("Q")])
        }
        try h.check("patch outside image crop", damage: .partial) { try h.patch(x: 2, y: 16, [cell("R")]) }
        h.check("selection over positive-z image") { h.select(fromX: 7, fromY: 17, toX: 14, toY: 19) }
        try h.check("patch beneath image and unchanged selection", changesPixels: false) {
            try h.patch(x: 10, y: 18, [cell("Q", foreground: 0x0220ff30, background: 0x02604020)])
        }
        try h.check("cursor over cropped image", damage: .partial) {
            try h.patch(cursor: ["visible": true, "x": 12, "y": 18, "shape": 0])
        }
        h.check("IME over positive-z image") { h.mark("画像 e\u{301}") }
        h.check("unmark over image") { h.surface.unmarkText() }
        h.check("clear image selection") { h.click(x: 100, y: 28) }
        h.placements[0]["x"] = 24
        h.placements[1]["z"] = -1
        try h.check("full frame relocates image and changes z order", damage: .full) { try h.full() }
    }

    static func main() throws {
        _ = NSApplication.shared
        precondition(CommandLine.arguments.count > 1, "Pass the built .app bundle as the first argument")
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            preconditionFailure("Invalid resource bundle")
        }
        let fonts = try TerminalFonts.load(size: 16, bundle: bundle)
        for scale in [1, 2] {
            let h = try Oracle(scale: scale, fonts: fonts)
            try glyphCases(h)
            try selectionCases(h)
            try cursorAndIMECases(h)
            try imageCases(h)
            try h.check("full frame invalidates bounds", damage: .full, changesPixels: false) { try h.full() }
            h.check("identical geometry does not invalidate", damage: .none, changesPixels: false) {
                h.surface.updateGeometry()
                h.surface.setFrameSize(h.surface.frame.size)
            }
            h.check("backing change refreshes image geometry", damage: .full) {
                h.window.changeBackingScale(CGFloat(3 - scale))
            }
            h.check("pixel geometry changes with same columns/rows", damage: .full) {
                h.surface.setFrameSize(NSSize(width: 1281, height: 901))
            }
            h.check("clear invalidates bounds", damage: .full) { h.surface.clear() }
            h.window.close()
        }
        print("PASS: captured damage replay equals full 160x45 rendering at 1x and 2x")
    }
}
