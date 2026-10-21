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
        try missingBold(in: bundle)
        try damagedRegular(in: bundle)
        print("Passed 3 bundled-font scenarios")
    }
}
