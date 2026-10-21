import Foundation

enum TerminalSelectionReadError: Error, LocalizedError {
    case staleContent
    var errorDescription: String? { L("core.selection.staleContent") }
}

struct TerminalTextPoint: Equatable, Comparable {
    let row: Int
    let col: Int
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
    }
    var parameters: [String: Int] { ["row": row, "col": col] }
}

struct TerminalSelectionViewport {
    let paneID: String
    let x: Int
    let y: Int
    let columns: Int
    let rows: Int
    let offset: Int
    let maximum: Int
    let contentRevision: UInt64
    let alternateScreen: Bool
    let hasHistory: Bool
    var top: Int { maximum - offset }

    func point(x column: Int, y row: Int) -> TerminalTextPoint {
        TerminalTextPoint(row: top + max(0, min(rows - 1, row - y)),
                          col: max(0, min(columns - 1, column - x)))
    }
}

struct TerminalSelectionCell: Equatable {
    let symbol: String
    let continuation: Bool
}

// Координаты принадлежат буферу одной панели, а не общей экранной сетке.
struct TerminalSelection {
    enum Granularity { case character, word, line }
    let boot: String
    private(set) var viewport: TerminalSelectionViewport
    private(set) var anchor: TerminalTextPoint
    let granularity: Granularity
    private let initialRange: ClosedRange<TerminalTextPoint>
    var head: TerminalTextPoint?
    private(set) var requiresCapturedCopy = false
    private struct CapturedRow {
        let revision: UInt64
        let cells: [TerminalSelectionCell]
    }
    private var capturedRows: [Int: CapturedRow] = [:]
    var ordered: (TerminalTextPoint, TerminalTextPoint)? {
        guard let head else { return nil }
        return (min(anchor, head), max(anchor, head))
    }

    init(boot: String, viewport: TerminalSelectionViewport, anchor: TerminalTextPoint,
         granularity: Granularity = .character, wordColumns: ClosedRange<Int>? = nil) {
        self.boot = boot; self.viewport = viewport; self.granularity = granularity
        let columns = granularity == .line ? 0...(viewport.columns - 1) : wordColumns ?? anchor.col...anchor.col
        let first = TerminalTextPoint(row: anchor.row, col: columns.lowerBound)
        let last = TerminalTextPoint(row: anchor.row, col: columns.upperBound)
        self.anchor = first; initialRange = first...last
        if granularity != .character { head = last }
    }

    mutating func reconcile(boot: String, viewport next: TerminalSelectionViewport,
                           cell: (Int, Int) -> TerminalSelectionCell) -> Bool {
        guard boot == self.boot, next.paneID == viewport.paneID,
              next.columns == viewport.columns, next.rows == viewport.rows,
              next.alternateScreen == viewport.alternateScreen, next.hasHistory == viewport.hasHistory,
              next.maximum >= viewport.maximum else { return false }
        let changed = next.contentRevision != viewport.contentRevision
        if changed || requiresCapturedCopy {
            let (first, last) = ordered ?? (anchor, anchor)
            var unverified = false
            for row in first.row...last.row {
                // Новые строки могли прокрутить выбранный текст в историю.
                // Его снимок сохраняется, но удалённые координаты пока не доказаны.
                guard row >= next.top && row < next.top + next.rows else {
                    guard !changed || (next.maximum > viewport.maximum && row < next.maximum) else { return false }
                    unverified = true
                    continue
                }
                guard let captured = capturedRows[row]?.cells else { return false }
                var lo = row == first.row ? first.col : 0
                let hi = row == last.row ? last.col : viewport.columns - 1
                while lo > 0 && captured[lo].continuation { lo -= 1 }
                for column in lo...hi {
                    if captured[column] != cell(row, column) { return false }
                }
            }
            guard !unverified || hasCapturedRange else { return false }
            requiresCapturedCopy = unverified
        }
        viewport = next
        return true
    }

    // Снимок ограничен выбранными строками и обновляется только при жесте,
    // а не копированием всей терминальной сетки на каждом кадре.
    mutating func captureVisibleRows(cell: (Int, Int) -> TerminalSelectionCell) {
        let (first, last) = ordered ?? (anchor, anchor)
        let lo = max(first.row, viewport.top), hi = min(last.row, viewport.top + viewport.rows - 1)
        guard lo <= hi else { return }
        for row in lo...hi {
            if capturedRows[row]?.revision != viewport.contentRevision {
                capturedRows[row] = CapturedRow(revision: viewport.contentRevision,
                    cells: (0..<viewport.columns).map { cell(row, $0) })
            }
        }
    }

    var hasCapturedRange: Bool {
        let (first, last) = ordered ?? (anchor, anchor)
        return (first.row...last.row).allSatisfy { capturedRows[$0] != nil }
    }

    var capturedText: String? {
        guard let (first, last) = ordered else { return nil }
        var lines: [String] = []
        for row in first.row...last.row {
            guard let captured = capturedRows[row]?.cells else { return nil }
            var lo = row == first.row ? first.col : 0
            let hi = row == last.row ? last.col : viewport.columns - 1
            while lo > 0 && captured[lo].continuation { lo -= 1 }
            var line = ""
            for column in lo...hi where !captured[column].continuation { line += captured[column].symbol }
            while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    mutating func drag(to point: TerminalTextPoint, wordColumns: ClosedRange<Int>? = nil) {
        if granularity == .character {
            head = point == anchor ? nil : point
        } else {
            let columns = granularity == .line ? 0...(viewport.columns - 1) : wordColumns ?? point.col...point.col
            anchor = min(initialRange.lowerBound, TerminalTextPoint(row: point.row, col: columns.lowerBound))
            head = max(initialRange.upperBound, TerminalTextPoint(row: point.row, col: columns.upperBound))
        }
    }

    mutating func extend(columns: Int = 0, rows: Int = 0) {
        guard let head else { return }
        let lastRow = viewport.maximum + viewport.rows - 1
        let index = max(0, min((lastRow + 1) * viewport.columns - 1,
                               head.row * viewport.columns + head.col + columns + rows * viewport.columns))
        self.head = TerminalTextPoint(row: index / viewport.columns, col: index % viewport.columns)
    }

    func visibleColumns(row: Int) -> ClosedRange<Int>? {
        guard let (start, end) = ordered, row >= viewport.y, row < viewport.y + viewport.rows else { return nil }
        let absoluteRow = viewport.top + row - viewport.y
        guard absoluteRow >= start.row, absoluteRow <= end.row else { return nil }
        let first = absoluteRow == start.row ? start.col : 0
        let last = absoluteRow == end.row ? end.col : viewport.columns - 1
        return (viewport.x + first)...(viewport.x + last)
    }

    // Работаем в колонках терминала: второй столбец широкого глифа не является
    // отдельным символом, а комбинируемые знаки уже входят в symbol ячейки.
    static func wordColumns(at column: Int, count: Int, symbol: (Int) -> String,
                            isContinuation: (Int) -> Bool) -> ClosedRange<Int> {
        var first = max(0, min(count - 1, column))
        while first > 0 && isContinuation(first) { first -= 1 }
        let kind = wordClass(symbol(first))
        var last = first
        if kind != .symbol {
            while first > 0 {
                var previous = first - 1
                while previous > 0 && isContinuation(previous) { previous -= 1 }
                guard wordClass(symbol(previous)) == kind else { break }
                first = previous
            }
            while last + 1 < count {
                if !isContinuation(last + 1) && wordClass(symbol(last + 1)) != kind { break }
                last += 1
            }
        }
        while last + 1 < count && isContinuation(last + 1) { last += 1 }
        return first...last
    }
    private enum WordClass { case whitespace, word, symbol }
    private static func wordClass(_ symbol: String) -> WordClass {
        guard let scalar = symbol.unicodeScalars.first else { return .whitespace }
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .whitespace }
        if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) || scalar == "_" { return .word }
        return .symbol
    }

    var readParameters: [String: Any]? {
        guard let head else { return nil }
        return ["pane_id": viewport.paneID, "anchor": anchor.parameters,
                "cursor": head.parameters, "content_revision": viewport.contentRevision]
    }
}
