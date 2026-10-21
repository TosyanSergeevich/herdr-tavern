import AppKit
import CoreText

struct TerminalFonts {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let symbols: NSFont

    static func load(size: CGFloat, bundle: Bundle = .main) throws -> TerminalFonts {
        func loadFace(_ name: String) throws -> NSFont {
            guard let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                  let provider = CGDataProvider(url: url as CFURL), let face = CGFont(provider) else {
                throw NSError(domain: "HerdrTavern.Fonts", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: L("core.surface.fontUnavailable", name)])
            }
            // Загружаем конкретный файл, не регистрируя и не подменяя системные шрифты.
            return CTFontCreateWithGraphicsFont(face, size, nil, nil) as NSFont
        }
        return try TerminalFonts(
            regular: loadFace("IosevkaCustom-Medium"),
            bold: loadFace("IosevkaCustom-Bold"),
            italic: loadFace("IosevkaCustom-MediumOblique"),
            boldItalic: loadFace("IosevkaCustom-BoldOblique"),
            symbols: loadFace("SymbolsNerdFont-Regular")
        )
    }
}
