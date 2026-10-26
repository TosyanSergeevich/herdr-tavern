import AppKit
import CoreText

struct TerminalFonts {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let symbols: NSFont
    private let faces: Faces

    // Retain the original graphics fonts (and their in-memory providers) across
    // all size/weight changes. No font registration or installed-font lookup.
    private final class Faces {
        let thin: CGFont
        let thinOblique: CGFont
        let extraLight: CGFont
        let extraLightOblique: CGFont
        let light: CGFont
        let lightOblique: CGFont
        let regular: CGFont
        let oblique: CGFont
        let medium: CGFont
        let mediumOblique: CGFont
        let semibold: CGFont
        let semiboldOblique: CGFont
        let bold: CGFont
        let boldOblique: CGFont
        let extraBold: CGFont
        let extraBoldOblique: CGFont
        let heavy: CGFont
        let heavyOblique: CGFont
        let symbols: CGFont

        init(bundle: Bundle) throws {
            func loadFace(_ name: String) throws -> CGFont {
                guard let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts"),
                      let data = try? Data(contentsOf: url),
                      let provider = CGDataProvider(data: data as CFData),
                      let face = CGFont(provider) else {
                    throw NSError(domain: "HerdrTavern.Fonts", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: L("core.surface.fontUnavailable", name)])
                }
                return face
            }
            thin = try loadFace("IosevkaCustom-Thin")
            thinOblique = try loadFace("IosevkaCustom-ThinOblique")
            extraLight = try loadFace("IosevkaCustom-ExtraLight")
            extraLightOblique = try loadFace("IosevkaCustom-ExtraLightOblique")
            light = try loadFace("IosevkaCustom-Light")
            lightOblique = try loadFace("IosevkaCustom-LightOblique")
            regular = try loadFace("IosevkaCustom-Regular")
            oblique = try loadFace("IosevkaCustom-Oblique")
            medium = try loadFace("IosevkaCustom-Medium")
            mediumOblique = try loadFace("IosevkaCustom-MediumOblique")
            semibold = try loadFace("IosevkaCustom-SemiBold")
            semiboldOblique = try loadFace("IosevkaCustom-SemiBoldOblique")
            bold = try loadFace("IosevkaCustom-Bold")
            boldOblique = try loadFace("IosevkaCustom-BoldOblique")
            extraBold = try loadFace("IosevkaCustom-ExtraBold")
            extraBoldOblique = try loadFace("IosevkaCustom-ExtraBoldOblique")
            heavy = try loadFace("IosevkaCustom-Heavy")
            heavyOblique = try loadFace("IosevkaCustom-HeavyOblique")
            symbols = try loadFace("SymbolsNerdFont-Regular")
        }
    }

    private init(size: CGFloat, weight: TerminalFontWeight, faces: Faces) {
        self.faces = faces
        let normalFace: CGFont
        let obliqueFace: CGFont
        switch weight {
        case .thin: (normalFace, obliqueFace) = (faces.thin, faces.thinOblique)
        case .extraLight: (normalFace, obliqueFace) = (faces.extraLight, faces.extraLightOblique)
        case .light: (normalFace, obliqueFace) = (faces.light, faces.lightOblique)
        case .regular: (normalFace, obliqueFace) = (faces.regular, faces.oblique)
        case .medium: (normalFace, obliqueFace) = (faces.medium, faces.mediumOblique)
        case .semibold: (normalFace, obliqueFace) = (faces.semibold, faces.semiboldOblique)
        case .bold: (normalFace, obliqueFace) = (faces.bold, faces.boldOblique)
        case .extraBold: (normalFace, obliqueFace) = (faces.extraBold, faces.extraBoldOblique)
        }
        // Keep ANSI bold heavier even at the upper end of the selectable range.
        let strongFace = weight == .extraBold ? faces.heavy : weight == .bold ? faces.extraBold : faces.bold
        let strongOblique = weight == .extraBold ? faces.heavyOblique : weight == .bold ? faces.extraBoldOblique : faces.boldOblique
        regular = CTFontCreateWithGraphicsFont(normalFace, size, nil, nil) as NSFont
        italic = CTFontCreateWithGraphicsFont(obliqueFace, size, nil, nil) as NSFont
        bold = CTFontCreateWithGraphicsFont(strongFace, size, nil, nil) as NSFont
        boldItalic = CTFontCreateWithGraphicsFont(strongOblique, size, nil, nil) as NSFont
        symbols = CTFontCreateWithGraphicsFont(faces.symbols, size, nil, nil) as NSFont
    }

    static func load(size: CGFloat, weight: TerminalFontWeight = .medium,
                     bundle: Bundle = .main) throws -> TerminalFonts {
        try TerminalFonts(size: size, weight: weight, faces: Faces(bundle: bundle))
    }

    func configured(size: CGFloat, weight: TerminalFontWeight) -> TerminalFonts {
        TerminalFonts(size: size, weight: weight, faces: faces)
    }

    func cellSize(backingScale: CGFloat) -> NSSize {
        let font = regular as CTFont
        var character = UniChar(48)
        var glyph = CGGlyph()
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let scale = max(1, backingScale)
        let height = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        return NSSize(width: ceil(advance.width * scale) / scale,
                      height: ceil(height * scale) / scale)
    }
}
