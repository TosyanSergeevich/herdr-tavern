import AppKit

/// Construction is independent of selection and list position. Coordinates are points, Y down.
enum TavernPlankConstruction: String, Hashable {
    case agent, workspace
}

final class TavernPlankMaps: NSObject {
    let contexts: [CGContext]
    init(_ contexts: [CGContext]) { self.contexts = contexts }
}

/// One decoded artistic source; only card-sized, premultiplied maps reach Metal.
final class TavernPlankMaterial {
    private let atlas: CGContext
    private let atlasBytes: UnsafeMutablePointer<UInt8>

    init(atlas image: CGImage) throws {
        let decoded = try Self.context(width: image.width, height: image.height)
        decoded.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        atlas = decoded
        atlasBytes = decoded.data!.assumingMemoryBound(to: UInt8.self)
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw TavernCardResourceError.invalid(L("core.card.insufficientMemory", width, height))
        }
        context.interpolationQuality = .high
        return context
    }

    private struct Board {
        let x: Float, y: Float, zoom: Float, tone: Float, warmth: Float
        let crown: Float, tilt: Float
    }

    private static func random(_ seed: UInt64, _ channel: UInt64) -> Float {
        var value = seed &+ channel &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Float(value >> 40) / Float(1 << 24)
    }

    private func board(seed: UInt64, index: UInt64) -> Board {
        let channel = index * 11
        // Reserve enough space for ordinary card widths without a mirrored join.
        // Origins never depend on geometry, so resizing reveals the same plank.
        return Board(x: Self.random(seed, channel + 1) * Float(atlas.width) * 0.18,
            y: Self.random(seed, channel + 2) * Float(atlas.height) * 0.75,
            zoom: 2.0 + Self.random(seed, channel + 3) * 0.9,
            tone: 0.91 + Self.random(seed, channel + 4) * 0.16,
            warmth: (Self.random(seed, channel + 5) - 0.5) * 0.055,
            crown: 0.9 + Self.random(seed, channel + 6) * 0.9,
            tilt: (Self.random(seed, channel + 7) - 0.5) * 0.05)
    }

    private func sample(x: Float, y: Float) -> SIMD3<Float> {
        // Mirroring keeps arbitrary-width cards continuous without stretching the grain.
        func coordinate(_ value: Float, _ size: Int) -> Float {
            let edge = Float(size - 1)
            let period = edge * 2
            let wrapped = value.truncatingRemainder(dividingBy: period)
            let positive = wrapped < 0 ? wrapped + period : wrapped
            return positive > edge ? period - positive : positive
        }
        let px = coordinate(x, atlas.width), py = coordinate(y, atlas.height)
        let x0 = Int(px), y0 = Int(py)
        let x1 = min(x0 + 1, atlas.width - 1), y1 = min(y0 + 1, atlas.height - 1)
        func colour(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let offset = y * atlas.bytesPerRow + x * 4
            return SIMD3(Float(atlasBytes[offset]), Float(atlasBytes[offset + 1]),
                         Float(atlasBytes[offset + 2])) / 255
        }
        let tx = px - Float(x0), ty = py - Float(y0)
        let top = colour(x0, y0) * (1 - tx) + colour(x1, y0) * tx
        let bottom = colour(x0, y1) * (1 - tx) + colour(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    func build(seed: UInt64, construction: TavernPlankConstruction,
               width: Int, height: Int, pointSize: CGSize) throws -> TavernPlankMaps {
        let contexts = try (0..<4).map { _ in try Self.context(width: width, height: height) }
        let pixels = contexts.map { $0.data!.assumingMemoryBound(to: UInt8.self) }
        let stepX = Float(pointSize.width) / Float(width)
        let stepY = Float(pointSize.height) / Float(height)
        let pointWidth = Float(pointSize.width), pointHeight = Float(pointSize.height)
        let sceneScale = min(1, pointHeight / 140)
        let first = board(seed: seed, index: 0), second = board(seed: seed, index: 1)
        // Surface inset is 3pt. Both seams lie between native text rows, never under glyphs.
        let twoBoards = construction == .agent && Self.random(seed, 30) > 0.24
        let seam = (Self.random(seed, 31) < 0.5 ? Float(29) : Float(48))
            + (Self.random(seed, 32) - 0.5) * 0.6
        let seamWidth = 0.38 + Self.random(seed, 33) * 0.25
        let phase = Self.random(seed, 34) * .pi * 2
        let glintX = 0.12 + Self.random(seed, 35) * 0.72
        let glintY = 0.18 + Self.random(seed, 36) * 0.64
        let jointStep = 0.45 + Self.random(seed, 37) * 0.4
        // Один профиль вдоль стыка, а не повторные sin для каждого пикселя карты.
        let jointProfile: [Float] = twoBoards ? (0..<width).map { column in
            let x = (Float(column) + 0.5) * stepX
            return seam + sin(x * 0.11 + phase) * 0.1 + sin(x * 0.37 + phase) * 0.05
        } : []
        let columnX: [Float] = (0..<width).map { (Float($0) + 0.5) * stepX }
        let columnEdgeX: [Float] = columnX.map { min($0, pointWidth - $0) }
        let leftColumns = (0..<width).map { max(0, $0 - 1) }
        let rightColumns = (0..<width).map { min(width - 1, $0 + 1) }
        let dxDenominators: [Float] = (0..<width).map {
            Float(max(1, rightColumns[$0] - leftColumns[$0])) * stepX
        }
        let aboveRows = (0..<height).map { max(0, $0 - 1) }
        let belowRows = (0..<height).map { min(height - 1, $0 + 1) }
        let dyDenominators: [Float] = (0..<height).map {
            Float(max(1, belowRows[$0] - aboveRows[$0])) * stepY
        }
        let columnGlint: [Float] = columnX.map {
            exp(-pow(($0 - pointWidth * glintX) / 11, 2))
        }
        let rowGlint: [Float] = (0..<height).map { row in
            let y = (Float(row) + 0.5) * stepY
            return exp(-pow((y - pointHeight * glintY) / 5, 2))
        }
        var elevations = [Float](repeating: 0, count: width * height)

        func smooth(_ a: Float, _ b: Float, _ value: Float) -> Float {
            let t = max(0, min(1, (value - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        func store(_ kind: Int, _ offset: Int, _ colour: SIMD3<Float>, _ alpha: Float) {
            let pointer = pixels[kind]
            pointer[offset] = UInt8(max(0, min(255, colour.x * alpha * 255)).rounded())
            pointer[offset + 1] = UInt8(max(0, min(255, colour.y * alpha * 255)).rounded())
            pointer[offset + 2] = UInt8(max(0, min(255, colour.z * alpha * 255)).rounded())
            pointer[offset + 3] = UInt8((alpha * 255).rounded())
        }

        for row in 0..<height {
            let y = (Float(row) + 0.5) * stepY
            // Общая пологая дуга всей деревянной вставки, не отдельные «волны»
            // у каждой доски. Верх и низ утоплены относительно середины.
            let faceY = max(0, min(1, (y - 2.5) / max(1, pointHeight - 5)))
            let arch = 4 * faceY * (1 - faceY)
            let faceCrown = min(3, pointHeight * 0.06) * arch
            // Широкая мягкая полутень в углублениях у верхней и нижней рамки.
            // Профиль непрерывен; никаких полос и зависимости от hover.
            let recessedShade = 0.62 + 0.43 * pow(arch, 0.7)
            for column in 0..<width {
                let x = columnX[column]
                let joint = twoBoards ? jointProfile[column] : pointHeight
                let lowerBoard = twoBoards && y > joint
                let plank = lowerBoard ? second : first
                let localY = lowerBoard ? y - joint : y
                let boardHeight = lowerBoard ? pointHeight - joint : joint
                let t = max(0, min(1, localY / max(1, boardHeight)))
                // Пологая выпуклость и малый наклон меняют нормали, но не текстуру
                // или силуэт. У каждой доски своя форма, закреплённая за seed.
                let crown = plank.crown * min(1, boardHeight / 28) * 4 * t * (1 - t)
                let lean = plank.tilt * (localY - boardHeight * 0.5)
                let index = row * width + column, offset = index * 4
                let edgeX = columnEdgeX[column], edgeY = min(y, pointHeight - y)
                let distance = min(min(edgeX, edgeY), (edgeX + edgeY - 4.5) * 0.7071068) - 0.7
                let alpha = smooth(-max(stepX, stepY) * 0.5, max(stepX, stepY) * 0.5, distance)
                let source = sample(x: plank.x + x * plank.zoom, y: plank.y + localY * plank.zoom)
                let luminance = source.x * 0.2126 + source.y * 0.7152 + source.z * 0.0722
                var colour = source * plank.tone * SIMD3(1 + plank.warmth, 1, 1 - plank.warmth)
                // Волокна остаются микрорельефом; крупная форма задаётся отдельно.
                var elevation: Float = 2.6 + faceCrown + crown * 0.35 + lean * 0.4
                    + (luminance - 0.25) * 0.18
                if lowerBoard { elevation -= jointStep }
                var material = SIMD3<Float>(0.87, 0.035, 0)
                if twoBoards {
                    let gap = abs(y - joint)
                    // Верхняя доска нависает; более широкая фаска нижней смотрит вверх.
                    let bevel = smooth(seamWidth * 0.5, seamWidth * 0.5 + (lowerBoard ? 1.45 : 0.55), gap)
                    elevation -= (1 - bevel) * (lowerBoard ? 1.05 : 0.55)
                    colour *= 0.34 + smooth(0, seamWidth * 0.6, gap) * 0.66
                    if lowerBoard {
                        let exposed = (1 - bevel) * smooth(0, seamWidth * 0.6, gap)
                        colour *= SIMD3(1.0 + exposed * 0.28, 1.0 + exposed * 0.20, 1.0 + exposed * 0.10)
                        // Тонкая контактная тень под нависающей доской, без внешнего ореола.
                        colour *= 1 - 0.16 * exp(-max(0, gap - seamWidth * 0.5) / 1.1)
                    }
                    material.x = 0.9 - bevel * 0.03
                }
                // A narrow continuous chamfer, not a painted uniform outline.
                if distance < 1.85 {
                    let outer = smooth(0, 0.78, distance)
                    let inner = smooth(1.2, 1.85, distance)
                    elevation = 1.3 + outer * 3.3 - inner * 2.0
                    let patina = sin(x * 0.093 + sin(y * 0.23 + phase) * 1.6 + phase)
                        * sin(y * 0.17 + x * 0.018 + phase) * 0.045
                    let face: Float = 0.66 + 0.29 * outer - 0.22 * inner
                    colour = SIMD3<Float>(0.43 + patina, 0.285 + patina * 0.7, 0.145 + patina * 0.35) * face
                    // Only short, local polished scars; the shader supplies their actual lighting.
                    let topGlint = columnGlint[column] * (1 - smooth(1, 2.4, y))
                    let sideGlint = rowGlint[row]
                        * (1 - smooth(1, 2.4, pointWidth - x))
                    let polish = min(1, topGlint + sideGlint * 0.55)
                    colour += SIMD3<Float>(0.18, 0.14, 0.075) * polish
                    material = SIMD3(0.48 - polish * 0.2 + abs(patina), 0.8, 0)
                } else {
                    // Recessed wood and a contact shadow beneath the inner metal lip.
                    colour *= 0.66 + smooth(1.85, 4.2, distance) * 0.34
                    colour *= recessedShade
                }
                elevations[index] = elevation
                store(0, offset, colour, alpha)
                store(3, offset, material, alpha)
            }
        }
        // Derive both maps from the same point-space surface. +Y points down, so a rising
        // top bevel has a negative-Y normal and genuinely catches the overhead light.
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column, offset = index * 4
                let left = leftColumns[column], right = rightColumns[column]
                let above = aboveRows[row], below = belowRows[row]
                let dx = (elevations[row * width + right] - elevations[row * width + left])
                    / dxDenominators[column]
                let dy = (elevations[below * width + column] - elevations[above * width + column])
                    / dyDenominators[row]
                let inverseLength = 1 / sqrt(dx * dx + dy * dy + 1)
                let normal = SIMD3(-dx, -dy, 1) * inverseLength
                let alpha = Float(pixels[0][offset + 3]) / 255
                store(1, offset, SIMD3(repeating: elevations[index] / (sceneScale * 32)), alpha)
                store(2, offset, normal * 0.5 + SIMD3(repeating: 0.5), alpha)
            }
        }
        return TavernPlankMaps(contexts)
    }
}
