import AppKit
import CoreGraphics
import ImageIO

@main struct GraphicAssetTests {
    static let width = 4, height = 3
    // Include transparent nonzero RGB and partial alpha, not just opaque primaries.
    static let rgba: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 128, 17, 43, 91, 0, 1, 2, 3, 1,
        0, 0, 255, 255, 255, 255, 255, 64, 103, 29, 211, 200, 0, 0, 0, 255,
        33, 67, 99, 240, 220, 170, 20, 32, 128, 128, 128, 127, 255, 0, 255, 255
    ]

    static func rawImage(_ data: Data, channels: Int, space: CGColorSpace,
                         width: Int = GraphicAssetTests.width, height: Int = GraphicAssetTests.height) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: channels * 8,
                bytesPerRow: width * channels, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: channels == 3 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.last.rawValue),
                provider: CGDataProvider(data: data as CFData)!, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func png(_ image: CGImage) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination), "PNG fixture encoding failed")
        return data as Data
    }

    static func raster(_ image: CGImage, background: CGFloat, scale: Int = 1) -> Data {
        let w = image.width * scale, h = image.height * scale
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Data(bytes: context.data!, count: w * h * 4)
    }

    static func equalRaster(_ actual: CGImage, _ expected: CGImage, name: String) {
        precondition(actual.width == expected.width && actual.height == expected.height, name + ": dimensions")
        for scale in [1, 2] {
            for background: CGFloat in [0, 0.37, 1] {
                precondition(raster(actual, background: background, scale: scale) == raster(expected, background: background, scale: scale),
                             "\(name): raster mismatch at \(scale)x on \(background)")
            }
        }
    }

    static func fails(_ asset: GraphicAsset, key: String, name: String) {
        do {
            _ = try GraphicAssetDecoder.decode(asset)
            preconditionFailure(name + ": invalid asset accepted")
        } catch {
            precondition(error.localizedDescription == L(key), "\(name): unexpected error \(error)")
        }
    }

    static func rawFormatsAndOwnership() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for channels in [3, 4] {
            let bytes = channels == 4 ? rgba : stride(from: 0, to: rgba.count, by: 4).flatMap { Array(rgba[$0..<$0 + 3]) }
            let expected = rawImage(Data(bytes), channels: channels, space: space)
            let actual: CGImage = try autoreleasepool {
                var source = Data(bytes)
                let image = try GraphicAssetDecoder.decode(GraphicAsset(id: "owned", width: width, height: height,
                                                                        format: channels == 3 ? 0 : 1, data: source))
                // Mutating/dropping the sender's value must not invalidate the provider.
                source.resetBytes(in: 0..<source.count)
                source.removeAll(keepingCapacity: false)
                return image
            }
            equalRaster(actual, expected, name: "owned \(channels)-channel raw")
        }
        print("PASS: RGB/RGBA sRGB raster and provider lifetime after source mutation/drop")
    }

    static func pngOracleAndOwnership() throws {
        for (name, space) in [("sRGB", CGColorSpace(name: CGColorSpace.sRGB)!),
                              ("ICC Display P3", CGColorSpace(name: CGColorSpace.displayP3)!)] {
            var encoded = png(rawImage(Data(rgba), channels: 4, space: space))
            if name.hasPrefix("ICC") {
                precondition(encoded.range(of: Data("iCCP".utf8)) != nil, "Fixture must contain an embedded ICC profile")
            }
            let expected = NSBitmapImageRep(data: encoded)!.cgImage!
            let actual = try autoreleasepool {
                try GraphicAssetDecoder.decode(GraphicAsset(id: name, width: width, height: height, format: 2, data: encoded))
            }
            encoded.resetBytes(in: 0..<encoded.count)
            encoded.removeAll(keepingCapacity: false)
            equalRaster(actual, expected, name: name + " PNG transparency")
        }
        // The old PNG path uses the encoded dimensions, not the declared metadata dimensions.
        let encoded = png(rawImage(Data(rgba), channels: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        let mismatched = try GraphicAssetDecoder.decode(GraphicAsset(id: "metadata", width: 1, height: 1, format: 2, data: encoded))
        equalRaster(mismatched, NSBitmapImageRep(data: encoded)!.cgImage!, name: "PNG encoded dimensions")
        print("PASS: PNG transparency/ICC matches old AppKit raster on identical targets; owned decoded lifetime")
    }

    static func invalidRawAndPNG() {
        for (name, w, h) in [("zero width", 0, 1), ("negative width", -1, 1),
                              ("zero height", 1, 0), ("negative height", 1, -1),
                              ("oversized width", 32769, 1), ("oversized height", 1, 32769),
                              ("overflow dimensions", Int.max, Int.max)] {
            for format in [0, 1, 2] {
                fails(GraphicAsset(id: name, width: w, height: h, format: format, data: Data()),
                      key: "core.surface.invalidAssetSize", name: "\(name) format \(format)")
            }
        }
        for (name, format, data) in [("short RGB", 0, Data([1, 2])), ("long RGB", 0, Data([1, 2, 3, 4])),
                                     ("short RGBA", 1, Data([1, 2, 3])), ("long RGBA", 1, Data([1, 2, 3, 4, 5])),
                                     ("unknown format", 99, Data([1, 2, 3, 4])), ("negative format", -1, Data()),
                                     ("corrupt PNG", 2, Data("not a PNG".utf8)), ("empty PNG", 2, Data())] {
            fails(GraphicAsset(id: name, width: 1, height: 1, format: format, data: data),
                  key: "core.surface.assetDecodeFailed", name: name)
        }
        let encoded = png(rawImage(Data(rgba), channels: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        fails(GraphicAsset(id: "truncated PNG", width: width, height: height, format: 2, data: encoded.prefix(24)),
              key: "core.surface.assetDecodeFailed", name: "truncated PNG")
        print("PASS: malformed PNG, format, dimensions and exact raw lengths are rejected")
    }

    static func oversizedPNGHeaderPreflight() {
        let encoded = png(rawImage(Data(rgba), channels: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!))
        for offset in [16, 20] {
            var bytes = Array(encoded)
            let oversized: UInt32 = 32769
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: oversized >> (24 - i * 8)) }
            // Recompute IHDR CRC so this is a genuine PNG header, not random corruption.
            var crc: UInt32 = 0xffffffff
            for byte in bytes[12..<29] {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
            }
            crc ^= 0xffffffff
            for i in 0..<4 { bytes[29 + i] = UInt8(truncatingIfNeeded: crc >> (24 - i * 8)) }
            fails(GraphicAsset(id: "oversized IHDR", width: width, height: height, format: 2, data: Data(bytes)),
                  key: "core.surface.invalidAssetSize", name: "oversized actual PNG \(offset == 16 ? "width" : "height") preflight")
        }
        print("PASS: valid-CRC oversized PNG dimensions fail size preflight before raster materialization")
    }

    static func main() throws {
        _ = NSApplication.shared
        precondition(CommandLine.arguments.count > 1 && Bundle(path: CommandLine.arguments[1]) != nil,
                     "Pass the built .app bundle as the first argument")
        try rawFormatsAndOwnership()
        try pngOracleAndOwnership()
        invalidRawAndPNG()
        oversizedPNGHeaderPreflight()
    }
}
