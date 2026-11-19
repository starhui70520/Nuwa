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

    private static let layoutRecognitionExts: Set<String> = ["pdf", "doc", "docx", "ppt", "pptx"]
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"]

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

    static func saveLocally(data: Data, originalName: String, isImage: Bool) throws -> (FileAttachment, Data) {
        var finalData = data
        var finalName = originalName
        var mimeType = inferMimeType(fileName: originalName, isImage: isImage)

        if isImage {
            let ext = fileExtension(of: originalName)
            if ext == "heic" || ext == "heif" || ext == "bmp" || mimeType == "image/heic" {
                if let uiImage = UIImage(data: data), let jpeg = uiImage.jpegData(compressionQuality: 0.88) {
                    finalData = jpeg
                    let stem = (originalName as NSString).deletingPathExtension
                    finalName = "\(stem).jpg"
                    mimeType = "image/jpeg"
                }
            }
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
