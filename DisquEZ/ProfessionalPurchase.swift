import Foundation
import Observation
import StoreKit

@MainActor @Observable
final class ProfessionalPurchase {
    static let live = ProfessionalPurchase()
    static let productID = "com.wuyuchen.disquez.professional.video"

    private(set) var unlocked = false
    private(set) var product: Product?
    private(set) var busy = false
    private(set) var loadingProduct = false
    var message: String?
    @ObservationIgnored private var refreshID = UUID()

    func observeTransactions() async {
        let listener = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = update,
                      transaction.productID == Self.productID else { continue }
                await transaction.finish()
                await self?.refresh()
            }
        }
        defer { listener.cancel() }
        await refresh()
        await withTaskCancellationHandler { await listener.value } onCancel: { listener.cancel() }
    }

    func refresh() async {
        let request = UUID()
        refreshID = request
        var found = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = result, Self.grantsAccess(transaction) {
                found = true
                break
            }
        }
        if refreshID == request, !Task.isCancelled { unlocked = found }
    }

    func loadProduct() async {
        guard !loadingProduct, product == nil else { return }
        loadingProduct = true
        defer { loadingProduct = false }
        do {
            product = try await Product.products(for: [Self.productID]).first { $0.type == .nonConsumable }
            if product == nil, !Task.isCancelled { message = "暂时无法读取买断商品，可重试或恢复购买。" }
        } catch {
            if !Task.isCancelled { message = "无法读取买断商品，请稍后重试。" }
        }
    }

    func buy() async {
        guard let product, !busy, !unlocked else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)) where Self.grantsAccess(transaction):
                refreshID = UUID()
                unlocked = true
                await transaction.finish()
                message = "专业视频已解锁。"
            case .success: message = "未能验证购买，请尝试恢复购买。"
            case .pending: message = "购买正在等待系统批准，完成后会自动解锁。"
            case .userCancelled: break
            @unknown default: message = "购买状态暂不可用，请稍后核对。"
            }
        } catch { message = "购买未完成，请稍后重试。" }
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            message = unlocked ? "已恢复专业视频买断。" : "当前账户没有可恢复的专业视频买断。"
        } catch { message = "未能恢复购买，请稍后重试。" }
    }

    private static func grantsAccess(_ transaction: StoreKit.Transaction) -> Bool {
        transaction.productID == productID && transaction.productType == .nonConsumable
            && transaction.revocationDate == nil && !transaction.isUpgraded
    }
}

struct ProfessionalPreset: Codable, Identifiable {
    let id: UUID
    let name: String
    let settings: ProfessionalVideoSettings
}

@MainActor @Observable
final class ProfessionalPresets {
    private(set) var items: [ProfessionalPreset] = []
    private(set) var message: String?
    @ObservationIgnored private let url = URL.applicationSupportDirectory
        .appending(path: "ProfessionalVideo", directoryHint: .isDirectory).appending(path: "presets-v1.json")
    @ObservationIgnored private var readable = true

    init() {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let saved = try JSONDecoder().decode([ProfessionalPreset].self, from: Data(contentsOf: url))
                guard Set(saved.map(\.id)).count == saved.count,
                      saved.allSatisfy({ $0.settings.validation == nil }) else { throw CocoaError(.fileReadCorruptFile) }
                items = saved
            } catch {
                readable = false
                message = "本机预设暂时无法读取，已有记录保留。"
            }
        }
    }

    func save(_ name: String, settings: ProfessionalVideoSettings) {
        guard readable else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 32 else { message = "预设名称须为 1–32 个字符。"; return }
        guard !items.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            message = "已有同名预设，请使用其他名称。"
            return
        }
        guard settings.validation == nil else { message = settings.validation; return }
        store(items + [.init(id: UUID(), name: name, settings: settings)], message: "已保存「\(name)」。")
    }

    func remove(_ id: UUID) {
        guard readable else { return }
        store(items.filter { $0.id != id }, message: "已移除该预设。")
    }

    private func store(_ next: [ProfessionalPreset], message: String) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            items = next
            self.message = message
        } catch { self.message = "无法保存本机预设。" }
    }
}
