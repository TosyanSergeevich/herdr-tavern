import Foundation

@main struct TerminalSelectionTests {
    static func viewport(offset: Int = 0, maximum: Int = 100, revision: UInt64 = 2,
                         columns: Int = 20, rows: Int = 5, x: Int = 21, y: Int = 3,
                         alternate: Bool = false, pane: String = "right") -> TerminalSelectionViewport {
        TerminalSelectionViewport(paneID: pane, x: x, y: y, columns: columns, rows: rows,
            offset: offset, maximum: maximum, contentRevision: revision, alternateScreen: alternate, hasHistory: true)
    }
    static func stableCell(_ row: Int, _ column: Int) -> TerminalSelectionCell {
        TerminalSelectionCell(symbol:"a", continuation:false)
    }
    static func selected() -> TerminalSelection {
        var value = TerminalSelection(boot: "one", viewport: viewport(), anchor: TerminalTextPoint(row: 101, col: 2))
        value.drag(to: TerminalTextPoint(row: 102, col: 7))
        value.captureVisibleRows(cell:stableCell)
        return value
    }
    static func scrollMovesWithText() {
        var value = selected()
        precondition(value.visibleColumns(row: 4) == 23...40)
        precondition(value.visibleColumns(row: 5) == 21...28)
        precondition(value.reconcile(boot: "one", viewport: viewport(offset: 1), cell:stableCell))
        precondition(value.visibleColumns(row: 5) == 23...40 && value.visibleColumns(row: 4) == nil)
        precondition(value.reconcile(boot: "one", viewport: viewport(offset: 10), cell:stableCell))
        precondition((3..<8).allSatisfy { value.visibleColumns(row: $0) == nil }, "Невидимый текст не оставляет подсветку")
        precondition(value.ordered?.0 == TerminalTextPoint(row: 101, col: 2))
        precondition(value.reconcile(boot: "one", viewport: viewport(), cell:stableCell))
        precondition(value.visibleColumns(row: 4) == 23...40, "Обратная прокрутка возвращает выделение")
        print("PASS: подсветка следует за текстом, исчезает за экраном и возвращается")
    }
    static func appendedOutputKeepsRange() {
        var value = TerminalSelection(boot:"one", viewport:viewport(offset:10), anchor:TerminalTextPoint(row:91,col:2))
        value.drag(to:TerminalTextPoint(row:92,col:7))
        value.captureVisibleRows(cell:stableCell)
        precondition(value.reconcile(boot: "one", viewport: viewport(maximum: 103, revision: 4), cell:stableCell))
        precondition((3..<8).allSatisfy { value.visibleColumns(row: $0) == nil })
        precondition(value.ordered?.0 == TerminalTextPoint(row: 91, col: 2))
        precondition(value.ordered?.1 == TerminalTextPoint(row: 92, col: 7))
        precondition(value.reconcile(boot: "one", viewport: viewport(offset: 13, maximum: 103, revision: 4), cell:stableCell))
        precondition(value.visibleColumns(row: 4) == 23...40)
        print("PASS: новый вывод с ростом истории сохраняет исходный диапазон")
    }
    static func dragAcrossPagesStaysInPane() {
        let start = viewport()
        var value = TerminalSelection(boot: "one", viewport: start, anchor: start.point(x: 23, y: 4))
        value.captureVisibleRows(cell:stableCell)
        precondition(value.head == nil, "Одиночный клик не создаёт выделение")
        precondition(value.reconcile(boot: "one", viewport: viewport(offset: 10), cell:stableCell))
        value.drag(to: value.viewport.point(x: 0, y: 4))
        precondition(value.ordered?.0 == TerminalTextPoint(row: 91, col: 0))
        precondition(value.ordered?.1 == TerminalTextPoint(row: 101, col: 2))
        precondition(value.visibleColumns(row: 4) == 21...40)
        precondition(value.visibleColumns(row: 7) == 21...40)
        precondition(value.visibleColumns(row: 2) == nil)
        print("PASS: протягивание через несколько экранов и границы соседней панели")
    }
    static func keyboardUsesPaneWidth() {
        var value = selected()
        value.extend(rows: 1)
        precondition(value.head == TerminalTextPoint(row: 103, col: 7))
        value.extend(columns: -9)
        precondition(value.head == TerminalTextPoint(row: 102, col: 18))
        value.extend(rows: 1000)
        precondition(value.head == TerminalTextPoint(row: 104, col: 19))
        value.extend(rows: -1000)
        precondition(value.head == TerminalTextPoint(row: 0, col: 0))
        print("PASS: Shift+стрелки используют ширину панели и границы истории")
    }
    static func layoutMovementKeepsPaneCoordinates() {
        var value = selected()
        precondition(value.reconcile(boot: "one", viewport: viewport(x: 0, y: 0), cell:stableCell))
        precondition(value.visibleColumns(row: 1) == 2...19)
        precondition(value.visibleColumns(row: 2) == 0...7)
        print("PASS: перемещение панели не переносит выделение на соседний текст")
    }
    static func resizedPaneInvalidatesCoordinates() {
        var value = selected()
        precondition(!value.reconcile(boot: "one", viewport: viewport(columns: 10), cell:stableCell))
        print("PASS: изменение ширины не оставляет устаревшие координаты после переноса строк")
    }
    static func alternateScreenInvalidatesCoordinates() {
        var value = selected()
        precondition(!value.reconcile(boot: "one", viewport: viewport(alternate: true), cell:stableCell))
        print("PASS: переключение терминального буфера снимает прежнее выделение")
    }
    static func evictionInvalidatesCoordinates() {
        var value = selected()
        precondition(!value.reconcile(boot: "one", viewport: viewport(maximum: 90, revision: 4), cell:stableCell))
        print("PASS: сокращение истории не переносит диапазон на другой текст")
    }
    static func ambiguousOutputInvalidatesCoordinates() {
        var value = selected()
        precondition(!value.reconcile(boot: "one", viewport: viewport(revision: 4), cell: { _, _ in
            TerminalSelectionCell(symbol:"b", continuation:false)
        }))
        print("PASS: перезапись или вытеснение без роста истории не подменяет выделенный текст")
    }
    static func restartedServerInvalidatesCoordinates() {
        var value = selected()
        precondition(!value.reconcile(boot: "two", viewport: viewport(), cell:stableCell))
        print("PASS: новый сервер не наследует диапазон прежнего")
    }
    static func wordSelectionSurvivesScrollingAndReverseDrag() {
        var value = TerminalSelection(boot: "one", viewport: viewport(),
            anchor: TerminalTextPoint(row: 101, col: 3), granularity: .word, wordColumns: 2...5)
        value.captureVisibleRows(cell:stableCell)
        precondition(value.visibleColumns(row: 4) == 23...26)
        precondition(value.reconcile(boot: "one", viewport: viewport(offset: 10), cell:stableCell))
        precondition((3..<8).allSatisfy { value.visibleColumns(row: $0) == nil })
        value.drag(to: TerminalTextPoint(row: 92, col: 6), wordColumns: 4...7)
        precondition(value.ordered?.0 == TerminalTextPoint(row: 92, col: 4))
        precondition(value.ordered?.1 == TerminalTextPoint(row: 101, col: 5))
        precondition(value.visibleColumns(row: 5) == 25...40)
        print("PASS: выделение слова сохраняется при прокрутке и расширяется назад до границы слова")
    }
    static func reverseLineDragSelectsWholeRows() {
        var value = TerminalSelection(boot: "one", viewport: viewport(),
            anchor: TerminalTextPoint(row: 103, col: 7), granularity: .line)
        value.drag(to: TerminalTextPoint(row: 101, col: 10))
        precondition(value.ordered?.0 == TerminalTextPoint(row: 101, col: 0))
        precondition(value.ordered?.1 == TerminalTextPoint(row: 103, col: 19))
        precondition(value.visibleColumns(row: 4) == 21...40 && value.visibleColumns(row: 6) == 21...40)
        print("PASS: обратное протягивание после тройного клика выбирает целые строки")
    }
    static func outputOutsideSelectedColumnsKeepsRange() {
        var value = selected()
        value.captureVisibleRows { _, _ in TerminalSelectionCell(symbol:"a", continuation:false) }
        precondition(value.reconcile(boot:"one", viewport:viewport(revision:4), cell: { row, column in
            TerminalSelectionCell(symbol: row == 101 && column < 2 ? "b" : "a", continuation:false)
        }), "Изменение вне выбранных колонок не снимает выделение")
        precondition(value.capturedText == String(repeating:"a",count:18) + "\n" + String(repeating:"a",count:8))
        print("PASS: изменения вне диапазона не снимают проверенное выделение")
    }
    static func selectedRewriteWithHistoryGrowthIsRejected() {
        var value = selected()
        value.captureVisibleRows { _, _ in TerminalSelectionCell(symbol:"a", continuation:false) }
        precondition(!value.reconcile(boot:"one", viewport:viewport(offset:1, maximum:101, revision:4), cell: { _, _ in
            TerminalSelectionCell(symbol:"b", continuation:false)
        }))
        print("PASS: рост истории не разрешает подмену выбранного текста")
    }
    static func liveRowsScrollingIntoHistoryKeepSnapshot() {
        var value = selected()
        precondition(value.reconcile(boot:"one", viewport:viewport(maximum:103, revision:4), cell:stableCell))
        precondition(value.requiresCapturedCopy)
        precondition(value.capturedText == String(repeating:"a",count:18) + "\n" + String(repeating:"a",count:8))
        precondition(value.reconcile(boot:"one", viewport:viewport(offset:3, maximum:103, revision:4), cell:stableCell))
        precondition(!value.requiresCapturedCopy, "Полностью проверенный диапазон снова разрешает серверное чтение")
        print("PASS: уход live-строк в историю сохраняет снимок до повторной проверки координат")
    }
    static func unseenGrowthWithoutCompleteSnapshotIsRejected() {
        var value = TerminalSelection(boot:"one", viewport:viewport(), anchor:TerminalTextPoint(row:101,col:2))
        value.drag(to:TerminalTextPoint(row:102,col:7))
        precondition(!value.reconcile(boot:"one", viewport:viewport(maximum:103, revision:4), cell:stableCell))
        print("PASS: уход за экран без полного снимка снимает диапазон")
    }
    static func returnedLiveSnapshotRejectsRewrittenRows() {
        var value = selected()
        precondition(value.reconcile(boot:"one", viewport:viewport(maximum:103, revision:4), cell:stableCell))
        precondition(!value.reconcile(boot:"one", viewport:viewport(offset:3, maximum:103, revision:4), cell: { _, _ in
            TerminalSelectionCell(symbol:"b", continuation:false)
        }))
        print("PASS: возвращённые строки сверяются со снимком до повторного использования координат")
    }
    static func unseenHistoryAtLimitIsRejected() {
        var value = selected()
        value.captureVisibleRows { _, _ in TerminalSelectionCell(symbol:"a", continuation:false) }
        precondition(value.reconcile(boot:"one", viewport:viewport(offset:10), cell:stableCell))
        precondition(!value.reconcile(boot:"one", viewport:viewport(offset:10, revision:4), cell: { _, _ in
            TerminalSelectionCell(symbol:"a", continuation:false)
        }))
        print("PASS: невидимый диапазон при неоднозначном сдвиге истории снимается")
    }
    static func missingSnapshotNeverCopiesPartialRange() {
        var value = selected()
        value.captureVisibleRows { _, _ in TerminalSelectionCell(symbol:"a", continuation:false) }
        value.extend(rows:-1000)
        precondition(value.capturedText == nil)
        print("PASS: отсутствующие в снимке строки не превращаются в неполную копию")
    }
    static func repeatedDragDoesNotRecaptureUnchangedRows() {
        var value = TerminalSelection(boot:"one", viewport:viewport(), anchor:TerminalTextPoint(row:101,col:2))
        value.drag(to:TerminalTextPoint(row:102,col:7))
        var count = 0
        value.captureVisibleRows { _, _ in count += 1; return TerminalSelectionCell(symbol:"a", continuation:false) }
        precondition(count == 40)
        value.drag(to:TerminalTextPoint(row:102,col:8))
        value.captureVisibleRows { _, _ in count += 1; return TerminalSelectionCell(symbol:"a", continuation:false) }
        precondition(count == 40, "Неизменённые строки не копируются повторно при drag")
        print("PASS: снимок не копирует строки повторно без новой ревизии")
    }
    static func main() {
        scrollMovesWithText()
        appendedOutputKeepsRange()
        dragAcrossPagesStaysInPane()
        keyboardUsesPaneWidth()
        layoutMovementKeepsPaneCoordinates()
        resizedPaneInvalidatesCoordinates()
        alternateScreenInvalidatesCoordinates()
        evictionInvalidatesCoordinates()
        ambiguousOutputInvalidatesCoordinates()
        restartedServerInvalidatesCoordinates()
        wordSelectionSurvivesScrollingAndReverseDrag()
        reverseLineDragSelectsWholeRows()
        outputOutsideSelectedColumnsKeepsRange()
        selectedRewriteWithHistoryGrowthIsRejected()
        liveRowsScrollingIntoHistoryKeepSnapshot()
        unseenGrowthWithoutCompleteSnapshotIsRejected()
        returnedLiveSnapshotRejectsRewrittenRows()
        unseenHistoryAtLimitIsRejected()
        missingSnapshotNeverCopiesPartialRange()
        repeatedDragDoesNotRecaptureUnchangedRows()
    }
}
