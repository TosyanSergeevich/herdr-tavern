import Foundation

// Only one uninterrupted run of scroll requests belongs to an intent. Other
// endpoint operations, pane changes and connection changes are barriers.
struct TerminalScrollIntent {
    struct Context: Equatable {
        let boot: String
        let pane: String
        let focusedPane: String
        let alternateScreen: Bool
    }
    private(set) var context: Context?
    private var desired: Int?
    private var pending: [String: Int] = [:]
    private struct Metrics {
        let offset: Int
        let maximum: Int

        func offset(at maximum: Int) -> Int {
            // A scrolled-back viewport is anchored from the history's top.
            // Live-bottom (zero) instead follows the bottom as history grows.
            guard offset > 0 else { return 0 }
            let growth = max(0, maximum - self.maximum)
            let (sum, overflow) = offset.addingReportingOverflow(growth)
            return min(maximum, overflow ? Int.max : sum)
        }
    }
    private var acknowledged: Metrics?
    private var lastObserved: Metrics?
    private var maximum = 0

    mutating func reset() { self = TerminalScrollIntent() }

    mutating func observe(_ context: Context, offset: Int, maximum: Int) {
        if self.context != context { reset(); self.context = context }
        self.maximum = max(0, maximum)
        let offset = clamp(offset)
        if pending.isEmpty {
            // PaneInfo has no surface revision. An already displayed frame can
            // precede the response; compare its scroll metrics, not arrival order.
            if let acknowledged {
                desired = acknowledged.offset(at: self.maximum)
                if offset == desired { self.acknowledged = nil }
            } else {
                desired = offset
            }
        }
        if let desired { self.desired = clamp(desired) }
        for (id, target) in pending { pending[id] = clamp(target) }
        lastObserved = Metrics(offset: offset, maximum: self.maximum)
    }

    mutating func enqueue(id: String, delta: Int?, absolute: Int?, replacing: String?) -> Int {
        let base = desired ?? lastObserved?.offset ?? 0
        let target: Int
        if let delta {
            // Avoid overflowing even for a malformed synthetic input event.
            let (sum, overflow) = base.addingReportingOverflow(delta)
            target = clamp(overflow ? (delta > 0 ? Int.max : 0) : sum)
        } else {
            target = clamp(absolute ?? base)
        }
        if let replacing { pending.removeValue(forKey: replacing) }
        pending[id] = target
        desired = target
        acknowledged = nil
        return target
    }

    mutating func acknowledge(id: String, offset: Int, maximum: Int) {
        guard pending.removeValue(forKey: id) != nil else { return }
        self.maximum = max(0, maximum)
        for (id, target) in pending { pending[id] = clamp(target) }
        if pending.isEmpty {
            let confirmed = Metrics(offset: clamp(offset), maximum: self.maximum)
            if let observed = lastObserved,
               observed.maximum >= confirmed.maximum,
               observed.offset == confirmed.offset(at: observed.maximum) {
                self.maximum = observed.maximum
                desired = observed.offset
                acknowledged = nil
            } else {
                desired = confirmed.offset
                acknowledged = confirmed
            }
        } else if let desired {
            self.desired = clamp(desired)
        }
    }

    func target(for id: String) -> Int? { pending[id] }
    func canReplace(boot: String, pane: String, id: String) -> Bool {
        context?.boot == boot && context?.pane == pane && pending[id] != nil
    }
    private func clamp(_ offset: Int) -> Int { max(0, min(maximum, offset)) }
}

struct TerminalScrollRemainder {
    private var context = ""
    private var remainder: Double = 0

    mutating func reset() { context = ""; remainder = 0 }
    mutating func consume(_ lines: Double, context: String) -> Int {
        if self.context != context { reset(); self.context = context }
        guard lines.isFinite else { return 0 }
        remainder += lines
        guard remainder > Double(Int.min), remainder < Double(Int.max) else { reset(); return 0 }
        let delta = Int(remainder)
        remainder -= Double(delta)
        return delta
    }
}
