import AppKit

/// Материал сообщает назначение, а не состояние операции.
enum TavernButtonRole { case navigation, primary, tool }

struct TavernButtonSkins {
    private let navigation: NSImage
    private let primary: NSImage
    private let tool: NSImage
    private let toolIcon: NSImage

    init(bundle: Bundle) throws {
        func load(_ name: String) throws -> NSImage {
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Textures"),
                  let image = NSImage(contentsOf: url), image.isValid,
                  let bitmap = image.representations.first else {
                throw NSError(domain: "HerdrTavern.Materials", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L("core.resources.buttonMaterial", name)])
            }
            image.size = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            return image
        }
        navigation = try load("ButtonNavigation")
        primary = try load("ButtonPrimary")
        tool = try load("ButtonTool")
        toolIcon = try load("ButtonToolIcon")
    }

    /// Концы масштабируются пропорционально высоте; растягивается только середина.
    /// TavernButton кэширует результат до смены размера или роли.
    func image(role: TavernButtonRole, icon: Bool, size: NSSize) -> NSImage {
        let source: NSImage
        switch role {
        case .navigation: source = navigation
        case .primary: source = primary
        case .tool: source = icon ? toolIcon : tool
        }
        let image = NSImage(size: size, flipped: false) { bounds in
            if icon && role == .tool {
                let scale = min(bounds.width / source.size.width, bounds.height / source.size.height)
                let fitted = NSSize(width: source.size.width * scale, height: source.size.height * scale)
                source.draw(in: NSRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                                       width: fitted.width, height: fitted.height),
                            from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: false, hints: TavernMaterials.frameHints)
                return true
            }
            let cap = min(source.size.width / 3, source.size.height * 0.65)
            let end = min(bounds.width / 2, cap * bounds.height / source.size.height)
            let sourceX: [CGFloat] = [0, cap, source.size.width - cap]
            let sourceWidths: [CGFloat] = [cap, source.size.width - 2 * cap, cap]
            let targetX: [CGFloat] = [bounds.minX, bounds.minX + end, bounds.maxX - end]
            let targetWidths: [CGFloat] = [end, bounds.width - 2 * end, end]
            for index in 0..<3 where targetWidths[index] > 0 {
                source.draw(in: NSRect(x: targetX[index], y: bounds.minY, width: targetWidths[index], height: bounds.height),
                            from: NSRect(x: sourceX[index], y: 0, width: sourceWidths[index], height: source.size.height),
                            operation: .sourceOver, fraction: 1, respectFlipped: false, hints: TavernMaterials.frameHints)
            }
            return true
        }
        image.cacheMode = .always
        return image
    }
}
