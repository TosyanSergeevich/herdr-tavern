import AppKit

// Запускается из .app с ресурсами Tavern: проверяет в том числе карточки,
// которые ещё не были показаны (соседи за пределами прокручиваемого списка).
@main struct CardDragImageTests {
    static func image(of card: TavernButton) throws -> NSImage {
        var captured: Result<NSImage, Error>?
        card.requestDragImage { result in
            precondition(Thread.isMainThread)
            captured = result
        }
        let deadline = Date(timeIntervalSinceNow: 10)
        while captured == nil, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard let captured else { preconditionFailure("Async drag image timed out") }
        return try captured.get()
    }

    #if TAVERN_RENDER_TESTING
    private final class Gate {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var started = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return started }
        func block() {
            precondition(!Thread.isMainThread)
            lock.lock(); started = true; lock.unlock()
            precondition(semaphore.wait(timeout: .now() + 8) == .success)
        }
        func release() { semaphore.signal() }
    }

    static func pixels(_ image: NSImage) -> Data {
        let bitmap = image.representations[0] as! NSBitmapImageRep
        var result = Data()
        for row in 0..<bitmap.pixelsHigh {
            result.append(bitmap.bitmapData! + row * bitmap.bytesPerRow, count: bitmap.pixelsWide * 4)
        }
        return result
    }
    #endif

    static func main() throws {
        _ = NSApplication.shared
        try TavernAppearance.validateFonts()
        var prepared: Result<Void, Error>?
        TavernCardSurfaceView.prepareResources { prepared = $0 }
        let preparationDeadline = Date(timeIntervalSinceNow: 10)
        while prepared == nil, Date() < preparationDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
        guard let prepared else { preconditionFailure("Renderer preparation timed out") }
        try prepared.get()
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
            let image = try image(of: card)
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
        #if TAVERN_RENDER_TESTING
        let card = TavernButton(frame: NSRect(x: 0, y: 0, width: 380, height: 84))
        card.title = "Captured title"
        card.prepare(style: .agent, selected: true, subtitle: "Captured subtitle",
                     context: "/tmp/captured", identity: "frozen-drag")
        window.contentView!.addSubview(card)
        let baseline = try image(of: card)
        let surface = card.subviews.compactMap { $0 as? TavernCardSurfaceView }.first!
        let gate = Gate()
        surface.snapshotCompletionGate = { gate.block() }
        var captured: Result<NSImage, Error>?
        card.requestDragImage { captured = $0 }
        card.title = "New title after capture"
        card.prepare(style: .agent, selected: false, subtitle: "New subtitle",
                     context: "/tmp/new", identity: "new-drag")
        card.setFrameSize(NSSize(width: 240, height: 70))
        card.layoutSubtreeIfNeeded()
        let gateDeadline = Date(timeIntervalSinceNow: 5)
        while !gate.entered, Date() < gateDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        precondition(gate.entered && captured == nil)
        gate.release()
        let completionDeadline = Date(timeIntervalSinceNow: 5)
        while captured == nil, Date() < completionDeadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }
        guard let captured else { preconditionFailure("Frozen drag image timed out") }
        let frozen = try captured.get()
        precondition(frozen.size == baseline.size && pixels(frozen) == pixels(baseline),
                     "Async composition mixed captured material/text/geometry with later state")
        surface.snapshotCompletionGate = nil
        let replacement = try image(of: card)
        precondition(replacement.size == NSSize(width: 240, height: 70))
        card.removeFromSuperview()
        print("PASS: async drag bitmap freezes AppKit text, geometry and GPU material together")
        #endif
    }
}
