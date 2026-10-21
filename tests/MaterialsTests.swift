import AppKit

@main struct MaterialsTests {
    static func sample(_ image: NSImage, x: CGFloat, top: CGFloat,
                       width: Int, height: Int) -> [UInt8] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: width * 4, bitsPerPixel: 32)!
        bitmap.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        graphics.cgContext.translateBy(x: -x, y: -(image.size.height - top - CGFloat(height)))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: width * height * 4))
    }

    static func unchanged(_ first: NSImage, _ second: NSImage, x: CGFloat, top: CGFloat,
                          width: Int, height: Int, message: String, tolerance: Int = 0) {
        let left = sample(first, x: x, top: top, width: width, height: height)
        let right = sample(second, x: x, top: top, width: width, height: height)
        let maxError = zip(left, right).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        precondition(maxError <= tolerance, "\(message): максимальная ошибка канала \(maxError)")
    }

    static func main() throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Передайте путь к собранной Herdr Tavern.app")
        }
        let materials = try TavernMaterials(bundle: bundle)
        let tab = materials.tabImage(size: NSSize(width: 150, height: 38))
        let wideTab = materials.tabImage(size: NSSize(width: 300, height: 38))
        unchanged(tab, wideTab, x: 30, top: 13, width: 90, height: 12,
                  message: "Древесина вкладки не должна менять масштаб с шириной")
        print("PASS: масштаб древесины верхней вкладки")

        for (style, edge, name) in [(TavernMaterials.FrameStyle.viewport, CGFloat(14.7), "терминал"),
                                    (.root, 8.4, "окно")] {
            let frame = materials.frameImage(size: NSSize(width: 680, height: 400), edge: edge, style: style)
            let wide = materials.frameImage(size: NSSize(width: 1600, height: 400), edge: edge, style: style)
            let tall = materials.frameImage(size: NSSize(width: 680, height: 1100), edge: edge, style: style)
            // CoreGraphics при повторной растеризации в backing bitmap другого
            // размера может округлить 8-битный канал на 1; геометрия остаётся той же.
            unchanged(frame, wide, x: 80, top: 2, width: 180, height: 6,
                      message: "Горизонтальная рейка \(name) растягивается", tolerance: 1)
            unchanged(frame, tall, x: 2, top: 100, width: 6, height: 140,
                      message: "Вертикальная рейка \(name) растягивается", tolerance: 1)
            unchanged(frame, tall, x: 0, top: 0, width: 30, height: 30,
                      message: "Угловая накладка \(name) меняет масштаб", tolerance: 1)
            let opening = sample(tall, x: 100, top: 100, width: 100, height: 100)
            precondition(stride(from: 3, to: opening.count, by: 4).allSatisfy { opening[$0] == 0 },
                         "Рамка \(name) не должна закрашивать терминальный проём")
            print("PASS: рейки, угол и прозрачный проём — \(name)")
        }

        let recess = materials.tabRecessImage(size: NSSize(width: 400, height: 61))
        let wideRecess = materials.tabRecessImage(size: NSSize(width: 1400, height: 61))
        unchanged(recess, wideRecess, x: 50, top: 1, width: 180, height: 6,
                  message: "Кромка паза вкладок растягивается", tolerance: 1)
        print("PASS: масштаб кромки паза вкладок")
        print("Пройдено 4 сценария масштабирования вкладок и рамок")
    }
}
