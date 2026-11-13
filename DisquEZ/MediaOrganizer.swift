import ImageIO
import CoreML
import Observation
import os
import Photos
import Vision

struct MediaMember: Identifiable {
    let snapshot: PhotoSnapshot
    let digest: ResourceDigest
    let isVideo: Bool
    var id: String { snapshot.identifier }
    var photo: PHAsset? { PhotoLibrary.fetch(id) }
}

struct MediaGroup: Identifiable {
    enum Kind: String { case exact = "完全重复", similar = "可能相似" }
    let id = UUID()
    let kind: Kind
    let members: [MediaMember]
}

struct GroupSelection {
    private(set) var keeper: String?
    private(set) var removals: Set<String> = []
    mutating func keep(_ id: String) { keeper = id; removals = [] }
    mutating func toggle(_ id: String) {
        guard let keeper, id != keeper else { return }
        if !removals.insert(id).inserted { removals.remove(id) }
    }
    func isValid(for group: MediaGroup) -> Bool {
        guard let keeper, !removals.isEmpty, !removals.contains(keeper) else { return false }
        let ids = Set(group.members.map(\.id))
        return ids.contains(keeper) && removals.isSubset(of: ids)
    }
}

struct VisualSignature {
    let hash: UInt64
    let aspect: Double
    let feature: VNFeaturePrintObservation

    static func make(_ url: URL) throws -> VisualSignature {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { throw CompressionError.unreadable }
        var pixels = [UInt8](repeating: 0, count: 9 * 8)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 9, height: 8, bitsPerComponent: 8,
                                          bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard rendered else { throw CompressionError.unreadable }
        var hash: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 where pixels[y * 9 + x] > pixels[y * 9 + x + 1] { hash |= 1 << (y * 8 + x) } }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFit
        #if targetEnvironment(simulator)
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
        #endif
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let feature = request.results?.first else { throw CompressionError.unreadable }
        return VisualSignature(hash: hash, aspect: Double(image.width) / Double(image.height), feature: feature)
    }
    var bucketKeys: [Int] { (0..<8).map { ($0 << 8) | Int((hash >> ($0 * 8)) & 255) } }
    func resembles(_ other: VisualSignature) -> Bool {
        guard abs(aspect - other.aspect) <= 0.08, (hash ^ other.hash).nonzeroBitCount <= 7 else { return false }
        var distance: Float = 0
        guard (try? feature.computeDistance(&distance, to: other.feature)) != nil else { return false }
        return distance.isFinite && distance <= 0.22
    }
}

struct MediaScanResult {
    let members: [MediaMember]
    let groups: [MediaGroup]
    let protectedCount: Int
    let cloudCount: Int
    let unreadableCount: Int
    let similarityUnavailableCount: Int
}

enum MediaAnalysis {
    static func scan(_ assets: [PHAsset], progress: @escaping @MainActor (Int, Int, String) -> Void) async throws -> MediaScanResult {
        var members: [MediaMember] = []
        var signatures: [String: VisualSignature] = [:]
        var protected = 0, cloud = 0, unreadable = 0, similarityUnavailable = 0
        for (index, photo) in assets.enumerated() {
            try Task.checkCancellation()
            await progress(index, assets.count, "读取本机素材")
            if MediaLibrary.protectionReason(photo) != nil { protected += 1; continue }
            let temporary = URL.temporaryDirectory.appending(path: UUID().uuidString + ".image")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let resource = try MediaLibrary.resource(photo)
                let before = PhotoSnapshot(photo)
                let digest = try await MediaResourceRead.read(resource, to: photo.mediaType == .image ? temporary : nil)
                try Task.checkCancellation()
                guard let latest = PhotoLibrary.fetch(photo.localIdentifier), before.matches(latest) else { unreadable += 1; continue }
                members.append(MediaMember(snapshot: before, digest: digest, isVideo: photo.mediaType == .video))
                if photo.mediaType == .image {
                    do { signatures[photo.localIdentifier] = try autoreleasepool { try VisualSignature.make(temporary) } }
                    catch { similarityUnavailable += 1 }
                }
            } catch is CancellationError { throw CancellationError() }
            catch CompressionError.cloudOnly { cloud += 1 }
            catch CompressionError.insufficientSpace(let bytes) { throw CompressionError.insufficientSpace(bytes) }
            catch { unreadable += 1 }
        }
        let exact = exactGroups(members)
        let exactIDs = Set(exact.flatMap { $0.members.map(\.id) })
        var clusters: [[MediaMember]] = []
        var buckets: [Int: Set<Int>] = [:]
        let candidates = members.filter { !$0.isVideo && !exactIDs.contains($0.id) }
        for (index, member) in candidates.enumerated() {
            try Task.checkCancellation()
            await progress(index, candidates.count, "比对相似照片")
            guard let signature = signatures[member.id] else { continue }
            let possible = signature.bucketKeys.reduce(into: Set<Int>()) { $0.formUnion(buckets[$1] ?? []) }
            var matched: Int?
            for i in possible.sorted() {
                try Task.checkCancellation()
                // Every pair must pass, so similarity cannot spread through a chain of weak matches.
                if clusters[i].allSatisfy({ signatures[$0.id].map(signature.resembles) == true }) { matched = i; break }
            }
            if let matched { clusters[matched].append(member) }
            else {
                let i = clusters.count
                clusters.append([member])
                for key in signature.bucketKeys { buckets[key, default: []].insert(i) }
            }
        }
        await progress(assets.count, assets.count, "扫描完成")
        return MediaScanResult(members: members, groups: exact + clusters.filter { $0.count > 1 }.map { MediaGroup(kind: .similar, members: $0) },
                               protectedCount: protected, cloudCount: cloud, unreadableCount: unreadable,
                               similarityUnavailableCount: similarityUnavailable)
    }

    static func exactGroups(_ members: [MediaMember]) -> [MediaGroup] {
        var groups: [String: [MediaMember]] = [:]
        var order: [String] = []
        for member in members {
            let key = "\(member.isVideo)-\(member.digest.bytes)-\(member.digest.hash.base64EncodedString())"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(member)
        }
        return order.compactMap { key in
            guard let values = groups[key], values.count > 1 else { return nil }
            return MediaGroup(kind: .exact, members: values)
        }
    }

    static func remove(_ selection: GroupSelection, from group: MediaGroup,
                       allows: @escaping @Sendable (PHAsset) -> Bool = { _ in true }) async throws {
        guard PhotoLibrary.access == .authorized, selection.isValid(for: group),
              let keeperID = selection.keeper, let keeper = group.members.first(where: { $0.id == keeperID }) else {
            throw CompressionError.replacementUnavailable
        }
        let selected = group.members.filter { selection.removals.contains($0.id) }
        for member in [keeper] + selected {
            try Task.checkCancellation()
            guard let photo = PhotoLibrary.fetch(member.id), member.snapshot.matches(photo), allows(photo),
                  member.id == keeperID || photo.canPerform(.delete) else { throw CompressionError.replacementUnavailable }
            let digest = try await MediaResourceRead.read(MediaLibrary.resource(photo))
            guard digest == member.digest,
                  group.kind != .exact || digest == keeper.digest else { throw CompressionError.replacementUnavailable }
        }
        try Task.checkCancellation()
        let requested = OSAllocatedUnfairLock(initialState: false)
        try await PHPhotoLibrary.shared().performChanges {
            guard PhotoLibrary.access == .authorized,
                  let kept = PhotoLibrary.fetch(keeperID), keeper.snapshot.matches(kept), allows(kept) else { return }
            var originals: [PHAsset] = []
            for member in selected {
                guard let photo = PhotoLibrary.fetch(member.id), member.snapshot.matches(photo), allows(photo), photo.canPerform(.delete) else { return }
                originals.append(photo)
            }
            guard !originals.isEmpty else { return }
            PHAssetChangeRequest.deleteAssets(originals as NSArray)
            requested.withLock { $0 = true }
        }
        guard requested.withLock({ $0 }) else { throw CompressionError.replacementUnavailable }
    }
}

@MainActor @Observable
final class OrganizerSession {
    private(set) var groups: [MediaGroup] = []
    private(set) var scanning = false
    private(set) var removing = false
    private(set) var progress = 0.0
    private(set) var status = ""
    var message: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let allows: @Sendable (PHAsset) -> Bool

    init(groups: [MediaGroup] = [], allows: @escaping @Sendable (PHAsset) -> Bool = { _ in true }) {
        self.groups = groups
        self.allows = allows
    }
    func clearResults() {
        guard !scanning, !removing else { return }
        groups = []
        message = "筛选范围已变化，请重新扫描。"
    }
    func scan(_ photos: [PHAsset]) {
        guard !scanning, !removing else { return }
        groups = []; message = nil; scanning = true; progress = 0
        task = Task {
            defer { self.scanning = false; self.task = nil }
            do {
                let result = try await MediaAnalysis.scan(photos) { [weak self = self] done, total, label in
                    self?.progress = total == 0 ? 0 : Double(done) / Double(total)
                    self?.status = "\(label) \(done)/\(total)"
                }
                try Task.checkCancellation()
                self.groups = result.groups
                self.message = "找到 \(result.groups.count) 组。已保护 \(result.protectedCount) 项，\(result.cloudCount) 项原片在 iCloud，\(result.unreadableCount) 项未能读取。"
                if result.similarityUnavailableCount > 0 {
                    self.message? += " \(result.similarityUnavailableCount) 张照片未完成相似分析，仍已核对完全重复项。"
                }
            } catch is CancellationError { self.message = "扫描已停止。可重新扫描当前范围。" }
            catch { self.message = error.localizedDescription }
        }
    }
    func cancel() { if scanning { task?.cancel() } }
    func remove(_ selection: GroupSelection, group: MediaGroup) {
        guard !scanning, !removing, groups.contains(where: { $0.id == group.id }), selection.isValid(for: group) else { return }
        removing = true; message = nil
        task = Task {
            defer { self.removing = false; self.task = nil }
            do {
                try await MediaAnalysis.remove(selection, from: group, allows: self.allows)
                self.groups.removeAll { $0.id == group.id }
                self.message = "\(selection.removals.count) 项原件已移到「最近删除」，设备可用空间以系统读数为准。剩余项目可重新扫描。"
            } catch { self.message = "移除未完成。\(error.localizedDescription) 请重新扫描并复核。" }
        }
    }
}
