import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImage {
    struct Packed { let data: Data; let mime: String }

    static func pngForCLI(_ data: Data) throws -> Data {
        let (source, type, _) = try inspect(data)
        if type == UTType.png.identifier { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw invalid() }
        return try encode(image, type: UTType.png.identifier, properties: [:])
    }

    static func forAnalysis(_ data: Data, maxDimension: Int = 3072, preserveText: Bool = false) throws -> Packed {
        let (source, type, dimensions) = try inspect(data)
        if preserveText {
            if type == UTType.jpeg.identifier { return Packed(data: data, mime: "image/jpeg") }
            return Packed(data: try pngForCLI(data), mime: "image/png")
        }
        let largest = max(dimensions.width, dimensions.height)
        let resize = largest > maxDimension
        if !resize, type == UTType.jpeg.identifier { return Packed(data: data, mime: "image/jpeg") }
        if !resize, type == UTType.png.identifier, data.count < 200_000 {
            return Packed(data: data, mime: "image/png")
        }
        let image: CGImage?
        if resize {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: maxDimension]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { throw invalid() }
        let photo = type == UTType.jpeg.identifier || type == UTType.heic.identifier
        if photo {
            return Packed(data: try encode(image, type: UTType.jpeg.identifier,
                                           properties: [kCGImageDestinationLossyCompressionQuality: 0.9]),
                          mime: "image/jpeg")
        }
        // Keep transparency lossless and only use JPEG when it substantially reduces the payload.
        if data.count >= 200_000, isOpaque(image) {
            let jpeg = try encode(image, type: UTType.jpeg.identifier,
                                  properties: [kCGImageDestinationLossyCompressionQuality: 0.9])
            if jpeg.count * 2 < data.count { return Packed(data: jpeg, mime: "image/jpeg") }
        }
        if !resize, type == UTType.png.identifier { return Packed(data: data, mime: "image/png") }
        return Packed(data: try encode(image, type: UTType.png.identifier, properties: [:]), mime: "image/png")
    }

    private static func isOpaque(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return true
        case .alphaOnly: return false
        default: break
        }
        // An alpha channel may contain transparency anywhere in the image.
        return false
    }

    static func instructionNeedsTextDetail(_ instruction: String) -> Bool {
        let words = ["текст", "надпис", "прочт", "читай", "читать", "букв", "символ", "перев",
                     "напис", "цифр", "номер", "код", "распоз", "text", "read", "word", "letter",
                     "translat", "ocr", "number", "digit", "caption"]
        let lower = instruction.lowercased()
        return words.contains { lower.contains($0) }
    }

    private static func inspect(_ data: Data) throws -> (CGImageSource, String, (width: Int, height: Int)) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw invalid() }
        return (source, type, (width, height))
    }

    private static func encode(_ image: CGImage, type: String, properties: [CFString: Any]) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw invalid() }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw invalid() }
        return data as Data
    }

    private static func invalid() -> DictationError { DictationError("Не удалось прочитать изображение из буфера обмена.") }
}
