import AppKit
import QuartzCore
import CoreText

// Оформление только оболочки: цвета ячеек и шрифт терминала задаёт SurfaceView.
enum TavernAppearance {
    static let wood = rgb(0x302016)
    static let chrome = rgb(0x211a15)
    static let border = rgb(0x795735)
    static let accent = rgb(0xd4b382)
    static let text = rgb(0xeee0ca)
    static let secondary = rgb(0xb7aa96)
    static let selected = rgb(0x31454a)
    static let hover = rgb(0x3a2c20)
    static let agentAccent = rgb(0x65cfe5)
    static let agentShadow = NSColor.black.withAlphaComponent(0.72).cgColor
    static let agentEdge = rgb(0x20140c).cgColor
    static let agentHoverLight = NSGradient(starting: NSColor.white.withAlphaComponent(0.07),
                                            ending: NSColor.white.withAlphaComponent(0.02))!
    static let terminal = TerminalTheme.background
    static let success = rgb(0x83d994)
    static let working = rgb(0x79bfd1)
    static let idle = rgb(0x83cf8c)
    // Загружаем из ресурсов без системной регистрации и без подмены
    // установленными одноимёнными гарнитурами.
    private static let interfaceFonts: Result<(body: CGFont, heading: CGFont, symbols: CGFont), Error> = Result {
        func load(_ name: String, _ ext: String) throws -> CGFont {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Fonts"),
                  let provider = CGDataProvider(url: url as CFURL), let face = CGFont(provider) else {
                throw NativeError.message(L("core.appearance.fontUnavailable", name))
            }
            return face
        }
        return (try load("FrizQuadrataC", "ttf"), try load("MorpheusAlt1Cyr", "otf"),
                try load("SymbolsNerdFont-Regular", "ttf"))
    }
    static func validateFonts() throws { _ = try interfaceFonts.get() }
    private static func bodyFont(size: CGFloat) -> NSFont {
        CTFontCreateWithGraphicsFont(try! interfaceFonts.get().body, size, nil, nil) as NSFont
    }
    private static func headingFont(size: CGFloat) -> NSFont {
        CTFontCreateWithGraphicsFont(try! interfaceFonts.get().heading, size, nil, nil) as NSFont
    }
    static let bodyFont = bodyFont(size: 16)
    private static let titleSymbolsFont = CTFontCreateWithGraphicsFont(try! interfaceFonts.get().symbols, 16, nil, nil) as NSFont
    private static let statusSymbolsFont = CTFontCreateWithGraphicsFont(try! interfaceFonts.get().symbols, 12, nil, nil) as NSFont

    static func navigationTitle(_ title: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let rendered = NSMutableAttributedString(string: title, attributes: attributes)
        let symbols = (attributes[.font] as? NSFont)?.pointSize == statusFont.pointSize ? statusSymbolsFont : titleSymbolsFont
        var offset = 0
        for scalar in title.unicodeScalars {
            let length = scalar.utf16.count
            if (0xE000...0xF8FF).contains(scalar.value)
                || (0xF0000...0xFFFFD).contains(scalar.value)
                || (0x100000...0x10FFFD).contains(scalar.value) {
                rendered.addAttribute(.font, value: symbols, range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return rendered
    }
    static let headingFont = headingFont(size: 25)
    static let workspaceHeadingFont = headingFont(size: 20)
    static let narrowWorkspaceHeadingFont = headingFont(size: 18)
    static let smallFont = bodyFont(size: 14)
    static let controlFont = bodyFont(size: 13)
    static let detailFont = bodyFont(size: 12)
    static let statusFont = bodyFont(size: 12)
    static let badgeFont = bodyFont(size: 10)
    static let tabHeight: CGFloat = 42
    static let inset: CGFloat = 12
    static let grainOpacity: CGFloat = 0.055
    static let surfaceLight = NSGradient(starting: NSColor.white.withAlphaComponent(0.045),
                                         ending: NSColor.black.withAlphaComponent(0.12))!
    // Один тайл 128 pt с разрешением 2×; при изменении окна меняется число повторений.
    static let grain: NSColor = {
        let side = 256
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
                                      bytesPerRow: side * 4, bitsPerPixel: 32)!
        let pixels = bitmap.bitmapData!
        var seed: UInt32 = 0x74617665
        for index in 0..<(side * side) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let value: UInt8 = seed & 1 == 0 ? 0 : 255
            let offset = index * 4
            pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
            pixels[offset + 3] = UInt8((seed >> 8) & 255)
        }
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.addRepresentation(bitmap)
        return NSColor(patternImage: image)
    }()

    static func agentState(_ value: String) -> (String, NSColor) {
        switch value {
        case "working": return (L("core.agent.working"), working)
        case "blocked": return (L("core.agent.blocked"), accent)
        case "idle": return (L("core.agent.idle"), idle)
        case "done": return (L("core.agent.done"), success)
        default: return (L("core.agent.unknown"), secondary)
        }
    }
}

final class TavernSplitView: NSSplitView {
    override var dividerColor: NSColor { TavernAppearance.border }
    override var dividerThickness: CGFloat { 7 }
    override func mouseDown(with event: NSEvent) {
        let previous = TavernMotion.directLayout
        TavernMotion.directLayout = true
        defer { TavernMotion.directLayout = previous }
        super.mouseDown(with: event)
    }
    override func drawDivider(in rect: NSRect) {
        TavernAppearance.chrome.setFill(); rect.fill()
        TavernAppearance.border.setFill()
        NSRect(x: rect.midX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSRect(x: rect.midX + 1, y: rect.minY, width: 2, height: rect.height).fill()
    }
}


final class TavernTabScrollView: NSScrollView {
    weak var addButton: NSButton?
    var onScrollerStyleChange: (() -> Void)?
    override var scrollerStyle: NSScroller.Style {
        didSet {
            if oldValue != scrollerStyle { onScrollerStyleChange?() }
        }
    }

    override func tile() {
        super.tile()
        // Legacy-scroller занимает часть строки, overlay — нет. Геометрия
        // документа и кнопок всегда следует настоящему viewport, включая смену стиля.
        let height = contentSize.height
        if let document = documentView {
            if document.frame.height != height {
                document.setFrameSize(NSSize(width: document.frame.width, height: height))
            }
            for view in document.subviews {
                guard let button = view as? NSButton else { continue }
                var rect = button.frame
                rect.size.height = min(38, max(0, height))
                rect.origin.y = 0
                if button.frame != rect { button.frame = rect }
            }
        }
        if let addButton, let parent = addButton.superview {
            var rect = addButton.frame
            rect.size.height = min(38, max(0, height))
            let viewport = contentView.convert(contentView.bounds, to: parent)
            rect.origin.y = viewport.minY
            if addButton.frame != rect { addButton.frame = rect }
        }
    }
}

final class TavernTabRecessView: NSView {
    private let materials = try! TavernMaterials.bundled.get()
    private let edgeShade = NSGradient(starting: NSColor(calibratedRed: 0.07, green: 0.04, blue: 0.02, alpha: 0.82),
                                       ending: NSColor(calibratedRed: 0.07, green: 0.04, blue: 0.02, alpha: 0))!
    private var artwork: NSImage?
    private var artworkSize = NSSize.zero
    var contentRect = NSRect.zero {
        didSet { if oldValue != contentRect { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("TavernTabRecessView requires a frame") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if artworkSize != newSize {
            artworkSize = newSize
            artwork = newSize.width > 0 && newSize.height > 0 ? materials.tabRecessImage(size: newSize) : nil
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let width = min(9, contentRect.width / 2)
        if width > 0 && contentRect.height > 0 {
            edgeShade.draw(in: NSRect(x: contentRect.minX, y: contentRect.minY,
                                   width: width, height: contentRect.height), angle: 0)
            edgeShade.draw(in: NSRect(x: contentRect.maxX-width, y: contentRect.minY,
                                   width: width, height: contentRect.height), angle: 180)
        }
        artwork?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: false, hints: TavernMaterials.frameHints)
    }
}

final class ChromeView: NSView {
    enum Material { case grain, wood }
    private let fill: NSColor
    private let topBorder: Bool
    private let material: Material?

    init(frame: NSRect = .zero, fill: NSColor, topBorder: Bool = false, material: Material? = nil) {
        self.fill = fill; self.topBorder = topBorder; self.material = material
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("ChromeView requires a fill color") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill(); bounds.fill()
        if let material, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            if material == .wood {
                let texture = try! TavernMaterials.bundled.get().wood
                let visible = bounds.intersection(dirtyRect)
                if !visible.isEmpty {
                    // Древесина сохраняет масштаб и на узкой панели, и на широком окне.
                    let first = floor((bounds.maxY - visible.maxY) / texture.size.height) * texture.size.height
                    let firstX = floor(visible.minX / texture.size.width) * texture.size.width
                    for offset in stride(from: first, to: bounds.maxY - visible.minY, by: texture.size.height) {
                        let height = min(texture.size.height, bounds.height - offset)
                        for x in stride(from: firstX, to: visible.maxX, by: texture.size.width) {
                            let width = min(texture.size.width, bounds.maxX - x)
                            let destination = NSRect(x: x, y: bounds.maxY - offset - height,
                                                     width: width, height: height)
                            let source = NSRect(x: 0, y: texture.size.height - height,
                                                width: width, height: height)
                            texture.draw(in: destination, from: source, operation: .sourceOver,
                                         fraction: 1, respectFlipped: true, hints: TavernMaterials.frameHints)
                        }
                    }
                }
            } else {
                context.setAlpha(TavernAppearance.grainOpacity)
                TavernAppearance.grain.setFill(); bounds.fill()
            }
            context.restoreGState()
            TavernAppearance.surfaceLight.draw(in: bounds, angle: -90)
        }
        if topBorder {
            TavernAppearance.border.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
    }
}

final class SectionDivider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 24, let context = NSGraphicsContext.current?.cgContext else { return }
        let x = bounds.midX, y = bounds.midY
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.65).cgColor); context.setLineWidth(2)
        context.move(to: CGPoint(x: bounds.minX, y: y-0.5))
        context.addLine(to: CGPoint(x: x-10, y: y-0.5))
        context.move(to: CGPoint(x: x+10, y: y-0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: y-0.5)); context.strokePath()
        context.setStrokeColor(TavernAppearance.border.cgColor); context.setLineWidth(0.75)
        context.move(to: CGPoint(x: bounds.minX, y: y+0.5))
        context.addLine(to: CGPoint(x: x-10, y: y+0.5))
        context.move(to: CGPoint(x: x+10, y: y+0.5))
        context.addLine(to: CGPoint(x: bounds.maxX, y: y+0.5)); context.strokePath()
        let ornament = NSBezierPath()
        for (index, point) in [NSPoint(x: -6, y: 0), NSPoint(x: -2, y: 2), NSPoint(x: 0, y: 6),
                               NSPoint(x: 2, y: 2), NSPoint(x: 6, y: 0), NSPoint(x: 2, y: -2),
                               NSPoint(x: 0, y: -6), NSPoint(x: -2, y: -2)].enumerated() {
            let p = NSPoint(x: x+point.x, y: y+point.y)
            if index == 0 { ornament.move(to: p) } else { ornament.line(to: p) }
        }
        ornament.close()
        TavernAppearance.chrome.setFill(); ornament.fill()
        TavernAppearance.border.setStroke(); ornament.lineWidth = 1; ornament.stroke()
        context.setStrokeColor(TavernAppearance.accent.withAlphaComponent(0.6).cgColor)
        context.move(to: CGPoint(x: x-5, y: y)); context.addLine(to: CGPoint(x: x-1.5, y: y+1.5))
        context.addLine(to: CGPoint(x: x, y: y+5)); context.strokePath()
        context.setFillColor(TavernAppearance.accent.withAlphaComponent(0.5).cgColor)
        context.fillEllipse(in: CGRect(x: x-1, y: y-1, width: 2, height: 2))
    }
}

/// Декоративная связь карточек; события мыши остаются у навигации.
final class AgentChainView: NSView {
    static let extraGap: CGFloat = 2
    static let groupGap: CGFloat = 8
    private let connector = try! TavernMaterials.bundled.get().agentChainConnector
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: bounds)
        for index in 0..<2 {
            let x = index == 0 ? bounds.minX + 18 : bounds.maxX - 28
            connector.draw(in: NSRect(x: x, y: bounds.midY - 12, width: 10, height: 24),
                           from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: false, hints: TavernMaterials.frameHints)
        }
    }
}

final class TavernStatusLight: NSView {
    var color = TavernAppearance.idle { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Self.drawGem(in: bounds.insetBy(dx: 1, dy: 1), color: color)
    }
    static func drawGem(in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setShadow(offset: .zero, blur: 3, color: color.withAlphaComponent(0.5).cgColor)
        context.setFillColor(NSColor.black.withAlphaComponent(0.8).cgColor); context.fillEllipse(in: rect)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setFillColor(color.cgColor); context.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
        context.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        let highlightY = NSGraphicsContext.current?.isFlipped == true ? rect.minY+2.5 : rect.maxY-4
        context.fillEllipse(in: CGRect(x: rect.minX+2, y: highlightY, width: 2, height: 1.5))
    }
}

final class TavernBoardPanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        guard rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        TavernAppearance.chrome.setFill(); path.fill()
        TavernAppearance.surfaceLight.draw(in: path, angle: -90)
        TavernAppearance.border.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1; path.stroke()
    }
}


// NSButton сохраняет нативные действия, клавиатурную навигацию и Accessibility.
private enum TavernGlyphs {
    private static var cache: [String: NSImage] = [:]
    static func image(_ name: String) -> NSImage? {
        if let image = cache[name] { return image }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) else { return nil }
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: false) { rect in
            symbol.draw(in: rect.insetBy(dx: 2, dy: 2))
            TavernAppearance.accent.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        cache[name] = image
        return image
    }
}

class TavernButton: NSButton {
    enum Style { case workspace, agent, tab, addTab, utility }
    private var style: Style = .utility
    private var selected = false
    private var indicator: NSColor?
    private var renderedTitle = NSAttributedString()
    private var titleAttributes: [NSAttributedString.Key: Any] = [:]
    private var renderedTitleHeight: CGFloat = 24
    private var renderedSubtitle = NSAttributedString()
    private var renderedContext = NSAttributedString()
    private var unread: AgentUnreadKind?
    private var renderedBadge = NSAttributedString()
    private var badgeWidth: CGFloat = 0
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private let materials = try! TavernMaterials.bundled.get()
    private var boardImage: NSImage?
    private var boardSize = NSSize.zero
    private var artwork: NSImage?
    var symbolName: String? { didSet { if symbolName != oldValue { dragVisualVersion &+= 1 } } }
    var role: TavernButtonRole = .tool {
        didSet {
            guard role != oldValue else { return }
            dragVisualVersion &+= 1
            boardImage = nil
            updateMaterialImage()
            needsLayout = true
            needsDisplay = true
        }
    }
    private var renderedIcon: NSImage?
    private var cardSurface: TavernCardSurfaceView?
    private var cardText: TavernCardTextView?
    private var talisman: TavernTalismanView?
    private var workspaceNebula: TavernWorkspaceNebulaView?
    private var workspaceAttention: AgentUnreadKind?

    func setWorkspaceAttention(_ kind: AgentUnreadKind?) {
        workspaceAttention = kind
        updateWorkspaceNebula()
    }

    private func removeWorkspaceNebula() {
        guard let nebula = workspaceNebula else { return }
        nebula.onLightingChange = nil
        nebula.configure(cardSize: bounds.insetBy(dx: 3, dy: 3).size, kind: nil)
        nebula.removeFromSuperview()
        workspaceNebula = nil
        cardSurface?.nebulaLightingProvider = nil
        cardSurface?.refreshLighting()
    }

    private func updateWorkspaceNebula() {
        let workspaceActive = style == .workspace && !selected && workspaceAttention != nil
        let agentColor = style == .agent ? dragAgentStatus?.color : nil
        guard (workspaceActive || agentColor != nil), isEnabled,
              let parent = superview, let surface = cardSurface else {
            removeWorkspaceNebula()
            return
        }
        let padding = TavernWorkspaceNebulaView.padding
        let decorationFrame = frame.insetBy(dx: -padding, dy: -padding)
        let nebula: TavernWorkspaceNebulaView
        if let existing = workspaceNebula {
            nebula = existing
            TavernMotion.move(nebula, to: decorationFrame)
        } else {
            nebula = TavernWorkspaceNebulaView(frame: decorationFrame)
            nebula.wantsLayer = true
            nebula.setAccessibilityElement(false)
            workspaceNebula = nebula
            // Весь декор ниже карточек, не внутри кнопки и не влияет на layout.
            parent.addSubview(nebula, positioned: .below, relativeTo: nil)
            nebula.onLightingChange = { [weak surface] in surface?.refreshLighting() }
            surface.nebulaLightingProvider = { [weak nebula] in nebula?.materialLights ?? .none }
            TavernMotion.appear(nebula)
        }
        if let agentColor {
            nebula.configure(cardSize: bounds.insetBy(dx: 3, dy: 3).size, agentColor: agentColor)
        } else {
            nebula.configure(cardSize: bounds.insetBy(dx: 3, dy: 3).size, kind: workspaceAttention)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateWorkspaceNebula()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        updateWorkspaceNebula()
    }
    var lampWindowPosition: (() -> CGPoint)?
    private var isBoard: Bool { style == .workspace || style == .agent }
    private let interactionSurface = CALayer()
    private let surfaceMask = CAShapeLayer()
    private let artworkMask = CALayer()
    private let hoverLight = CAGradientLayer()
    private let selectionWash = CAGradientLayer()
    private let selectionEdge = CALayer()
    private let pressShade = CALayer()
    private var feedbackPrepared = false
    private var pressed = false
    private struct DragGeometry: Equatable {
        let bounds: NSRect
        let backingScale: CGFloat
        let language: TavernLanguage
    }
    private struct DragFeedback: Equatable {
        let hovered: Bool
        let pressed: Bool
        let enabled: Bool
    }
    private var dragVisualVersion: UInt64 = 0
    private var dragGeometry: DragGeometry?
    private var dragFeedback: DragFeedback?
    private var dragIdentity = ""
    private var dragAgentStatus: TavernAgentVisualStatus?
    var dragVisualRevision: UInt64 {
        let geometry = DragGeometry(bounds: bounds, backingScale: window?.backingScaleFactor ?? 2,
                                    language: TavernLocalization.shared.language)
        if dragGeometry != geometry {
            dragGeometry = geometry
            dragVisualVersion &+= 1
        }
        return dragVisualVersion
    }
    private var isTopTab: Bool { style == .tab || style == .addTab }
    private var usesButtonSkin: Bool { style == .utility }
    private var usesIconSkin: Bool { title == "⋯" || title == "+" || (title.isEmpty && symbolName != nil) }
    private var surfaceBounds: NSRect {
        let rect = isTopTab
            ? NSRect(x: 1, y: isFlipped ? 2 : 0, width: bounds.width-2, height: bounds.height-2)
            : bounds.insetBy(dx: 3, dy: 3)
        guard let artwork, rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / artwork.size.width, rect.height / artwork.size.height)
        let size = NSSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
        return NSRect(x: rect.midX-size.width/2, y: rect.midY-size.height/2,
                      width: size.width, height: size.height)
    }

    private func updateMaterialImage() {
        if isBoard { boardImage = nil; return }
        let size = surfaceBounds.size
        guard size.width > 0, size.height > 0 else { return }
        guard boardImage == nil || boardSize != size else { return }
        boardSize = size
        if let artwork {
            boardImage = artwork
        } else {
            switch style {
            case .workspace, .agent: break // Материал этих кнопок принадлежит Metal-поверхности.
            case .tab: boardImage = materials.tabImage(size: size)
            case .utility: boardImage = materials.buttonSkins.image(role: role, icon: usesIconSkin, size: size)
            case .addTab: boardImage = materials.addButton
            }
        }
        if usesButtonSkin {
            artworkMask.contents = boardImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            artworkMask.contentsGravity = .resize
        }
    }

    private func prepareFeedback() {
        guard !feedbackPrepared else { return }
        wantsLayer = true
        interactionSurface.mask = surfaceMask
        // AppKit повторно упорядочивает backing layers дочерних NSView.
        // Одного addSublayer недостаточно: Metal иначе перекрывает hover и нажатие.
        interactionSurface.zPosition = 1
        selectionWash.colors = [NSColor(srgbRed: 0.025, green: 0.235, blue: 0.337, alpha: 0.30).cgColor,
                                NSColor(srgbRed: 0.025, green: 0.235, blue: 0.337, alpha: 0.18).cgColor]
        selectionWash.startPoint = CGPoint(x: 0, y: 0.5); selectionWash.endPoint = CGPoint(x: 1, y: 0.5)
        hoverLight.colors = [NSColor(srgbRed: 1, green: 0.83, blue: 0.58, alpha: 0.13).cgColor,
                            NSColor.white.withAlphaComponent(0.015).cgColor]
        hoverLight.startPoint = CGPoint(x: 0.5, y: isFlipped ? 0 : 1)
        hoverLight.endPoint = CGPoint(x: 0.5, y: isFlipped ? 1 : 0)
        pressShade.backgroundColor = NSColor.black.withAlphaComponent(0.19).cgColor
        selectionEdge.backgroundColor = NSColor(srgbRed: 0.28, green: 0.78, blue: 0.87, alpha: 1).cgColor
        selectionEdge.shadowColor = selectionEdge.backgroundColor
        selectionEdge.shadowRadius = 2; selectionEdge.shadowOpacity = 0.5; selectionEdge.shadowOffset = .zero
        for overlay in [selectionWash, hoverLight, pressShade, selectionEdge] {
            overlay.opacity = 0; interactionSurface.addSublayer(overlay)
        }
        layer?.addSublayer(interactionSurface)
        feedbackPrepared = true
        needsLayout = true
    }

    private func updateFeedback(animated: Bool = true) {
        let feedback = DragFeedback(hovered: hovered, pressed: pressed, enabled: isEnabled)
        if dragFeedback != feedback {
            dragFeedback = feedback
            dragVisualVersion &+= 1
        }
        guard feedbackPrepared else { return }
        let duration = animated ? TavernMotion.hoverDuration : 0
        needsDisplay = true
        TavernMotion.animate(hoverLight, key: "opacity", to: Float(isEnabled && hovered && !pressed ? 1 : 0), duration: duration)
        TavernMotion.animate(pressShade, key: "opacity", to: Float(isEnabled && pressed ? 1 : 0), duration: pressed ? 0.06 : duration)
        TavernMotion.animate(selectionWash, key: "opacity", to: Float(selected && !isBoard && !usesButtonSkin ? 1 : 0), duration: animated ? TavernMotion.selectionDuration : 0)
        TavernMotion.animate(selectionEdge, key: "opacity", to: Float(selected && (style == .tab || (usesButtonSkin && role == .navigation)) ? 1 : 0), duration: animated ? TavernMotion.selectionDuration : 0)
    }

    override func layout() {
        super.layout()
        updateMaterialImage()
        if let cardSurface {
            let frame = bounds.insetBy(dx: 3, dy: 3)
            if cardSurface.frame != frame { cardSurface.frame = frame }
            cardSurface.layoutSubtreeIfNeeded()
        }
        cardText?.frame = bounds
        talisman?.frame = bounds
        updateWorkspaceNebula()
        guard feedbackPrepared else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        interactionSurface.frame = bounds
        for overlay in [selectionWash, hoverLight, pressShade] { overlay.frame = bounds }
        let rect = surfaceBounds
        artworkMask.frame = rect
        surfaceMask.path = isTopTab ? TavernMaterials.tabOutline(in: rect, flipped: isFlipped).cgPath
            : CGPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerWidth: 4, cornerHeight: 4, transform: nil)
        if usesButtonSkin && role == .navigation {
            selectionEdge.backgroundColor = NSColor(srgbRed: 0.46, green: 0.12, blue: 0.14, alpha: 1).cgColor
            selectionEdge.shadowOpacity = 0
            selectionEdge.cornerRadius = 2
            selectionEdge.frame = NSRect(x: rect.minX + 4, y: rect.minY + 5, width: 3, height: max(0, rect.height - 10))
        } else {
            selectionEdge.backgroundColor = NSColor(srgbRed: 0.28, green: 0.78, blue: 0.87, alpha: 1).cgColor
            selectionEdge.frame = NSRect(x: rect.minX+3, y: isFlipped ? rect.maxY-1.3 : rect.minY, width: max(0, rect.width-6), height: 1.3)
        }
        CATransaction.commit()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMaterialImage()
        needsLayout = true
        updateWorkspaceNebula()
    }

    override var isEnabled: Bool {
        didSet {
            updateFeedback()
            updateWorkspaceNebula()
        }
    }

    override var title: String {
        didSet {
            guard title != oldValue else { return }
            dragVisualVersion &+= 1
            guard !titleAttributes.isEmpty else { return }
            updateRenderedTitle()
            invalidateIntrinsicContentSize()
            cardText?.needsDisplay = true
            needsDisplay = true
        }
    }

    private func updateRenderedTitle() {
        renderedTitle = TavernAppearance.navigationTitle(title, attributes: titleAttributes)
        renderedTitleHeight = ceil(renderedTitle.size().height)
    }

    func prepare(style: Style, selected: Bool = false, subtitle: String = "", context: String = "", indicator: NSColor? = nil, unread: AgentUnreadKind? = nil, identity: String = "") {
        if self.style != style || self.selected != selected || self.indicator != indicator || self.unread != unread
            || renderedSubtitle.string != subtitle || renderedContext.string != context || dragIdentity != identity {
            dragVisualVersion &+= 1
        }
        dragIdentity = identity
        let artwork: NSImage?
        if style == .addTab {
            artwork = materials.addButton
        } else {
            artwork = nil
        }
        if self.style != style || self.artwork !== artwork { boardImage = nil }
        self.artwork = artwork
        self.style = style; self.selected = selected; self.indicator = indicator; self.unread = unread
        let icon = artwork == nil ? symbolName ?? (style == .workspace ? "books.vertical" : style == .tab ? "terminal" : "") : ""
        renderedIcon = icon.isEmpty ? nil : TavernGlyphs.image(icon)
        let animateFeedback = feedbackPrepared
        prepareFeedback()
        interactionSurface.mask = usesButtonSkin ? artworkMask : surfaceMask
        if isBoard {
            if cardSurface == nil {
                let surface = TavernCardSurfaceView(frame: bounds.insetBy(dx: 3, dy: 3))
                surface.lightPositionProvider = { [weak self, weak surface] in
                    guard let surface, let point = self?.lampWindowPosition?() else {
                        return CGPoint(x: -500, y: -500)
                    }
                    let local = surface.convert(point, from: nil)
                    return CGPoint(x: local.x, y: surface.bounds.height - local.y)
                }
                addSubview(surface); cardSurface = surface
                let text = TavernCardTextView(frame: bounds)
                text.owner = self
                addSubview(text); cardText = text
            }
            let hash = identity.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            cardSurface?.configure(seed: hash, construction: style == .workspace ? .workspace : .agent, selected: selected)
            if style != .agent, let talisman {
                talisman.removeFromSuperview()
                self.talisman = nil
                cardSurface?.magicLightProvider = nil
            }
            if style == .agent && talisman == nil {
                let effects = TavernTalismanView(frame: bounds)
                addSubview(effects); talisman = effects
                cardSurface?.magicLightProvider = { [weak effects] in
                    guard let light = effects?.materialLight else { return nil }
                    return (CGPoint(x: light.position.x - 3, y: light.position.y - 3), light.colour, light.power)
                }
            }
            // Обратная связь поверх материала; текст остаётся нативным.
            layer?.addSublayer(interactionSurface)
        } else {
            cardSurface?.removeFromSuperview(); cardSurface = nil
            cardText?.removeFromSuperview(); cardText = nil
            talisman?.removeFromSuperview(); talisman = nil
        }
        updateWorkspaceNebula()
        updateFeedback(animated: animateFeedback)
        isBordered = false; focusRingType = .exterior
        setButtonType(.momentaryPushIn)
        state = selected ? .on : .off
        let titleFont = style == .utility ? TavernAppearance.controlFont : TavernAppearance.bodyFont
        font = titleFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = style == .utility ? .center : .left
        titleAttributes = [
            .font: titleFont, .foregroundColor: TavernAppearance.text, .paragraphStyle: paragraph
        ]
        updateRenderedTitle()
        renderedSubtitle = NSAttributedString(string: subtitle, attributes: [
            .font: TavernAppearance.detailFont, .foregroundColor: TavernAppearance.secondary, .paragraphStyle: paragraph
        ])
        let contextParagraph = NSMutableParagraphStyle()
        contextParagraph.lineBreakMode = .byTruncatingMiddle
        renderedContext = NSAttributedString(string: context, attributes: [
            .font: TavernAppearance.detailFont, .foregroundColor: TavernAppearance.secondary, .paragraphStyle: contextParagraph
        ])
        if let unread {
            renderedBadge = NSAttributedString(string: unread.badgeTitle, attributes: [
                .font: TavernAppearance.badgeFont,
                .foregroundColor: unread == .attention ? TavernAppearance.chrome : TavernAppearance.accent
            ])
            badgeWidth = ceil(renderedBadge.size().width) + 12
        } else { renderedBadge = NSAttributedString(); badgeWidth = 0 }
        let detail = [subtitle, context, unread?.label ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        toolTip = detail.isEmpty ? title : title + " — " + detail
        setAccessibilityHelp(detail.isEmpty ? nil : detail)
        invalidateIntrinsicContentSize()
        updateMaterialImage()
        needsLayout = true
        cardText?.needsDisplay = true
        needsDisplay = true
    }
    func setAgentVisualStatus(_ status: TavernAgentVisualStatus?) {
        if dragAgentStatus != status { dragAgentStatus = status; dragVisualVersion &+= 1 }
        talisman?.configure(status: status)
        updateWorkspaceNebula()
        cardSurface?.refreshLighting()
    }
    func requestDragImage(completion: @escaping (Result<NSImage, Error>) -> Void) {
        precondition(Thread.isMainThread)
        layoutSubtreeIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) {
                completion(.failure(NativeError.message(L("core.card.snapshotUnavailable"))))
            }
            return
        }
        cacheDisplay(in: bounds, to: bitmap)
        let size = bounds.size
        guard let cardSurface else {
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            RunLoop.main.perform(inModes: [.default, .eventTracking, .modalPanel]) { completion(.success(image)) }
            return
        }
        let frame = cardSurface.frame
        let rect = NSRect(x: frame.minX, y: isFlipped ? size.height - frame.maxY : frame.minY,
                          width: frame.width, height: frame.height)
        cardSurface.requestSnapshot { result in
            precondition(Thread.isMainThread)
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let material):
                guard let context = NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext else {
                    completion(.failure(NativeError.message(L("core.card.snapshotUnavailable"))))
                    return
                }
                context.saveGState()
                context.setBlendMode(.destinationOver)
                context.draw(material, in: rect)
                context.restoreGState()
                let image = NSImage(size: size)
                image.addRepresentation(bitmap)
                completion(.success(image))
            }
        }
    }
    override var intrinsicContentSize: NSSize {
        guard style == .utility else { return super.intrinsicContentSize }
        let hasIcon = renderedIcon != nil || (artwork != nil && title.isEmpty)
        return NSSize(width: max(34, ceil(renderedTitle.size().width) + (hasIcon ? 48 : 26)), height: 30)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateFeedback(); talisman?.setHovered(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateFeedback(); talisman?.setHovered(false) }
    override func mouseDown(with event: NSEvent) {
        pressed = true; updateFeedback(); CATransaction.flush()
        defer { pressed = false; updateFeedback() }
        super.mouseDown(with: event)
    }
    override func performClick(_ sender: Any?) {
        pressed = true; updateFeedback()
        super.performClick(sender)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.pressed = false; self?.updateFeedback()
        }
    }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() {
        if usesButtonSkin {
            let radius: CGFloat = role == .tool && !usesIconSkin ? surfaceBounds.height / 2 : 4
            NSBezierPath(roundedRect: surfaceBounds, xRadius: radius, yRadius: radius).fill()
        }
        else if isTopTab { TavernMaterials.tabOutline(in: focusRingMaskBounds, flipped: isFlipped).fill() }
        else { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill() }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isBoard { return }
        drawTextContents(dirtyRect, drawSurface: true)
    }
    fileprivate func drawTextContents(_ dirtyRect: NSRect, drawSurface: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); defer { context.restoreGState() }
        let rect = surfaceBounds
        guard rect.width > 0, rect.height > 0 else { return }
        if drawSurface {
            context.saveGState()
            if !isTopTab {
                context.setShadow(offset: CGSize(width: 0, height: isFlipped ? 2 : -2), blur: 3,
                                  color: TavernAppearance.agentShadow)
            }
            boardImage?.draw(in: rect, from: .zero, operation: .sourceOver,
                             fraction: !isEnabled ? 0.45 : 1,
                             respectFlipped: true, hints: TavernMaterials.frameHints)
            context.restoreGState()
        }
        if style == .addTab || (style == .utility && title == "+") {
            let half = min(5, rect.width * 0.18)
            context.setStrokeColor((isEnabled ? TavernAppearance.accent
                : TavernAppearance.secondary.withAlphaComponent(0.45)).cgColor)
            context.setLineWidth(1.2)
            context.setLineCap(.butt)
            context.move(to: CGPoint(x: rect.midX-half, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.midX+half, y: rect.midY))
            context.move(to: CGPoint(x: rect.midX, y: rect.midY-half))
            context.addLine(to: CGPoint(x: rect.midX, y: rect.midY+half))
            context.strokePath()
        }
        if usesButtonSkin && title == "+" { return }
        if artwork != nil { return }
        context.setAlpha(style == .agent || isEnabled ? 1 : 0.45)
        if usesButtonSkin && pressed && isEnabled { context.translateBy(x: 0, y: isFlipped ? 0.5 : -0.5) }
        var left: CGFloat = style == .utility ? 6 : 15
        if let renderedIcon {
            let side: CGFloat = style == .tab || usesButtonSkin ? 16 : 22
            let iconX: CGFloat = style == .utility ? (bounds.width-side)/2 : style == .tab ? 12 : 16
            let icon = NSRect(x: iconX, y: (bounds.height-side)/2, width: side, height: side)
            renderedIcon.draw(in: icon)
            left = style == .utility && title.isEmpty ? 9 : style == .tab ? 36 : 44
        } else if let indicator, !isBoard {
            let y = renderedSubtitle.length == 0 ? (bounds.height - 9) / 2 : (isFlipped ? 20 : bounds.height - 29)
            TavernStatusLight.drawGem(in: NSRect(x: 17, y: y, width: 9, height: 9), color: indicator)
            left = 35
        }
        // Постоянное место справа под закладку и подвес, независимо от выбора.
        let rightInset: CGFloat = isBoard ? max(40, 94 * TavernTalismanView.visualScale(forCardHeight: bounds.height - 6)) : style == .utility ? left : 14
        let width = max(0, bounds.width - left - rightInset)
        let badgeInset: CGFloat = unread == nil ? 0 : badgeWidth + 8
        let hasContext = renderedContext.length != 0
        let titleWidth = max(0, width - (hasContext ? 0 : badgeInset))
        if let unread {
            let badgeY = hasContext ? (isFlipped ? 53 : bounds.height - 71) : (isFlipped ? 15 : bounds.height - 33)
            let badge = NSRect(x: bounds.width - badgeWidth - rightInset, y: badgeY, width: badgeWidth, height: 18)
            context.setFillColor((unread == .attention ? TavernAppearance.accent : TavernAppearance.hover).cgColor)
            context.addPath(CGPath(roundedRect: badge, cornerWidth: 3, cornerHeight: 3, transform: nil)); context.fillPath()
            context.setStrokeColor((unread == .attention ? TavernAppearance.accent : TavernAppearance.border).cgColor)
            context.setLineWidth(1)
            context.addPath(CGPath(roundedRect: badge.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil)); context.strokePath()
            renderedBadge.draw(in: NSRect(x: badge.minX + 6, y: badge.midY - 7, width: badgeWidth - 12, height: 14))
        }
        if renderedSubtitle.length == 0 {
            renderedTitle.draw(in: NSRect(x: left, y: (bounds.height - renderedTitleHeight) / 2,
                                         width: titleWidth, height: renderedTitleHeight))
        } else {
            let titleTop: CGFloat = style == .workspace ? 8 : 12
            let subtitleTop: CGFloat = style == .workspace ? 29 : 35
            renderedTitle.draw(in: NSRect(x: left, y: isFlipped ? titleTop : bounds.height - titleTop - 24, width: titleWidth, height: 24))
            renderedSubtitle.draw(in: NSRect(x: left, y: isFlipped ? subtitleTop : bounds.height - subtitleTop - 17, width: width, height: 17))
            if renderedContext.length != 0 {
                renderedContext.draw(in: NSRect(x: left, y: isFlipped ? 54 : bounds.height - 71, width: max(0, width - badgeInset), height: 17))
            }
        }
    }
}

private final class TavernCardTextView: NSView {
    weak var owner: TavernButton?
    override var isFlipped: Bool { owner?.isFlipped ?? true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { owner?.drawTextContents(dirtyRect) }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); setAccessibilityElement(false) }
}
