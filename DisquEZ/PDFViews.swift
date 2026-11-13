import PDFKit
import SwiftUI

struct PDFCompareSheet: View {
    let original: URL
    let compressed: URL
    let pages: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showingOriginal = false
    @State private var page = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Picker("对比版本", selection: $showingOriginal) { Text("原文件").tag(true); Text("优化件").tag(false) }
                    .pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("pdf-comparison-version")
                HStack {
                    Button("上一页") { page = max(0, page - 1) }.disabled(page <= 0)
                    Spacer()
                    Text("第 \(page + 1) / \(pages) 页").monospacedDigit().accessibilityIdentifier("pdf-page-number")
                    Spacer()
                    Button("下一页") { page = min(pages - 1, page + 1) }.disabled(page >= pages - 1).accessibilityIdentifier("pdf-next-page")
                }.font(.subheadline).padding(.horizontal)
                PDFReader(url: showingOriginal ? original : compressed, page: $page).accessibilityIdentifier("pdf-reader")
                Text("双指缩放，滚动翻页；切换版本会保留当前页。请复核小字、图表和扫描件细节。")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8)
            }.background(Graphite.background).navigationTitle("PDF 对比").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(Graphite.accent)
    }
}

private struct PDFReader: UIViewRepresentable {
    let url: URL
    @Binding var page: Int
    func makeCoordinator() -> Coordinator { Coordinator(page: $page) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = UIColor(Graphite.background)
        context.coordinator.observation = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak view, weak coordinator = context.coordinator] _ in
            guard let view, coordinator?.updating == false, let current = view.currentPage, let document = view.document else { return }
            let index = document.index(for: current)
            if index != NSNotFound { coordinator?.page.wrappedValue = index }
        }
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        context.coordinator.page = $page
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.document = PDFDocument(url: url); view.autoScales = true
        }
        if let document = view.document, let target = document.page(at: min(max(0, page), max(0, document.pageCount - 1))), view.currentPage !== target { view.go(to: target) }
    }
    final class Coordinator {
        var page: Binding<Int>
        var url: URL?
        var updating = false
        var observation: NSObjectProtocol?
        init(page: Binding<Int>) { self.page = page }
        deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    }
}
