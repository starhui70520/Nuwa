import Foundation
import Photos
import UIKit

struct RecentPhotoAsset: Identifiable, Equatable {
    let id: String
    let fileName: String
}

/// PhotoKit recent photos loader powering the DeepSeek-style horizontal quick-pick strip inside the attachment drawer.
@MainActor
final class RecentPhotosStore: ObservableObject {
    @Published private(set) var items: [RecentPhotoAsset] = []
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var permissionDenied = false

    private var assetsById: [String: PHAsset] = [:]
    private var loadGeneration = 0

    func loadRecentPhotos(limit: Int = 16) {
        loadGeneration += 1
        let gen = loadGeneration
        isLoading = true
        permissionDenied = false

        Task {
            let status = await requestPhotoPermissionIfNeeded()
            guard gen == self.loadGeneration else { return }
            guard status == .authorized || status == .limited else {
                self.items = []
                self.assetsById = [:]
                self.permissionDenied = (status == .denied || status == .restricted)
                self.isLoading = false
                return
            }

            let fetched: [(asset: PHAsset, item: RecentPhotoAsset)] = await Task.detached(priority: .userInitiated) {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                options.fetchLimit = max(1, min(limit, 32))
                let result = PHAsset.fetchAssets(with: .image, options: options)
                var list: [(PHAsset, RecentPhotoAsset)] = []
                list.reserveCapacity(result.count)
                result.enumerateObjects { asset, idx, _ in
                    let rawName = PHAssetResource.assetResources(for: asset).first?.originalFilename
                    let name = (rawName?.isEmpty == false ? rawName! : "photo_\(idx).jpg")
                    list.append((asset, RecentPhotoAsset(id: asset.localIdentifier, fileName: name)))
                }
                return list
            }.value

            guard gen == self.loadGeneration else { return }
            var map: [String: PHAsset] = [:]
            for pair in fetched {
                map[pair.item.id] = pair.asset
            }
            self.assetsById = map
            self.items = fetched.map(\.item)
            self.isLoading = false

            let targetPixels = CGSize(width: 220, height: 220)
            let reqOpts = PHImageRequestOptions()
            reqOpts.deliveryMode = .opportunistic
            reqOpts.resizeMode = .fast
            reqOpts.isNetworkAccessAllowed = true
            let manager = PHImageManager.default()

            for pair in fetched {
                let assetId = pair.item.id
                if self.thumbnails[assetId] != nil { continue }
                manager.requestImage(
                    for: pair.asset,
                    targetSize: targetPixels,
                    contentMode: .aspectFill,
                    options: reqOpts
                ) { [weak self] image, _ in
                    guard let image else { return }
                    Task { @MainActor [weak self] in
                        guard let self, gen == self.loadGeneration else { return }
                        self.thumbnails[assetId] = image
                    }
                }
            }
        }
    }

    func loadFullImageData(assetId: String) async -> (data: Data, fileName: String)? {
        let asset: PHAsset?
        if let cached = assetsById[assetId] {
            asset = cached
        } else {
            asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject
        }
        guard let asset else { return nil }
        let fallbackName = items.first(where: { $0.id == assetId })?.fileName
            ?? "photo_\(Int(Date().timeIntervalSince1970)).jpg"

        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            let lock = NSLock()
            var resumed = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, _ in
                lock.lock()
                if resumed {
                    lock.unlock()
                    return
                }
                resumed = true
                lock.unlock()
                guard let data, !data.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                var fileName = fallbackName
                if !fileName.contains(".") {
                    let ext: String
                    if let uti = dataUTI?.lowercased(), uti.contains("png") {
                        ext = "png"
                    } else if let uti = dataUTI?.lowercased(), uti.contains("heic") || uti.contains("heif") {
                        ext = "heic"
                    } else {
                        ext = "jpg"
                    }
                    fileName = "\(fileName).\(ext)"
                }
                continuation.resume(returning: (data, fileName))
            }
        }
    }

    private func requestPhotoPermissionIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}
