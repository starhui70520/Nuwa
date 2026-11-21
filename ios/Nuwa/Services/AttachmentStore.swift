import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Local file storage + HEIC normalization + memory-cached thumbnail loader (zero main-thread disk I/O jank).
enum AttachmentStore {
    static let maxSizeMB = 64
    static let maxUserDataSizeMB = 32
    static let maxCount = 50
    static let maxImageDimension = 4096

    private static let layoutRecognitionExts: Set<String> = ["pdf", "doc", "docx", "ppt", "pptx"]
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif"]
    private static let supportedDocumentAndCodeExts: Set<String> = [
        // Documents & Office & E-books
        "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "rtf", "epub", "csv", "tsv",
        // Images (HEIC/HEIF/BMP/TIFF/AVIF are normalized to JPEG before upload)
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif", "svg",
        // Text, Markdown, Config, Data
        "txt", "md", "markdown", "json", "jsonl", "json5", "jsonc", "xml", "yaml", "yml",
        "toml", "ini", "conf", "cfg", "env", "log", "html", "htm", "css", "scss", "less",
        "sass", "sql", "graphql", "gql", "proto", "plist", "xcconfig", "pbxproj", "tex", "bib",
        // Source Code
        "swift", "m", "mm", "h", "hh", "hpp", "hxx", "c", "cc", "cpp", "cxx", "cs", "csx",
        "java", "kt", "kts", "scala", "groovy", "gradle", "go", "rs", "py", "py3", "pyi",
        "rb", "php", "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "vue", "svelte",
        "dart", "ets", "wxml", "wxss", "wxs", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        "lua", "r", "pl", "pm", "ex", "exs", "erl", "hs", "clj", "cljs", "lisp", "el",
        "cmake", "dockerfile", "makefile", "diff", "patch", "asm", "s", "v", "sv", "vhd", "zig",
    ]
    private static let unsupportedBinaryExts: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso", "pkg", "deb", "rpm",
        "exe", "dll", "so", "dylib", "a", "o", "bin", "class", "jar", "war", "apk", "ipa", "hap",
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "mp4", "mov", "avi", "mkv", "webm", "wmv",
        "ttf", "otf", "woff", "woff2", "eot", "sqlite", "db", "psd", "ai", "sketch", "fig",
    ]

    static func isLikelyUTF8Text(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { return false }
        let sample = data.prefix(4096)
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil
    }

    static func normalizedChatFileForZipEntry(name: String, data: Data) -> (fileName: String, isImage: Bool)? {
        let ext = fileExtension(of: name)
        if !ext.isEmpty {
            if unsupportedBinaryExts.contains(ext) {
                return nil
            }
            if supportedDocumentAndCodeExts.contains(ext) {
                return (name, isImageName(name))
            }
            if isLikelyUTF8Text(data) {
                return (name, false)
            }
            return nil
        }
        // Extensionless UTF-8 text files (e.g., README, LICENSE, Makefile, Dockerfile)
        if isLikelyUTF8Text(data) {
            return ("\(name).txt", false)
        }
        return nil
    }

    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    static var filesDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Nuwa/files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileExtension(of name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }

    static func isImageName(_ name: String) -> Bool {
        imageExts.contains(fileExtension(of: name))
    }

    static func uploadPurpose(fileName: String, isImage: Bool) -> String? {
        if isImage { return nil }
        return layoutRecognitionExts.contains(fileExtension(of: fileName))
            ? "rich_layout_recognition"
            : "user_data"
    }

    static func localURL(for attachment: FileAttachment) -> URL? {
        guard let fileName = attachment.localFileName else { return nil }
        return filesDirectory.appendingPathComponent(fileName)
    }

    private static func loadThumbnail(for attachment: FileAttachment, maxPixels: Int) -> UIImage? {
        guard attachment.isImage, let fileName = attachment.localFileName else { return nil }
        let key = "\(fileName)@\(maxPixels)" as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        guard let url = localURL(for: attachment),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels
              ] as CFDictionary)
        else { return nil }

        let thumb = UIImage(cgImage: image)
        thumbnailCache.setObject(thumb, forKey: key, cost: image.bytesPerRow * image.height)
        return thumb
    }

    static func thumbnail(for attachment: FileAttachment, maxPixels: Int) async -> UIImage? {
        await Task.detached(priority: .utility) {
            loadThumbnail(for: attachment, maxPixels: maxPixels)
        }.value
    }

    /// Full-resolution image for Lightbox preview only.
    static func loadLocalImage(for attachment: FileAttachment) -> UIImage? {
        guard attachment.isImage, let url = localURL(for: attachment),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return UIImage(data: data)
    }

    /// Sniffs actual file magic bytes for DeepSeek Messages API natively supported image formats
    /// (JPEG / PNG / GIF / WebP), matching Android `6ba574f` (`sniffApiSupportedImageMime`).
    static func sniffApiSupportedImageMime(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let header = [UInt8](data.prefix(12))
        if header.count >= 3 && header[0] == 0xFF && header[1] == 0xD8 && header[2] == 0xFF {
            return "image/jpeg"
        }
        if header.count >= 8
            && header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47
            && header[4] == 0x0D && header[5] == 0x0A && header[6] == 0x1A && header[7] == 0x0A {
            return "image/png"
        }
        if header.count >= 6 {
            let prefix6 = String(bytes: header.prefix(6), encoding: .ascii)
            if prefix6 == "GIF87a" || prefix6 == "GIF89a" {
                return "image/gif"
            }
        }
        if header.count >= 12 {
            let riff = String(bytes: header[0..<4], encoding: .ascii)
            let webp = String(bytes: header[8..<12], encoding: .ascii)
            if riff == "RIFF" && webp == "WEBP" {
                return "image/webp"
            }
        }
        return nil
    }

    /// Reads pixel dimensions from image headers without decoding the full bitmap.
    private static func imagePixelDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawW = props[kCGImagePropertyPixelWidth] as? Int,
              let rawH = props[kCGImagePropertyPixelHeight] as? Int,
              rawW > 0, rawH > 0
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        if (5...8).contains(orientation) {
            return (rawH, rawW)
        }
        return (rawW, rawH)
    }

    /// Normalizes images before upload (matching Android v0.1.33):
    /// - Transcodes non-standard formats (HEIC/HEIF/AVIF/BMP/TIFF) to JPEG (0.92);
    /// - Proportionally downscales any image whose width or height exceeds 4096px (e.g. long screenshots)
    ///   via memory-safe `CGImageSourceCreateThumbnailAtIndex` so DeepSeek API never rejects with `too large to process`;
    /// - Leaves standard-format images within 4096px untouched and lossless.
    static func normalizeImageForUpload(data: Data, fileName: String) -> (data: Data, fileName: String, mimeType: String) {
        let supportedMime = sniffApiSupportedImageMime(data)
        let dims = imagePixelDimensions(data)
        let needsResize = dims.map { $0.width > maxImageDimension || $0.height > maxImageDimension } ?? false

        if let supportedMime, !needsResize {
            return (data, fileName, supportedMime)
        }

        let jpegName: String = {
            let stem = (fileName as NSString).deletingPathExtension
            return stem.isEmpty ? "\(fileName).jpg" : "\(stem).jpg"
        }()

        if needsResize,
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: maxImageDimension
           ] as CFDictionary),
           let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92),
           !jpeg.isEmpty {
            return (jpeg, jpegName, "image/jpeg")
        }

        if let uiImage = UIImage(data: data) {
            let pixelW = uiImage.size.width * uiImage.scale
            let pixelH = uiImage.size.height * uiImage.scale
            let maxSide = max(pixelW, pixelH)
            let outputImage: UIImage
            if maxSide > CGFloat(maxImageDimension), maxSide > 0 {
                let scale = CGFloat(maxImageDimension) / maxSide
                let targetSize = CGSize(
                    width: max(1, floor(pixelW * scale)),
                    height: max(1, floor(pixelH * scale))
                )
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                outputImage = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                    uiImage.draw(in: CGRect(origin: .zero, size: targetSize))
                }
            } else {
                outputImage = uiImage
            }
            if let jpeg = outputImage.jpegData(compressionQuality: 0.92), !jpeg.isEmpty {
                return (jpeg, jpegName, "image/jpeg")
            }
        }
        return (data, fileName, supportedMime ?? inferMimeType(fileName: fileName, isImage: true))
    }

    static func saveLocally(data: Data, originalName: String, isImage: Bool) throws -> (FileAttachment, Data) {
        var finalData = data
        var finalName = originalName
        var mimeType = inferMimeType(fileName: originalName, isImage: isImage)

        if isImage {
            let normalized = normalizeImageForUpload(data: data, fileName: originalName)
            finalData = normalized.data
            finalName = normalized.fileName
            mimeType = normalized.mimeType
        }

        let id = UUID().uuidString
        let ext = fileExtension(of: finalName)
        let localFileName = ext.isEmpty ? id : "\(id).\(ext)"
        let targetURL = filesDirectory.appendingPathComponent(localFileName)
        try finalData.write(to: targetURL, options: [.atomic])

        let attachment = FileAttachment(
            id: id,
            serverId: nil,
            name: finalName,
            size: finalData.count,
            isImage: isImage,
            mimeType: mimeType,
            localFileName: localFileName
        )
        return (attachment, finalData)
    }

    static func inferMimeType(fileName: String, isImage: Bool) -> String {
        let ext = fileExtension(of: fileName)
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }
        return isImage ? "image/jpeg" : "application/octet-stream"
    }

    static func formatByteSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }

    static func deleteAllLocalFiles() {
        thumbnailCache.removeAllObjects()
        let dir = filesDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in items {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

struct AttachmentThumbnail<Content: View>: View {
    let file: FileAttachment
    let pointSize: CGFloat
    @ViewBuilder let content: (UIImage?) -> Content
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: (key: String, image: UIImage?)?

    var body: some View {
        let maxPixels = max(1, Int((pointSize * displayScale).rounded(.up)))
        let key = "\(file.localFileName ?? file.id)@\(maxPixels)"
        content(loaded?.key == key ? loaded?.image : nil)
            .task(id: key) {
                guard file.isImage, file.localFileName != nil else { return }
                let image = await AttachmentStore.thumbnail(for: file, maxPixels: maxPixels)
                if !Task.isCancelled { loaded = (key, image) }
            }
    }
}
