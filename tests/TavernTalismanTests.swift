import AppKit

@main
struct TavernTalismanTests {
    static func main() {
        mapsOnlyDocumentedAgentStatuses()
        ignoresInitialAndRepeatedSnapshots()
        displaysCompletionAndQuestionUntilIdle()
        emitsEveryKnownVisualChange()
        unknownStatusDoesNotInventTransition()
        preservesReferenceGeometryScale()
        print("TavernTalismanTests: passed")
    }

    private static func mapsOnlyDocumentedAgentStatuses() {
        precondition(TavernAgentVisualStatus(agentStatus: "working") == .progress)
        precondition(TavernAgentVisualStatus(agentStatus: "idle") == nil)
        precondition(TavernAgentVisualStatus(agentStatus: "done") == .waiting)
        precondition(TavernAgentVisualStatus(agentStatus: "blocked") == .question)
        precondition(TavernAgentVisualStatus(agentStatus: "") == nil)
        precondition(TavernAgentVisualStatus(agentStatus: "disconnected") == nil)
        precondition(TavernAgentVisualStatus(agentStatus: "unread") == nil)
        precondition(TavernAgentVisualStatus(agentStatus: "future-status") == nil)
    }

    private static func ignoresInitialAndRepeatedSnapshots() {
        var transition = TavernTalismanTransition()
        precondition(!transition.update(nil))
        precondition(!transition.update(.progress))
        precondition(!transition.update(.progress))
        precondition(transition.status == .progress)
        precondition(transition.update(.success))
        precondition(!transition.update(.success))
    }

    private static func displaysCompletionAndQuestionUntilIdle() {
        var transition = TavernTalismanTransition()
        _ = transition.update(TavernAgentVisualStatus(agentStatus: "working"))
        precondition(transition.update(TavernAgentVisualStatus(agentStatus: "done")))
        precondition(transition.status == .waiting)
        precondition(transition.update(TavernAgentVisualStatus(agentStatus: "blocked")))
        precondition(transition.status == .question)
        precondition(!transition.update(TavernAgentVisualStatus(agentStatus: "idle")))
        precondition(transition.status == nil)
    }

    private static func emitsEveryKnownVisualChange() {
        var transition = TavernTalismanTransition()
        precondition(!transition.update(.progress))
        precondition(transition.update(.question))
        precondition(transition.update(.error))
        precondition(transition.update(.waiting))
        precondition(transition.update(.success))
        precondition(transition.update(.progress))
    }

    private static func unknownStatusDoesNotInventTransition() {
        var transition = TavernTalismanTransition()
        precondition(!transition.update(.success))
        precondition(!transition.update(nil))
        precondition(transition.status == nil)
        precondition(!transition.update(.error))
        precondition(transition.status == .error)
        precondition(transition.update(.success))
    }

    private static func preservesReferenceGeometryScale() {
        precondition(TavernTalismanView.visualScale(forCardHeight: 140) == 1)
        precondition(TavernTalismanView.visualScale(forCardHeight: 70) == 0.5)
        precondition(TavernTalismanView.visualScale(forCardHeight: 280) == 1)
        precondition(TavernTalismanView.visualScale(forCardHeight: 0) == 0)
    }
}
