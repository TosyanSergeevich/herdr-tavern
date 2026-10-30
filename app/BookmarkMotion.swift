import Foundation

/// Scene-space displacement; the cloth keeps its length while the tip bends.
struct TavernBookmarkPose: Equatable {
    var offset: Float
    var bend: Float
    static let hidden = TavernBookmarkPose(offset: -96, bend: 0)
    static let shown = TavernBookmarkPose(offset: 0, bend: 0)
}

struct TavernBookmarkMotion {
    private(set) var selected: Bool?
    private var began: TimeInterval = 0
    private var duration: TimeInterval = 0
    private var from = TavernBookmarkPose.hidden
    private(set) var isAnimating = false

    mutating func select(_ value: Bool, at time: TimeInterval, animated: Bool) {
        guard selected != value else { return }
        let previous = pose(at: time)
        let hadSelection = selected != nil
        selected = value
        guard animated && hadSelection else { finish(); return }
        from = previous
        began = time
        duration = value ? 0.28 : 0.12
        isAnimating = true
    }

    mutating func finish() { isAnimating = false }

    mutating func advance(at time: TimeInterval) {
        if isAnimating && time - began >= duration { finish() }
    }

    func pose(at time: TimeInterval) -> TavernBookmarkPose {
        guard isAnimating else { return selected == true ? .shown : .hidden }
        let progress = Float(max(0, min(1, (time - began) / duration)))
        if selected != true {
            return TavernBookmarkPose(offset: from.offset + (-96 - from.offset) * progress * progress,
                                      bend: from.bend * (1 - progress))
        }
        let fall = min(1, progress / 0.54)
        let swing = max(0, (progress - 0.28) / 0.72)
        let bend = swing >= 1 ? 0 : 0.19 * sin(swing * 2 * .pi) * pow(1 - swing, 1.25)
        return TavernBookmarkPose(offset: from.offset * (1 - fall * fall),
                                  bend: bend + from.bend * (1 - progress))
    }
}
