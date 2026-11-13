import PDFKit
import XCTest
@testable import DisquEZ

final class PDFTests: XCTestCase {
    func testScannedPDFShrinksAndRetainsSearchableTextOrderAndGeometry() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SyntheticPDF.make(in: directory)
        let fingerprint = try FileAccess.digest(source)
        for preset in PDFPreset.allCases {
            let output = try await PDFCompression.optimize(source, preset: preset, directory: directory)
            let saved = try XCTUnwrap(PDFDocument(url: output.url))
            XCTAssertLessThan(output.digest.bytes, fingerprint.bytes)
            XCTAssertEqual(saved.pageCount, 2)
            XCTAssertTrue(saved.page(at: 0)!.string!.contains("page 1"))
            XCTAssertTrue(saved.page(at: 1)!.string!.contains("page 2"))
            XCTAssertEqual(output.summary.textPages, 2)
            XCTAssertEqual(try FileAccess.digest(source), fingerprint)
            XCTAssertEqual(try FileAccess.digest(output.url), output.digest)
        }
    }
    func testRotationSurvivesOptimization() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SyntheticPDF.make(in: directory, rotated: true)
        let output = try await PDFCompression.optimize(source, preset: .detail, directory: directory)
        XCTAssertEqual(PDFDocument(url: output.url)?.page(at: 1)?.rotation, 90)
        XCTAssertTrue(PDFDocument(url: output.url)?.page(at: 1)?.string?.contains("page 2") == true)
    }
    func testEncryptedPDFIsProtectedWithoutChangingOriginal() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SyntheticPDF.make(in: directory)
        let encrypted = directory.appending(path: "encrypted.pdf")
        XCTAssertTrue(PDFDocument(url: source)!.write(to: encrypted, withOptions: [.userPasswordOption: "synthetic-test-only", .ownerPasswordOption: "synthetic-owner-only"]))
        try await assertProtected(encrypted, directory: directory)
    }
    func testFormsSignaturePermissionsAndExtraStructuresAreProtected() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for entry in ["/AcroForm << /Fields [] /SigFlags 3 >>", "/Perms << /DocMDP << /Type /Sig >> >>", "/Names << /EmbeddedFiles << /Names [] >> >>", "/Outlines << /Type /Outlines /Count 0 >>", "/StructTreeRoot << /Type /StructTreeRoot >>"] {
            let source = try SyntheticPDF.structured(in: directory, entry: entry)
            try await assertProtected(source, directory: directory)
        }
    }
    func testAnnotationAndWidgetAreProtected() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SyntheticPDF.make(in: directory)
        let document = PDFDocument(url: source)!
        document.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 100, height: 30), forType: .widget, withProperties: nil))
        let annotated = directory.appending(path: "widget.pdf")
        XCTAssertTrue(document.write(to: annotated))
        try await assertProtected(annotated, directory: directory)
    }
    func testCancellationLeavesOriginalAndNoOutput() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try SyntheticPDF.make(in: directory)
        let before = try FileAccess.digest(source)
        let target = directory.appending(path: "Output")
        let task = Task { try await PDFCompression.optimize(source, preset: .detail, directory: target) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled PDF must not be retained") } catch is CancellationError {}
        XCTAssertEqual(try FileAccess.digest(source), before)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty) ?? true)
    }
    @MainActor
    func testPDFFileQueueReplacementAndRecoveryAreByteExact() async throws {
        let root = URL.documentsDirectory.appending(path: UUID().uuidString)
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        let source = try SyntheticPDF.make(in: root)
        let before = try FileAccess.digest(source)
        let session = FileSession(store: store)
        session.scan([source]); try await wait(session)
        let id = try XCTUnwrap(session.candidates.first?.id)
        XCTAssertEqual(session.candidates.first?.kind, .pdf)
        session.enqueue([id]); session.compress([id]); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .ready, session.message ?? "")
        XCTAssertEqual(session.job(id)?.result?.pdf?.pages, 2)
        XCTAssertNil(FileReplacement.reason(try XCTUnwrap(session.job(id)), store: store))
        session.replace(id); try await wait(session)
        XCTAssertEqual(session.job(id)?.stage, .replaced, session.message ?? "")
        let reloaded = FileSession(store: store)
        reloaded.restore(id); try await wait(reloaded)
        XCTAssertEqual(reloaded.job(id)?.stage, .restored, reloaded.message ?? "")
        XCTAssertEqual(try FileAccess.digest(source), before)
    }
    func testUnreadablePDFAndTextOnlyDocumentNeverLoseOriginal() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = try SyntheticPDF.make(in: directory, images: false)
        let before = try FileAccess.digest(text)
        do {
            let output = try await PDFCompression.optimize(text, preset: .detail, directory: directory)
            XCTAssertEqual(PDFDocument(url: output.url)?.page(at: 0)?.string, PDFDocument(url: text)?.page(at: 0)?.string)
        } catch CompressionError.noSavings { }
        XCTAssertEqual(try FileAccess.digest(text), before)
        let corrupt = directory.appending(path: "corrupt.pdf")
        try Data("%PDF-1.7\nbroken synthetic fixture".utf8).write(to: corrupt)
        let corruptBefore = try FileAccess.digest(corrupt)
        do { _ = try await PDFCompression.optimize(corrupt, preset: .detail, directory: directory); XCTFail("Corrupt PDF must be refused") } catch { }
        XCTAssertEqual(try FileAccess.digest(corrupt), corruptBefore)
    }
    private func assertProtected(_ source: URL, directory: URL) async throws {
        let before = try FileAccess.digest(source)
        do { _ = try await PDFCompression.optimize(source, preset: .detail, directory: directory); XCTFail("Protected PDF must not be rewritten") }
        catch CompressionError.unsupported { }
        XCTAssertEqual(try FileAccess.digest(source), before)
    }
    @MainActor private func wait(_ session: FileSession) async throws {
        let deadline = Date().addingTimeInterval(40)
        while session.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(session.busy, "PDF task timed out")
    }
}
