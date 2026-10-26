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
    private(set) var gridFont: NSFont
    private(set) var boldFont: NSFont
    private(set) var italicFont: NSFont
    private(set) var boldItalicFont: NSFont
    private var emDashFonts: [NSFont]
    private var symbolsFont: NSFont
    private var symbolsCharacterSet: CFCharacterSet
    private var primaryCharacterSets: [CFCharacterSet]
    private var configuredFonts: TerminalFonts
    private(set) var cellWidth: CGFloat
    private(set) var cellHeight: CGFloat
    private(set) var ascent: CGFloat
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
    private var markedMetrics: (text: String, rect: NSRect?)?
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
    private let hoverResolver: TerminalLinkHoverResolver
    private var hoverSnapshot: TerminalLinkHoverSnapshot?
    private var hoverGeneration: UInt64 = 0
    private var hoverResolved = false
    private var hoverTarget: URL?
    private var hoverTimer: Timer?
    private var hoverRowGenerations: [UInt64] = []
    private var hoverRowGeneration: UInt64 = 0
    private var pendingHoverMove: (snapshot: TerminalLinkHoverSnapshot, command: [String: Any])?
    private var hoverWindowObservers: [NSObjectProtocol] = []
    private var languageObserver: NSObjectProtocol?
    #if TAVERN_RENDER_TESTING
    var onInvalidation: ((NSRect) -> Void)?
    var linkHoverEnvironment: (() -> (location: NSPoint?, flags: NSEvent.ModifierFlags, visible: Bool))?
    #endif
    private var geometryBounds: NSRect?
    private var geometryScale: CGFloat?
    private struct RowInk {
        var bounds = NSRect.null
        var leftOverflow: CGFloat = 0
        var rightOverflow: CGFloat = 0
        var unknownColumns: [Int] = []
        var footprints: [NSRect] = []
    }
    private var rowInk: [RowInk] = []
    private struct GlyphKey: Hashable {
        let symbol: String
        let style: UInt16
        let columns: Int
    }
    private struct Glyph {
        let line: CTLine
        let matrix: CGAffineTransform
        let ink: NSRect?
    }
    private var glyphs: [GlyphKey: Glyph] = [:]

    init(fonts: TerminalFonts, hoverResolver: TerminalLinkHoverResolver = TerminalLinkHoverResolver()) {
        self.hoverResolver = hoverResolver
        configuredFonts = fonts
        let cellSize = fonts.cellSize(backingScale: 1)
        cellWidth = cellSize.width
        cellHeight = cellSize.height
        let font = fonts.regular
        gridFont = font
        boldFont = fonts.bold
        italicFont = fonts.italic
        boldItalicFont = fonts.boldItalic
        symbolsFont = fonts.symbols
        symbolsCharacterSet = CTFontCopyCharacterSet(fonts.symbols as CTFont)
        primaryCharacterSets = [font, boldFont, italicFont, boldItalicFont].map { CTFontCopyCharacterSet($0 as CTFont) }
        emDashFonts = Self.dashFonts(size: font.pointSize)
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
    private static func dashFonts(size: CGFloat) -> [NSFont] {
        let regular = NSFont(name: "Menlo", size: size)!
        let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
        return [regular, bold,
                NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask),
                NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)]
    }
    func setFonts(_ fonts: TerminalFonts) {
        guard gridFont != fonts.regular || boldFont != fonts.bold ||
              italicFont != fonts.italic || boldItalicFont != fonts.boldItalic ||
              symbolsFont != fonts.symbols else { return }
        cancelLinkHover()
        configuredFonts = fonts
        gridFont = fonts.regular
        boldFont = fonts.bold
        italicFont = fonts.italic
        boldItalicFont = fonts.boldItalic
        symbolsFont = fonts.symbols
        symbolsCharacterSet = CTFontCopyCharacterSet(fonts.symbols as CTFont)
        primaryCharacterSets = [gridFont, boldFont, italicFont, boldItalicFont].map {
            CTFontCopyCharacterSet($0 as CTFont)
        }
        emDashFonts = Self.dashFonts(size: gridFont.pointSize)
        ascent = CTFontGetAscent(gridFont as CTFont)
        glyphs.removeAll(keepingCapacity: true)
        markedMetrics = nil
        selectionVersion &+= 1
        selecting = false; selectionPointer = nil
        dragSplit = nil; lastSplitRatio = nil
        geometryBounds = nil; geometryScale = nil
        updateGeometry()
    }
    deinit {
        hoverTimer?.invalidate()
        for observer in hoverWindowObservers { NotificationCenter.default.removeObserver(observer) }
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
    override func setBoundsSize(_ newSize: NSSize) { super.setBoundsSize(newSize); updateGeometry() }
    override func setBoundsOrigin(_ newOrigin: NSPoint) { super.setBoundsOrigin(newOrigin); updateGeometry() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelLinkHover()
        for observer in hoverWindowObservers { NotificationCenter.default.removeObserver(observer) }
        hoverWindowObservers.removeAll()
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
                hoverWindowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in self?.cancelLinkHover() })
            }
        }
        hoverWindowObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.cancelLinkHover() })
        updateGeometry()
    }
    override func viewDidHide() { super.viewDidHide(); cancelLinkHover() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }
    func updateGeometry() {
        let scale = max(1, window?.backingScaleFactor ?? 1)
        guard geometryBounds != bounds || geometryScale != scale else { return }
        if geometryScale != scale {
            let cellSize = configuredFonts.cellSize(backingScale: scale)
            if cellWidth != cellSize.width || cellHeight != cellSize.height {
                cancelLinkHover()
                glyphs.removeAll(keepingCapacity: true)
            }
            cellWidth = cellSize.width; cellHeight = cellSize.height
        }
        geometryBounds = bounds; geometryScale = scale
        cols = max(1, min(65535, Int(bounds.width / cellWidth)))
        rows = max(1, min(65535, Int(bounds.height / cellHeight)))
        rebuildInk(rows: 0..<height)
        geometryChanged?(cols, rows, Int(cellWidth * scale), Int(cellHeight * scale))
        inputContext?.invalidateCharacterCoordinates()
        invalidate([bounds])
    }
    private func invalidate(_ rects: [NSRect]) {
        let scale = max(1, window?.backingScaleFactor ?? 1)
        for rect in rects {
            let clipped = rect.intersection(bounds)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            let x = floor(clipped.minX * scale) / scale, y = floor(clipped.minY * scale) / scale
            let rounded = NSRect(x: x, y: y, width: ceil(clipped.maxX * scale) / scale - x,
                                 height: ceil(clipped.maxY * scale) / scale - y).intersection(bounds)
            guard !rounded.isEmpty else { continue }
            #if TAVERN_RENDER_TESTING
            onInvalidation?(rounded)
            #endif
            setNeedsDisplay(rounded)
        }
    }
    func clear() {
        cancelLinkHover()
        hoverResolver.invalidate()
        hoverRowGenerations.removeAll()
        clearInputSelection()
        unmarkText()
        scene = [:]; cells.removeAll(); images.removeAll(); placements.removeAll(); width = 0; height = 0
        rowInk.removeAll()
        pressedKeys.removeAll(); reportedButtons.removeAll(); dragSplit = nil
        commandKeybindings.resetInput()
        linkClickButton = nil
        invalidate([bounds])
    }
    func apply(metadata: [String: Any], segments: [CellSegment], images decoded: [String: CGImage], patch: Bool) throws {
        precondition(Thread.isMainThread)
        let w = patch ? width : integer(metadata["width"])
        let h = patch ? height : integer(metadata["height"])
        if patch {
            guard w > 0, h > 0, cells.count == w * h,
                  string(metadata["boot_id"]) == string(scene["boot_id"]),
                  integer(metadata["projection_revision"]) == integer(scene["projection_revision"]),
                  integer(metadata["base_surface_revision"]) == integer(scene["surface_revision"]) else {
                throw NativeError.message(L("core.surface.patchMismatch"))
            }
        } else {
            guard w > 0, h > 0, w <= 10000, h <= 10000, w * h <= 4_000_000,
                  segments.count == 1, segments[0].x == 0, segments[0].y == 0, segments[0].cells.count == w * h else {
                throw NativeError.message(L("core.surface.invalidGrid"))
            }
        }
        for segment in segments {
            guard segment.x >= 0, segment.y >= 0, segment.x < w, segment.y < h,
                  segment.cells.count <= w * h - (segment.y * w + segment.x),
                  !patch || segment.cells.count <= w - segment.x else {
                throw NativeError.message(L("core.surface.segmentOutOfBounds"))
            }
        }
        // Validate the future cache before changing any view state, including dimensions.
        let reset = !patch && flag(metadata["image_cache_reset"])
        if !patch {
            for placement in objects(metadata["placements"]) {
                let id = string(placement["id"])
                guard decoded[id] != nil || (!reset && images[id] != nil) else {
                    throw NativeError.message(L("core.surface.missingAsset"))
                }
            }
        }
        let oldCursor = cursorRect(in: scene), oldMarked = markedTextRect(marked, in: scene)
        let oldCursorPosition = NSPoint(x: number(dictionary(scene["cursor"])["x"]), y: number(dictionary(scene["cursor"])["y"]))
        let oldSelection = selection
        var damage: [NSRect] = []
        var changedRows = Set<Int>()
        if patch {
            let anchors = affectedAnchors(segments)
            damage = anchors.map { glyphFootprint(at: $0) }
            let scale = max(1, window?.backingScaleFactor ?? 1)
            for p in placements where decoded[string(p["id"])] != nil {
                if let image = images[string(p["id"])], let geometry = imageGeometry(p, image: image, scale: scale) {
                    damage.append(geometry.clip)
                }
            }
            for segment in segments where !segment.cells.isEmpty { changedRows.insert(segment.y) }
        } else {
            let nextPane = string(objects(metadata["panes"]).first(where: { flag($0["focused"]) })?["pane_id"])
            if string(scene["boot_id"]) != string(metadata["boot_id"]) { pressedKeys.removeAll() }
            else if nextPane != focusedPane { releasePressedKeys() }
        }
        if !patch {
            width = w; height = h
            cells = segments[0].cells
            scene = metadata
            placements = objects(metadata["placements"]).sorted(by: { integer($0["z"]) < integer($1["z"]) })
            if reset { images.removeAll() }
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
        if !patch, let retained = scene["retained_assets"] as? [String] {
            let live = Set(retained + placements.map { string($0["id"]) })
            images = images.filter { live.contains($0.key) }
        }
        if patch {
            for row in changedRows { hoverRowGenerations[row] &+= 1 }
            damage += affectedAnchors(segments).map { glyphFootprint(at: $0) }
            rebuildInk(rows: changedRows.sorted())
        } else {
            cancelLinkHover()
            hoverResolver.invalidate()
            hoverRowGeneration &+= 1
            hoverRowGenerations = Array(repeating: hoverRowGeneration, count: height)
            rowInk = Array(repeating: RowInk(), count: height)
            rebuildInk(rows: 0..<height)
        }
        reconcileSelection()
        if patch {
            // Repaint overlays over the entire old/new ink, not only patched cells.
            damage += selectionDifference(oldSelection, selection)
            let nextCursor = cursorRect(in: scene), nextMarked = markedTextRect(marked, in: scene)
            let nextPosition = NSPoint(x: number(dictionary(scene["cursor"])["x"]), y: number(dictionary(scene["cursor"])["y"]))
            if oldCursor != nextCursor {
                damage += [oldCursor, nextCursor].compactMap { $0 }
            }
            if oldMarked != nextMarked || oldCursorPosition != nextPosition {
                damage += [oldMarked, nextMarked].compactMap { $0 }
            }
            if oldCursorPosition != nextPosition { inputContext?.invalidateCharacterCoordinates() }
            // A patch may replace an existing asset without changing its placement.
            if !decoded.isEmpty {
                let scale = max(1, window?.backingScaleFactor ?? 1)
                for p in placements where decoded[string(p["id"])] != nil {
                    if let image = images[string(p["id"])], let geometry = imageGeometry(p, image: image, scale: scale) {
                        damage.append(geometry.clip)
                    }
                }
            }
            invalidate(damage)
        } else {
            inputContext?.invalidateCharacterCoordinates()
            invalidate([bounds])
        }
        refreshLinkHover()
    }
    private func colors(_ cell: TerminalCell) -> (NSColor, NSColor) {
        var fg = packedColor(cell.foreground, foreground: true), bg = packedColor(cell.background, foreground: false)
        if cell.modifier & 64 != 0 { swap(&fg, &bg) }
        if cell.modifier & 2 != 0 { fg = fg.blended(withFraction: 0.45, of: bg) ?? fg }
        return (fg, bg)
    }
    private func imageGeometry(_ placement: [String: Any], image: CGImage, scale: CGFloat) -> (destination: NSRect, clip: NSRect)? {
        let sx = number(placement["source_x"]), sy = number(placement["source_y"])
        let sw = number(placement["source_width"]) == 0 ? CGFloat(image.width) : number(placement["source_width"])
        let sh = number(placement["source_height"]) == 0 ? CGFloat(image.height) : number(placement["source_height"])
        guard sw > 0, sh > 0 else { return nil }
        let source = NSRect(x: sx, y: sy, width: sw, height: sh).intersection(NSRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard !source.isEmpty else { return nil }
        let dw = number(placement["cols"]) > 0 ? number(placement["cols"]) * cellWidth : sw / scale
        let dh = number(placement["rows"]) > 0 ? number(placement["rows"]) * cellHeight : sh / scale
        let dest = NSRect(x: number(placement["x"]) * cellWidth + number(placement["x_offset"]) / scale,
                          y: number(placement["y"]) * cellHeight + number(placement["y_offset"]) / scale, width: dw, height: dh)
        let clip = NSRect(x: dest.minX + (source.minX - sx) * dw / sw, y: dest.minY + (source.minY - sy) * dh / sh,
                          width: source.width * dw / sw, height: source.height * dh / sh)
        return (dest, clip)
    }
    private func drawImages(negative: Bool, dirtyRect: NSRect, context: CGContext) {
        let scale = max(1, window?.backingScaleFactor ?? 1)
        for p in placements {
            guard (integer(p["z"]) < 0) == negative, let image = images[string(p["id"])],
                  let geometry = imageGeometry(p, image: image, scale: scale), geometry.clip.intersects(dirtyRect) else { continue }
            let sx = number(p["source_x"]), sy = number(p["source_y"])
            let sw = number(p["source_width"]) == 0 ? CGFloat(image.width) : number(p["source_width"])
            let sh = number(p["source_height"]) == 0 ? CGFloat(image.height) : number(p["source_height"])
            let dest = geometry.destination
            context.saveGState(); context.clip(to: geometry.clip)
            let fullHeight = CGFloat(image.height) * dest.height / sh
            context.translateBy(x: dest.minX - sx * dest.width / sw, y: dest.minY - sy * dest.height / sh + fullHeight)
            context.scaleBy(x: 1, y: -1); context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width) * dest.width / sw, height: fullHeight))
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
        let ink = reliableInk(of: line).map { $0.applying(matrix).insetBy(dx: attributes[.strokeWidth] == nil ? 0 : -font.pointSize * 0.01,
                                                                       dy: attributes[.strokeWidth] == nil ? 0 : -font.pointSize * 0.01) }
        let glyph = Glyph(line: line, matrix: matrix, ink: ink)
        // При смене шрифта кэш очищается; цвет задаётся при рисовании.
        // Ограничение не позволяет истории с уникальными символами разрастить кэш.
        if glyphs.count >= 4096 { glyphs.removeAll(keepingCapacity: true) }
        glyphs[key] = glyph
        return glyph
    }
    // Path bounds are not reliable for bitmap/color fallback runs (notably emoji).
    // Such runs deliberately use full-surface damage instead of guessed advances.
    private func reliableInk(of line: CTLine) -> NSRect? {
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName] else { return nil }
            let font = value as! CTFont
            if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) { return nil }
            let count = CTRunGetGlyphCount(run)
            var glyphIDs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphIDs)
            for glyphID in glyphIDs {
                var glyphID = glyphID
                let box = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphID, nil, 1)
                if !box.isEmpty && CTFontCreatePathForGlyph(font, glyphID, nil) == nil { return nil }
            }
        }
        let rect = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        return rect.isInfinite || rect.isNull ? nil : rect
    }
    private func anchor(at index: Int) -> Int {
        var result = index
        while result % width > 0 && cells[result].skip { result -= 1 }
        return result
    }
    private func glyphGeometry(at index: Int) -> (span: Int, columns: Int) {
        let x = index % width, cell = cells[index]
        var span = 1
        while x + span < width && cells[index + span].skip { span += 1 }
        var columns = span
        if span == 1, x + 1 < width, usesSymbolsFont(for: cell) {
            let next = cells[index + 1]
            if !next.skip, next.symbol == " ", colors(cell).1 == colors(next).1 { columns = 2 }
        }
        return (span, columns)
    }
    private func glyphFootprint(at index: Int) -> NSRect {
        guard width > 0, cells.indices.contains(index) else { return .zero }
        let index = anchor(at: index), cell = cells[index], geometry = glyphGeometry(at: index)
        let x = CGFloat(index % width) * cellWidth, y = CGFloat(index / width) * cellHeight
        var rect = NSRect(x: x, y: y, width: CGFloat(geometry.span) * cellWidth, height: cellHeight)
        guard !cell.skip, cell.modifier & 128 == 0, !cell.symbol.isEmpty else { return rect }
        if cell.symbol != " " {
            guard let ink = glyph(for: cell, columns: geometry.columns).ink else { return bounds }
            if !ink.isEmpty {
                let pixel = 1 / max(1, window?.backingScaleFactor ?? 1)
                rect = rect.union(NSRect(x: x + ink.minX, y: y + ascent - ink.maxY,
                                         width: ink.width, height: ink.height).insetBy(dx: -pixel, dy: -pixel))
            }
        }
        for offset in [cell.modifier & 8 != 0 ? ascent + 1 : -1, cell.modifier & 256 != 0 ? ascent * 0.62 : -1] where offset >= 0 {
            rect = rect.union(NSRect(x: x - 1, y: y + offset - 1, width: CGFloat(geometry.span) * cellWidth + 2, height: 2))
        }
        return rect
    }
    private func affectedAnchors(_ segments: [CellSegment]) -> Set<Int> {
        var result = Set<Int>()
        for segment in segments {
            let start = segment.y * width + segment.x
            for index in start..<(start + segment.cells.count) {
                let current = anchor(at: index)
                result.insert(current)
                if current % width > 0 { result.insert(anchor(at: current - 1)) }
            }
        }
        return result
    }
    private func rebuildInk<S: Sequence>(rows changed: S) where S.Element == Int {
        guard width > 0, height > 0 else { rowInk.removeAll(); return }
        if rowInk.count != height { rowInk = Array(repeating: RowInk(), count: height) }
        for row in changed {
            var ink = RowInk()
            ink.footprints = Array(repeating: .zero, count: width)
            for x in 0..<width {
                let index = row * width + x
                guard !cells[index].skip else { continue }
                let rect = glyphFootprint(at: index)
                ink.bounds = ink.bounds.union(rect)
                ink.footprints[x] = rect
                let cell = cells[index]
                if cell.modifier & 128 == 0, !cell.symbol.isEmpty, cell.symbol != " ",
                   glyph(for: cell, columns: glyphGeometry(at: index).columns).ink == nil {
                    ink.unknownColumns.append(x)
                } else {
                    ink.leftOverflow = max(ink.leftOverflow, CGFloat(x) * cellWidth - rect.minX)
                    ink.rightOverflow = max(ink.rightOverflow, rect.maxX - CGFloat(x + 1) * cellWidth)
                }
            }
            rowInk[row] = ink
        }
    }
    private func forEachGlyph(intersecting rect: NSRect, _ body: (Int) -> Void) {
        guard !rect.isEmpty, !rect.isNull else { return }
        for (row, ink) in rowInk.enumerated() where ink.bounds.intersects(rect) {
            let lo = max(0, min(width, Int(floor((rect.minX - ink.rightOverflow) / cellWidth))))
            let hi = max(0, min(width, Int(ceil((rect.maxX + ink.leftOverflow) / cellWidth))))
            if ink.unknownColumns.isEmpty {
                guard lo < hi else { continue }
                for column in lo..<hi {
                    let index = row * width + column
                    if !cells[index].skip, ink.footprints[column].intersects(rect) { body(index) }
                }
            } else {
                // Merge the bounded column range with unknown bitmap anchors, keeping
                // original composition order without scanning every cell in those rows.
                var column = lo, unknown = 0
                while column < hi || unknown < ink.unknownColumns.count {
                    let fallback = unknown < ink.unknownColumns.count ? ink.unknownColumns[unknown] : width
                    let candidate = min(column < hi ? column : width, fallback)
                    if candidate == column { column += 1 }
                    if candidate == fallback { unknown += 1 }
                    let index = row * width + candidate
                    if !cells[index].skip, ink.footprints[candidate].intersects(rect) { body(index) }
                }
            }
        }
    }
    private func selectionRects(_ selection: TerminalSelection?) -> [NSRect] {
        guard let selection else { return [] }
        return (0..<height).compactMap { row in
            guard let columns = selection.visibleColumns(row: row) else { return nil }
            return NSRect(x: CGFloat(columns.lowerBound) * cellWidth, y: CGFloat(row) * cellHeight,
                          width: CGFloat(columns.count) * cellWidth, height: cellHeight)
        }
    }
    private func selectionDifference(_ old: TerminalSelection?, _ new: TerminalSelection?) -> [NSRect] {
        let before = selectionRects(old), after = selectionRects(new)
        var result: [NSRect] = []
        func subtract(_ source: [NSRect], _ other: [NSRect]) {
            for rect in source {
                guard let overlap = other.first(where: { $0.minY == rect.minY })?.intersection(rect), !overlap.isEmpty else {
                    result.append(rect); continue
                }
                if rect.minX < overlap.minX { result.append(NSRect(x: rect.minX, y: rect.minY, width: overlap.minX - rect.minX, height: rect.height)) }
                if overlap.maxX < rect.maxX { result.append(NSRect(x: overlap.maxX, y: rect.minY, width: rect.maxX - overlap.maxX, height: rect.height)) }
            }
        }
        subtract(before, after); subtract(after, before)
        return result
    }
    private func cursorRect(in scene: [String: Any]) -> NSRect? {
        let cursor = dictionary(scene["cursor"])
        let x = integer(cursor["x"]), y = integer(cursor["y"]), shape = integer(cursor["shape"])
        guard flag(cursor["visible"]), x >= 0, x < width, y >= 0, y < height else { return nil }
        var rect = NSRect(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight, width: cellWidth, height: cellHeight)
        if shape == 3 || shape == 4 { rect.origin.y += cellHeight - 2; rect.size.height = 2 }
        else if shape == 5 || shape == 6 { rect.size.width = 2 }
        return rect
    }
    private var markedAttributes: [NSAttributedString.Key: Any] {
        [.font: gridFont, .foregroundColor: TerminalTheme.foreground, .backgroundColor: TerminalTheme.background,
         .underlineStyle: NSUnderlineStyle.single.rawValue]
    }
    private func markedTextRect(_ text: String, in scene: [String: Any]) -> NSRect? {
        guard !text.isEmpty else { return nil }
        if markedMetrics?.text != text {
            let attributed = NSAttributedString(string: text, attributes: markedAttributes)
            let line = CTLineCreateWithAttributedString(attributed)
            if let pathInk = reliableInk(of: line) {
                let size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                // draw(at:) uses NSString's single-line origin, not a paragraph's
                // line-fragment origin. Fallback fonts may extend above that origin.
                let layout = attributed.boundingRect(with: size, options: [])
                let deviceInk = attributed.boundingRect(with: size, options: [.usesDeviceMetrics])
                let baselineInk = NSRect(x: pathInk.minX, y: ascent - pathInk.maxY,
                                         width: pathInk.width, height: pathInk.height)
                var lineAscent: CGFloat = 0, lineDescent: CGFloat = 0
                let advance = CGFloat(CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil))
                let background = NSRect(x: 0, y: ascent - lineAscent, width: advance,
                                        height: lineAscent + lineDescent)
                let underlineY = ascent - CTFontGetUnderlinePosition(gridFont as CTFont)
                let underlineThickness = CTFontGetUnderlineThickness(gridFont as CTFont)
                let underline = NSRect(x: 0, y: underlineY - underlineThickness / 2,
                                       width: advance, height: underlineThickness)
                markedMetrics = (text, layout.union(deviceInk).union(baselineInk).union(background).union(underline))
            } else {
                markedMetrics = (text, nil)
            }
        }
        guard let rect = markedMetrics?.rect else { return bounds }
        let cursor = dictionary(scene["cursor"])
        let pixel = 1 / max(1, window?.backingScaleFactor ?? 1)
        return rect.insetBy(dx: -pixel, dy: -pixel)
            .offsetBy(dx: number(cursor["x"]) * cellWidth, dy: number(cursor["y"]) * cellHeight)
    }
    private func drawGlyph(at index: Int, foreground: NSColor, context: CGContext) {
        let cell = cells[index], modifier = cell.modifier
        guard !cell.skip, modifier & 128 == 0, !cell.symbol.isEmpty else { return }
        let x = index % width, y = index / width
        if cell.symbol != " " {
            let glyph = glyph(for: cell, columns: glyphGeometry(at: index).columns)
            context.saveGState(); context.translateBy(x: CGFloat(x) * cellWidth, y: CGFloat(y) * cellHeight + ascent)
            context.scaleBy(x: 1, y: -1)
            let color = foreground.cgColor
            context.setFillColor(color); context.setStrokeColor(color)
            context.textMatrix = glyph.matrix
            context.textPosition = .zero; CTLineDraw(glyph.line, context); context.restoreGState()
        }
        if modifier & (8 | 256) != 0 {
            let span = glyphGeometry(at: index).span
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
        forEachGlyph(intersecting: rect.intersection(context.boundingBoxOfClipPath)) {
            drawGlyph(at: $0, foreground: foreground, context: context)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: dirtyRect)
        TerminalTheme.background.setFill(); bounds.fill()
        guard width > 0, height > 0 else { return }
        let y0 = max(0, min(height, Int(floor(dirtyRect.minY / cellHeight))))
        let y1 = max(0, min(height, Int(ceil(dirtyRect.maxY / cellHeight))))
        let x0 = max(0, min(width, Int(floor(dirtyRect.minX / cellWidth))))
        let x1 = max(0, min(width, Int(ceil(dirtyRect.maxX / cellWidth))))
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
        if x0 < x1 { for y in y0..<y1 {
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
        } }
        drawImages(negative: true, dirtyRect: dirtyRect, context: context)
        forEachGlyph(intersecting: dirtyRect) { index in
            drawGlyph(at: index, foreground: drawingColors(cells[index]).0, context: context)
        }
        drawImages(negative: false, dirtyRect: dirtyRect, context: context)
        for y in y0..<y1 {
            if let columns = selection?.visibleColumns(row: y) {
                let start = y * width + columns.lowerBound, end = y * width + columns.upperBound
                drawOverlay(from: start, through: end, foreground: TerminalTheme.selectionText, background: TerminalTheme.selection, context: context)
            }
        }
        let cursor = dictionary(scene["cursor"])
        if let rect = cursorRect(in: scene), rect.intersects(dirtyRect) {
            let x = integer(cursor["x"]), y = integer(cursor["y"]), shape = integer(cursor["shape"])
            if shape != 3 && shape != 4 && shape != 5 && shape != 6 {
                drawOverlay(from: y * width + x, through: y * width + x, foreground: TerminalTheme.cursorText, background: TerminalTheme.cursor, context: context)
            } else {
                TerminalTheme.cursor.setFill(); rect.fill()
            }
        }
        if let rect = markedTextRect(marked, in: scene), rect.intersects(dirtyRect) {
            (marked as NSString).draw(at: NSPoint(x: number(cursor["x"]) * cellWidth, y: number(cursor["y"]) * cellHeight),
                                     withAttributes: markedAttributes)
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
        let old = selection
        let target = selected.viewport.point(x: Int(point.x), y: Int(point.y))
        let columns = selected.granularity == .word ? wordColumns(at: target, viewport: selected.viewport) : nil
        selected.drag(to: target, wordColumns: columns)
        let changed = selected.head != selection?.head || selected.anchor != selection?.anchor
        if changed { selectionVersion &+= 1 }
        selection = selected; selectionPointer = point
        if changed { captureSelection() }
        invalidate(selectionDifference(old, selection))
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
        cancelLinkHover()
        guard !event.modifierFlags.intersection([.command, .control]).isEmpty,
              let target = link(at: cellAt(event)), let openLink else { return false }
        selecting = false
        linkClickButton = event.buttonNumber
        openLink(target)
        return true
    }
    private func currentLinkHoverEnvironment() -> (location: NSPoint?, flags: NSEvent.ModifierFlags, visible: Bool) {
        #if TAVERN_RENDER_TESTING
        if let linkHoverEnvironment { return linkHoverEnvironment() }
        #endif
        let visible = window.map {
            $0.isVisible && $0.isKeyWindow && !$0.isMiniaturized
                && $0.occlusionState.contains(.visible)
        } ?? false
        return (window?.mouseLocationOutsideOfEventStream, NSEvent.modifierFlags,
                visible && !NSApp.isHidden && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty)
    }
    private func captureLinkHover() -> TerminalLinkHoverSnapshot? {
        let environment = currentLinkHoverEnvironment()
        guard environment.visible, let location = environment.location,
              !environment.flags.intersection([.command, .control]).isEmpty else { return nil }
        let point = convert(location, from: nil)
        guard bounds.contains(point), visibleRect.contains(point) else { return nil }
        let x = Int(floor(point.x / cellWidth)), y = Int(floor(point.y / cellHeight))
        guard x >= 0, y >= 0, x < width, y < height,
              hoverRowGenerations.indices.contains(y),
              let pane = paneAt(NSPoint(x: x, y: y)) else { return nil }
        let rect = dictionary(pane["inner_rect"])
        let left = max(0, integer(rect["x"])), right = min(width, integer(rect["x"]) + integer(rect["width"]))
        guard left <= x, x < right else { return nil }
        var anchor = x
        while anchor > left && cells[y * width + anchor].skip { anchor -= 1 }
        let paneID = string(pane["pane_id"])
        var text = "", offset = 0
        var explicit: String?
        if let reference = cells[y * width + anchor].hyperlink {
            let links = scene["hyperlinks"] as? [String] ?? []
            // An invalid OSC reference remains an explicit miss, not an implicit link.
            explicit = Int(reference) < links.count ? links[Int(reference)] : ""
        } else {
            var utf16Count = 0
            for column in left..<right {
                let cell = cells[y * width + column]
                if column == anchor { offset = utf16Count }
                if !cell.skip { text += cell.symbol; utf16Count += cell.symbol.utf16.count }
            }
        }
        return TerminalLinkHoverSnapshot(
            bootID: string(scene["boot_id"]),
            projectionID: (scene["projection_revision"] as? NSNumber)?.uint64Value ?? 0,
            paneID: paneID, rowGeneration: hoverRowGenerations[y],
            rowGeometry: NSRect(x: left, y: y, width: right - left, height: 1),
            column: x, anchor: anchor, utf16Offset: offset,
            cwd: workingDirectoryForPane?(paneID), explicitTarget: explicit, rowText: text)
    }
    func cancelLinkHover() {
        hoverGeneration &+= 1
        hoverResolver.cancel()
        hoverTimer?.invalidate(); hoverTimer = nil
        hoverSnapshot = nil; hoverResolved = false; hoverTarget = nil
        pendingHoverMove = nil
        toolTip = nil
        if hoveringLink { NSCursor.iBeam.set() }
        hoveringLink = false
    }
    func refreshLinkHover() { requestLinkHover(force: false) }
    private func requestLinkHover(force: Bool) {
        guard let snapshot = captureLinkHover() else { cancelLinkHover(); return }
        if !force && hoverSnapshot == snapshot { return }
        cancelLinkHover()
        hoverSnapshot = snapshot
        let generation = hoverGeneration
        hoverResolver.request(snapshot) { [weak self] target in
            guard let self, self.hoverGeneration == generation,
                  self.hoverSnapshot == snapshot else { return }
            guard self.captureLinkHover() == snapshot else { self.cancelLinkHover(); return }
            self.hoverResolved = true; self.hoverTarget = target
            self.hoveringLink = target != nil
            self.toolTip = target.map { $0.isFileURL ? $0.path : $0.absoluteString }
            if target != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
            if let pending = self.pendingHoverMove, pending.snapshot == snapshot {
                self.pendingHoverMove = nil
                if target == nil,
                   !self.currentLinkHoverEnvironment().flags.contains(.shift),
                   let pane = objects(self.scene["panes"]).first(where: { string($0["pane_id"]) == snapshot.paneID }),
                   flag(pane["mouse_reporting"]) { self.send?(pending.command) }
            }
            if target == nil || target?.isFileURL == true {
                let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
                    guard let self, self.hoverGeneration == generation else { return }
                    self.hoverTimer = nil
                    self.requestLinkHover(force: true)
                }
                self.hoverTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control]).isEmpty { cancelLinkHover() }
        else { refreshLinkHover() }
    }
    override func mouseExited(with event: NSEvent) { cancelLinkHover() }
    private var focusedPane: String { string(objects(scene["panes"]).first(where: { flag($0["focused"]) })?["pane_id"]) }
    private func mouse(_ event: NSEvent, phase: String, paneID: String? = nil, lines: Int = 1) {
        guard let command = mouseCommand(event, phase: phase, paneID: paneID, lines: lines) else { return }
        send?(command)
    }
    private func mouseCommand(_ event: NSEvent, phase: String, paneID: String? = nil, lines: Int = 1) -> [String: Any]? {
        let cell = cellAt(event)
        let target = paneID.flatMap { id in objects(scene["panes"]).first { string($0["pane_id"]) == id } } ?? paneAt(cell)
        guard let pane = target else { return nil }
        let rect = dictionary(pane["inner_rect"])
        let cols = integer(rect["width"]), rows = integer(rect["height"])
        guard cols > 0, rows > 0 else { return nil }
        let col = max(0, min(cols - 1, Int(cell.x) - integer(rect["x"])))
        let row = max(0, min(rows - 1, Int(cell.y) - integer(rect["y"])))
        return ["type": "mouse", "pane_id": string(pane["pane_id"]), "phase": phase,
                "button": event.buttonNumber == 1 ? "right" : event.buttonNumber == 2 ? "middle" : "left",
                "col": col, "row": row, "modifiers": terminalModifiers(event.modifierFlags), "lines": lines]
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    private func beginMouse(_ event: NSEvent) {
        cancelLinkHover()
        let old = selection
        defer { invalidate(selectionDifference(old, selection)) }
        window?.makeFirstResponder(self)
        let cell = cellAt(event)
        guard let pane = paneAt(cell) else { return }
        let id = string(pane["pane_id"])
        if id != focusedPane { focusPane?(id) }
        if event.buttonNumber <= 2 && flag(pane["mouse_reporting"]) && !event.modifierFlags.contains(.shift) {
            selection = nil; selecting = false; selectionPointer = nil; selectionVersion &+= 1
            reportedButtons[event.buttonNumber] = id; mouse(event, phase: "down", paneID: id)
        } else if event.buttonNumber == 0 {
            selection = nil; selecting = false; selectionPointer = nil; selectionVersion &+= 1
            if let viewport = selectionViewport(pane) {
                let anchor = viewport.point(x: Int(cell.x), y: Int(cell.y))
                let granularity: TerminalSelection.Granularity = event.clickCount >= 3 ? .line : event.clickCount == 2 ? .word : .character
                selection = TerminalSelection(boot: string(scene["boot_id"]), viewport: viewport, anchor: anchor,
                    granularity: granularity, wordColumns: granularity == .word ? wordColumns(at: anchor, viewport: viewport) : nil)
                selecting = true; selectionPointer = cell
                captureSelection()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        cancelLinkHover()
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
        cancelLinkHover()
        if let id = reportedButtons[event.buttonNumber] { mouse(event, phase: "drag", paneID: id) }
        else if selecting && event.buttonNumber == 0 {
            updateSelection(at: cellAt(event))
        }
    }
    override func mouseDragged(with event: NSEvent) {
        cancelLinkHover()
        guard linkClickButton != event.buttonNumber else { return }
        if dragSplit != nil { splitRatio(event) } else { dragMouse(event) }
    }
    private func endMouse(_ event: NSEvent) {
        cancelLinkHover()
        // Открытый адрес не порождает ни выделения, ни одиночного mouse-up в PTY.
        if linkClickButton == event.buttonNumber { linkClickButton = nil; return }
        if let id = reportedButtons.removeValue(forKey: event.buttonNumber) { mouse(event, phase: "up", paneID: id) }
        else if selecting && event.buttonNumber == 0 {
            updateSelection(at: cellAt(event))
            selecting = false; selectionPointer = nil
        }
    }
    override func mouseUp(with event: NSEvent) {
        cancelLinkHover()
        if dragSplit != nil { splitRatio(event); dragSplit = nil; dragPane = "" } else { endMouse(event) }
    }
    private func showPaneMenu(_ event: NSEvent) -> Bool {
        cancelLinkHover()
        guard let pane = paneAt(cellAt(event)),
              let menu = contextMenuForPane?(string(pane["pane_id"])),
              let presentContextMenu else { return false }
        presentContextMenu(menu, event, self)
        return true
    }
    override func rightMouseDown(with event: NSEvent) {
        cancelLinkHover()
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
        refreshLinkHover()
        pendingHoverMove = nil
        guard !event.modifierFlags.contains(.shift),
              let pane = paneAt(cellAt(event)), flag(pane["mouse_reporting"]),
              let command = mouseCommand(event, phase: "move") else { return }
        if let snapshot = hoverSnapshot {
            let cell = cellAt(event)
            guard snapshot.paneID == string(pane["pane_id"]),
                  snapshot.column == Int(cell.x), Int(snapshot.rowGeometry.minY) == Int(cell.y) else { return }
            if !hoverResolved { pendingHoverMove = (snapshot, command) }
            else if hoverTarget == nil { send?(command) }
        } else {
            send?(command)
        }
    }
    override func scrollWheel(with event: NSEvent) {
        cancelLinkHover()
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
        let old = selection
        defer { invalidate(selectionDifference(old, selection)) }
        selection = nil; selecting = false; selectionPointer = nil; selectionVersion &+= 1
        guard let pane = objects(scene["panes"]).first(where: { flag($0["focused"]) }),
              let viewport = selectionViewport(pane) else { return }
        var selected = TerminalSelection(boot: string(scene["boot_id"]), viewport: viewport,
            anchor: TerminalTextPoint(row: viewport.top, col: 0))
        selected.head = TerminalTextPoint(row: viewport.top + viewport.rows - 1, col: viewport.columns - 1)
        selection = selected; captureSelection()
    }
    private func clearInputSelection() {
        let old = selection
        selection = nil; selecting = false; selectionPointer = nil
        selectionVersion &+= 1
        invalidate(selectionRects(old))
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
        let old = selection
        switch event.keyCode {
        case 123: selection?.extend(columns: -1)
        case 124: selection?.extend(columns: 1)
        case 125: selection?.extend(rows: 1)
        case 126: selection?.extend(rows: -1)
        default: return false
        }
        selectionVersion &+= 1; captureSelection()
        invalidate(selectionDifference(old, selection))
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
        let old = markedTextRect(marked, in: scene)
        marked = (value as? NSAttributedString)?.string ?? string(value)
        let length = (marked as NSString).length, location = min(selectedRange.location, length)
        markedSelection = NSRange(location: location, length: min(selectedRange.length, length - location))
        invalidate([old, markedTextRect(marked, in: scene)].compactMap { $0 })
        inputContext?.invalidateCharacterCoordinates()
    }
    func unmarkText() {
        let old = markedTextRect(marked, in: scene)
        marked = ""; markedSelection = NSRange(location: 0, length: 0)
        markedMetrics = nil
        invalidate([old].compactMap { $0 })
        inputContext?.invalidateCharacterCoordinates()
    }
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
        let size = (marked as NSString).size(withAttributes: markedAttributes)
        let rect = NSRect(x: number(cursor["x"]) * cellWidth, y: number(cursor["y"]) * cellHeight,
                          width: max(cellWidth, size.width), height: max(cellHeight, size.height))
        return window?.convertToScreen(convert(rect, to: nil)) ?? .zero
    }
}
