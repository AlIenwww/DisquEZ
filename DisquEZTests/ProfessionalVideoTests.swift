import AVFoundation
import StoreKitTest
import XCTest
import os
@testable import DisquEZ

final class ProfessionalVideoTests: XCTestCase {
    func testResizeAndFrameLimitKeepOrientationTimelineAndAudioBytes() async throws {
        let url = try await SyntheticVideo.make(size: CGSize(width: 1_280, height: 720), frames: 48, rotated: true, audio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let before = try FileAccess.digest(url)
        let settings = ProfessionalVideoSettings(customResolution: true, longEdge: 720, limitFrameRate: true,
                                                 framesPerSecond: 12, rateMode: .bitrate, videoKbps: 450)
        let result = try await VideoCompression.compress(source, preset: .balanced, professional: settings) { _ in }
        defer { try? FileManager.default.removeItem(at: result.url) }
        let output = try await VideoSource.inspect(AVURLAsset(url: result.url))
        XCTAssertEqual(output.displaySize, CGSize(width: 404, height: 720))
        XCTAssertEqual(output.duration.seconds, source.duration.seconds, accuracy: 0.10)
        XCTAssertLessThanOrEqual(output.frameRate, 13.5)
        XCTAssertGreaterThan(output.frameRate, 9)
        XCTAssertEqual(result.format?.details?.audioTreatment, .preserved)
        XCTAssertEqual(try audioSamples(source), try audioSamples(output))
        XCTAssertEqual(try FileAccess.digest(url), before)
    }

    func testAACResamplingStereoAndMuteReportActualTracks() async throws {
        let url = try await SyntheticVideo.make(size: CGSize(width: 640, height: 360), frames: 42, audio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let before = try FileAccess.digest(url)
        var settings = ProfessionalVideoSettings(encoding: .h264, rateMode: .bitrate, videoKbps: 300,
                                                 audioMode: .compress, audioKbps: 96, audioSampleRate: 44_100, audioChannels: 2)
        let encoded = try await VideoCompression.compress(source, preset: .balanced, professional: settings) { _ in }
        defer { try? FileManager.default.removeItem(at: encoded.url) }
        let output = try await VideoSource.inspect(AVURLAsset(url: encoded.url))
        XCTAssertEqual(encoded.format?.details?.audioTreatment, .encoded)
        XCTAssertEqual(encoded.format?.details?.audioSampleRate, 44_100)
        XCTAssertEqual(encoded.format?.details?.audioChannels, 2)
        XCTAssertEqual(output.audioFormat.map(CMFormatDescriptionGetMediaSubType), kAudioFormatMPEG4AAC)
        XCTAssertEqual(output.duration.seconds, source.duration.seconds, accuracy: 0.10)
        settings.audioMode = .mute
        settings.encoding = .hevc
        let muted = try await VideoCompression.compress(source, preset: .balanced, professional: settings) { _ in }
        defer { try? FileManager.default.removeItem(at: muted.url) }
        let silent = try await VideoSource.inspect(AVURLAsset(url: muted.url))
        XCTAssertNil(silent.audioTrack)
        XCTAssertEqual(muted.format?.details?.audioTreatment, .muted)
        XCTAssertEqual(silent.duration.seconds, source.duration.seconds, accuracy: 0.10)
        XCTAssertEqual(try FileAccess.digest(url), before)
    }

    func testTargetSizeReportsActualBytesAndBoundsRetry() async throws {
        let url = try await SyntheticVideo.make(size: CGSize(width: 1_280, height: 720), frames: 45, audio: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try await VideoSource.inspect(AVURLAsset(url: url))
        let settings = ProfessionalVideoSettings(rateMode: .target, targetMB: 1)
        let plan = try VideoEncodePlan(source: source, preset: .balanced, encoding: .hevc, professional: settings)
        XCTAssertNil(plan.retryBitrate(after: 1_000_000))
        XCTAssertLessThan(try XCTUnwrap(plan.retryBitrate(after: 1_250_000)), plan.bitrate)
        let result = try await VideoCompression.compress(source, preset: .balanced, professional: settings) { _ in }
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.format?.details?.targetBytes, 1_000_000)
        XCTAssertEqual(result.bytes, try StorageCapacity.fileSize(result.url))
        XCTAssertLessThanOrEqual(result.bytes, 1_000_000)
        XCTAssertLessThan(result.bytes, source.bytes)
    }

    @MainActor func testLocalStoreKitBuyRestoreAndRevoke() async throws {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("DisquEZ") == true else {
            throw XCTSkip("Use isolated DisquEZ simulator for local StoreKit session")
        }
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "DisquEZ", withExtension: "storekit"))
        let test = try SKTestSession(contentsOf: config)
        test.resetToDefaultState(); test.clearTransactions(); test.disableDialogs = true
        defer { test.clearTransactions() }
        let probeResult = OSAllocatedUnfairLock(initialState: Optional<Result<Void, Error>>.none)
        let probe = Task.detached {
            do {
                _ = try await test.buyProduct(identifier: ProfessionalPurchase.productID)
                test.clearTransactions()
                probeResult.withLock { $0 = .success(()) }
            } catch { probeResult.withLock { $0 = .failure(error) } }
        }
        defer { probe.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while probeResult.withLock({ $0 == nil }), Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        guard let preflight = probeResult.withLock({ $0 }) else { throw XCTSkip("Local StoreKit test service did not respond within 5 seconds") }
        if case .failure(let error) = preflight {
            throw XCTSkip("Local StoreKit test service is unavailable: \(error.localizedDescription)")
        }
        let purchase = ProfessionalPurchase.live
        await purchase.refresh()
        XCTAssertFalse(purchase.unlocked)
        await purchase.loadProduct()
        guard let product = purchase.product else {
            throw XCTSkip("The simulator did not load the local StoreKit test product. Run the StoreKit scheme in Xcode.")
        }
        XCTAssertEqual(product.id, ProfessionalPurchase.productID)
        await purchase.buy()
        guard purchase.unlocked else { XCTFail(purchase.message ?? "Test purchase did not grant access"); return }
        let reloaded = ProfessionalPurchase()
        await reloaded.restore()
        XCTAssertTrue(reloaded.unlocked, reloaded.message ?? "")
        let transaction = try XCTUnwrap(test.allTransactions().first { $0.productIdentifier == ProfessionalPurchase.productID })
        try test.refundTransaction(identifier: transaction.identifier)
        await purchase.refresh()
        XCTAssertFalse(purchase.unlocked)
    }

    @MainActor func testMixedQueueRestoresSettingsAndKeepsFreeProcessingAfterAccessLoss() async throws {
        let root = URL.documentsDirectory.appending(path: UUID().uuidString)
        let store = FileTaskStore(root: URL.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: store.root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try await SyntheticVideo.make(size: CGSize(width: 640, height: 360), frames: 24, audio: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let original = try FileAccess.digest(fixture)
        for name in ["Standard", "Professional", "Silent"] {
            try FileManager.default.copyItem(at: fixture, to: root.appending(path: "\(name).mov"))
        }
        let session = FileSession(store: store, hasProfessionalAccess: { true })
        session.scan([root]); try await wait(session)
        session.enqueue(Set(session.candidates.map(\.id)))
        let custom = try XCTUnwrap(session.jobs.first { $0.name == "Professional.mov" })
        let silent = try XCTUnwrap(session.jobs.first { $0.name == "Silent.mov" })
        let standard = try XCTUnwrap(session.jobs.first { $0.name == "Standard.mov" })
        session.setProfessional(.init(rateMode: .bitrate, videoKbps: 250), for: [custom.id])
        session.setProfessional(.init(rateMode: .bitrate, videoKbps: 280, audioMode: .mute), for: [silent.id])
        let locked = FileSession(store: store, hasProfessionalAccess: { false })
        locked.compress([custom.id, standard.id]); try await wait(locked)
        XCTAssertEqual(locked.job(custom.id)?.stage, .skipped)
        XCTAssertEqual(locked.job(standard.id)?.stage, .ready)
        let resumed = FileSession(store: store, hasProfessionalAccess: { true })
        XCTAssertNil(resumed.job(standard.id)?.professional)
        XCTAssertEqual(resumed.job(custom.id)?.professional?.videoKbps, 250)
        XCTAssertEqual(resumed.job(silent.id)?.professional?.audioMode, .mute)
        resumed.compress(resumed.jobs.map(\.id)); try await wait(resumed)
        for job in resumed.jobs {
            XCTAssertEqual(job.stage, .ready, "\(job.name) \(job.note ?? "")")
            XCTAssertEqual(try FileAccess.digest(root.appending(path: job.name)), original)
        }
        XCTAssertEqual(resumed.job(standard.id)?.result?.videoFormat?.details?.audioTreatment, .preserved)
        XCTAssertEqual(resumed.job(silent.id)?.result?.videoFormat?.details?.audioTreatment, .muted)
    }

    @MainActor private func wait(_ session: FileSession) async throws {
        let deadline = Date().addingTimeInterval(75)
        while session.busy, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(session.busy)
    }

    private func audioSamples(_ source: VideoSource) throws -> Data {
        let track = try XCTUnwrap(source.audioTrack)
        let reader = try AVAssetReader(asset: source.asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw CompressionError.unreadable }
        var result = Data()
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let count = CMBlockBufferGetDataLength(block)
            guard count > 0 else { continue }
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: bytes.baseAddress!)
            }
            guard status == noErr else { throw CompressionError.unreadable }
            result.append(data)
        }
        XCTAssertFalse(result.isEmpty)
        return result
    }
}
