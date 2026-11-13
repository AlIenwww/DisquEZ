import Photos
import SwiftUI

enum TaskBatchAction: String, CaseIterable, Identifiable {
    case start = "开始所选任务", download = "下载原片并压缩", save = "保存所选成品", verify = "重新核验成品"
    case replace = "移除已核验原片", pause = "暂停所选任务", cancel = "取消所选任务", retry = "重新开始所选任务"
    case discard = "移除所选任务", deleteOriginal = "直接删除原视频"
    case export = "导出所选副本"
    var id: String { rawValue }
    var destructive: Bool { [.replace, .cancel, .discard, .deleteOriginal].contains(self) }
    var explanation: String {
        switch self {
        case .download: "只为本次列出的任务下载 iCloud 原片，可能使用蜂窝数据。下载和压缩均需要本机空间，下载时请保持 App 打开。"
        case .replace: "仅移除成品已保存并重新核验的原片。启用 iCloud 照片时删除同步到其他设备，原片先进入「最近删除」。"
        case .pause: "暂停所选任务，已完成成品保留；之后可从未完成的文件重新处理。其他任务继续。"
        case .cancel: "停止所选任务并退出待执行队列，保留已完成成品供复核。不会删除照片库素材。系统下载缓存由系统管理。"
        case .discard: "清理所选任务记录及 App 内副本。照片库中的原片和已保存成品保留。"
        case .deleteOriginal: "直接删除原视频，不以已有压缩件为前提。下一步逐项复核原片。"
        case .save: "将所选成品保存到照片库，再回读核验。未确认移除的原片保留。"
        case .verify: "重新读取照片库成品并核验，不移除原片。"
        case .retry: "重新开始所选未完成项。只在本机读取原片，iCloud 原片需另行确认下载。"
        case .export: "在「文件」中选择副本保存位置。原位置文件和 App 内成品保留。"
        case .start: "按所选顺序处理本机原片。仅在 iCloud 的素材会标记为待下载。"
        }
    }
}

struct BatchTaskItem: Identifiable {
    let id: UUID
    let original: PhotoSnapshot
    let stage: CompressionJob.Stage
    let hasOutput: Bool
    let hasCopy: Bool
    let copyOnly: Bool
    var directDeletion: CompressionJob.DirectDeletion? = nil
    let note: String?
    var professionalSummary: String? = nil
    var title: String { original.creationDate?.formatted(.dateTime.year().month().day().hour().minute()) ?? "素材" }
    func reason(for action: TaskBatchAction, busy: Bool, interruptible: Bool, video: Bool) -> String? {
        if busy && (![.pause, .cancel].contains(action) || !interruptible) { return "请等待当前操作完成" }
        if action == .discard { return nil }
        if action == .deleteOriginal {
            guard video, directDeletion != .removed, stage != .removed else { return "原片已移除或不是视频" }
            guard let photo = PhotoLibrary.fetch(original.identifier), original.matches(photo), photo.canPerform(.delete) else {
                return "原片已变化、无法访问或系统不允许删除"
            }
            return nil
        }
        if [.start, .download, .retry].contains(action), directDeletion != nil { return "原片已直接删除或状态待核对" }
        switch action {
        case .start: return stage == .waiting ? nil : "仅适用于待压缩任务"
        case .download: return [.waiting, .awaitingDownload].contains(stage) ? nil : "仅适用于待压缩或待下载任务"
        case .save: return stage == .ready && hasOutput && !hasCopy ? nil : "没有待保存成品"
        case .verify: return hasCopy && hasOutput && !stage.isClosed ? nil : "没有可重新核验的成品"
        case .replace:
            guard hasCopy, hasOutput, !copyOnly, [.saved, .verified, .savePending].contains(stage), directDeletion == nil else {
                return "需有已保存且可替换的成品"
            }
            return PhotoLibrary.replaceableAlbums(for: original, resourceType: video ? .video : .photo) == nil
                ? "照片权限或原片状态已变化，当前无法替换" : nil
        case .pause, .cancel:
            return !hasCopy && !hasOutput && [.waiting, .awaitingDownload, .downloading, .processing, .failed, .skipped].contains(stage)
                ? nil : "任务已完成或已退出处理队列"
        case .retry:
            return !hasCopy && !hasOutput && [.failed, .skipped, .cancelled].contains(stage) ? nil : "仅适用于失败、跳过或取消的任务"
        case .export: return "照片库任务使用保存成品"
        case .discard, .deleteOriginal: return nil
        }
    }
}

@MainActor
protocol BatchTaskSession: AnyObject {
    var batchItems: [BatchTaskItem] { get }
    func batchItem(_ id: UUID) -> BatchTaskItem?
    var batchBusy: Bool { get }
    var batchInterruptible: Bool { get }
    var batchVideo: Bool { get }
}

