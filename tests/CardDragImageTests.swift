import AppKit

// Запускается из .app с ресурсами Tavern: проверяет в том числе карточки,
// которые ещё не были показаны (соседи за пределами прокручиваемого списка).
@main struct CardDragImageTests {
    static func main() throws {
        _ = NSApplication.shared
        try TavernAppearance.validateFonts()
        try TavernCardSurfaceView.validateResources()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        for (size, selected, style) in [
            (NSSize(width: 380, height: 84), true, TavernButton.Style.agent),
            (NSSize(width: 240, height: 70), false, TavernButton.Style.agent),
            (NSSize(width: 380, height: 46), true, TavernButton.Style.workspace)
        ] {
            let card = TavernButton(frame: NSRect(origin: .zero, size: size))
            card.title = "Карточка"
            card.prepare(style: style, selected: selected, identity: "snapshot-regression")
            window.contentView!.addSubview(card)
            let image = card.dragImage()!
            let bitmap = image.representations[0] as! NSBitmapImageRep
            for x in [0.2, 0.4, 0.6, 0.8] {
                let pixel = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
                                          y: Int(Double(bitmap.pixelsHigh) * 0.85))!
                precondition(pixel.alphaComponent > 0.99, "Древесина пропала из образа перетаскивания")
            }
            // Двойное применение backing scale обрезает правую/нижнюю рамку.
            for (x, y) in [(0, bitmap.pixelsHigh / 2), (bitmap.pixelsWide - 1, bitmap.pixelsHigh / 2),
                           (bitmap.pixelsWide / 2, 0), (bitmap.pixelsWide / 2, bitmap.pixelsHigh - 1)] {
                precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01,
                             "Материал вышел за границы карточки при масштабировании")
            }
            card.removeFromSuperview()
            print("PASS: материал и границы \(size), selected=\(selected)")
        }
    }
}
