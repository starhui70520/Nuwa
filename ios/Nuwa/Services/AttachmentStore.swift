import Foundation
import UIKit
import UniformTypeIdentifiers

/// Local file storage + HEIC normalization + DeepSeek Files API upload manager (1:1 attachments.ts).
enum AttachmentStore {
    static let maxSizeMB = 64
    static let maxUserDataSizeMB = 32
    static let maxCount = 50

    private static let layoutRecognitionExts: Set<String> = ["pdf", "doc", "docx", "ppt", "pptx"]
    private static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"]

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
        let dir = filesDirectory
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in items {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
