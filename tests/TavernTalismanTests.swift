import AppKit
import QuartzCore

@main
struct TavernTalismanTests {
    static func main() {
        mapsOnlyDocumentedAgentStatuses()
        ignoresInitialAndRepeatedSnapshots()
        displaysCompletionAndQuestionUntilIdle()
        emitsEveryKnownVisualChange()
        unknownStatusDoesNotInventTransition()
        preservesReferenceGeometryScale()
        #if TAVERN_RENDER_TESTING
        _ = NSApplication.shared
        preservesEagerParticlesAndBurstLifetime()
        preservesStaticGeometryThroughResizeAndBackingChanges()
        restoresTalismanAfterHideReduceMotionAndReset()
        expiresHoverReactionAtFourSeconds()
        restoresRuneParticlesAfterPolicyAndGeometryChanges()
        #endif
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

#if TAVERN_RENDER_TESTING
private extension TavernTalismanTests {
    // Inspect actual model layers, not cache bookkeeping or setter-call counters.
    struct LayerSnapshot: Equatable {
        let bounds: CGRect
        let position: CGPoint
        let opacity: Float
        let hidden: Bool
        let transform: [CGFloat]
        let shadowRadius: CGFloat
        let shadowOffset: CGSize
        let rasterizationScale: CGFloat

        init(_ layer: CALayer) {
            bounds = layer.bounds
            position = layer.position
            opacity = layer.opacity
            hidden = layer.isHidden
            let t = layer.affineTransform()
            transform = [t.a, t.b, t.c, t.d, t.tx, t.ty]
            shadowRadius = layer.shadowRadius
            shadowOffset = layer.shadowOffset
            rasterizationScale = layer.rasterizationScale
        }
    }

    struct TalismanLayers {
        let assembly: CALayer
        let body: CALayer
        let links: [CALayer]
        let mount: CALayer
        let burst: [CALayer]
        let glows: [CALayer]
        let cloud: [CALayer]

        init(_ view: TavernTalismanView) {
            let layers = view.layer!.sublayers!
            precondition(layers.count == 1 + 78 * 2 + 3 + 11 * 2,
                         "All burst/cloud soft and core layers must exist before first activation")
            assembly = layers[0]
            let hanging = assembly.sublayers!
            precondition(hanging.count == 8, "Body, six links and mount must remain separate")
            body = hanging[0]
            links = Array(hanging[1...6])
            mount = hanging[7]
            burst = Array(layers[1..<(1 + 78 * 2)])
            glows = Array(layers[(1 + 78 * 2)..<(1 + 78 * 2 + 3)])
            cloud = Array(layers.suffix(11 * 2))
        }

        var snapshots: [LayerSnapshot] {
            ([assembly, body] + links + [mount] + burst + glows + cloud).map(LayerSnapshot.init)
        }
    }

    static func talisman() -> TavernTalismanView {
        let view = TavernTalismanView(frame: CGRect(x: 0, y: 0, width: 380, height: 146))
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        return view
    }

    static func assertHidden(_ layers: [CALayer], _ message: String) {
        precondition(layers.allSatisfy { $0.opacity == 0 }, message)
    }

    static func preservesEagerParticlesAndBurstLifetime() {
        let view = talisman()
        let layers = TalismanLayers(view)
        let identities = (layers.burst + layers.cloud).map(ObjectIdentifier.init)
        assertHidden(layers.burst + layers.cloud, "Unconfigured talisman must have no particles")
        view.configure(status: .progress)
        assertHidden(layers.burst, "Initial status must not burst")
        precondition(layers.cloud.filter { $0.opacity > 0 }.count == 11 * 2)
        view.configure(status: .progress)
        assertHidden(layers.burst, "Repeated status must not burst")
        view.configure(status: .waiting)
        assertHidden(layers.burst, "Burst particles respect their initial delay")
        view.advanceRenderingTestTime(by: 0.1)
        precondition(layers.burst.allSatisfy { $0.opacity > 0 },
                     "All 78 particles must be alive after maximum 0.08-second delay")
        view.advanceRenderingTestTime(by: 0.399)
        precondition(layers.burst.allSatisfy { $0.opacity > 0 }, "Burst lasts until 0.5 seconds")
        view.advanceRenderingTestTime(by: 0.002)
        assertHidden(layers.burst, "Burst must finish after 0.5 seconds")
        view.configure(status: .question)
        precondition(layers.cloud.filter { $0.opacity > 0 }.count == 9 * 2)
        view.configure(status: .error)
        precondition(layers.cloud.filter { $0.opacity > 0 }.count == 9 * 2)
        view.configure(status: .success)
        assertHidden(layers.cloud, "Success must stop ambient particles")
        precondition(view.materialLight == nil)
        precondition((TalismanLayers(view).burst + TalismanLayers(view).cloud)
            .map(ObjectIdentifier.init) == identities, "Activation must reuse eager particle layers")
    }

    static func preservesStaticGeometryThroughResizeAndBackingChanges() {
        let view = talisman()
        view.setRenderingTestPolicy(visible: true, reduceMotion: true)
        view.configure(status: .progress)
        let layers = TalismanLayers(view)
        for (bounds, backing) in [
            (CGRect(x: 0, y: 0, width: 380, height: 146), CGFloat(1)),
            (CGRect(x: 2.25, y: 1.5, width: 240.5, height: 76), CGFloat(2)),
            (CGRect(x: 0, y: 0, width: 380, height: 146), CGFloat(1))
        ] {
            view.bounds = bounds
            view.layout()
            view.setRenderingTestBackingScale(backing)
            let card = view.bounds.insetBy(dx: 3, dy: 3)
            let scale = TavernTalismanView.visualScale(forCardHeight: card.height)
            precondition(layers.assembly.bounds == CGRect(origin: .zero, size: view.bounds.size))
            precondition(layers.assembly.position == CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            precondition(layers.body.bounds == CGRect(x: 0, y: 0, width: 48 * scale, height: 60 * scale))
            precondition(layers.mount.bounds == CGRect(x: 0, y: 0, width: 16 * scale, height: 16 * scale))
            precondition(layers.mount.position == CGPoint(x: card.maxX - 38 * scale, y: card.minY + 14 * scale))
            precondition(layers.links.allSatisfy {
                $0.bounds == CGRect(x: 0, y: 0, width: 5 * scale, height: 7 * scale)
            })
            precondition(layers.body.shadowRadius == 1.5 * scale)
            precondition(layers.body.shadowOffset == CGSize(width: -1.5 * scale, height: 2.5 * scale))
            precondition(layers.body.rasterizationScale == backing)
            let snapshot = layers.snapshots
            view.layout()
            view.viewDidChangeBackingProperties()
            precondition(layers.snapshots == snapshot, "Identical layout/backing must preserve actual rendering")
        }
        let beforeBacking = layers.snapshots
        view.setRenderingTestBackingScale(2)
        precondition(layers.body.rasterizationScale == 2, "Backing-only change must update rasterization")
        view.setRenderingTestBackingScale(1)
        precondition(layers.snapshots == beforeBacking, "Returning backing scale must restore all layer geometry")
    }

    static func restoresTalismanAfterHideReduceMotionAndReset() {
        let view = talisman()
        view.configure(status: .progress)
        view.advanceRenderingTestTime(by: 0.25)
        let layers = TalismanLayers(view)
        let active = layers.snapshots
        view.setRenderingTestPolicy(visible: false, reduceMotion: false)
        assertHidden(layers.cloud + layers.burst, "Hidden effects must stop")
        view.advanceRenderingTestTime(by: 10)
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        precondition(layers.snapshots == active, "Hide/show must restore cached nonzero particle opacity")
        view.setRenderingTestPolicy(visible: true, reduceMotion: true)
        assertHidden(layers.cloud + layers.burst, "Reduce Motion must stop particles")
        view.advanceRenderingTestTime(by: 10)
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        precondition(layers.snapshots == active, "Restoring motion must restore exact geometry and opacity")
        view.configure(status: nil)
        precondition(layers.assembly.isHidden && view.materialLight == nil)
        assertHidden(layers.cloud + layers.burst + layers.glows, "Reset must remove every effect")
        view.configure(status: .progress)
        precondition(layers.snapshots == active, "Reset/reactivate must not retain hidden cached opacity")

        view.configure(status: .waiting)
        view.setHovered(true)
        view.advanceRenderingTestTime(by: 0.1)
        precondition(layers.burst.contains { $0.opacity > 0 })
        view.setRenderingTestPolicy(visible: false, reduceMotion: false)
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        assertHidden(layers.burst, "A cancelled burst must not resume after show")
        view.configure(status: .progress)
        view.advanceRenderingTestTime(by: 0.1)
        precondition(layers.burst.contains { $0.opacity > 0 })
        view.setRenderingTestPolicy(visible: true, reduceMotion: true)
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        assertHidden(layers.burst, "A cancelled burst must not resume after Reduce Motion")
        view.configure(status: .waiting)
        view.advanceRenderingTestTime(by: 0.1)
        precondition(layers.burst.contains { $0.opacity > 0 })
        view.configure(status: nil)
        assertHidden(layers.burst + layers.cloud + layers.glows, "Reset must cancel an active burst")
        view.configure(status: .progress)
        assertHidden(layers.burst, "First status after reset must not resume or invent a burst")
    }

    static func expiresHoverReactionAtFourSeconds() {
        let view = talisman()
        view.configure(status: .progress)
        view.setHovered(true)
        view.advanceRenderingTestTime(by: 4)
        let layers = TalismanLayers(view)
        let expired = ([layers.body] + layers.links).map(LayerSnapshot.init)
        view.setHovered(false)
        precondition(([layers.body] + layers.links).map(LayerSnapshot.init) == expired,
                     "Hover reaction must have expired at four seconds")
    }

    static func restoresRuneParticlesAfterPolicyAndGeometryChanges() {
        let view = TavernRuneParticlesView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.runeCenter = CGPoint(x: 120.25, y: 84.5)
        view.visualScale = 0.5
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        view.advanceRenderingTestTime(by: 1.25)
        let layers = view.layer!.sublayers!
        precondition(layers.count == 1 + 9 * 2, "Rune must eagerly retain nine soft/core pairs")
        let active = layers.map(LayerSnapshot.init)
        view.runeCenter = CGPoint(x: 120.25, y: 84.5)
        view.visualScale = 0.5
        precondition(layers.map(LayerSnapshot.init) == active, "Identical rune inputs must preserve rendering")
        for index in 0..<9 {
            let i = Double(index), angle = i * 2.399
            let phase = 1.25 * (0.35 + Double(index % 4) * 0.03)
            let radius = Double(42 + (index % 3) * 9)
            let point = CGPoint(
                x: 120.25 + CGFloat(cos(angle) * radius + sin(phase + i * 1.3) * 7) * 0.5,
                y: 84.5 + CGFloat(sin(angle) * radius * 0.65 + sin(phase * 0.71 + i) * 8) * 0.5)
            let size = CGFloat(1.2 + Double(index % 3) * 0.25) * 0.5
            let opacity = Float((0.25 + 0.65 * (0.5 + 0.5 * sin(1.25 * (0.8 + i * 0.019) + i))) * 0.8)
            let soft = layers[1 + index * 2], core = layers[2 + index * 2]
            precondition(soft.position == point && core.position == point)
            precondition(soft.bounds.size == CGSize(width: size * 8, height: size * 8))
            precondition(core.bounds.size == CGSize(width: size * 2, height: size * 2))
            precondition(soft.opacity == opacity && core.opacity == opacity)
        }
        view.runeCenter = CGPoint(x: 20, y: 30)
        view.visualScale = 1
        view.runeCenter = CGPoint(x: 120.25, y: 84.5)
        view.visualScale = 0.5
        view.viewDidChangeBackingProperties()
        precondition(layers.map(LayerSnapshot.init) == active)
        view.setRenderingTestPolicy(visible: false, reduceMotion: false)
        assertHidden(Array(layers.dropFirst()), "Hidden rune must stop particles")
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        precondition(layers.map(LayerSnapshot.init) == active)
        view.setRenderingTestPolicy(visible: true, reduceMotion: true)
        assertHidden(Array(layers.dropFirst()), "Reduced-motion rune must stop particles")
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        precondition(layers.map(LayerSnapshot.init) == active)
        view.pulse()
        precondition(layers[0].opacity == Float(0.8 * (0.35 + 0.45)))
        view.advanceRenderingTestTime(by: 0.4)
        let pulseAge = (1.25 + 0.4) - 1.25
        precondition(layers[0].opacity == Float(0.8 * (0.35 + exp(-pulseAge * 2.5) * 0.45)))
        view.setRenderingTestPolicy(visible: false, reduceMotion: false)
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        precondition(layers[0].opacity == Float(0.8 * 0.35), "Cancelled rune pulse must not resume")
        view.pulse()
        view.setRenderingTestPolicy(visible: true, reduceMotion: true)
        view.setRenderingTestPolicy(visible: true, reduceMotion: false)
        precondition(layers[0].opacity == Float(0.8 * 0.35), "Reduce Motion must cancel an active pulse")
    }
}
#endif
