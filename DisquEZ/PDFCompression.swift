import PDFKit

enum PDFPreset: String, Codable, CaseIterable, Identifiable {
    case detail = "保留细节", screen = "屏幕阅读"
    var id: Self { self }
    var explanation: String {
        self == .detail ? "保留图片尺寸，尝试优化图片编码。文字仍可搜索，适合保留更多细节。"
            : "同时缩小过大的图片，适合屏幕阅读。打印和放大前请仔细复核细节。"
    }
}

struct PDFSummary: Codable { let pages: Int; let textPages: Int }
struct PDFOutput { let url: URL; let digest: ResourceDigest; let summary: PDFSummary; let copyOnlyReason: String? }

enum PDFCompression {
    private struct PageCheck {
        let boxes: [CGRect]
        let rotation: Int
        let label: String?
        let text: String
        let preview: [UInt8]
    }
    private struct DocumentCheck {
        let pages: [PageCheck]
        let attributes: [String: String]
    }
    static func optimize(_ source: URL, preset: PDFPreset, directory: URL) async throws -> PDFOutput {
        try Task.checkCancellation()
        return try autoreleasepool {
            let originalBytes = try StorageCapacity.fileSize(source)
            guard originalBytes <= 512 * 1_024 * 1_024 else { throw CompressionError.unsupported("当前 PDF 超过 512 MB，已保护原文件。") }
            guard let document = PDFDocument(url: source), let raw = CGPDFDocument(source as CFURL) else { throw CompressionError.unreadable }
            try protect(document, raw: raw)
            let before = try inspect(document, raw: raw)
            try StorageCapacity.require(StorageCapacity.downloadRequirement(bytes: originalBytes))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: UUID().uuidString).appendingPathExtension("pdf")
            var keep = false
            defer { if !keep { try? FileManager.default.removeItem(at: target) } }
            try Task.checkCancellation()
            // PDFKit keeps the document objects and text layer; pages are not flattened into images.
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: preset == .screen]
            guard document.write(to: target, withOptions: options) else { throw CompressionError.invalidOutput }
            // PDFKit does not offer a mid-write cancellation callback. Discard a completed write if stopped.
            try Task.checkCancellation()
            let bytes = try StorageCapacity.fileSize(target)
            guard bytes < originalBytes else { throw CompressionError.noSavings(original: originalBytes, output: bytes) }
            guard let saved = PDFDocument(url: target), let savedRaw = CGPDFDocument(target as CFURL) else { throw CompressionError.invalidOutput }
            try protect(saved, raw: savedRaw)
            let after = try inspect(saved, raw: savedRaw)
            guard matches(before, after) else { throw CompressionError.unsupported("PDF 页数、顺序、文字或页面内容未能通过核对，已保留原文件。") }
            let digest = try FileAccess.digest(target)
            let summary = PDFSummary(pages: before.pages.count, textPages: before.pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
            let reason = before.attributes == after.attributes ? nil : "PDF 的部分文档信息无法完整保留，仅支持导出副本"
            keep = true
            return PDFOutput(url: target, digest: digest, summary: summary, copyOnlyReason: reason)
        }
    }
    private static func has(_ key: String, in dictionary: CGPDFDictionaryRef) -> Bool {
        var object: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(dictionary, key, &object)
    }
    private static func protect(_ document: PDFDocument, raw: CGPDFDocument) throws {
        guard !document.isEncrypted, !document.isLocked, !raw.isEncrypted else { throw CompressionError.unsupported("加密或受密码保护的 PDF 已作为保护项跳过。") }
        guard document.pageCount > 0, document.pageCount <= 200, document.pageCount == raw.numberOfPages,
              let catalog = raw.catalog else { throw CompressionError.unsupported("当前仅处理 1 至 200 页的普通 PDF，原文件保留。") }
        let protected = ["AcroForm", "Perms", "DSS", "Collection", "OCProperties", "Names", "Outlines", "OpenAction", "AA", "AF", "StructTreeRoot"]
        guard !protected.contains(where: { has($0, in: catalog) }) else {
            throw CompressionError.unsupported("PDF 含表单、签名、附件、书签、图层或其他需保护的结构，原文件保留。")
        }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let rawPage = raw.page(at: index + 1), let dictionary = rawPage.dictionary,
                  page.annotations.isEmpty, !has("Annots", in: dictionary), !has("AA", in: dictionary) else {
                throw CompressionError.unsupported("PDF 含批注、表单或交互内容，已作为保护项跳过。")
            }
        }
    }
    private static func inspect(_ document: PDFDocument, raw: CGPDFDocument) throws -> DocumentCheck {
        var pages: [PageCheck] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let check = try autoreleasepool { () throws -> PageCheck in
                guard let page = document.page(at: index), let rawPage = raw.page(at: index + 1) else { throw CompressionError.invalidOutput }
                let boxes = [CGPDFBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].map { rawPage.getBoxRect($0) }
                guard boxes.allSatisfy({ !$0.isEmpty && !$0.isInfinite && !$0.isNull && $0.width.isFinite && $0.height.isFinite && $0.width <= 20_000 && $0.height <= 20_000 }) else { throw CompressionError.unsupported("PDF 页面尺寸无法安全处理，原文件保留。") }
                return PageCheck(boxes: boxes, rotation: page.rotation, label: page.label, text: page.string ?? "", preview: try preview(rawPage))
            }
            pages.append(check)
        }
        // PDFKit writes new PDF dates and producer information. Check user-supplied descriptive fields.
        let keys: [PDFDocumentAttribute] = [.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute, .creatorAttribute]
        var attributes: [String: String] = [:]
        for key in keys {
            guard let value = document.documentAttributes?[key] else { continue }
            if let strings = value as? [String], strings.allSatisfy(\.isEmpty) { continue }
            if let string = value as? String, string.isEmpty { continue }
            attributes[key.rawValue] = String(describing: value)
        }
        return DocumentCheck(pages: pages, attributes: attributes)
    }
    private static func preview(_ page: CGPDFPage) throws -> [UInt8] {
        let edge = 96
        var bytes = [UInt8](repeating: 255, count: edge * edge * 4)
        try bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CompressionError.invalidOutput }
            let rectangle = CGRect(x: 0, y: 0, width: edge, height: edge)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rectangle)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rectangle, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
        }
        return bytes
    }
    private static func matches(_ before: DocumentCheck, _ after: DocumentCheck) -> Bool {
        guard before.pages.count == after.pages.count else { return false }
        return zip(before.pages, after.pages).allSatisfy { first, second in
            guard first.rotation == second.rotation, first.label == second.label, first.text == second.text,
                  first.boxes.count == second.boxes.count, first.preview.count == second.preview.count else { return false }
            for (left, right) in zip(first.boxes, second.boxes) {
                if abs(left.minX - right.minX) > 0.01 || abs(left.minY - right.minY) > 0.01 || abs(left.width - right.width) > 0.01 || abs(left.height - right.height) > 0.01 { return false }
            }
            let difference = zip(first.preview, second.preview).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
            return difference / Double(first.preview.count * 255) < 0.035
        }
    }
}
