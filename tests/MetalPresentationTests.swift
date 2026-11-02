import AppKit

@main
struct MetalPresentationTests {
    static func main() {
        let recorder = TavernPerformance.shared
        recorder.reset()
        let metrics = TavernMetalPresentationMetrics(stage: .nebulaPresentation, counter: .nebulaPresented)
        func frame(_ time: Double, continuous: Bool = true) {
            metrics.presented(at: time, token: metrics.frameToken(continuous: continuous))
        }
        func stage() -> [String: Any] {
            (recorder.snapshot()["stages"] as! [String: [String: Any]])["nebulaPresentation"]!
        }

        let oldToken = metrics.frameToken(continuous: true)
        metrics.presented(at: 1, token: oldToken)
        frame(1.04)
        metrics.suspend()
        frame(101)
        // A callback from the suspended generation must not poison the resumed clock.
        metrics.presented(at: 1_000, token: oldToken)
        frame(101.04)
        frame(200, continuous: false)
        frame(500)
        frame(499) // Out-of-order completion must not move time backwards.
        frame(500.04)
        metrics.presented(at: .nan, token: metrics.frameToken(continuous: true))
        metrics.presented(at: -1, token: metrics.frameToken(continuous: true))

        var result = stage()
        precondition(result["count"] as! UInt64 == 3, "paused/static/stale callbacks became frame intervals")
        precondition((result["max_ns"] as! UInt64) < 41_000_000, "intentional pause became a frame stall")
        let counters = recorder.snapshot()["counters"] as! [String: UInt64]
        precondition(counters["nebulaPresented"] == 9, "valid presentations must remain counted")

        // Genuine stalls within an uninterrupted animation must remain observable.
        frame(500.54)
        result = stage()
        precondition(result["count"] as! UInt64 == 4)
        precondition(result["max_ns"] as! UInt64 >= 499_000_000, "a genuine stall was hidden")
        print("MetalPresentationTests passed")
    }
}
