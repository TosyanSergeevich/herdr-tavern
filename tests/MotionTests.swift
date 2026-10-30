import AppKit

@main struct MotionTests {
    static func main() {
        savedChoiceAndSystemPriority()
        selectionDoesNotRestartOnRefresh()
        reversalKeepsCurrentPose()
        disabledAndInitialSelectionAreImmediate()
        print("MotionTests: passed")
    }

    private static func savedChoiceAndSystemPriority() {
        let suite = "Tavern.MotionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var reduced = false
        let policy = TavernMotionSettings(defaults: defaults, center: NotificationCenter(), reduceMotion: { reduced })
        policy.setAnimationsEnabled(false)
        let restored = TavernMotionSettings(defaults: defaults, center: NotificationCenter(), reduceMotion: { reduced })
        precondition(!restored.enabled && !restored.animationsEnabled, "Saved opt-out must survive a new controller")
        restored.setAnimationsEnabled(true)
        reduced = true
        restored.refresh()
        precondition(restored.animationsEnabled && !restored.enabled, "System accessibility must override opt-in without erasing it")
        reduced = false
        restored.refresh()
        precondition(restored.enabled, "Turning off Reduce Motion restores the saved opt-in")
        restored.setAnimationsEnabled(false)
        reduced = true
        restored.refresh()
        reduced = false
        restored.refresh()
        precondition(!restored.enabled, "A system policy change must not override the user's opt-out")
    }

    private static func selectionDoesNotRestartOnRefresh() {
        var motion = TavernBookmarkMotion()
        motion.select(false, at: 0, animated: true)
        motion.select(true, at: 1, animated: true)
        let moving = motion.pose(at: 1.1)
        precondition(moving.offset > TavernBookmarkPose.hidden.offset && moving.offset < 0)
        motion.select(true, at: 1.1, animated: true)
        precondition(motion.pose(at: 1.1) == moving, "An ordinary metadata refresh must not restart the ribbon")
        precondition(abs(motion.pose(at: 1.17).bend) > 0.01, "The cloth tip must swing, not only slide")
        motion.advance(at: 1.3)
        precondition(!motion.isAnimating && motion.pose(at: 1.3) == .shown)
    }

    private static func reversalKeepsCurrentPose() {
        var motion = TavernBookmarkMotion()
        motion.select(false, at: 0, animated: false)
        motion.select(true, at: 1, animated: true)
        let mid = motion.pose(at: 1.1)
        motion.select(false, at: 1.1, animated: true)
        precondition(motion.pose(at: 1.1) == mid, "Deselection must start at the current pose")
        let leaving = motion.pose(at: 1.14)
        motion.select(true, at: 1.14, animated: true)
        precondition(motion.pose(at: 1.14) == leaving, "Rapid reselection must not jump or enqueue an old animation")
        motion.advance(at: 2)
        precondition(motion.pose(at: 2) == .shown)
    }

    private static func disabledAndInitialSelectionAreImmediate() {
        var motion = TavernBookmarkMotion()
        motion.select(true, at: 1, animated: true)
        precondition(!motion.isAnimating && motion.pose(at: 1) == .shown, "Initial state must not replay selection")
        motion.select(false, at: 2, animated: false)
        precondition(!motion.isAnimating && motion.pose(at: 2) == .hidden)
        motion.select(true, at: 3, animated: true)
        motion.finish()
        precondition(!motion.isAnimating && motion.pose(at: 3.01) == .shown, "Disabling mid-flight must settle to the current selection")
    }
}
