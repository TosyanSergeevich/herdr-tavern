import AppKit
import CoreText
import CoreGraphics
import UniformTypeIdentifiers

func string(_ value: Any?) -> String { value as? String ?? "" }
func integer(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
func number(_ value: Any?) -> CGFloat { CGFloat((value as? NSNumber)?.doubleValue ?? 0) }
func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
func objects(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
func flag(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }

struct TerminalCell {
    var symbol = " "
    var foreground: UInt32 = 0
    var background: UInt32 = 0
    var modifier: UInt16 = 0
    var skip = false
    var hyperlink: UInt32?
}
struct CellSegment { let x: Int; let y: Int; let cells: [TerminalCell] }
struct GraphicAsset { let id: String; let width: Int; let height: Int; let format: Int; let data: Data }


final class SurfaceView: NSView, NSTextInputClient {
    let gridFont: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let boldItalicFont: NSFont
    private let emDashFonts: [NSFont]
    private let symbolsFont: NSFont
    private let symbolsCharacterSet: CFCharacterSet
    private let primaryCharacterSets: [CFCharacterSet]
    let cellWidth: CGFloat = 8
    let cellHeight: CGFloat = 20
    let ascent: CGFloat
    var cols = 1
    var rows = 1
    var width = 0
    var height = 0
    var scene: [String: Any] = [:]
    private var cells: [TerminalCell] = []
    private var images: [String: CGImage] = [:]
    private var placements: [[String: Any]] = []
    var send: (([String: Any]) -> Void)?
    var request: ((String, [String: Any]) -> Void)?
    let commandKeybindings = CommandKeybindings()
    var invokeCommand: ((String, [String: Any]?) -> Void)?
    var focusPane: ((String) -> Void)?
    var contextMenuForPane: ((String) -> NSMenu?)?
    var presentContextMenu: ((NSMenu, NSEvent, NSView) -> Void)?
    var workingDirectoryForPane: ((String) -> String?)?
    var openLink: ((URL) -> Void)?
    var readSelection: (([String: Any], @escaping (Result<String, Error>) -> Void) -> Void)?
    var selectionError: ((String) -> Void)?
    var geometryChanged: ((Int, Int, Int, Int) -> Void)?
    private var selection: TerminalSelection?
    private var selectionVersion: UInt64 = 0
    private var selecting = false
    private var selectionPointer: NSPoint?
    private var marked = ""
    private var markedSelection = NSRange(location: 0, length: 0)
    private var pressedKeys: [UInt16: (TerminalKeyStroke, String)] = [:]
    private var interpretingEvent: NSEvent?
    private var interpretingComposition = false
    private var reportedButtons: [Int: String] = [:]
    private var tracking: NSTrackingArea?
    private var scrollRemainder: CGFloat = 0
    private var dragSplit: [String: Any]?
    private var dragPane = ""
    private var dragBoot = ""
    private var lastSplitRatio: CGFloat?
    private var linkClickButton: Int?
    private var hoveringLink = false
    private var languageObserver: NSObjectProtocol?
    private struct GlyphKey: Hashable {
        let symbol: String
        let style: UInt16
        let columns: Int
    }
    private struct Glyph {
        let line: CTLine
        let matrix: CGAffineTransform
    }
    private var glyphs: [GlyphKey: Glyph] = [:]

    init(fonts: TerminalFonts) {
        let font = fonts.regular
        gridFont = font
        boldFont = fonts.bold
        italicFont = fonts.italic
        boldItalicFont = fonts.boldItalic
        symbolsFont = fonts.symbols
        symbolsCharacterSet = CTFontCopyCharacterSet(fonts.symbols as CTFont)
        primaryCharacterSets = [font, boldFont, italicFont, boldItalicFont].map { CTFontCopyCharacterSet($0 as CTFont) }
        let menlo = NSFont(name: "Menlo", size: font.pointSize)!
        let menloBold = NSFontManager.shared.convert(menlo, toHaveTrait: .boldFontMask)
        emDashFonts = [
            menlo, menloBold,
            NSFontManager.shared.convert(menlo, toHaveTrait: .italicFontMask),
            NSFontManager.shared.convert(menloBold, toHaveTrait: .italicFontMask)
        ]
        ascent = CTFontGetAscent(font as CTFont)
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        updateLocalizedAccessibility()
        languageObserver = NotificationCenter.default.addObserver(
            forName: .tavernLanguageDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.updateLocalizedAccessibility() }
    }
    required init?(coder: NSCoder) { fatalError("SurfaceView requires the configured font") }
    deinit {
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
    private func updateLocalizedAccessibility() {
        setAccessibilityLabel(L("core.surface.terminal"))
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        releasePressedKeys()
        return true
    }
    func releasePressedKeys() {
        for (_, (stroke, pane)) in pressedKeys { send?(stroke.command(pane: pane, kind: 2)) }
        pressedKeys.removeAll()
        commandKeybindings.resetInput()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateGeometry() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateGeometry() }
    func updateGeometry() {
        let c = max(1, min(65535, Int(bounds.width / cellWidth)))
        let r = max(1, min(65535, Int(bounds.height / cellHeight)))
        cols = c; rows = r
        let scale = window?.backingScaleFactor ?? 1
        geometryChanged?(c, r, Int(cellWidth * scale), Int(cellHeight * scale))
        needsDisplay = true
    }
    func clear() {
        scene = [:]; cells.removeAll(); images.removeAll(); placements.removeAll(); width = 0; height = 0
        clearInputSelection()
        pressedKeys.removeAll(); reportedButtons.removeAll(); dragSplit = nil
        commandKeybindings.resetInput()
        linkClickButton = nil; clearLinkHover()
        unmarkText(); needsDisplay = true
    }
    private func decode(_ asset: GraphicAsset) throws -> CGImage {
        guard asset.width > 0, asset.height > 0, asset.width <= 32768, asset.height <= 32768 else {
            throw NativeError.message(L("core.surface.invalidAssetSize"))
        }
        if asset.format == 2, let rep = NSBitmapImageRep(data: asset.data), let image = rep.cgImage { return image }
        let channels = asset.format == 0 ? 3 : 4
        guard asset.format == 0 || asset.format == 1,
              asset.data.count == asset.width * asset.height * channels,
              let provider = CGDataProvider(data: asset.data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: asset.width, height: asset.height, bitsPerComponent: 8,
                                  bitsPerPixel: channels * 8, bytesPerRow: asset.width * channels,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: channels == 3 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw NativeError.message(L("core.surface.assetDecodeFailed"))
        }
        return image
    }
    func apply(metadata: [String: Any], segments: [CellSegment], assets: [GraphicAsset], patch: Bool) throws {
        precondition(Thread.isMainThread)
        var decoded: [String: CGImage] = [:]
        for asset in assets { decoded[asset.id] = try decode(asset) }
        if patch {
            guard string(metadata["boot_id"]) == string(scene["boot_id"]),
                  integer(metadata["projection_revision"]) == integer(scene["projection_revision"]),
                  integer(metadata["base_surface_revision"]) == integer(scene["surface_revision"]) else {
                throw NativeError.message(L("core.surface.patchMismatch"))
            }
        } else {
            let w = integer(metadata["width"]), h = integer(metadata["height"])
            guard w > 0, h > 0, w <= 10000, h <= 10000, w * h <= 4_000_000,
                  segments.count == 1, segments[0].x == 0, segments[0].y == 0, segments[0].cells.count == w * h else {
                throw NativeError.message(L("core.surface.invalidGrid"))
            }
            width = w; height = h
        }
        for segment in segments {
            let start = segment.y * width + segment.x
            guard segment.x >= 0, segment.y >= 0, segment.x < width, segment.y < height,
                  start + segment.cells.count <= width * height,
                  !patch || segment.x + segment.cells.count <= width else {
                throw NativeError.message(L("core.surface.segmentOutOfBounds"))
            }
        }
        if !patch {
            let nextPane = string(objects(metadata["panes"]).first(where: { flag($0["focused"]) })?["pane_id"])
            if string(scene["boot_id"]) != string(metadata["boot_id"]) { pressedKeys.removeAll() }
            else if nextPane != focusedPane {
                releasePressedKeys()
            }
        }
        if !patch {
            cells = segments[0].cells
            scene = metadata
            placements = objects(metadata["placements"]).sorted(by: { integer($0["z"]) < integer($1["z"]) })
            if flag(metadata["image_cache_reset"]) { images.removeAll() }
        } else {
            for segment in segments {
                let start = segment.y * width + segment.x
                for (offset, cell) in segment.cells.enumerated() { cells[start + offset] = cell }
            }
            let changed = objects(metadata["panes"])
            scene["panes"] = objects(scene["panes"]).map { original in
                changed.first(where: { string($0["pane_id"]) == string(original["pane_id"]) }) ?? original
            }
            scene["cursor"] = metadata["cursor"] ?? NSNull()
            scene["surface_revision"] = metadata["surface_revision"]
        }
        images.merge(decoded) { _, new in new }
        if !patch {
            let placements = objects(scene["placements"])
            for placement in placements where images[string(placement["id"])] == nil {
                throw NativeError.message(L("core.surface.missingAsset"))
            }
            if let retained = scene["retained_assets"] as? [String] {
                let live = Set(retained + placements.map { string($0["id"]) })
                images = images.filter { live.contains($0.key) }
            }
        }
        reconcileSelection()
        needsDisplay = true
        updateLinkHover(at: window?.mouseLocationOutsideOfEventStream, flags: NSEvent.modifierFlags)
    }
    private func colors(_ cell: TerminalCell) -> (NSColor, NSColor) {
        var fg = packedColor(cell.foreground, foreground: true), bg = packedColor(cell.background, foreground: false)
        if cell.modifier & 64 != 0 { swap(&fg, &bg) }
        if cell.modifier & 2 != 0 { fg = fg.blended(withFraction: 0.45, of: bg) ?? fg }
        return (fg, bg)
    }
    private func drawImages(negative: Bool, context: CGContext) {
        for p in placements {
            guard (integer(p["z"]) < 0) == negative, let image = images[string(p["id"])] else { continue }
            let sx = number(p["source_x"]), sy = number(p["source_y"])
            let sw = number(p["source_width"]) == 0 ? CGFloat(image.width) : number(p["source_width"])
            let sh = number(p["source_height"]) == 0 ? CGFloat(image.height) : number(p["source_height"])
            guard sw > 0, sh > 0 else { continue }
            let source = NSRect(x: sx, y: sy, width: sw, height: sh).intersection(NSRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            guard !source.isEmpty else { continue }
            let scale = max(1, window?.backingScaleFactor ?? 1)
            let dw = number(p["cols"]) > 0 ? number(p["cols"]) * cellWidth : sw / scale
            let dh = number(p["rows"]) > 0 ? number(p["rows"]) * cellHeight : sh / scale
            let dest = NSRect(x: number(p["x"]) * cellWidth + number(p["x_offset"]) / scale,
                              y: number(p["y"]) * cellHeight + number(p["y_offset"]) / scale, width: dw, height: dh)
            let clip = NSRect(x: dest.minX + (source.minX - sx) * dw / sw, y: dest.minY + (source.minY - sy) * dh / sh,
                              width: source.width * dw / sw, height: source.height * dh / sh)
            context.saveGState(); context.clip(to: clip)
            let fullHeight = CGFloat(image.height) * dh / sh
            context.translateBy(x: dest.minX - sx * dw / sw, y: dest.minY - sy * dh / sh + fullHeight)
            context.scaleBy(x: 1, y: -1); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * dw / sw, height: fullHeight))
            context.restoreGState()
        }
    }
    private func usesSymbolsFont(for cell: TerminalCell) -> Bool {
        let scalar = cell.symbol.unicodeScalars.first?.value ?? 0
        let isPrivateUse = (0xE000...0xF8FF).contains(scalar) ||
            (0xF0000...0xFFFFD).contains(scalar) || (0x100000...0x10FFFD).contains(scalar)
        guard isPrivateUse else { return false }
        let styleIndex = (cell.modifier & 1 != 0 ? 1 : 0) + (cell.modifier & 4 != 0 ? 2 : 0)
        return !CFCharacterSetIsLongCharacterMember(primaryCharacterSets[styleIndex], scalar) &&
            CFCharacterSetIsLongCharacterMember(symbolsCharacterSet, scalar)
    }
    private func glyph(for cell: TerminalCell, columns: Int) -> Glyph {
        let key = GlyphKey(symbol: cell.symbol, style: cell.modifier & 5, columns: columns)
        if let cached = glyphs[key] { return cached }
        let bold = key.style & 1 != 0, italic = key.style & 4 != 0
        let styleIndex = (bold ? 1 : 0) + (italic ? 2 : 0)
        let scalar = cell.symbol.unicodeScalars.first?.value ?? 0
        let isEmDash = scalar == 0x2014
        let usesSymbols = usesSymbolsFont(for: cell)
        let font = isEmDash ? emDashFonts[styleIndex] : (usesSymbols ? symbolsFont :
            (bold ? (italic ? boldItalicFont : boldFont) : (italic ? italicFont : gridFont)))
        let traits = NSFontManager.shared.traits(of: font)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        // У набора иконок одно начертание; искусственная обводка портит мелкие детали.
        if bold && !usesSymbols && !traits.contains(.boldFontMask) { attributes[.strokeWidth] = -2.0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: cell.symbol, attributes: attributes))
        var matrix = italic && !traits.contains(.italicFontMask) ? CGAffineTransform(a: 1, b: 0, c: 0.18, d: 1, tx: 0, ty: 0) : .identity
        if isEmDash {
            // Menlo шире Iosevka: тире остаётся в одной ячейке, не задевая соседний символ.
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if advance > cellWidth { matrix.a = cellWidth / advance; matrix.c *= matrix.a }
        }
        if usesSymbols {
            // У Symbols Nerd Font собственные метрики. Вписываем рисунок без искажения
            // пропорций в колонки, отведённые herdr, и центрируем по высоте строки.
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).applying(matrix)
            if !bounds.isEmpty {
                let availableWidth = cellWidth * CGFloat(columns)
                let scale = min(1, availableWidth / bounds.width, cellHeight / bounds.height)
                matrix = matrix.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).applying(matrix)
                // Широкая иконка начинается в своей ячейке; узкая остаётся
                // по центру первой, даже когда справа разрешён свободный пробел.
                matrix.tx = max(0, (cellWidth - ink.width) / 2) - ink.minX
                matrix.ty = ascent - cellHeight / 2 - ink.midY
            }
        }
        let glyph = Glyph(line: line, matrix: matrix)
        // Шрифт фиксирован на время жизни поверхности; цвет задаётся при рисовании.
        // Ограничение не позволяет истории с уникальными символами разрастить кэш.
        if glyphs.count >= 4096 { glyphs.removeAll(keepingCapacity: true) }
        glyphs[key] = glyph
        return glyph
    }
    private func drawGlyph(at index: Int, foreground: NSColor, context: CGContext) {
        let cell = cells[index], modifier = cell.modifier
        guard !cell.skip, modifier & 128 == 0, !cell.symbol.isEmpty else { return }
        let x = index % width, y = index / width
        if cell.symbol != " " {
            var columns = 1
            while x + columns < width && cells[index + columns].skip { columns += 1 }
            // Private Use остаётся одним терминальным символом. Как в Ghostty,
            // рисунок может занять ещё одну пустую ячейку, но не соседний текст.
            if columns == 1, x + 1 < width, usesSymbolsFont(for: cell) {
                let next = cells[index + 1]
                if !next.skip, next.symbol == " ", colors(cell).1 == colors(next).1 {
                    columns = 2
                }
            }
            let glyph = glyph(for: cell, columns: columns)
            context.saveGState(); context.translateBy(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight + ascent)
            context.scaleBy(x: 1, y: -1)
            let color = foreground.cgColor
            context.setFillColor(color); context.setStrokeColor(color)
            context.textMatrix = glyph.matrix
            context.textPosition = .zero; CTLineDraw(glyph.line, context); context.restoreGState()
        }
        if modifier & (8 | 256) != 0 {
            var span = 1
            while x + span < width && cells[index + span].skip { span += 1 }
            let path = NSBezierPath(); path.lineWidth = 1; foreground.setStroke()
            for offset in [modifier & 8 != 0 ? ascent + 1 : -1, modifier & 256 != 0 ? ascent * 0.62 : -1] where offset >= 0 {
                path.move(to: NSPoint(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight + offset))
                path.line(to: NSPoint(x: CGFloat(x + span) * cellWidth, y: CGFloat(y) * cellHeight + offset))
            }
            path.stroke()
        }
    }
    private func drawOverlay(from start: Int, through end: Int, foreground: NSColor, background: NSColor, context: CGContext) {
        let rect = NSRect(x: CGFloat(start % width) * cellWidth, y: CGFloat(start / width) * cellHeight,
                          width: CGFloat(end - start + 1) * cellWidth, height: cellHeight)
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: rect); background.setFill(); rect.fill()
        // Глиф из предыдущей ячейки может занимать две колонки.
        let first = max(start - start % width, start - 1)
        for index in first...end { drawGlyph(at: index, foreground: foreground, context: context) }
    }
    override func draw(_ dirtyRect: NSRect) {
        TerminalTheme.background.setFill(); bounds.fill()
        guard width > 0, height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let y0 = max(0, Int(dirtyRect.minY / cellHeight)), y1 = min(height, Int(ceil(dirtyRect.maxY / cellHeight)))
        // Глиф слева может заходить в пустую ячейку внутри dirtyRect.
        let x0 = max(0, Int(dirtyRect.minX / cellWidth) - 1), x1 = min(width, Int(ceil(dirtyRect.maxX / cellWidth)))
        guard y0 < y1, x0 < x1 else { return }
        // Переиспользуем только последний стиль в пределах draw, без растущего кэша.
        var previousStyle: (UInt32, UInt32, UInt16)?
        var previousColors: (NSColor, NSColor)?
        func drawingColors(_ cell: TerminalCell) -> (NSColor, NSColor) {
            let style = (cell.foreground, cell.background, cell.modifier & 66)
            if let previousStyle, let previousColors, previousStyle == style { return previousColors }
            let resolved = colors(cell)
            previousStyle = style; previousColors = resolved
            return resolved
        }
        for y in y0..<y1 {
            var start = x0
            var background = drawingColors(cells[y * width + start]).1
            for x in (x0 + 1)...x1 {
                let next = x < x1 ? drawingColors(cells[y * width + x]).1 : nil
                if next != background {
                    background.setFill()
                    NSRect(x: CGFloat(start) * cellWidth, y: CGFloat(y) * cellHeight,
                           width: CGFloat(x - start) * cellWidth, height: cellHeight).fill()
                    if let next { background = next; start = x }
                }
            }
        }
        drawImages(negative: true, context: context)
        for y in y0..<y1 { for x in x0..<x1 {
            let index = y * width + x
            drawGlyph(at: index, foreground: drawingColors(cells[index]).0, context: context)
        } }
        drawImages(negative: false, context: context)
        for y in y0..<y1 {
            if let columns = selection?.visibleColumns(row: y) {
                let start = y * width + columns.lowerBound, end = y * width + columns.upperBound
                drawOverlay(from: start, through: end, foreground: TerminalTheme.selectionText, background: TerminalTheme.selection, context: context)
            }
        }
        let cursor = dictionary(scene["cursor"])
        if flag(cursor["visible"]) {
            let x = integer(cursor["x"]), y = integer(cursor["y"]), shape = integer(cursor["shape"])
            if x >= 0 && x < width && y >= 0 && y < height {
                var rect = NSRect(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight, width: cellWidth, height: cellHeight)
                if shape == 3 || shape == 4 { rect.origin.y += cellHeight - 2; rect.size.height = 2 }
                else if shape == 5 || shape == 6 { rect.size.width = 2 }
                if shape != 3 && shape != 4 && shape != 5 && shape != 6 {
                    drawOverlay(from: y * width + x, through: y * width + x, foreground: TerminalTheme.cursorText, background: TerminalTheme.cursor, context: context)
                } else {
                    TerminalTheme.cursor.setFill(); rect.fill()
                }
            }
        }
        if !marked.isEmpty {
            (marked as NSString).draw(at: NSPoint(x: number(cursor["x"]) * cellWidth, y: number(cursor["y"]) * cellHeight),
                                     withAttributes: [.font: gridFont, .foregroundColor: TerminalTheme.foreground, .backgroundColor: TerminalTheme.background, .underlineStyle: NSUnderlineStyle.single.rawValue])
        }
    }
    func paneAt(_ cell: NSPoint) -> [String: Any]? {
        objects(scene["panes"]).first { pane in
            let r = dictionary(pane["inner_rect"])
            return NSRect(x: number(r["x"]), y: number(r["y"]), width: number(r["width"]), height: number(r["height"])).contains(cell)
        }
    }
    private func cellAt(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: floor(point.x / cellWidth), y: floor(point.y / cellHeight))
    }
    private func selectionViewport(_ pane: [String: Any]) -> TerminalSelectionViewport? {
        let rect = dictionary(pane["inner_rect"]), scroll = dictionary(pane["scroll"])
        let x = integer(rect["x"]), y = integer(rect["y"])
        let columns = integer(rect["width"]), rows = integer(rect["height"])
        guard columns > 0, rows > 0, x >= 0, y >= 0, x + columns <= width, y + rows <= height else { return nil }
        let maximum = max(0, integer(scroll["max_offset_from_bottom"]))
        return TerminalSelectionViewport(paneID: string(pane["pane_id"]), x: x, y: y, columns: columns, rows: rows,
            offset: max(0, min(maximum, integer(scroll["offset_from_bottom"]))), maximum: maximum,
            contentRevision: (pane["content_revision"] as? NSNumber)?.uint64Value
                ?? (scene["surface_revision"] as? NSNumber)?.uint64Value ?? 0,
            alternateScreen: flag(pane["alternate_screen_active"]), hasHistory: !scroll.isEmpty)
    }
    private func selectionCell(row: Int, column: Int, viewport: TerminalSelectionViewport) -> TerminalSelectionCell {
        let index = (viewport.y + row - viewport.top) * width + viewport.x + column
        return TerminalSelectionCell(symbol: cells[index].symbol, continuation: cells[index].skip)
    }
    private func captureSelection() {
        guard var selected = selection else { return }
        let viewport = selected.viewport
        selected.captureVisibleRows { self.selectionCell(row: $0, column: $1, viewport: viewport) }
        guard !selected.requiresCapturedCopy || selected.hasCapturedRange else {
            clearInputSelection(); return
        }
        selection = selected
    }
    private func reconcileSelection() {
        guard var selected = selection else { return }
        guard let pane = objects(scene["panes"]).first(where: { string($0["pane_id"]) == selected.viewport.paneID }),
              let viewport = selectionViewport(pane),
              selected.reconcile(boot: string(scene["boot_id"]), viewport: viewport,
                  cell: { self.selectionCell(row: $0, column: $1, viewport: viewport) }) else {
            clearInputSelection(); return
        }
        selection = selected
        if selecting, let selectionPointer { updateSelection(at: selectionPointer) }
    }
    private func updateSelection(at point: NSPoint) {
        guard var selected = selection else { return }
        let target = selected.viewport.point(x: Int(point.x), y: Int(point.y))
        let columns = selected.granularity == .word ? wordColumns(at: target, viewport: selected.viewport) : nil
        selected.drag(to: target, wordColumns: columns)
        let changed = selected.head != selection?.head || selected.anchor != selection?.anchor
        if changed { selectionVersion &+= 1 }
        selection = selected; selectionPointer = point; needsDisplay = true
        if changed { captureSelection() }
    }
    private func wordColumns(at point: TerminalTextPoint, viewport: TerminalSelectionViewport) -> ClosedRange<Int> {
        let start = (viewport.y + point.row - viewport.top) * width + viewport.x
        return TerminalSelection.wordColumns(at: point.col, count: viewport.columns,
            symbol: { cells[start + $0].symbol }, isContinuation: { cells[start + $0].skip })
    }
    func link(at cell: NSPoint) -> URL? {
        guard cell.x >= 0, cell.y >= 0, cell.x < CGFloat(width), cell.y < CGFloat(height),
              let pane = paneAt(cell) else { return nil }
        let x = Int(cell.x), y = Int(cell.y), index = y * width + x
        guard cells.indices.contains(index) else { return nil }
        let rect = dictionary(pane["inner_rect"])
        let left = max(0, integer(rect["x"])), right = min(width, integer(rect["x"]) + integer(rect["width"]))
        guard left < right else { return nil }
        var anchor = x
        while anchor > left && cells[y * width + anchor].skip { anchor -= 1 }
        let cwd = workingDirectoryForPane?(string(pane["pane_id"]))
        if let reference = cells[y * width + anchor].hyperlink {
            let links = scene["hyperlinks"] as? [String] ?? []
            guard Int(reference) < links.count else { return nil }
            return TerminalLinks.explicitTarget(links[Int(reference)], cwd: cwd)
        }
        var text = "", offset = 0
        for column in left..<right {
            let current = cells[y * width + column]
            if column == anchor { offset = text.utf16.count }
            if !current.skip { text += current.symbol }
        }
        return TerminalLinks.target(in: text, utf16Offset: offset, cwd: cwd)
    }
    private func activateLink(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.intersection([.command, .control]).isEmpty,
              let target = link(at: cellAt(event)), let openLink else { return false }
        selecting = false
        linkClickButton = event.buttonNumber
        openLink(target)
        return true
    }
    private func clearLinkHover() {
        toolTip = nil
        if hoveringLink { NSCursor.iBeam.set() }
        hoveringLink = false
    }
    private func updateLinkHover(at location: NSPoint?, flags: NSEvent.ModifierFlags) {
        guard let location, !flags.intersection([.command, .control]).isEmpty else { clearLinkHover(); return }
        let point = convert(location, from: nil)
        guard bounds.contains(point),
              let target = link(at: NSPoint(x: floor(point.x / cellWidth), y: floor(point.y / cellHeight))) else {
            clearLinkHover(); return
        }
        hoveringLink = true
        toolTip = target.isFileURL ? target.path : target.absoluteString
        NSCursor.pointingHand.set()
    }
    override func flagsChanged(with event: NSEvent) {
        updateLinkHover(at: window?.mouseLocationOutsideOfEventStream, flags: event.modifierFlags)
    }
    override func mouseExited(with event: NSEvent) { clearLinkHover() }
    private var focusedPane: String { string(objects(scene["panes"]).first(where: { flag($0["focused"]) })?["pane_id"]) }
    private func mouse(_ event: NSEvent, phase: String, paneID: String? = nil, lines: Int = 1) {
        let cell = cellAt(event)
        let target = paneID.flatMap { id in objects(scene["panes"]).first { string($0["pane_id"]) == id } } ?? paneAt(cell)
        guard let pane = target else { return }
        let rect = dictionary(pane["inner_rect"])
        let cols = integer(rect["width"]), rows = integer(rect["height"])
        guard cols > 0, rows > 0 else { return }
        let col = max(0, min(cols - 1, Int(cell.x) - integer(rect["x"])))
        let row = max(0, min(rows - 1, Int(cell.y) - integer(rect["y"])))
        send?(["type": "mouse", "pane_id": string(pane["pane_id"]), "phase": phase,
               "button": event.buttonNumber == 1 ? "right" : event.buttonNumber == 2 ? "middle" : "left",
               "col": col, "row": row, "modifiers": terminalModifiers(event.modifierFlags), "lines": lines])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    private func beginMouse(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        let cell = cellAt(event)
        guard let pane = paneAt(cell) else { return }
        let id = string(pane["pane_id"])
        if id != focusedPane { focusPane?(id) }
        if event.buttonNumber <= 2 && flag(pane["mouse_reporting"]) && !event.modifierFlags.contains(.shift) {
            clearInputSelection()
            reportedButtons[event.buttonNumber] = id; mouse(event, phase: "down", paneID: id)
        } else if event.buttonNumber == 0 {
            clearInputSelection()
            if let viewport = selectionViewport(pane) {
                let anchor = viewport.point(x: Int(cell.x), y: Int(cell.y))
                let granularity: TerminalSelection.Granularity = event.clickCount >= 3 ? .line : event.clickCount == 2 ? .word : .character
                selection = TerminalSelection(boot: string(scene["boot_id"]), viewport: viewport, anchor: anchor,
                    granularity: granularity, wordColumns: granularity == .word ? wordColumns(at: anchor, viewport: viewport) : nil)
                selecting = true; selectionPointer = cell
                captureSelection()
            }
        }
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        linkClickButton = nil
        if activateLink(event) { return }
        if event.modifierFlags.contains(.control), showPaneMenu(event) { return }
        let cell = cellAt(event)
        for split in objects(scene["splits"]) {
            let r = dictionary(split["hit_rect"])
            if NSRect(x: number(r["x"]), y: number(r["y"]), width: number(r["width"]), height: number(r["height"])).contains(cell) {
                dragSplit = split; dragPane = focusedPane; dragBoot = string(scene["boot_id"]); lastSplitRatio = nil
                window?.makeFirstResponder(self); return
            }
        }
        beginMouse(event)
    }
    private func splitRatio(_ event: NSEvent) {
        guard let split = dragSplit, !dragPane.isEmpty, dragBoot == string(scene["boot_id"]) else { return }
        let cell = cellAt(event), area = dictionary(split["area"])
        let horizontal = string(split["direction"]) == "Horizontal"
        let length = number(area[horizontal ? "width" : "height"])
        guard length > 0 else { return }
        let ratio = max(0.1, min(0.9, ((horizontal ? cell.x : cell.y) - number(area[horizontal ? "x" : "y"])) / length))
        if let lastSplitRatio, abs(lastSplitRatio - ratio) < 0.005 { return }
        lastSplitRatio = ratio
        request?("layout.set_split_ratio", ["pane_id": dragPane, "path": split["path"] ?? [], "ratio": ratio])
    }
    private func dragMouse(_ event: NSEvent) {
        if let id = reportedButtons[event.buttonNumber] { mouse(event, phase: "drag", paneID: id) }
        else if selecting && event.buttonNumber == 0 {
            updateSelection(at: cellAt(event))
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard linkClickButton != event.buttonNumber else { return }
        if dragSplit != nil { splitRatio(event) } else { dragMouse(event) }
    }
    private func endMouse(_ event: NSEvent) {
        // Открытый адрес не порождает ни выделения, ни одиночного mouse-up в PTY.
        if linkClickButton == event.buttonNumber { linkClickButton = nil; return }
        if let id = reportedButtons.removeValue(forKey: event.buttonNumber) { mouse(event, phase: "up", paneID: id) }
        else if selecting && event.buttonNumber == 0 {
            updateSelection(at: cellAt(event))
            selecting = false; selectionPointer = nil
        }
    }
    override func mouseUp(with event: NSEvent) {
        if dragSplit != nil { splitRatio(event); dragSplit = nil; dragPane = "" } else { endMouse(event) }
    }
    private func showPaneMenu(_ event: NSEvent) -> Bool {
        guard let pane = paneAt(cellAt(event)),
              let menu = contextMenuForPane?(string(pane["pane_id"])),
              let presentContextMenu else { return false }
        presentContextMenu(menu, event, self)
        return true
    }
    override func rightMouseDown(with event: NSEvent) {
        linkClickButton = nil
        // AppKit может доставить Control-click как rightMouseDown.
        if event.modifierFlags.contains(.control), activateLink(event) { return }
        if !showPaneMenu(event) { beginMouse(event) }
    }
    override func rightMouseDragged(with event: NSEvent) { dragMouse(event) }
    override func rightMouseUp(with event: NSEvent) { endMouse(event) }
    override func otherMouseDown(with event: NSEvent) { beginMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { dragMouse(event) }
    override func otherMouseUp(with event: NSEvent) { endMouse(event) }
    override func mouseMoved(with event: NSEvent) {
        updateLinkHover(at: event.locationInWindow, flags: event.modifierFlags)
        if hoveringLink { return }
        if !event.modifierFlags.contains(.shift), let pane = paneAt(cellAt(event)), flag(pane["mouse_reporting"]) { mouse(event, phase: "move") }
    }
    override func scrollWheel(with event: NSEvent) {
        scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY
        let delta = Int(scrollRemainder)
        guard delta != 0, let pane = paneAt(cellAt(event)) else { return }
        scrollRemainder -= CGFloat(delta)
        if flag(pane["mouse_reporting"]) && !event.modifierFlags.contains(.shift) {
            mouse(event, phase: delta > 0 ? "upward" : "downward", lines: min(65535, abs(delta)))
        } else {
            let scroll = dictionary(pane["scroll"])
            let offset = max(0, min(integer(scroll["max_offset_from_bottom"]), integer(scroll["offset_from_bottom"]) + delta))
            request?("pane.scroll", ["pane_id": string(pane["pane_id"]), "offset_from_bottom": offset])
        }
    }
    private func text(from start: Int, through end: Int, trim: Bool) -> String {
        guard width > 0, start >= 0, end >= start, end < cells.count else { return "" }
        var lo = start
        while lo % width > 0 && cells[lo].skip { lo -= 1 }
        var lines: [String] = [], line = ""
        for i in lo...end {
            if !cells[i].skip { line += cells[i].symbol }
            if i == end || i % width == width - 1 {
                if trim { while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() } }
                lines.append(line); line = ""
            }
        }
        return lines.joined(separator: "\n")
    }
    override func accessibilityValue() -> Any? { cells.isEmpty ? "" : text(from: 0, through: cells.count - 1, trim: true) }
    @objc func copy(_ sender: Any?) {
        guard let selected = selection, let parameters = selected.readParameters else { return }
        let version = selectionVersion
        let store: (String) -> Void = { text in
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
        if selected.requiresCapturedCopy {
            if let captured = selected.capturedText { store(captured) }
            return
        }
        if selected.viewport.hasHistory {
            guard let readSelection else { selectionError?(L("core.surface.historyUnavailable")); return }
            readSelection(parameters) { [weak self] result in
                guard let self, self.selection != nil, self.selectionVersion == version else { return }
                switch result {
                case .success(let text): store(text)
                case .failure(let failure):
                    // Ревизия могла измениться после показанного кадра.
                    // Копируем именно захваченный текст, не новый текст по старым координатам.
                    if case TerminalSelectionReadError.staleContent = failure, let captured = selected.capturedText { store(captured) }
                    else { self.selectionError?(failure.localizedDescription) }
                }
            }
        } else {
            // Всплывающий терминал не предоставляет API истории.
            let viewport = selected.viewport
            let lines = (viewport.y..<(viewport.y + viewport.rows)).compactMap { row -> String? in
                guard let columns = selected.visibleColumns(row: row) else { return nil }
                return text(from: row * width + columns.lowerBound, through: row * width + columns.upperBound, trim: true)
            }
            store(lines.joined(separator: "\n"))
        }
    }
    override func selectAll(_ sender: Any?) {
        clearInputSelection()
        guard let pane = objects(scene["panes"]).first(where: { flag($0["focused"]) }),
              let viewport = selectionViewport(pane) else { return }
        var selected = TerminalSelection(boot: string(scene["boot_id"]), viewport: viewport,
            anchor: TerminalTextPoint(row: viewport.top, col: 0))
        selected.head = TerminalTextPoint(row: viewport.top + viewport.rows - 1, col: viewport.columns - 1)
        selection = selected; captureSelection(); needsDisplay = true
    }
    private func clearInputSelection() {
        selection = nil; selecting = false; selectionPointer = nil
        selectionVersion &+= 1; needsDisplay = true
    }
    private func dropPane(_ sender: NSDraggingInfo) -> String? {
        let point = convert(sender.draggingLocation, from: nil)
        guard bounds.contains(point),
              let pane = paneAt(NSPoint(x: floor(point.x / cellWidth), y: floor(point.y / cellHeight))) else { return nil }
        let id = string(pane["pane_id"])
        return id.isEmpty ? nil : id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard send != nil, sender.draggingSourceOperationMask.contains(.copy), dropPane(sender) != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                     options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingEntered(sender) == .copy, let pane = dropPane(sender),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        // Один файл — один аргумент shell, включая пробелы, кавычки и метасимволы.
        // Передаём paste, чтобы herdr сохранил bracketed-paste-режим приложения.
        let text = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ") + " "
        window?.makeFirstResponder(self)
        if pane != focusedPane { focusPane?(pane) }
        clearInputSelection()
        unmarkText()
        send?(["type": "paste", "pane_id": pane, "text": text])
        return true
    }
    @objc func paste(_ sender: Any?) {
        let pane = focusedPane
        guard !pane.isEmpty else { return }
        clearInputSelection()
        let board = NSPasteboard.general
        let fileURLs = board.types?.contains(.fileURL) == true
            ? board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            : nil
        let containsImageFile = fileURLs?.contains {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
        } ?? false
        if containsImageFile || board.canReadObject(forClasses: [NSImage.self], options: nil) {
            // Терминал передаёт стандартный пустой paste, а не Ctrl+V или
            // пиксели. Поддерживающий этот сценарий редактор (в том числе omp)
            // сам читает буфер. Назначения клавиш и метки процессов не нужны.
            send?(["type": "paste", "pane_id": pane, "text": ""])
        } else if let text = board.string(forType: .string) {
            send?(["type": "paste", "pane_id": pane, "text": text])
        }
    }
    private func press(_ stroke: TerminalKeyStroke, event: NSEvent) {
        let pane = focusedPane
        guard !pane.isEmpty else { return }
        clearInputSelection()
        send?(stroke.command(pane: pane, kind: event.isARepeat ? 1 : 0))
        pressedKeys[event.keyCode] = (stroke, pane)
    }
    private func handleEditShortcut(_ event: NSEvent) -> Bool {
        guard terminalModifiers(event.modifierFlags) == 8, !TerminalInput.isSpecial(event) else { return false }
        switch TerminalInput.stroke(event)?.key {
        case "c": copy(nil)
        case "v": paste(nil)
        case "a": selectAll(nil)
        default: return false
        }
        return true
    }
    private func handleCommandShortcut(_ event: NSEvent) -> Bool {
        guard invokeCommand != nil, !hasMarkedText() else { return false }
        switch commandKeybindings.keyDown(event) {
        case .passThrough: return false
        case .consumed: return true
        case .invoke(let id):
            let selected = selection.flatMap { selected -> [String: Any]? in
                guard selected.viewport.paneID == focusedPane, !selected.requiresCapturedCopy else { return nil }
                return selected.readParameters
            }
            invokeCommand?(id, selected)
            return true
        }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if handleCommandShortcut(event) { return true }
        // Правка адресуется этой поверхности; остальные команды оболочки —
        // меню. Неназначенный Command передаётся терминальному приложению.
        if handleEditShortcut(event) { return true }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        forwardKeyDown(event)
        return true
    }
    private func handleHistoryShortcut(_ event: NSEvent) -> Bool {
        guard terminalModifiers(event.modifierFlags) == 8,
              let pane = objects(scene["panes"]).first(where: { flag($0["focused"]) }) else { return false }
        let scroll = dictionary(pane["scroll"])
        let offset = integer(scroll["offset_from_bottom"]), maximum = integer(scroll["max_offset_from_bottom"])
        let target: Int
        switch event.keyCode {
        case 115: target = maximum
        case 119: target = 0
        case 116: target = min(maximum, offset + max(1, integer(scroll["viewport_rows"])))
        case 121: target = max(0, offset - max(1, integer(scroll["viewport_rows"])))
        default: return false
        }
        request?("pane.scroll", ["pane_id": string(pane["pane_id"]), "offset_from_bottom": target])
        return true
    }
    private func adjustExistingSelection(_ event: NSEvent) -> Bool {
        guard terminalModifiers(event.modifierFlags) == 1, selection?.head != nil else { return false }
        switch event.keyCode {
        case 123: selection?.extend(columns: -1)
        case 124: selection?.extend(columns: 1)
        case 125: selection?.extend(rows: 1)
        case 126: selection?.extend(rows: -1)
        default: return false
        }
        selectionVersion &+= 1; captureSelection(); needsDisplay = true
        return true
    }
    override func keyDown(with event: NSEvent) {
        if handleCommandShortcut(event) { return }
        forwardKeyDown(event)
    }
    private func forwardKeyDown(_ event: NSEvent) {
        if handleEditShortcut(event) { return }
        if handleHistoryShortcut(event) || adjustExistingSelection(event) { return }
        if let text = TerminalInput.textBinding(event), !focusedPane.isEmpty {
            if hasMarkedText() { inputContext?.discardMarkedText(); unmarkText() }
            clearInputSelection()
            send?(["type": "text", "pane_id": focusedPane, "text": text])
            return
        }
        let modified = !event.modifierFlags.intersection([.control, .command]).isEmpty ||
            (event.modifierFlags.contains(.option) && TerminalInput.optionAsAlt)
        if TerminalInput.requiresSemanticInput(event), !hasMarkedText() || modified {
            if hasMarkedText() { inputContext?.discardMarkedText(); unmarkText() }
            if let stroke = TerminalInput.stroke(event) { press(stroke, event: event) }
            return
        }
        interpretingEvent = event
        interpretingComposition = hasMarkedText()
        defer { interpretingEvent = nil; interpretingComposition = false }
        interpretKeyEvents([event])
    }
    override func keyUp(with event: NSEvent) {
        if commandKeybindings.keyUp(event) { return }
        if let (stroke, pane) = pressedKeys.removeValue(forKey: event.keyCode) {
            send?(stroke.command(pane: pane, kind: 2))
        }
    }
    func insertText(_ value: Any, replacementRange: NSRange) {
        let text = (value as? NSAttributedString)?.string ?? string(value)
        let composed = interpretingComposition || hasMarkedText()
        unmarkText()
        guard !text.isEmpty, !focusedPane.isEmpty else { return }
        clearInputSelection()
        let optionText = interpretingEvent.map { $0.modifierFlags.contains(.option) && !TerminalInput.optionAsAlt } ?? false
        if !composed, !optionText, text.unicodeScalars.count == 1, let event = interpretingEvent,
           let stroke = TerminalInput.stroke(event, committedText: text) {
            press(stroke, event: event)
        } else {
            send?(["type": "text", "pane_id": focusedPane, "text": text])
        }
    }
    override func doCommand(by selector: Selector) {
        guard let event = interpretingEvent ?? NSApp.currentEvent,
              let stroke = TerminalInput.stroke(event) else { return }
        press(stroke, event: event)
    }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: (marked as NSString).length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if interpretingEvent != nil { interpretingComposition = true }
        marked = (value as? NSAttributedString)?.string ?? string(value)
        let length = (marked as NSString).length, location = min(selectedRange.location, length)
        markedSelection = NSRange(location: location, length: min(selectedRange.length, length - location)); needsDisplay = true
    }
    func unmarkText() { marked = ""; markedSelection = NSRange(location: 0, length: 0); needsDisplay = true }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle,.foregroundColor,.backgroundColor] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText(), range.location < (marked as NSString).length else { actualRange?.pointee = NSRange(location: NSNotFound, length: 0); return nil }
        let selected = NSIntersectionRange(range, markedRange()); actualRange?.pointee = selected
        return NSAttributedString(string: (marked as NSString).substring(with: selected), attributes: [.font:gridFont])
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange()
        let cursor = dictionary(scene["cursor"])
        let rect = NSRect(x: number(cursor["x"]) * cellWidth, y: number(cursor["y"]) * cellHeight,
                          width: max(cellWidth, CGFloat((marked as NSString).length) * cellWidth), height: cellHeight)
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
}
