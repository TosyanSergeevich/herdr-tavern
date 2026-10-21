import AppKit

// Ресурсы читаются один раз. Ошибка упаковки проверяется до построения окна.
struct TavernMaterials {
    static let bundled: Result<TavernMaterials, Error> = Result { try TavernMaterials(bundle: .main) }
    static let frameHints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high]

    let wood: NSImage
    let boardWood: NSImage
    let topTab: NSImage
    let tabRecess: NSImage
    let addButton: NSImage
    let buttonSkins: TavernButtonSkins
    let frame: NSImage
    let sidebarFrame: NSImage
    let sidebarSprig: NSImage
    let sidebarLeaves: NSImage
    let rootFrame: NSImage
    let scrollerBronze: NSImage
    let agentChainConnector: NSImage
    let agentChainStrap: NSImage
    let agentChainBelt: NSImage

    enum FrameStyle { case viewport, root }

    init(bundle: Bundle) throws {
        func image(_ name: String, size: NSSize) throws -> NSImage {
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Textures"),
                  let image = NSImage(contentsOf: url), image.isValid else {
                throw NSError(domain: "HerdrTavern.Materials", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L("core.resources.material", name)])
            }
            image.size = size
            return image
        }
        wood = try image("OakPanel", size: NSSize(width: 640, height: 2440))
        boardWood = try image("LivingBoardWood", size: NSSize(width: 1024, height: 256))
        topTab = try image("LivingTopTab", size: NSSize(width: 258, height: 52))
        tabRecess = try image("LivingTabRecess", size: NSSize(width: 885, height: 122))
        addButton = try image("LivingAddButton", size: NSSize(width: 55, height: 52))
        buttonSkins = try TavernButtonSkins(bundle: bundle)
        frame = try image("LivingFrame", size: NSSize(width: 1185, height: 837))
        sidebarFrame = try image("LivingSidebarFrame", size: NSSize(width: 339, height: 905))
        sidebarSprig = try image("LivingSidebarSprig", size: NSSize(width: 64, height: 64))
        sidebarLeaves = try image("LivingSidebarLeaves", size: NSSize(width: 76, height: 60))
        rootFrame = try image("LivingRootFrame", size: NSSize(width: 1531, height: 967))
        scrollerBronze = try image("ScrollerBronze", size: NSSize(width: 64, height: 64))
        agentChainConnector = try image("AgentChainConnector", size: NSSize(width: 10, height: 24))
        agentChainStrap = try image("AgentChainStrap", size: NSSize(width: 8, height: 56))
        agentChainBelt = try image("AgentChainBelt", size: NSSize(width: 56, height: 8))
    }

    static func tabOutline(in rect: NSRect, flipped: Bool = false) -> NSBezierPath {
        let top = flipped ? rect.minY : rect.maxY
        let bottom = flipped ? rect.maxY : rect.minY
        let direction: CGFloat = flipped ? 1 : -1
        let cut = min(7, min(rect.width, rect.height) * 0.22)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: bottom))
        path.line(to: NSPoint(x: rect.maxX, y: bottom))
        path.line(to: NSPoint(x: rect.maxX, y: top + cut * direction))
        path.line(to: NSPoint(x: rect.maxX-cut, y: top))
        path.line(to: NSPoint(x: rect.minX+cut, y: top))
        path.line(to: NSPoint(x: rect.minX, y: top + cut * direction))
        path.close()
        return path
    }

    private static let topTabCaps = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 18)
    private static let tabRecessCaps = NSEdgeInsets(top: 18, left: 64, bottom: 24, right: 64)
    private static let frameCaps = NSEdgeInsets(top: 70, left: 70, bottom: 70, right: 70)
    private static let rootCaps = NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80)

    func tabImage(size: NSSize) -> NSImage {
        nineSlice(topTab, size: size, sourceCaps: Self.topTabCaps, scale: 0.7, center: boardWood)
    }

    func tabRecessImage(size: NSSize) -> NSImage {
        nineSlice(tabRecess, size: size, sourceCaps: Self.tabRecessCaps, scale: 0.5)
    }



    // Размеры мастеров — пиксели утверждённого концепта; edge задаёт pt рейки.
    // Замкнутые рамы остаются только у корпуса и терминального проёма.
    func frameImage(size: NSSize, edge: CGFloat, style: FrameStyle = .viewport) -> NSImage {
        switch style {
        case .viewport: return nineSlice(frame, size: size, sourceCaps: Self.frameCaps, scale: edge / 21)
        case .root: return nineSlice(rootFrame, size: size, sourceCaps: Self.rootCaps, scale: edge / 12)
        }
    }

    // Боковая панель — заполнение общего корпуса, а не вторая замкнутая рама.
    // Резьба включает прилегающую древесину; торцы скрываются общими рейками.
    func sidebarTrimImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { bounds in
            let postWidth = min(9.8, bounds.width)
            let beamHeight = min(8.4, bounds.height)
            let shadow = NSGradient(starting: NSColor.black.withAlphaComponent(0.58),
                                    ending: NSColor.black.withAlphaComponent(0))!
            shadow.draw(in: NSRect(x: 0, y: 0, width: min(10, bounds.width), height: bounds.height), angle: 0)
            shadow.draw(in: NSRect(x: 0, y: max(0, bounds.height - 12),
                                  width: bounds.width, height: min(12, bounds.height)), angle: 270)
            shadow.draw(in: NSRect(x: max(0, bounds.width - postWidth - 12), y: 0,
                                  width: min(12, max(0, bounds.width - postWidth)), height: bounds.height), angle: 180)
            shadow.draw(in: NSRect(x: 0, y: beamHeight, width: bounds.width,
                                  height: min(10, max(0, bounds.height - beamHeight))), angle: 90)
            // Основание ветки скрывает металл; длинные побеги обрамляют проём.
            self.sidebarSprig.draw(in: NSRect(x: bounds.minX - 3, y: bounds.maxY - 63,
                                              width: 64, height: 64),
                                    from: .zero, operation: .sourceOver, fraction: 1,
                                    respectFlipped: false, hints: Self.frameHints)
            // Неподвижная фоновая ветка: прокручиваемые карточки рисуются поверх.
            self.sidebarLeaves.draw(in: NSRect(x: bounds.minX + 3, y: bounds.minY + beamHeight,
                                              width: 76, height: 60),
                                    from: .zero, operation: .sourceOver, fraction: 1,
                                    respectFlipped: false, hints: Self.frameHints)
            Self.drawTiled(self.sidebarFrame,
                           from: NSRect(x: self.sidebarFrame.size.width - 14, y: 45,
                                        width: 14, height: self.sidebarFrame.size.height - 90),
                           in: NSRect(x: bounds.maxX - postWidth, y: 0, width: postWidth, height: bounds.height),
                           scale: 0.7)
            // Общая нижняя перекладина закрывает торец стойки без второго уголка.
            Self.drawTiled(self.rootFrame,
                           from: NSRect(x: 80, y: 0, width: self.rootFrame.size.width - 160, height: 12),
                           in: NSRect(x: 0, y: 0, width: bounds.width, height: beamHeight), scale: 0.7)
            // Стойка входит под общую балку без отдельного колпачка.
            // Узкая контактная тень объясняет глубину, не добавляя ещё одну рамку.
            shadow.draw(in: NSRect(x: bounds.maxX - postWidth, y: bounds.maxY - 5,
                                  width: postWidth, height: 5), angle: 270)
            return true
        }
        image.cacheMode = .always
        return image
    }

    // Углы фиксированы; рейки повторяются вдоль своей оси, древесина — отдельным
    // материалом. Размер окна меняет площадь, но не масштаб рисунка.
    // Только контрол меньше суммы накладок уменьшает весь материал равномерно.
    private func nineSlice(_ source: NSImage, size: NSSize, sourceCaps: NSEdgeInsets,
                           scale: CGFloat, center: NSImage? = nil) -> NSImage {
        let cornerScale = max(0, min(scale,
                                    size.width / (sourceCaps.left + sourceCaps.right),
                                    size.height / (sourceCaps.top + sourceCaps.bottom)))
        func segments(length: CGFloat, leading: CGFloat, trailing: CGFloat) -> [(origin: CGFloat, length: CGFloat)] {
            [(0, leading), (leading, max(0, length-leading-trailing)), (length-trailing, trailing)]
        }
        let sourceColumns = segments(length: source.size.width, leading: sourceCaps.left, trailing: sourceCaps.right)
        let sourceRows = segments(length: source.size.height, leading: sourceCaps.bottom, trailing: sourceCaps.top)
        let columns = segments(length: size.width, leading: sourceCaps.left * cornerScale,
                               trailing: sourceCaps.right * cornerScale)
        let rows = segments(length: size.height, leading: sourceCaps.bottom * cornerScale,
                            trailing: sourceCaps.top * cornerScale)
        let image = NSImage(size: size, flipped: false) { bounds in
            for row in 0..<3 {
                for column in 0..<3 {
                    let x = columns[column], y = rows[row]
                    guard x.length > 0, y.length > 0 else { continue }
                    let destination = NSRect(x: bounds.minX+x.origin, y: bounds.minY+y.origin,
                                             width: x.length, height: y.length)
                    if row == 1 && column == 1 {
                        if let center {
                            Self.drawTiled(center, from: NSRect(origin: .zero, size: center.size),
                                           in: destination, scale: cornerScale)
                        }
                    } else {
                        let sx = sourceColumns[column], sy = sourceRows[row]
                        Self.drawTiled(source, from: NSRect(x: sx.origin, y: sy.origin,
                                                           width: sx.length, height: sy.length),
                                       in: destination, scale: cornerScale)
                    }
                }
            }
            return true
        }
        image.cacheMode = .always
        return image
    }

    // Привязка к левому верхнему краю: текстура не плывёт при resize.
    // Последний тайл обрезается clip-областью: его transform и sampling не меняются.
    static func drawTiled(_ source: NSImage, from sourceRect: NSRect,
                          in rect: NSRect, scale: CGFloat) {
        let tileWidth = sourceRect.width * scale, tileHeight = sourceRect.height * scale
        guard tileWidth > 0, tileHeight > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        var top = rect.maxY
        while top > rect.minY {
            var left = rect.minX
            while left < rect.maxX {
                source.draw(in: NSRect(x: left, y: top-tileHeight, width: tileWidth, height: tileHeight),
                            from: sourceRect, operation: .sourceOver, fraction: 1,
                            respectFlipped: false, hints: frameHints)
                left += tileWidth
            }
            top -= tileHeight
        }
    }
}
