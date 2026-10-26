import AppKit

#if !TAVERN_RENDER_TESTING
#error("SurfaceTypographyTests requires -D TAVERN_RENDER_TESTING")
#endif

private final class TypographyWindow: NSWindow {
    private var scale: CGFloat
    override var backingScaleFactor: CGFloat { scale }

    init(scale: CGFloat, size: NSSize) {
        self.scale = scale
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
    func changeScale(_ scale: CGFloat) {
        self.scale = scale
        contentView?.viewDidChangeBackingProperties()
    }
}

@main struct SurfaceTypographyTests {
    static let canvas = NSSize(width: 480, height: 240)
    static let columns = 48, rows = 8

    static func installContent(_ surface: SurfaceView) throws {
        var cells = Array(repeating: TerminalCell(symbol: " ", foreground: 0x02eeeeee,
            background: 0x021b1c28, modifier: 0, skip: false), count: columns * rows)
        for (row, style) in [UInt16(0), 1, 4, 5].enumerated() {
            for (column, character) in Array("Wide W Ж кириллица e\u{301} 0123456789").enumerated() {
                cells[row * columns + column].symbol = String(character)
                cells[row * columns + column].modifier = style
            }
        }
        cells[4 * columns + 2].symbol = "\u{f07b}"
        cells[4 * columns + 4].symbol = "—"
        try surface.apply(metadata: [
            "boot_id": "typography", "projection_revision": 1, "surface_revision": 1,
            "width": columns, "height": rows,
            "cursor": ["visible": true, "x": 8, "y": 6, "shape": 0],
            "panes": [["pane_id": "typography-pane", "focused": true,
                "mouse_reporting": false, "content_revision": 1,
                "inner_rect": ["x": 0, "y": 0, "width": columns, "height": rows]]]
        ], segments: [CellSegment(x: 0, y: 0, cells: cells)], images: [:], patch: false)
        surface.selectAll(nil)
        surface.setMarkedText("Композиция e\u{301}", selectedRange: NSRange(location: 2, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    static func bitmap(scale: Int) -> NSBitmapImageRep {
        let result = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width) * scale, pixelsHigh: Int(canvas.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        result.size = canvas
        result.bitmapData!.initialize(repeating: 0, count: result.bytesPerRow * result.pixelsHigh)
        return result
    }

    static func draw(_ surface: SurfaceView, rects: [NSRect], into bitmap: NSBitmapImageRep) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: 0, y: canvas.height)
        context.scaleBy(x: 1, y: -1)
        for rect in rects {
            context.saveGState()
            context.clip(to: rect)
            surface.draw(rect)
            context.restoreGState()
        }
    }

    static func pixels(_ bitmap: NSBitmapImageRep) -> Data {
        Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    static func liveChanges(fonts: TerminalFonts, scale: Int) throws {
        let live = SurfaceView(fonts: fonts)
        let window = TypographyWindow(scale: CGFloat(scale), size: canvas)
        window.contentView = live
        live.setFrameSize(canvas)
        try installContent(live)
        let actual = bitmap(scale: scale)
        draw(live, rects: [live.bounds], into: actual)
        var invalidations: [NSRect] = []
        live.onInvalidation = { invalidations.append($0) }
        for (size, weight) in [(16, TerminalFontWeight.thin), (16, .extraLight), (16, .light),
                              (16, .regular), (16, .medium), (16, .semibold), (16, .bold),
                              (16, .extraBold), (24, .extraBold), (13, .thin), (16, .medium)] {
            let next = fonts.configured(size: CGFloat(size), weight: weight)
            let fresh = SurfaceView(fonts: next)
            let referenceWindow = TypographyWindow(scale: CGFloat(scale), size: canvas)
            referenceWindow.contentView = fresh
            fresh.setFrameSize(canvas)
            try installContent(fresh)
            let expected = bitmap(scale: scale)
            draw(fresh, rects: [fresh.bounds], into: expected)
            let before = pixels(actual)
            invalidations.removeAll()
            live.setFonts(next)
            draw(live, rects: invalidations, into: actual)
            precondition(pixels(actual) == pixels(expected),
                "Live font change leaves stale glyph, selection, cursor or marked-text pixels at \(size)/\(weight)/\(scale)x")
            precondition(before != pixels(actual), "Changing the selected face/size must change the terminal's pixels")
            precondition(live.hasMarkedText(), "Changing typography must preserve the current composition")
            referenceWindow.close()
        }
        window.close()
        print("PASS: live size/weight changes match a fresh render with selection, cursor and composition at \(scale)x")
    }

    static func backingChanges(fonts: TerminalFonts) throws {
        let oddSized = fonts.configured(size: 13, weight: .medium)
        let live = SurfaceView(fonts: oddSized)
        let window = TypographyWindow(scale: 1, size: canvas)
        window.contentView = live
        live.setFrameSize(canvas)
        try installContent(live)
        draw(live, rects: [live.bounds], into: bitmap(scale: 1))
        for scale in [2, 1] {
            window.changeScale(CGFloat(scale))
            let actual = bitmap(scale: scale)
            draw(live, rects: [live.bounds], into: actual)
            let fresh = SurfaceView(fonts: oddSized)
            let referenceWindow = TypographyWindow(scale: CGFloat(scale), size: canvas)
            referenceWindow.contentView = fresh
            fresh.setFrameSize(canvas)
            try installContent(fresh)
            let expected = bitmap(scale: scale)
            draw(fresh, rects: [fresh.bounds], into: expected)
            precondition(pixels(actual) == pixels(expected),
                "Backing change retained symbol/em-dash transforms for the old rounded cell size")
            referenceWindow.close()
        }
        window.close()
        print("PASS: odd-sized glyphs and icons match a fresh render after both backing-scale transitions")
    }

    static func main() throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
            preconditionFailure("Pass the built .app as the first argument")
        }
        let fonts = try TerminalFonts.load(size: 16, bundle: bundle)
        try liveChanges(fonts: fonts, scale: 1)
        try liveChanges(fonts: fonts, scale: 2)
        try backingChanges(fonts: fonts)
    }
}
