import Foundation

@main
struct ScrollIntentTests {
    static let pane = TerminalScrollIntent.Context(boot: "boot", pane: "pane", focusedPane: "pane", alternateScreen: false)

    static func baseline(_ offset: Int = 100, maximum: Int = 200) -> TerminalScrollIntent {
        var intent = TerminalScrollIntent()
        intent.observe(pane, offset: offset, maximum: maximum)
        return intent
    }

    static func rapidMovementsAccumulateBeforeFrames() {
        var intent = baseline()
        precondition(intent.enqueue(id: "sent", delta: 3, absolute: nil, replacing: nil) == 103)
        precondition(intent.enqueue(id: "queued", delta: 3, absolute: nil, replacing: nil) == 106)
        intent.observe(pane, offset: 103, maximum: 200)
        precondition(intent.enqueue(id: "replacement", delta: 3, absolute: nil, replacing: "queued") == 109)
        precondition(intent.target(for: "queued") == nil)
        intent.acknowledge(id: "sent", offset: 103, maximum: 200)
        intent.observe(pane, offset: 100, maximum: 200)
        intent.observe(pane, offset: 103, maximum: 200)
        precondition(intent.target(for: "replacement") == 109)
        precondition(intent.enqueue(id: "reverse", delta: -6, absolute: nil, replacing: "replacement") == 103)
    }

    static func boundsDoNotStoreOverscroll() {
        var intent = baseline(198)
        precondition(intent.enqueue(id: "top", delta: 20, absolute: nil, replacing: nil) == 200)
        precondition(intent.enqueue(id: "reverse", delta: -3, absolute: nil, replacing: nil) == 197)
        precondition(intent.enqueue(id: "bottom", delta: -Int.max, absolute: nil, replacing: nil) == 0)
        precondition(intent.enqueue(id: "up", delta: 3, absolute: nil, replacing: nil) == 3)
        precondition(intent.enqueue(id: "overflow", delta: Int.max, absolute: nil, replacing: nil) == 200)
    }

    static func outputAndAcknowledgedBounds() {
        var intent = baseline(198)
        _ = intent.enqueue(id: "sent", delta: 2, absolute: nil, replacing: nil)
        intent.observe(pane, offset: 198, maximum: 220)
        precondition(intent.enqueue(id: "queued", delta: 10, absolute: nil, replacing: nil) == 210)
        intent.acknowledge(id: "sent", offset: 150, maximum: 155)
        precondition(intent.target(for: "queued") == 155)
        intent.acknowledge(id: "queued", offset: 154, maximum: 155)
        precondition(intent.enqueue(id: "next", delta: -3, absolute: nil, replacing: nil) == 151)
    }

    static func acknowledgementSurvivesUnchangedFrame() {
        var intent = baseline()
        _ = intent.enqueue(id: "sent", delta: 3, absolute: nil, replacing: nil)
        intent.acknowledge(id: "sent", offset: 102, maximum: 200)
        intent.observe(pane, offset: 100, maximum: 200)
        precondition(intent.enqueue(id: "next", delta: 3, absolute: nil, replacing: nil) == 105)
        intent.acknowledge(id: "next", offset: 105, maximum: 200)
        intent.observe(pane, offset: 101, maximum: 200)
        precondition(intent.enqueue(id: "still-confirmed", delta: 3, absolute: nil, replacing: nil) == 108)
        intent.acknowledge(id: "still-confirmed", offset: 108, maximum: 200)
        intent.observe(pane, offset: 108, maximum: 200)
        intent.observe(pane, offset: 111, maximum: 210)
        precondition(intent.enqueue(id: "output", delta: 3, absolute: nil, replacing: nil) == 114)
    }

    static func barriersAndContextChangesDiscardOldIntent() {
        var intent = baseline()
        _ = intent.enqueue(id: "old", delta: 3, absolute: nil, replacing: nil)
        precondition(intent.canReplace(boot: "boot", pane: "pane", id: "old"))
        precondition(!intent.canReplace(boot: "different", pane: "pane", id: "old"))
        precondition(!intent.canReplace(boot: "boot", pane: "other", id: "old"))
        intent.reset() // An intervening endpoint command is an ordering barrier.
        intent.observe(pane, offset: 50, maximum: 200)
        precondition(!intent.canReplace(boot: "boot", pane: "pane", id: "old"))
        _ = intent.enqueue(id: "new", delta: 3, absolute: nil, replacing: nil)
        intent.acknowledge(id: "old", offset: 103, maximum: 200)
        precondition(intent.enqueue(id: "newer", delta: 3, absolute: nil, replacing: "new") == 56)
        let alternate = TerminalScrollIntent.Context(boot: "boot", pane: "pane", focusedPane: "pane", alternateScreen: true)
        intent.observe(alternate, offset: 0, maximum: 0)
        precondition(intent.target(for: "newer") == nil)
        precondition(intent.enqueue(id: "alternate", delta: 3, absolute: nil, replacing: nil) == 0)
        let restarted = TerminalScrollIntent.Context(boot: "new-boot", pane: "pane", focusedPane: "pane", alternateScreen: false)
        intent.observe(restarted, offset: 20, maximum: 200)
        precondition(intent.enqueue(id: "restarted", delta: 3, absolute: nil, replacing: nil) == 23)
    }

    static func fractionalMovementAndPaneIsolation() {
        var remainder = TerminalScrollRemainder()
        precondition(remainder.consume(0.75, context: "pane") == 0)
        precondition(remainder.consume(0.75, context: "pane") == 1)
        precondition(remainder.consume(-0.75, context: "pane") == 0)
        precondition(remainder.consume(-0.75, context: "pane") == -1)
        precondition(remainder.consume(0.75, context: "pane") == 0)
        precondition(remainder.consume(0.5, context: "other-pane") == 0)
        remainder.reset()
        precondition(remainder.consume(0.5, context: "other-pane") == 0)
    }

    static func frameBeforeAcknowledgementDoesNotFreezeIntent() {
        var intent = baseline()
        _ = intent.enqueue(id: "sent", delta: 3, absolute: nil, replacing: nil)
        intent.observe(pane, offset: 103, maximum: 200)
        intent.acknowledge(id: "sent", offset: 103, maximum: 200)
        intent.observe(pane, offset: 108, maximum: 205)
        precondition(intent.enqueue(id: "next", delta: 3, absolute: nil, replacing: nil) == 111)
    }

    static func historyGrowingBeforeAcknowledgementPreservesAnchor() {
        var intent = baseline()
        _ = intent.enqueue(id: "sent", delta: 3, absolute: nil, replacing: nil)
        intent.observe(pane, offset: 108, maximum: 205)
        intent.acknowledge(id: "sent", offset: 103, maximum: 200)
        precondition(intent.enqueue(id: "next", delta: 3, absolute: nil, replacing: nil) == 111)
    }

    static func historyGrowingAfterAcknowledgementPreservesAnchor() {
        var intent = baseline()
        _ = intent.enqueue(id: "sent", delta: 3, absolute: nil, replacing: nil)
        intent.acknowledge(id: "sent", offset: 103, maximum: 200)
        intent.observe(pane, offset: 108, maximum: 205)
        intent.observe(pane, offset: 112, maximum: 209)
        precondition(intent.enqueue(id: "next", delta: -3, absolute: nil, replacing: nil) == 109)
    }

    static func bottomAcknowledgementFollowsLiveOutput() {
        var intent = baseline(3)
        _ = intent.enqueue(id: "sent", delta: -3, absolute: nil, replacing: nil)
        intent.acknowledge(id: "sent", offset: 0, maximum: 200)
        intent.observe(pane, offset: 0, maximum: 205)
        precondition(intent.enqueue(id: "next", delta: 3, absolute: nil, replacing: nil) == 3)
    }

    static func main() {
        rapidMovementsAccumulateBeforeFrames()
        boundsDoNotStoreOverscroll()
        outputAndAcknowledgedBounds()
        acknowledgementSurvivesUnchangedFrame()
        barriersAndContextChangesDiscardOldIntent()
        fractionalMovementAndPaneIsolation()
        frameBeforeAcknowledgementDoesNotFreezeIntent()
        historyGrowingBeforeAcknowledgementPreservesAnchor()
        historyGrowingAfterAcknowledgementPreservesAnchor()
        bottomAcknowledgementFollowsLiveOutput()
        print("ScrollIntentTests passed")
    }
}
