import Foundation
import CoreGraphics
import ImageIO

enum GraphicAssetDecoder {
    static func decode(_ asset: GraphicAsset) throws -> CGImage {
        try validateSize(width: asset.width, height: asset.height)
        if asset.format == 2 { return try decodePNG(asset.data) }

        let channels = asset.format == 0 ? 3 : 4
        guard asset.format == 0 || asset.format == 1,
              asset.data.count == asset.width * asset.height * channels,
              let provider = CGDataProvider(data: asset.data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: asset.width, height: asset.height, bitsPerComponent: 8,
                                  bitsPerPixel: channels * 8, bytesPerRow: asset.width * channels,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: channels == 3 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw NativeError.message(L("core.surface.assetDecodeFailed"))
        }
        return image
    }

    private static func validateSize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 32768, height <= 32768 else {
            throw NativeError.message(L("core.surface.invalidAssetSize"))
        }
    }

    private static func decodePNG(_ data: Data) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw NativeError.message(L("core.surface.assetDecodeFailed"))
        }
        // Header dimensions must be bounded before ImageIO allocates the raster.
        try validateSize(width: width.intValue, height: height.intValue)
        let options = [kCGImageSourceShouldCache: true,
                       kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, options),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let space = decoded.colorSpace,
              let decodedProvider = decoded.dataProvider,
              let pixels = decodedProvider.data else {
            throw NativeError.message(L("core.surface.assetDecodeFailed"))
        }
        try validateSize(width: decoded.width, height: decoded.height)

        // Copying the decoded provider reads all raster bytes now. Rebuilding the
        // image from that owned CFData removes the ImageIO/source dependency;
        // cacheImmediately alone is not the ownership/materialization guarantee.
        // Preserve the native sample layout and ICC space rather than drawing
        // through a context, which would premultiply alpha or convert colors.
        guard CFDataGetLength(pixels) >= decoded.bytesPerRow * decoded.height,
              let provider = CGDataProvider(data: pixels),
              let image = CGImage(width: decoded.width, height: decoded.height,
                                  bitsPerComponent: decoded.bitsPerComponent,
                                  bitsPerPixel: decoded.bitsPerPixel, bytesPerRow: decoded.bytesPerRow,
                                  space: space, bitmapInfo: decoded.bitmapInfo,
                                  provider: provider, decode: decoded.decode,
                                  shouldInterpolate: decoded.shouldInterpolate, intent: decoded.renderingIntent) else {
            throw NativeError.message(L("core.surface.assetDecodeFailed"))
        }
        return image
    }
}
