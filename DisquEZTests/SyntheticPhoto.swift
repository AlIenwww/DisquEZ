import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SyntheticPhoto {
    static func make(in directory: URL, name: String = UUID().uuidString, width: Int = 800, height: Int = 600,
                     seed: UInt64 = 19, quality: Double = 1, heic: Bool = false, orientation: Int = 1) throws -> URL {
        var random = seed
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                let noise = Int((random >> 40) & 31)
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((x * 180 / width + noise) % 256)
                pixels[offset + 1] = UInt8((y * 180 / height + noise) % 256)
                pixels[offset + 2] = UInt8(((x / max(1, width / 9) + y / max(1, height / 7)) % 2) * 170 + noise)
                pixels[offset + 3] = 255
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name).appendingPathExtension(heic ? "heic" : "jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, (heic ? UTType.heic.identifier : UTType.jpeg.identifier) as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:06:01 12:00:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N",
                                          kCGImagePropertyGPSLongitude: 121.5, kCGImagePropertyGPSLongitudeRef: "E"]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}
