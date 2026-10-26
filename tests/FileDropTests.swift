import AppKit

private final class FileDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingLocation = NSPoint(x: 180, y: 40)
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var draggingFormation: NSDraggingFormation = .default
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    deinit { draggingPasteboard.releaseGlobally() }
}

@main struct FileDropTests {
    static func main() throws {
        _ = NSApplication.shared
        let surface = SurfaceView(fonts: try TerminalFonts.load(size: 16))
        surface.frame = NSRect(x: 0, y: 0, width: 320, height: 100)
        surface.scene = ["panes": [
            ["pane_id": "left", "focused": true, "inner_rect": ["x": 0, "y": 0, "width": 20, "height": 5]],
            ["pane_id": "right", "focused": false, "inner_rect": ["x": 21, "y": 0, "width": 19, "height": 5]]
        ]]
        let drag = FileDrag()
        let scene = surface.scene
        var commands: [[String: Any]] = []
        var focused = ""
        surface.send = { commands.append($0) }
        surface.focusPane = { focused = $0 }
        let paths = ["/tmp/Один файл.txt", "/tmp/it's $(printf INJECTED); [a]*.png", "/tmp/Папка"]
        drag.draggingPasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
        precondition(surface.draggingEntered(drag) == .copy)
        precondition(surface.performDragOperation(drag))
        precondition(focused == "right" && commands.count == 1 && commands[0]["pane_id"] as? String == "right",
                     "Файлы должны попадать в панель под курсором, а не в ранее активную")
        let text = commands[0]["text"] as! String
        let shell = Process(), output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-fc", "set -- " + text + "; printf '%s\\0' \"$@\""]
        shell.standardOutput = output
        try shell.run()
        let actual = output.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let arguments = String(decoding: actual, as: UTF8.self).split(separator: "\0").map(String.init)
        precondition(shell.terminationStatus == 0 && arguments == paths,
                     "Пробелы, кириллица, апострофы и shell-метасимволы должны сохранять исходные аргументы")
        print("PASS: несколько файлов и папка; точные аргументы zsh; панель под курсором")
        commands.removeAll()
        drag.draggingLocation = NSPoint(x: 162, y: 40)
        precondition(surface.draggingUpdated(drag).isEmpty && !surface.performDragOperation(drag))
        drag.draggingLocation = NSPoint(x: 180, y: 40)
        surface.scene = [:]
        precondition(!surface.performDragOperation(drag) && commands.isEmpty, "Исчезнувшая панель не должна получать ввод")
        print("PASS: разделитель и исчезнувшая панель отклонены")
        surface.scene = scene
        drag.draggingPasteboard.clearContents()
        drag.draggingPasteboard.setString("https://example.com/file", forType: .URL)
        precondition(surface.draggingEntered(drag).isEmpty && !surface.performDragOperation(drag))
        print("PASS: веб-ссылка не принимается как локальный файл")
    }
}
