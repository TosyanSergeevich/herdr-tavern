import AppKit
import CoreText

@main struct SurfaceGlyphTests {
    static let scale = 4

    static func render(_ surface: SurfaceView, cells: [TerminalCell], dirty: NSRect? = nil) throws -> NSBitmapImageRep {
        try surface.apply(metadata: ["boot_id": "glyph-test", "projection_revision": 1,
                                     "surface_revision": 1, "width": cells.count, "height": 1],
                          segments: [CellSegment(x: 0, y: 0, cells: cells)], images: [:], patch: false)
        surface.setFrameSize(NSSize(width: CGFloat(cells.count) * 8, height: 20))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cells.count * 8 * scale,
                                      pixelsHigh: 20 * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = surface.bounds.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.translateBy(x: 0, y: 20)
        context.scaleBy(x: 1, y: -1)
        if let dirty { context.clip(to: dirty) }
        surface.draw(dirty ?? surface.bounds)
        return bitmap
    }

    static func ink(_ bitmap: NSBitmapImageRep, from: Int = 0, to: Int? = nil) -> NSRect {
        var left = bitmap.pixelsWide, right = -1, bottom = bitmap.pixelsHigh, top = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in (from * scale)..<((to ?? (bitmap.pixelsWide / scale)) * scale) {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.redComponent > 0.65 && color.greenComponent > 0.65 && color.blueComponent > 0.65 {
                    left = min(left, x); right = max(right, x); bottom = min(bottom, y); top = max(top, y)
                }
            }
        }
        if right < left { return .zero }
        return NSRect(x: CGFloat(left) / CGFloat(scale), y: CGFloat(bottom) / CGFloat(scale),
                      width: CGFloat(right - left + 1) / CGFloat(scale), height: CGFloat(top - bottom + 1) / CGFloat(scale))
    }

    static func main() throws {
        _ = NSApplication.shared
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            preconditionFailure("Pass the built .app bundle as the first argument")
        }
        let surface = SurfaceView(fonts: try TerminalFonts.load(size: 16, bundle: bundle))
        func cell(_ symbol: String, style: UInt16 = 0, background: UInt32 = 0x02000000, skip: Bool = false) -> TerminalCell {
            TerminalCell(symbol: symbol, foreground: 0x02ffffff, background: background, modifier: style, skip: skip)
        }
        var neighbor = cell("X")
        neighbor.foreground = 0x0200ff00
        let textHeight = ink(try render(surface, cells: [cell("A"), cell(" ")])).height
        for scalar: UInt32 in [0xf07b, 0xf013, 0xf002, 0xf121, 0xf115, 0xf489, 0xf0001] {
            let symbol = String(UnicodeScalar(scalar)!)
            for style: UInt16 in [0, 1, 4, 5] {
                let spacious = ink(try render(surface, cells: [cell(symbol, style: style), cell(" "), neighbor]))
                precondition(spacious.height >= textHeight * 0.9, "Иконка \(scalar)/\(style) меньше текста: \(spacious)")
                precondition(spacious.maxX <= 16, "Иконка перекрывает текст после пробела")
                let tight = ink(try render(surface, cells: [cell(symbol, style: style), neighbor]))
                precondition(tight.maxX <= 8, "Иконка перекрывает соседний текст без пробела")
                precondition(tight.height < spacious.height, "Иконка без свободной ячейки не уменьшилась")
                let differentBackground = ink(try render(surface, cells: [cell(symbol, style: style), cell(" ", background: 0x02000080)]))
                precondition(differentBackground.maxX <= 8, "Иконка перекрывает ячейку с другим фоном")
                precondition(abs(differentBackground.height - tight.height) < 1, "Иконка заходит на другой фон")
            }
        }
        print("PASS: семь реальных Nerd-глифов, четыре начертания, свободный пробел/соседний текст/разный фон")
        let lastCell = ink(try render(surface, cells: [cell("\u{f07b}")]))
        precondition(lastCell.maxX <= 8, "Иконка выходит за правую границу строки")
        let wide = ink(try render(surface, cells: [cell("\u{f07b}"), cell("", skip: true)]))
        precondition(wide.height >= textHeight * 0.9, "Двухколоночный символ уменьшился")
        print("PASS: правая граница строки и двухколоночный символ")
        let dirty = try render(surface, cells: [cell("\u{f07b}"), cell(" ")], dirty: NSRect(x: 8, y: 0, width: 8, height: 20))
        precondition(ink(dirty, from: 8).width > 4, "Перерисовка правой ячейки потеряла часть иконки слева")
        print("PASS: частичная перерисовка свободной ячейки сохраняет широкую иконку")
    }
}
