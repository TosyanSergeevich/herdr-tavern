import AppKit
import CoreText

@main struct TerminalFontsTests {
    private static func validateFaces(in bundle: Bundle) throws {
        let fonts = try TerminalFonts.load(size: 16, bundle: bundle)
        let faces: [(NSFont, String)] = [
            (fonts.regular, "Iosevka-Custom-Medium"),
            (fonts.bold, "Iosevka-Custom-Bold"),
            (fonts.italic, "Iosevka-Custom-Medium-Oblique"),
            (fonts.boldItalic, "Iosevka-Custom-Bold-Oblique"),
        ]
        for (font, expected) in faces {
            precondition(font.fontName == expected, "Expected bundled \(expected), got \(font.fontName)")
        }
        var expectedAdvance: CGFloat?
        let characters = Array("0MWЖ".utf16)
        for font in [fonts.regular, fonts.bold, fonts.italic, fonts.boldItalic] {
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            precondition(CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count),
                         "All terminal faces must cover Latin and Cyrillic text")
            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, glyphs.count)
            if expectedAdvance == nil { expectedAdvance = advances[0].width }
            for advance in advances {
                precondition(abs(advance.width - expectedAdvance!) < 0.001,
                             "Changing text style must preserve the terminal's monospace grid")
            }
        }
        print("PASS: bundled faces preserve the selected typeface and monospace Latin/Cyrillic metrics")
    }

    private static func validateConfigurations(_ fonts: TerminalFonts) {
        let names: [(TerminalFontWeight, String, String, String)] = [
            (.thin, "Iosevka-Custom-Thin", "Iosevka-Custom-Thin-Oblique", "Iosevka-Custom-Bold"),
            (.extraLight, "Iosevka-Custom-Extralight", "Iosevka-Custom-Extralight-Oblique", "Iosevka-Custom-Bold"),
            (.light, "Iosevka-Custom-Light", "Iosevka-Custom-Light-Oblique", "Iosevka-Custom-Bold"),
            (.regular, "Iosevka-Custom", "Iosevka-Custom-Oblique", "Iosevka-Custom-Bold"),
            (.medium, "Iosevka-Custom-Medium", "Iosevka-Custom-Medium-Oblique", "Iosevka-Custom-Bold"),
            (.semibold, "Iosevka-Custom-Semibold", "Iosevka-Custom-Semibold-Oblique", "Iosevka-Custom-Bold"),
            (.bold, "Iosevka-Custom-Bold", "Iosevka-Custom-Bold-Oblique", "Iosevka-Custom-Extrabold"),
            (.extraBold, "Iosevka-Custom-Extrabold", "Iosevka-Custom-Extrabold-Oblique", "Iosevka-Custom-Heavy"),
        ]
        let characters = Array("0MWЖ".utf16)
        for size in [12, 13, 16, 24] {
            for (weight, normalName, obliqueName, strongName) in names {
                let selected = fonts.configured(size: CGFloat(size), weight: weight)
                precondition(selected.regular.fontName == normalName, "\(weight) at \(size) pt")
                precondition(selected.italic.fontName == obliqueName, "\(weight) must use true Oblique")
                precondition(selected.bold.fontName == strongName)
                precondition(selected.boldItalic.fontName == strongName + "-Oblique")
                let normalWeight = (CTFontCopyTraits(selected.regular as CTFont) as NSDictionary)[kCTFontWeightTrait] as! NSNumber
                let strongWeight = (CTFontCopyTraits(selected.bold as CTFont) as NSDictionary)[kCTFontWeightTrait] as! NSNumber
                precondition(strongWeight.doubleValue > normalWeight.doubleValue,
                             "ANSI bold must be heavier at every selectable base weight")
                precondition(selected.regular.fontName != selected.bold.fontName,
                             "ANSI bold must remain distinct from \(weight)")
                precondition(selected.symbols.pointSize == CGFloat(size))
                for font in [selected.regular, selected.bold, selected.italic, selected.boldItalic] {
                    precondition(font.pointSize == CGFloat(size))
                    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                    precondition(CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count))
                    var advances = [CGSize](repeating: .zero, count: glyphs.count)
                    CTFontGetAdvancesForGlyphs(font as CTFont, .horizontal, glyphs, &advances, glyphs.count)
                    for advance in advances {
                        precondition(abs(advance.width - CGFloat(size) / 2) < 0.001,
                                     "\(font.fontName) at \(size) must preserve Latin/Cyrillic monospace metrics")
                    }
                }
                for scale in [CGFloat(1), CGFloat(2)] {
                    let cell = selected.cellSize(backingScale: scale)
                    precondition(cell.width == ceil(CGFloat(size) / 2 * scale) / scale)
                    precondition(cell.height * scale == ceil(cell.height * scale))
                    if size == 16 {
                        precondition(cell == NSSize(width: 8, height: 20),
                                     "Default metrics must remain 8×20 points at both backing scales")
                    }
                }
            }
        }
        print("PASS: all weights/sizes preserve real Oblique, distinct ANSI bold and pixel-aligned monospace metrics")
    }

    private static func configurationsWithoutResources(in source: Bundle) throws {
        let (root, bundle) = try fixture(from: source)
        defer { try? FileManager.default.removeItem(at: root) }
        let fonts = try TerminalFonts.load(size: 16, bundle: bundle)
        try FileManager.default.removeItem(at: bundle.resourceURL!.appendingPathComponent("Fonts"))
        validateConfigurations(fonts)
        validateConfigurations(fonts.configured(size: 24, weight: .semibold))
        print("PASS: repeated size/weight changes retain all original faces after resource removal")
    }

    private static func missingSemibold(in source: Bundle) throws {
        let (root, bundle) = try fixture(from: source)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: bundle.resourceURL!
            .appendingPathComponent("Fonts/IosevkaCustom-SemiBold.ttf"))
        expectResourceError(in: bundle)
        print("PASS: loading validates optional-weight resources before the first settings change")
    }

    private static func fixture(from source: Bundle) throws -> (URL, Bundle) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalFonts-" + UUID().uuidString + ".app")
        let resources = root.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.bundleURL.appendingPathComponent("Contents/Info.plist"),
                                         to: root.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(at: source.resourceURL!.appendingPathComponent("Fonts"),
                                         to: resources.appendingPathComponent("Fonts"))
        return (root, Bundle(url: root)!)
    }

    private static func expectResourceError(in bundle: Bundle) {
        do {
            _ = try TerminalFonts.load(size: 16, bundle: bundle)
            preconditionFailure("Missing or damaged bundled faces must not use an installed substitute")
        } catch {
            precondition((error as NSError).domain == "HerdrTavern.Fonts",
                         "Invalid font resources must report a font-loading error")
        }
    }

    private static func missingBold(in source: Bundle) throws {
        let (root, bundle) = try fixture(from: source)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: bundle.resourceURL!
            .appendingPathComponent("Fonts/IosevkaCustom-Bold.ttf"))
        expectResourceError(in: bundle)
        print("PASS: a missing bold face fails instead of using a locally installed font")
    }

    private static func damagedRegular(in source: Bundle) throws {
        let (root, bundle) = try fixture(from: source)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a font".utf8).write(to: bundle.resourceURL!
            .appendingPathComponent("Fonts/IosevkaCustom-Medium.ttf"))
        expectResourceError(in: bundle)
        print("PASS: a damaged normal face fails instead of using a locally installed font")
    }

    static func main() throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
            preconditionFailure("Pass the built .app bundle as the first argument")
        }
        try validateFaces(in: bundle)
        try configurationsWithoutResources(in: bundle)
        try missingSemibold(in: bundle)
        try missingBold(in: bundle)
        try damagedRegular(in: bundle)
        print("Passed 5 bundled-font scenarios")
    }
}
