import AppKit

@main struct NavigationDragTests {
    static func main() {
        let container = NSRect(x: 20, y: 30, width: 350, height: 160)
        let size = NSSize(width: 100, height: 40)
        for x in stride(from: -500.0, through: 800, by: 17) {
            for y in stride(from: -400.0, through: 500, by: 23) {
                let result = TavernDragGeometry.clamped(NSRect(origin: NSPoint(x: x, y: y), size: size), inside: container)
                precondition(container.contains(result), "Блок вышел за контейнер")
                precondition(result.size == size, "Вмещающийся блок изменил размер")
            }
        }
        let oversized = TavernDragGeometry.clamped(NSRect(x: -200, y: -200, width: 800, height: 700), inside: container)
        precondition(oversized == container, "Блок после сужения окна должен помещаться целиком")
        print("PASS: весь блок ограничен контейнером, включая сужение контейнера")
        let from = NSRect(x: 40, y: 45, width: 100, height: 40)
        let to = NSRect(x: 270, y: 150, width: 100, height: 40)
        precondition(TavernDragGeometry.settling(from: from, to: to, elapsed: 0, inside: container) == from)
        for frame in 0...120 {
            let result = TavernDragGeometry.settling(from: from, to: to, elapsed: Double(frame) / 240, inside: container)
            precondition(container.contains(result), "Пружинная анимация вышла за границу")
            precondition(result.size == from.size, "Анимация растягивает терминальный снимок")
        }
        precondition(TavernDragGeometry.settling(from: from, to: to, elapsed: 1, inside: container) == to)
        let midpoint = TavernDragGeometry.settling(from: from, to: to, elapsed: 0.18, inside: container)
        precondition(midpoint.minX > (from.minX + to.minX) / 2, "Укладка должна замедляться, а не идти линейно")
        let smaller = NSRect(x: 80, y: 70, width: 120, height: 50)
        for frame in 0...100 {
            let result = TavernDragGeometry.settling(from: from, to: to, elapsed: Double(frame) / 240, inside: smaller)
            precondition(smaller.contains(result), "Сужение контейнера во время пружины выпустило блок наружу")
        }
        print("PASS: пружина нелинейна, завершается точно в цели и не пересекает границы ни на одном кадре")
        precondition(TavernDragGeometry.stackFrames(card: size, count: 0).isEmpty)
        for count in [1, 20] {
            let cardSize = NSSize(width: 208, height: 84)
            let cards = TavernDragGeometry.stackFrames(card: cardSize, count: count)
            precondition(cards.count == count, "Стопка не должна терять участников большой группы")
            let extent = cards.reduce(NSRect.zero) { $0.union($1) }
            let harness = NSRect(x: 0, y: 0, width: extent.maxX, height: extent.maxY + 4)
            let sourceFrames = cards.indices.map {
                NSRect(x: -40, y: 800 - CGFloat($0) * 92, width: cardSize.width, height: cardSize.height)
            }
            for reverse in [false, true] {
                for frame in 0...120 {
                    let progress = CGFloat(frame) / 120
                    // Контейнер сужается прямо во время сборки и возврата.
                    let bounds = frame < 50 ? container : smaller
                    let fittedHarness = TavernDragGeometry.fitted(harness.offsetBy(dx: 1000, dy: -1000), inside: bounds)
                    precondition(bounds.contains(fittedHarness), "Обвязка вышла за границу при сужении")
                    let scale = fittedHarness.width / harness.width
                    let projected = zip(sourceFrames, cards).map { source, card in
                        let target = NSRect(x: fittedHarness.minX + card.minX * scale,
                                            y: fittedHarness.minY + card.minY * scale,
                                            width: card.width * scale, height: card.height * scale)
                        return TavernDragGeometry.flight(from: reverse ? target : source,
                                                         to: reverse ? source : target,
                                                         progress: progress, inside: bounds)
                    }
                    for card in projected {
                        precondition(bounds.contains(card), "Карточка вышла за контейнер во время полёта")
                        precondition(abs(card.width / card.height - cardSize.width / cardSize.height) < 0.0001,
                                     "Сужение и возврат не должны искажать пропорции карточек")
                        precondition(abs(card.width - projected[0].width) < 0.0001
                                     && abs(card.height - projected[0].height) < 0.0001,
                                     "Участники одной стопки должны сохранять одинаковый размер")
                    }
                }
            }
        }
        print("PASS: сборка и возврат одиночной/большой группы ограничены контейнером без потери карточек и искажения")
        movingLandingTarget()
        repeatedLandingTarget()
        resizedLandingContainer()
    }

    static func movingLandingTarget() {
        let bounds = NSRect(x: 0, y: 0, width: 700, height: 600)
        let first = NSRect(x: 400, y: 400, width: 200, height: 84)
        let second = NSRect(x: 40, y: 80, width: 200, height: 84)
        var motion = TavernCardPlacement(frame: NSRect(x: 20, y: 20, width: 200, height: 84))
        for _ in 0..<8 { _ = motion.advance(toward: first, delta: 1.0 / 60, inside: bounds) }
        let before = motion.frame
        _ = motion.advance(toward: second, delta: 0, inside: bounds)
        precondition(motion.frame == before, "Новая цель без прошедшего времени не должна телепортировать карточку")
        _ = motion.advance(toward: second, delta: 1.0 / 60, inside: bounds)
        precondition(motion.frame != before && motion.frame != second, "После смены цели движение продолжается, а не замирает и не прыгает")
        var arrived = false
        for _ in 0..<240 {
            arrived = motion.advance(toward: second, delta: 1.0 / 60, inside: bounds)
            precondition(bounds.contains(motion.frame))
            if arrived { break }
        }
        precondition(arrived && motion.frame == second, "Запоздавшая раскладка должна завершаться точно в последней цели")
        print("PASS: новая цель не создаёт скачок или перезапуск с исходной позиции")
    }

    static func repeatedLandingTarget() {
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 500)
        let target = NSRect(x: 350, y: 350, width: 208, height: 84)
        var motion = TavernCardPlacement(frame: NSRect(x: 20, y: 20, width: 208, height: 84))
        var arrived = false
        for _ in 0..<240 {
            arrived = motion.advance(toward: target, delta: 1.0 / 60, inside: bounds)
            if arrived { break }
        }
        precondition(arrived && motion.frame == target, "Повторные одинаковые snapshot не должны продлевать постановку")
        print("PASS: непрерывные обновления неизменной цели не удерживают карточку в воздухе")
    }

    static func resizedLandingContainer() {
        let target = NSRect(x: 450, y: 450, width: 208, height: 84)
        let small = NSRect(x: 10, y: 20, width: 140, height: 90)
        let large = NSRect(x: 0, y: 0, width: 800, height: 700)
        var motion = TavernCardPlacement(frame: NSRect(x: 60, y: 80, width: 208, height: 84))
        for _ in 0..<8 { _ = motion.advance(toward: target, delta: 1.0 / 60, inside: large) }
        for _ in 0..<80 {
            _ = motion.advance(toward: target, delta: 1.0 / 60, inside: small)
            precondition(small.contains(motion.frame), "Изменение контейнера не должно выпускать карточку наружу")
        }
        precondition(motion.advance(toward: target, delta: 3, inside: large), "Пауза главного потока не должна оставлять незавершённую анимацию")
        precondition(motion.frame == target)
        print("PASS: сужение контейнера и пауза таймера не оставляют промежуточную позицию")
    }
}
