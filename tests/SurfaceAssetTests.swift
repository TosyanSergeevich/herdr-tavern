import AppKit
import CoreGraphics

@main struct SurfaceAssetTests {
    static let columns = 12, rows = 3

    static func cell(_ symbol: String) -> TerminalCell {
        TerminalCell(symbol: symbol, foreground: 0x02ffffff, background: 0x02112233,
                     modifier: 0, skip: false)
    }

    static func image(_ rgba: [UInt8]) throws -> CGImage {
        try GraphicAssetDecoder.decode(GraphicAsset(id: "fixture", width: 1, height: 1,
                                                   format: 1, data: Data(rgba)))
    }

    static func placement(_ id: String) -> [String: Any] {
        ["id": id, "x": 5, "y": 1, "cols": 3, "rows": 2, "z": 1]
    }

    private final class Fixture {
        let surface: SurfaceView
        let window: NSWindow
        let red: CGImage
        let blue: CGImage
        let values = Array("Alpha beta  Second row  Last row    ").map { SurfaceAssetTests.cell(String($0)) }
        var revision = 1

        init(fonts: TerminalFonts) throws {
            red = try SurfaceAssetTests.image([255, 17, 23, 192])
            blue = try SurfaceAssetTests.image([9, 33, 255, 128])
            surface = SurfaceView(fonts: fonts)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: columns * 8, height: rows * 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface
            surface.setFrameSize(NSSize(width: columns * 8, height: rows * 20))
            precondition(values.count == columns * rows)
            try surface.apply(metadata: metadata(placements: [placement("red")]),
                              segments: [CellSegment(x: 0, y: 0, cells: values)],
                              images: ["red": red], patch: false)
            selectFirstWord()
        }

        func metadata(placements: [[String: Any]] = [], retained: [String]? = nil,
                      reset: Bool = false, width: Int = columns, height: Int = rows) -> [String: Any] {
            var result: [String: Any] = [
                "boot_id": "surface-assets", "projection_revision": 1,
                "surface_revision": revision, "width": width, "height": height,
                "placements": placements, "image_cache_reset": reset,
                "cursor": ["visible": false, "x": 2, "y": 0, "shape": 0],
                "panes": [["pane_id": "fixture", "focused": true, "mouse_reporting": false,
                           "content_revision": revision,
                           "inner_rect": ["x": 0, "y": 0, "width": width, "height": height]]]
            ]
            if let retained { result["retained_assets"] = retained }
            return result
        }

        func selectFirstWord() {
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: 12, y: surface.bounds.height - 10),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 2, pressure: 1)!
            }
            surface.mouseDown(with: event(.leftMouseDown))
            surface.mouseUp(with: event(.leftMouseUp))
        }

        func selectedText() -> String? {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString("NO_SELECTION", forType: .string)
            surface.copy(nil)
            return board.string(forType: .string)
        }

        func bitmap() -> Data {
            let w = Int(surface.bounds.width), h = Int(surface.bounds.height)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
            bitmap.size = surface.bounds.size
            bitmap.bitmapData!.initialize(repeating: 0, count: bitmap.bytesPerRow * h)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            let context = NSGraphicsContext.current!.cgContext
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: 1, y: -1)
            surface.draw(surface.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * h)
        }

        func failsWithoutMutation(_ name: String, metadata: [String: Any], segments: [CellSegment],
                                  images: [String: CGImage] = [:], patch: Bool = false) {
            let pixels = bitmap()
            let accessibility = surface.accessibilityValue() as? String
            let scene = NSDictionary(dictionary: surface.scene)
            let geometry = [surface.width, surface.height, surface.cols, surface.rows]
            let selected = selectedText()
            precondition(selected == "Alpha", "Rollback fixture must start with a real selection")
            do {
                try surface.apply(metadata: metadata, segments: segments, images: images, patch: patch)
                preconditionFailure(name + ": invalid apply accepted")
            } catch {
                precondition(bitmap() == pixels, name + ": rendered state changed")
                precondition((surface.accessibilityValue() as? String) == accessibility, name + ": accessible cells changed")
                precondition(NSDictionary(dictionary: surface.scene).isEqual(scene), name + ": scene changed")
                precondition([surface.width, surface.height, surface.cols, surface.rows] == geometry, name + ": geometry changed")
                precondition(selectedText() == selected, name + ": selection changed")
            }
        }

        func full(_ ids: [String], images: [String: CGImage] = [:], retained: [String]? = nil,
                  reset: Bool = false) throws {
            revision += 1
            try surface.apply(metadata: metadata(placements: ids.map(SurfaceAssetTests.placement), retained: retained, reset: reset),
                              segments: [CellSegment(x: 0, y: 0, cells: values)], images: images, patch: false)
        }
    }

    private static func rollback(fonts: TerminalFonts) throws {
        let f = try Fixture(fonts: fonts)
        let changed = Array(repeating: cell("X"), count: 8 * 2)
        f.failsWithoutMutation("missing full asset after geometry change",
            metadata: f.metadata(placements: [placement("absent")], width: 8, height: 2),
            segments: [CellSegment(x: 0, y: 0, cells: changed)], images: ["unused": f.blue])
        f.failsWithoutMutation("reset removes required old asset",
            metadata: f.metadata(placements: [placement("red")], reset: true, width: 8, height: 2),
            segments: [CellSegment(x: 0, y: 0, cells: changed)], images: ["unused": f.blue])
        f.failsWithoutMutation("invalid full cell count",
            metadata: f.metadata(width: 8, height: 2),
            segments: [CellSegment(x: 0, y: 0, cells: Array(changed.dropLast()))], images: ["red": f.blue])
        f.failsWithoutMutation("invalid full grid dimensions", metadata: f.metadata(width: 0),
            segments: [CellSegment(x: 0, y: 0, cells: [])], images: ["red": f.blue])
        var patch = f.metadata()
        patch["base_surface_revision"] = f.revision
        patch["surface_revision"] = f.revision + 1
        f.failsWithoutMutation("later patch segment must roll back earlier valid segment",
            metadata: patch,
            segments: [CellSegment(x: 0, y: 0, cells: [cell("X")]),
                       CellSegment(x: columns - 1, y: 1, cells: [cell("Y"), cell("Z")])],
            images: ["red": f.blue], patch: true)
        patch["base_surface_revision"] = 999
        f.failsWithoutMutation("mismatched patch baseline", metadata: patch,
            segments: [CellSegment(x: 0, y: 0, cells: [cell("X")])], images: ["red": f.blue], patch: true)
        // Reusing the old image without resending proves failed cache changes also rolled back.
        let before = f.bitmap()
        try f.full(["red"])
        precondition(f.bitmap() == before, "Failed applies replaced or removed the cached image")
        print("PASS: failed full/reset/grid/later-segment/baseline preserves raster, cells, scene, geometry, cache and selection")
    }

    private static func cacheLifecycle(fonts: TerminalFonts) throws {
        let f = try Fixture(fonts: fonts)
        let red = f.bitmap()
        // Replace an already placed image through patch without touching cells/placements.
        var patch = f.metadata()
        patch["base_surface_revision"] = f.revision
        f.revision += 1
        patch["surface_revision"] = f.revision
        try f.surface.apply(metadata: patch, segments: [], images: ["red": f.blue, "blue": f.blue], patch: true)
        let blue = f.bitmap()
        precondition(blue != red, "Patch image replacement must update the rendered placement")
        try f.full(["red"])
        precondition(f.bitmap() == blue, "Full frame without new images must reuse the merged cache")
        try f.full([], retained: ["red"])
        try f.full(["red"], retained: [])
        precondition(f.bitmap() == blue, "Placed IDs survive even when omitted from retained_assets")
        // blue was not retained or placed by the preceding full frames.
        f.selectFirstWord()
        f.failsWithoutMutation("unretained asset is evicted", metadata: f.metadata(placements: [placement("blue")]),
            segments: [CellSegment(x: 0, y: 0, cells: f.values)])
        try f.full(["red"], images: ["red": f.red], retained: [], reset: true)
        precondition(f.bitmap() == red, "Reset plus replacement must commit the new raster")
        try f.full([], retained: [], reset: true)
        f.selectFirstWord()
        f.failsWithoutMutation("successful reset removes old cached ID",
            metadata: f.metadata(placements: [placement("red")]),
            segments: [CellSegment(x: 0, y: 0, cells: f.values)])
        print("PASS: patch replacement, full merge, retained assets, placed-ID retention, eviction and reset")
    }

    static func main() throws {
        _ = NSApplication.shared
        precondition(CommandLine.arguments.count > 1, "Pass the built .app bundle as the first argument")
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else { preconditionFailure("Invalid .app bundle") }
        let fonts = try TerminalFonts.load(size: 16, bundle: bundle)
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                item.data(forType: type).map { (type, $0) }
            }
        }
        defer {
            board.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        try rollback(fonts: fonts)
        try cacheLifecycle(fonts: fonts)
    }
}
