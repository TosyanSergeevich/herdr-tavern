import AppKit

@main struct SurfaceSelectionTests {
    static let width = 54, paneX = 30, paneWidth = 24, height = 3
    static let text = ["Привет, мир_42!", "猫咪   emoji 👩‍💻", "  Cafe\u{301} done"]
    static var surface: SurfaceView!
    static var window: NSWindow!

    static func apply(mouseReporting: Bool = false, lines: [String] = text, revision: UInt64 = 2,
                      history: Bool = false, maximum: Int = 100, offset: Int = 0) throws {
        var cells = Array(repeating: TerminalCell(symbol: " ", foreground: 0, background: 0, modifier: 0, skip: false), count: width * height)
        func put(_ value: String, row: Int, x: Int) {
            var column = x
            for character in value {
                let wide = character == "猫" || character == "咪" || character == "👩‍💻"
                cells[row * width + column] = TerminalCell(symbol: String(character), foreground: 0, background: 0, modifier: 0, skip: false)
                column += 1
                if wide {
                    cells[row * width + column] = TerminalCell(symbol: "", foreground: 0, background: 0, modifier: 0, skip: true)
                    column += 1
                }
            }
        }
        put("Соседняя панель", row: 0, x: 0)
        for (row,line) in lines.enumerated() { put(line, row: row, x: paneX) }
        var right: [String: Any] = ["pane_id":"right", "focused":true, "mouse_reporting":mouseReporting,
            "content_revision":revision, "inner_rect":["x":paneX,"y":0,"width":paneWidth,"height":height]]
        if history { right["scroll"] = ["offset_from_bottom":offset, "max_offset_from_bottom":maximum, "viewport_rows":height] }
        try surface.apply(metadata: ["boot_id":"clicks", "projection_revision":1, "surface_revision":revision,
            "width":width, "height":height, "panes":[
                ["pane_id":"left", "focused":false, "inner_rect":["x":0,"y":0,"width":28,"height":height]],
                right]],
            segments:[CellSegment(x:0,y:0,cells:cells)], assets:[], patch:false)
    }
    static func event(_ type: NSEvent.EventType, column: Int, row: Int = 0, clicks: Int = 1,
                      flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with:type,
            location:NSPoint(x:CGFloat(column)*8+4,y:surface.bounds.height-CGFloat(row)*20-10),
            modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,
            clickCount:clicks,pressure:1)!
    }
    static func click(column: Int, row: Int = 0, count: Int, flags: NSEvent.ModifierFlags = []) {
        surface.mouseDown(with:event(.leftMouseDown,column:column,row:row,clicks:count,flags:flags))
        surface.mouseUp(with:event(.leftMouseUp,column:column,row:row,clicks:count,flags:flags))
    }
    static func expectCopy(_ expected: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("NO_SELECTION",forType:.string)
        surface.copy(nil)
        precondition(NSPasteboard.general.string(forType:.string) == expected, "Ожидалось: \(expected)")
    }
    static func doubleClickSelectsUnicodeWord() {
        click(column:paneX+4,count:2); expectCopy("Привет")
        click(column:paneX+11,count:2); expectCopy("мир_42")
        click(column:paneX+4,row:2,count:2); expectCopy("Cafe\u{301}")
        print("PASS: двойной клик выбирает слово целиком: кириллица, цифры, подчёркивание и комбинируемый знак")
    }
    static func separatorsDoNotJoinWords() {
        click(column:paneX+6,count:2); expectCopy(",")
        click(column:paneX+5,row:1,count:2); expectCopy("")
        print("PASS: пунктуация и пробелы не захватывают соседние слова; при копировании хвостовые пробелы обрезаются")
    }
    static func wideCharactersUseTerminalColumns() {
        click(column:paneX+1,row:1,count:2); expectCopy("猫咪")
        click(column:paneX+14,row:1,count:2); expectCopy("👩‍💻")
        print("PASS: клик по второй колонке широкого символа выбирает целые иероглифы/emoji")
    }
    static func tripleClickSelectsOnlyPaneRow() {
        click(column:paneX+10,count:3); expectCopy(text[0])
        click(column:paneX+6,row:2,count:3); expectCopy(text[2])
        print("PASS: тройной клик выбирает строку с отступом без соседней панели и следующей строки")
    }
    static func wordDragKeepsWholeWordsInBothDirections() {
        surface.mouseDown(with:event(.leftMouseDown,column:paneX+10,clicks:2))
        surface.mouseDragged(with:event(.leftMouseDragged,column:paneX+3,clicks:2))
        surface.mouseUp(with:event(.leftMouseUp,column:paneX+3,clicks:2))
        expectCopy("Привет, мир_42")
        surface.mouseDown(with:event(.leftMouseDown,column:paneX+2,clicks:2))
        surface.mouseDragged(with:event(.leftMouseDragged,column:paneX+10,clicks:2))
        surface.mouseUp(with:event(.leftMouseUp,column:paneX+10,clicks:2))
        expectCopy("Привет, мир_42")
        print("PASS: протягивание после двойного клика расширяет диапазон целыми словами в обе стороны")
    }
    static func lineDragKeepsWholeRows() {
        surface.mouseDown(with:event(.leftMouseDown,column:paneX+3,clicks:3))
        surface.mouseDragged(with:event(.leftMouseDragged,column:paneX+6,row:2,clicks:3))
        surface.mouseUp(with:event(.leftMouseUp,column:paneX+6,row:2,clicks:3))
        expectCopy(text.joined(separator:"\n"))
        print("PASS: протягивание после тройного клика выбирает полные строки")
    }
    static func singleClickStillClearsSelection() {
        click(column:paneX+3,count:3)
        click(column:paneX+4,count:1); expectCopy("NO_SELECTION")
        print("PASS: одиночный клик снимает многократное выделение, не создавая второй курсор")
    }
    static func mouseReportingRequiresShift() throws {
        try apply(mouseReporting:true)
        click(column:paneX+3,count:2); expectCopy("NO_SELECTION")
        click(column:paneX+3,count:3); expectCopy("NO_SELECTION")
        click(column:paneX+3,count:2,flags:.shift); expectCopy("Привет")
        click(column:paneX+3,count:3,flags:.shift); expectCopy(text[0])
        print("PASS: терминальная мышь имеет приоритет; Shift включает двойное/тройное локальное выделение")
    }
    static func completedSelectionSurvivesProgressAndCopyRace() throws {
        surface.clear()
        try apply(history:true)
        click(column:paneX+3,count:2)
        try apply(lines:[text[0], text[1], "progress 1"], revision:4, history:true)
        var completion: ((Result<String, Error>) -> Void)?
        surface.readSelection = { params, done in
            precondition((params["content_revision"] as? UInt64) == 4)
            completion = done
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("NO_SELECTION",forType:.string)
        surface.copy(nil)
        precondition(completion != nil, "Прогресс не должен снимать завершённое выделение")
        try apply(lines:[text[0], text[1], "progress 2"], revision:6, history:true)
        completion?(.failure(TerminalSelectionReadError.staleContent))
        precondition(NSPasteboard.general.string(forType:.string) == "Привет", "Гонка ревизий копирует показанный текст")
        print("PASS: готовое выделение и копирование переживают новые кадры прогресса")
    }
    static func activeDragSurvivesProgress() throws {
        surface.clear()
        try apply(history:true)
        surface.mouseDown(with:event(.leftMouseDown,column:paneX))
        try apply(lines:[text[0], text[1], "progress 1"], revision:4, history:true)
        surface.mouseDragged(with:event(.leftMouseDragged,column:paneX+5))
        try apply(lines:[text[0], text[1], "progress 2"], revision:6, history:true)
        surface.mouseUp(with:event(.leftMouseUp,column:paneX+5))
        surface.readSelection = { _, done in done(.failure(TerminalSelectionReadError.staleContent)) }
        expectCopy("Привет")
        print("PASS: кадры между mouseDown, drag и mouseUp не уничтожают активное выделение")
    }
    static func selectedRewriteCancelsPendingCopy() throws {
        surface.clear()
        try apply(history:true)
        click(column:paneX+3,count:2)
        var completion: ((Result<String, Error>) -> Void)?
        surface.readSelection = { _, done in completion = done }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("NO_SELECTION",forType:.string)
        surface.copy(nil)
        try apply(lines:["Другой текст", text[1], text[2]], revision:4, history:true)
        completion?(.success("НЕВЕРНЫЙ ТЕКСТ"))
        precondition(NSPasteboard.general.string(forType:.string) == "NO_SELECTION")
        expectCopy("NO_SELECTION")
        print("PASS: перезапись выбранных ячеек отменяет выделение и отложенный ответ копирования")
    }
    static func unrelatedAPIFailureIsVisible() throws {
        surface.clear()
        try apply(history:true)
        click(column:paneX+3,count:2)
        var error: String?
        surface.selectionError = { error = $0 }
        surface.readSelection = { _, done in done(.failure(NativeError.message("Недоступен сервер"))) }
        expectCopy("NO_SELECTION")
        precondition(error == "Недоступен сервер")
        surface.selectionError = nil
        print("PASS: ошибка транспорта не маскируется локальным снимком")
    }
    static func historyLimitShiftCancelsSelection() throws {
        surface.clear()
        try apply(history:true)
        click(column:paneX+3,count:2)
        try apply(lines:[text[1], text[2], "новая строка"], revision:4, history:true)
        expectCopy("NO_SELECTION")
        print("PASS: сдвиг истории при неизменном maximum не переносит выделение на следующую строку")
    }
    static func liveRowScrollingIntoHistoryCopiesOriginalSnapshot() throws {
        surface.clear()
        try apply(history:true)
        click(column:paneX+3,count:3)
        var remoteCalled = false
        surface.readSelection = { _, done in
            remoteCalled = true
            done(.success("ДРУГОЙ ТЕКСТ ПО СТАРЫМ КООРДИНАТАМ"))
        }
        try apply(lines:[text[1], text[2], "новая строка"], revision:4, history:true, maximum:101)
        expectCopy(text[0])
        precondition(!remoteCalled, "Непроверенные координаты не передаются серверному чтению")
        try apply(lines:text, revision:4, history:true, maximum:101, offset:1)
        surface.readSelection = { _, done in remoteCalled = true; done(.success(text[0])) }
        expectCopy(text[0])
        precondition(remoteCalled, "Возвращённый и проверенный текст разрешает серверное чтение")
        print("PASS: уход live-строки в историю копирует прежний снимок, а не потенциально другой серверный диапазон")
    }
    static func main() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type -> (NSPasteboard.PasteboardType,Data)? in item.data(forType:type).map { (type,$0) } } }
        defer {
            board.clearContents()
            let items = saved.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem(); for (type,data) in values { item.setData(data,forType:type) }; return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        let font = NSFont.monospacedSystemFont(ofSize:16,weight:.regular)
        surface = SurfaceView(fonts: TerminalFonts(regular: font, bold: font, italic: font,
                                                 boldItalic: font, symbols: font))
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:width*8,height:height*20),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = surface
        try apply()
        doubleClickSelectsUnicodeWord()
        separatorsDoNotJoinWords()
        wideCharactersUseTerminalColumns()
        tripleClickSelectsOnlyPaneRow()
        wordDragKeepsWholeWordsInBothDirections()
        lineDragKeepsWholeRows()
        singleClickStillClearsSelection()
        try mouseReportingRequiresShift()
        try completedSelectionSurvivesProgressAndCopyRace()
        try activeDragSurvivesProgress()
        try selectedRewriteCancelsPendingCopy()
        try unrelatedAPIFailureIsVisible()
        try historyLimitShiftCancelsSelection()
        try liveRowScrollingIntoHistoryCopiesOriginalSnapshot()
    }
}
