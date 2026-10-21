import AppKit
import CoreText

// Run from the repository root: swift tools/render-readme-header.swift
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("docs/assets")
let width = 1800
let height = 760

guard let art = NSImage(contentsOf: assets.appendingPathComponent("header-art.webp")) else {
    fatalError("Missing README illustration: docs/assets/header-art.webp")
}

func font(_ filename: String, size: CGFloat) -> NSFont {
    let url = root.appendingPathComponent("resources/Fonts/" + filename)
    guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil),
          let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
          let descriptor = descriptors.first,
          let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
          let result = NSFont(name: name, size: size) else {
        fatalError("Cannot load the existing application font: \(filename)")
    }
    return result
}

let titleFont = font("MorpheusAlt1Cyr.otf", size: 124)
let bodyFont = font("FrizQuadrataC.ttf", size: 58)
let cream = NSColor(srgbRed: 0.96, green: 0.87, blue: 0.69, alpha: 1)
let warmWhite = NSColor(srgbRed: 0.88, green: 0.80, blue: 0.65, alpha: 1)

for (language, words) in [
    ("en", "More work?"),
    ("ru", "Опять работа?")
] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
        pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create README image canvas")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSColor(srgbRed: 0.047, green: 0.029, blue: 0.021, alpha: 1).setFill()
    bounds.fill()
    let artWidth = art.size.width * CGFloat(height) / art.size.height
    art.draw(in: NSRect(x: CGFloat(width) - artWidth, y: 0, width: artWidth,
                        height: CGFloat(height)))
    let fade = NSGradient(starting: NSColor(srgbRed: 0.047, green: 0.029, blue: 0.021, alpha: 1),
                          ending: .clear)!
    fade.draw(in: NSRect(x: 390, y: 0, width: 550, height: height), angle: 0)

    func text(_ string: String, font: NSFont, top: CGFloat, color: NSColor, spacing: CGFloat = 0) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = spacing
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        let styled = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .shadow: shadow
        ])
        let size = styled.boundingRect(with: NSSize(width: 1080, height: 400),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        precondition(size.width <= 1080 && size.height < 300, "README heading does not fit")
        styled.draw(in: NSRect(x: 88, y: CGFloat(height) - top - size.height,
                               width: 1080, height: size.height))
    }
    text("Herdr Tavern", font: titleFont, top: 178, color: cream)
    NSColor(srgbRed: 0.49, green: 0.32, blue: 0.15, alpha: 0.75).setFill()
    NSRect(x: 92, y: 405, width: 730, height: 2).fill()
    text(words, font: bodyFont, top: 385, color: warmWhite, spacing: 12)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode README image")
    }
    try png.write(to: assets.appendingPathComponent("header-\(language).png"))
    print("header-\(language).png: \(width)x\(height)")
}
