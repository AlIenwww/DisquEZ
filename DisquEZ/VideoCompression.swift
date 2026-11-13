import AVFoundation
import CoreMedia
import CryptoKit
import VideoToolbox

enum VideoEncoding: String, Codable, CaseIterable, Identifiable {
    case hevc, h264

    var id: Self { self }
    var title: String { self == .hevc ? "HEVC" : "H.264 兼容" }
    var fileExtension: String { self == .hevc ? "mov" : "mp4" }
    var fileType: AVFileType { self == .hevc ? .mov : .mp4 }
    var codec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
    var hint: String {
        switch self {
        case .hevc: "支持的 HDR 视频保留高动态范围，保存为副本。"
        case .h264: "导出 SDR MP4 兼容副本。AAC 音轨直接保留，其他受支持的音轨会有损转换为 AAC。"
        }
    }
}

enum VideoRange: String, Codable {
    case sdr, hlg, dolbyVision

    var title: String {
        switch self {
        case .sdr: "SDR"
        case .hlg: "HDR · HLG"
        case .dolbyVision: "HDR · Dolby Vision 8.4"
        }
    }
}

struct VideoOutputFormat: Codable {
    let encoding: VideoEncoding
    let sourceRange: VideoRange
    let range: VideoRange
    var details: VideoOutputDetails? = nil

    // HDR replacement requires device playback validation. Compatibility export is always a copy.
    var requiresCopy: Bool { encoding == .h264 || sourceRange != .sdr }
}

enum CompressionPreset: String, Codable, CaseIterable, Identifiable {
    case quality = "保画质"
    case balanced = "均衡"
    case space = "省空间"

    var id: Self { self }

    var summary: String {
        switch self {
        case .quality: "优先保留原分辨率"
        case .balanced: "最高 1080p，兼顾画质"
        case .space: "最高 720p，缩小体积"
        }
    }

    func dimensions(for size: CGSize) -> CGSize {
        let bounds: (long: Double, short: Double)
        switch self {
        case .quality: bounds = (3_840, 2_160)
        case .balanced: bounds = (1_920, 1_080)
        case .space: bounds = (1_280, 720)
        }
        let scale = min(1, bounds.long / max(size.width, size.height),
                        bounds.short / min(size.width, size.height))
        return CGSize(width: (size.width * scale / 2).rounded(.down) * 2,
                      height: (size.height * scale / 2).rounded(.down) * 2)
    }

    func bitrate(for source: VideoSource, output: CGSize) -> Int {
        bitrate(videoBitrate: source.videoBitrate, frameRate: source.frameRate, output: output)
    }

    func bitrate(videoBitrate: Double, frameRate: Double, output: CGSize) -> Int {
        let ratio: Double
        let bitsPerPixel: Double
        switch self {
        case .quality: (ratio, bitsPerPixel) = (0.85, 0.13)
        case .balanced: (ratio, bitsPerPixel) = (0.70, 0.085)
        case .space: (ratio, bitsPerPixel) = (0.50, 0.065)
        }
        let pixelBudget = output.width * output.height * max(frameRate, 1) * bitsPerPixel
        return max(1, Int(min(videoBitrate * ratio, pixelBudget)))
    }
}

enum CompressionError: LocalizedError {
    case noPermission
    case originalUnavailable
    case cloudOnly
    case downloadFailed
    case unreadable
    case unsupported(String)
    case insufficientSpace(Int64)
    case noSavings(original: Int64, output: Int64)
    case encoderFailed
    case invalidOutput
    case hdrNotPreserved
    case copyNotVerified
    case replacementUnavailable
    case directDeletionUnavailable

    var errorDescription: String? {
        switch self {
        case .noPermission:
            "请在系统设置中允许访问「照片」，再选取视频。"
        case .originalUnavailable:
            "当前找不到这段视频。请检查照片权限后重新选择。"
        case .cloudOnly:
            "原片只在 iCloud。可在任务中下载后继续。"
        case .downloadFailed:
            "原片下载未完成。请检查网络和 iCloud 照片状态后重试。"
        case .unreadable:
            "暂时无法读取这段视频的本地文件。"
        case .unsupported(let reason):
            reason
        case .insufficientSpace(let bytes):
            "本机可用空间不足。此操作预计需要至少 \(bytes.storageDescription) 的空闲空间。"
        case .noSavings(let original, let output):
            "成品 \(output.storageDescription)，原片 \(original.storageDescription)。这次压缩未缩小体积，已跳过。"
        case .encoderFailed:
            "视频编码未完成。可以重试或选取另一段视频。"
        case .invalidOutput:
            "成品未通过播放或轨道核验，请重新压缩。"
        case .hdrNotPreserved:
            "成品未通过 HDR 色彩或 Dolby Vision 核验。可以尝试导出 H.264 兼容副本。"
        case .copyNotVerified:
            "暂时无法核验照片库中的压缩件，原片已保留。"
        case .replacementUnavailable:
            "原片、压缩件或照片权限已变化，无法核对替换条件。"
        case .directDeletionUnavailable:
            "原视频已变化、无法访问或系统不允许删除。请重新选择后复核。"
        }
    }
}

struct VideoSource {
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let videoFormat: CMFormatDescription
    let audioFormat: CMFormatDescription?
    let duration: CMTime
    let size: CGSize
    let transform: CGAffineTransform
    let range: VideoRange
    let frameRate: Double
    let videoBitrate: Double
    let audioBitrate: Double
    let bytes: Int64

    var displaySize: CGSize { CGRect(origin: .zero, size: size).applying(transform).size }
    var ambientViewingEnvironment: Data? {
        CMFormatDescriptionGetExtension(videoFormat, extensionKey: kCMFormatDescriptionExtension_AmbientViewingEnvironment) as? Data
    }

    static func inspect(_ asset: AVURLAsset) async throws -> Self {
        let (isPlayable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        let additionalContent: Set<AVMediaType> = [.text, .subtitle, .closedCaption, .timecode, .muxed]
        guard isPlayable, duration.seconds.isFinite, duration.seconds > 0 else {
            throw CompressionError.unreadable
        }
        guard videoTracks.count == 1, audioTracks.count <= 1,
              !tracks.contains(where: { additionalContent.contains($0.mediaType) }) else {
            throw CompressionError.unsupported("首版支持普通的单画面视频和单条音轨。")
        }
        let video = videoTracks[0]
        let (size, transform, fps, videoRate, formats) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions
        )
        guard formats.count == 1, let format = formats.first else {
            throw CompressionError.unsupported("视频包含多种画面格式，已跳过。")
        }
        let codec = CMFormatDescriptionGetMediaSubType(format)
        guard [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_DolbyVisionHEVC].contains(codec) else {
            throw CompressionError.unsupported("请选择使用 H.264 或 HEVC 编码的普通视频。")
        }
        let characteristics = try await video.load(.mediaCharacteristics)
        guard Set(characteristics).isDisjoint(with: [.containsStereoMultiviewVideo, .containsAlphaChannel]) else {
            throw CompressionError.unsupported("空间视频或带透明通道的视频已跳过，拍摄效果保留在原片。")
        }
        let range = try Self.range(of: format, markedHDR: characteristics.contains(.containsHDRVideo))
        let pixelAspect = CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true,
                                                                            useCleanAperture: false)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let conventionalRotation = abs(abs(transform.a) + abs(transform.c) - 1) < 0.001
            && abs(abs(transform.b) + abs(transform.d) - 1) < 0.001
            && abs(abs(transform.a * transform.d - transform.b * transform.c) - 1) < 0.001
        guard conventionalRotation, fps.isFinite, fps > 0,
              size.width == CGFloat(dimensions.width), size.height == CGFloat(dimensions.height),
              size.width >= 16, size.height >= 16, pixelAspect == size else {
            throw CompressionError.unsupported("这段视频的方向或像素比例暂不支持。")
        }
        let bytes = try StorageCapacity.fileSize(asset.url)
        let audio = audioTracks.first
        var audioFormat: CMFormatDescription?
        var audioRate: Float = 0
        if let audio {
            let (formats, rate) = try await audio.load(.formatDescriptions, .estimatedDataRate)
            guard formats.count == 1 else {
                throw CompressionError.unsupported("这段视频的音轨格式暂不支持。")
            }
            audioFormat = formats.first
            audioRate = rate
        }
        let measuredVideoRate = Double(bytes) * 8 / duration.seconds - Double(audioRate)
        let videoBitrate = videoRate.isFinite && videoRate > 0 ? Double(videoRate) : max(1, measuredVideoRate)
        return Self(asset: asset, videoTrack: video, audioTrack: audio, videoFormat: format,
                    audioFormat: audioFormat, duration: duration, size: size, transform: transform, range: range,
                    frameRate: Double(fps), videoBitrate: videoBitrate, audioBitrate: Double(audioRate), bytes: bytes)
    }

    static func colors(of format: CMFormatDescription) -> [String: String] {
        let keys = [
            (AVVideoColorPrimariesKey, kCMFormatDescriptionExtension_ColorPrimaries),
            (AVVideoTransferFunctionKey, kCMFormatDescriptionExtension_TransferFunction),
            (AVVideoYCbCrMatrixKey, kCMFormatDescriptionExtension_YCbCrMatrix)
        ]
        var colors: [String: String] = [:]
        for (key, extensionKey) in keys {
            colors[key] = CMFormatDescriptionGetExtension(format, extensionKey: extensionKey) as? String
        }
        return colors
    }

    private static func range(of format: CMFormatDescription, markedHDR: Bool) throws -> VideoRange {
        let codec = CMFormatDescriptionGetMediaSubType(format)
        let colors = colors(of: format)
        let transfer = colors[AVVideoTransferFunctionKey]
        let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms)
            as? [String: Any]
        let dolby = (atoms?["dvvC"] ?? atoms?["dvcC"]) as? Data
        let isHLG = transfer == AVVideoTransferFunction_ITU_R_2100_HLG
        let isPQ = transfer == AVVideoTransferFunction_SMPTE_ST_2084_PQ
        guard markedHDR || isHLG || isPQ || dolby != nil || codec == kCMVideoCodecType_DolbyVisionHEVC else {
            return .sdr
        }
        // hvcC stores luma and chroma bit depth minus eight at bytes 17 and 18.
        guard isHLG, colors[AVVideoColorPrimariesKey] == AVVideoColorPrimaries_ITU_R_2020,
              colors[AVVideoYCbCrMatrixKey] == AVVideoYCbCrMatrix_ITU_R_2020,
              let hevc = atoms?["hvcC"] as? Data, hevc.count >= 19,
              hevc[hevc.startIndex + 17] & 7 == 2, hevc[hevc.startIndex + 18] & 7 == 2 else {
            throw CompressionError.unsupported("这段 HDR 视频的色彩格式暂不支持，已跳过。")
        }
        if let dolby {
            // Dolby Vision configuration record: profile, RPU presence, and base-layer compatibility.
            guard dolby.count >= 5, dolby[dolby.startIndex + 2] >> 1 == 8,
                  dolby[dolby.startIndex + 3] & 0x04 != 0, dolby[dolby.startIndex + 4] >> 4 == 4 else {
                throw CompressionError.unsupported("这段 Dolby Vision 视频的格式暂不支持，已跳过。")
            }
            return .dolbyVision
        }
        guard codec == kCMVideoCodecType_HEVC else {
            throw CompressionError.unsupported("这段视频缺少可核对的 Dolby Vision 信息，已跳过。")
        }
        return .hlg
    }
}

struct CompressedVideo {
    let url: URL
    let bytes: Int64
    let displaySize: CGSize
    let digest: Data
    var format: VideoOutputFormat? = nil

    var requiresCopy: Bool { format?.requiresCopy == true }
}

enum VideoCompression {
    private static let sdrColors = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
    ]

    static func compress(_ source: VideoSource, preset: CompressionPreset,
                         encoding: VideoEncoding = .hevc,
                         outputDirectory: URL? = nil,
                         professional: ProfessionalVideoSettings? = nil,
                         progress: @MainActor (Double) -> Void) async throws -> CompressedVideo {
        try Task.checkCancellation()
        let plan = try VideoEncodePlan(source: source, preset: preset, encoding: encoding, professional: professional)
        let encoding = plan.encoding
        let estimate = min(Double(source.bytes), (Double(plan.bitrate) + plan.audio.rate) * source.duration.seconds / 8 * 1.2)
        let budget = min(Double(Int64.max / 4), estimate.rounded(.up))
        try StorageCapacity.require(Int64(budget) * 2 + StorageCapacity.reserve)
        let directory = outputDirectory ?? StorageCapacity.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appending(path: UUID().uuidString).appendingPathExtension(encoding.fileExtension)
        var attempts = [first]
        var retained: URL?
        defer { for attempt in attempts where attempt != retained { try? FileManager.default.removeItem(at: attempt) } }

        let firstPassScale = plan.targetBytes == nil ? 1.0 : 0.5
        try await encode(source, to: first, plan: plan, bitrate: plan.bitrate) { progress($0 * firstPassScale) }
        try Task.checkCancellation()
        var url = first
        let firstBytes = try StorageCapacity.fileSize(first)
        var bytes = firstBytes
        if let lower = plan.retryBitrate(after: bytes) {
            let second = directory.appending(path: UUID().uuidString).appendingPathExtension(encoding.fileExtension)
            attempts.append(second)
            do {
                try await encode(source, to: second, plan: plan, bitrate: lower) { progress(0.5 + $0 * 0.5) }
                let secondBytes = try StorageCapacity.fileSize(second)
                if secondBytes < bytes { url = second; bytes = secondBytes }
            } catch is CancellationError { throw CancellationError() }
            catch { if bytes >= source.bytes { throw error } }
        }
        do {
            let result = try await finishCompression(source, at: url, bytes: bytes, plan: plan,
                                                     professional: professional != nil, progress: progress)
            retained = url
            return result
        } catch is CancellationError { throw CancellationError() }
        catch where url != first && firstBytes < source.bytes {
            let result = try await finishCompression(source, at: first, bytes: firstBytes, plan: plan,
                                                     professional: professional != nil, progress: progress)
            retained = first
            return result
        }
    }

    private static func finishCompression(_ source: VideoSource, at url: URL, bytes: Int64, plan: VideoEncodePlan,
                                          professional: Bool, progress: @MainActor (Double) -> Void) async throws -> CompressedVideo {
        let encoding = plan.encoding
        try Task.checkCancellation()
        guard bytes < source.bytes else {
            throw CompressionError.noSavings(original: source.bytes, output: bytes)
        }
        let output: VideoSource
        do {
            output = try await VideoSource.inspect(AVURLAsset(url: url))
        } catch CompressionError.unsupported(_) where source.range != .sdr && encoding == .hevc {
            throw CompressionError.hdrNotPreserved
        }
        let expectedRange: VideoRange = encoding == .hevc ? source.range : .sdr
        guard output.range == expectedRange else {
            throw expectedRange == .sdr ? CompressionError.invalidOutput : CompressionError.hdrNotPreserved
        }
        if expectedRange != .sdr, let ambient = source.ambientViewingEnvironment,
           output.ambientViewingEnvironment != ambient {
            throw CompressionError.hdrNotPreserved
        }
        let codec = CMFormatDescriptionGetMediaSubType(output.videoFormat)
        let compatible = codec == kCMVideoCodecType_H264
            && VideoSource.colors(of: output.videoFormat) == sdrColors
            && (output.audioFormat.map(CMFormatDescriptionGetMediaSubType) ?? kAudioFormatMPEG4AAC) == kAudioFormatMPEG4AAC
        let hevc = codec == kCMVideoCodecType_HEVC
            || (codec == kCMVideoCodecType_DolbyVisionHEVC && output.range == .dolbyVision)
        let tolerance = max(0.10, 3 / source.frameRate)
        guard encoding == .hevc ? hevc : compatible,
              abs(output.duration.seconds - source.duration.seconds) <= tolerance,
              (output.audioTrack != nil) == plan.audio.hasTrack, output.size == plan.size,
              output.transform == orientedTransform(source.transform, size: plan.size) else {
            throw CompressionError.invalidOutput
        }
        if let limit = plan.frameRateLimit, output.frameRate > Double(limit) + max(0.5, 2 / source.duration.seconds) {
            throw CompressionError.invalidOutput
        }
        let outputAudio = output.audioFormat.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        if professional {
            try await verifyTiming(source, output: output, plan: plan, tolerance: tolerance)
            if let expected = plan.audio.sampleRate, plan.audio.hasTrack {
                guard let outputAudio, abs(outputAudio.mSampleRate - expected) < 1 else { throw CompressionError.invalidOutput }
            }
            if let channels = plan.audio.channels, plan.audio.hasTrack,
               outputAudio.map({ Int($0.mChannelsPerFrame) }) != channels { throw CompressionError.invalidOutput }
            if plan.audio.treatment == .encoded, output.audioFormat.map(CMFormatDescriptionGetMediaSubType) != kAudioFormatMPEG4AAC {
                throw CompressionError.invalidOutput
            }
            if plan.audio.treatment == .preserved, output.audioFormat.map(CMFormatDescriptionGetMediaSubType) != source.audioFormat.map(CMFormatDescriptionGetMediaSubType) {
                throw CompressionError.invalidOutput
            }
        }
        let generator = AVAssetImageGenerator(asset: output.asset)
        generator.maximumSize = CGSize(width: 320, height: 320)
        let midpoint = CMTimeMultiplyByFloat64(output.duration, multiplier: 0.5)
        _ = try await generator.image(at: midpoint)
        let digest = Data(try fingerprint(url))
        let details = VideoOutputDetails(framesPerSecond: output.frameRate, videoBitrate: output.videoBitrate,
            audioTreatment: plan.audio.treatment, audioBitrate: outputAudio == nil || !output.audioBitrate.isFinite ? nil : output.audioBitrate,
            audioSampleRate: outputAudio?.mSampleRate, audioChannels: outputAudio.map { Int($0.mChannelsPerFrame) }, targetBytes: plan.targetBytes)
        await progress(1)
        try Task.checkCancellation()
        return CompressedVideo(url: url, bytes: bytes, displaySize: output.displaySize, digest: digest,
                               format: .init(encoding: encoding, sourceRange: source.range, range: output.range, details: details))
    }

    private static func verifyTiming(_ source: VideoSource, output: VideoSource, plan: VideoEncodePlan, tolerance: Double) async throws {
        let allowed = max(tolerance, plan.frameRateLimit.map { 1 / Double($0) } ?? 0)
        let inputVideo = try await source.videoTrack.load(.timeRange)
        let outputVideo = try await output.videoTrack.load(.timeRange)
        guard abs(inputVideo.start.seconds - outputVideo.start.seconds) <= tolerance,
              abs(inputVideo.end.seconds - outputVideo.end.seconds) <= allowed else { throw CompressionError.invalidOutput }
        if let inputAudio = source.audioTrack, let outputAudio = output.audioTrack {
            let before = try await inputAudio.load(.timeRange)
            let after = try await outputAudio.load(.timeRange)
            guard abs(before.start.seconds - after.start.seconds) <= 0.10,
                  abs(before.end.seconds - after.end.seconds) <= 0.10 else { throw CompressionError.invalidOutput }
        }
    }

    static func fingerprint(_ url: URL) throws -> SHA256.Digest {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return hash.finalize()
    }

    private static func orientedTransform(_ transform: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        let rotation = CGAffineTransform(a: transform.a, b: transform.b, c: transform.c, d: transform.d, tx: 0, ty: 0)
        let frame = CGRect(origin: .zero, size: size).applying(rotation)
        return CGAffineTransform(a: rotation.a, b: rotation.b, c: rotation.c, d: rotation.d,
                                 tx: -frame.minX, ty: -frame.minY)
    }

    private static func encode(_ source: VideoSource, to url: URL, plan: VideoEncodePlan, bitrate: Int,
                               progress: @MainActor (Double) -> Void) async throws {
        let size = plan.size
        let encoding = plan.encoding
        let reader = try AVAssetReader(asset: source.asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: encoding.fileType)
        // Keep the HDR frames at ten bits until the writer performs any SDR color conversion.
        let pixelFormat = source.range == .sdr ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                                              : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: source.videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ])
        videoOutput.alwaysCopiesSampleData = false
        var properties: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: plan.frameRateLimit.map(Double.init) ?? source.frameRate
        ]
        if encoding == .h264 {
            properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else if source.range != .sdr {
            properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            properties[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] =
                source.range == .dolbyVision ? kVTHDRMetadataInsertionMode_Auto : kVTHDRMetadataInsertionMode_None
            // Resize and re-encoding change the pixels that the per-frame Dolby Vision metadata describes.
            properties[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = false
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: encoding.codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: properties
        ]
        let colors = encoding == .h264 ? sdrColors : VideoSource.colors(of: source.videoFormat)
        if colors.count == sdrColors.count {
            settings[AVVideoColorPropertiesKey] = colors
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video), reader.canAdd(videoOutput) else {
            throw CompressionError.encoderFailed
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = orientedTransform(source.transform, size: size)
        guard writer.canAdd(videoInput) else { throw CompressionError.encoderFailed }
        writer.add(videoInput)
        reader.add(videoOutput)
        var audioPair: (output: AVAssetReaderOutput, input: AVAssetWriterInput)?
        if plan.audio.hasTrack, let audio = source.audioTrack, let format = source.audioFormat {
            let (output, input) = try audioEndpoints(track: audio, format: format, plan: plan.audio, writer: writer)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw CompressionError.encoderFailed }
            reader.add(output)
            writer.add(input)
            audioPair = (output, input)
        }
        var frameLimiter: VideoFrameLimiter?
        if let limit = plan.frameRateLimit {
            let range = try await source.videoTrack.load(.timeRange)
            frameLimiter = VideoFrameLimiter(rate: limit, end: range.end)
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        guard writer.startWriting(), reader.startReading() else {
            throw writer.error ?? reader.error ?? CompressionError.encoderFailed
        }
        writer.startSession(atSourceTime: .zero)
        var videoFinished = false
        var audioFinished = audioPair == nil
        var progressCheckpoint = 0.0
        var lastSpaceCheck = ContinuousClock.now
        while !videoFinished || !audioFinished {
            try Task.checkCancellation()
            if reader.status == .failed || writer.status != .writing {
                throw reader.error ?? writer.error ?? CompressionError.encoderFailed
            }
            var advanced = false
            if !videoFinished, videoInput.isReadyForMoreMediaData {
                let timestamp: CMTime?
                if var limiter = frameLimiter {
                    timestamp = try limiter.appendNext(videoOutput, to: videoInput)
                    frameLimiter = limiter
                }
                else { timestamp = try appendNext(videoOutput, to: videoInput) }
                videoFinished = timestamp == nil
                advanced = true
                if let timestamp, timestamp.seconds.isFinite {
                    let fraction = min(0.98, max(0, timestamp.seconds / source.duration.seconds))
                    if fraction - progressCheckpoint >= 0.01 {
                        progressCheckpoint = fraction
                        await progress(fraction)
                    }
                }
            }
            if let audioPair, !audioFinished, audioPair.input.isReadyForMoreMediaData {
                audioFinished = try appendNext(audioPair.output, to: audioPair.input) == nil
                advanced = true
            }
            if lastSpaceCheck.duration(to: .now) >= .seconds(1) {
                try StorageCapacity.require(StorageCapacity.reserve)
                lastSpaceCheck = .now
            }
            if !advanced { try await Task.sleep(for: .milliseconds(5)) }
        }
        guard reader.status != .failed else { throw reader.error ?? CompressionError.encoderFailed }
        try Task.checkCancellation()
        writer.endSession(atSourceTime: source.duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CompressionError.encoderFailed }
    }

    private static func audioEndpoints(track: AVAssetTrack, format: CMFormatDescription, plan: VideoAudioPlan,
                                       writer: AVAssetWriter) throws -> (AVAssetReaderOutput, AVAssetWriterInput) {
        if plan.treatment == .preserved {
            return (AVAssetReaderTrackOutput(track: track, outputSettings: nil),
                    AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format))
        }
        guard let sampleRate = plan.sampleRate, let channels = plan.channels else { throw CompressionError.encoderFailed }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: Int(plan.rate)
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw CompressionError.unsupported("这段音频无法转换为兼容的 AAC 音轨。")
        }
        var pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        if plan.explicitConversion {
            pcm[AVSampleRateKey] = sampleRate
            pcm[AVNumberOfChannelsKey] = channels
            return (AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm),
                    AVAssetWriterInput(mediaType: .audio, outputSettings: settings))
        }
        return (AVAssetReaderTrackOutput(track: track, outputSettings: pcm),
                AVAssetWriterInput(mediaType: .audio, outputSettings: settings))
    }

    private static func appendNext(_ output: AVAssetReaderOutput, to input: AVAssetWriterInput) throws -> CMTime? {
        try autoreleasepool {
            guard let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return nil
            }
            guard input.append(sample) else { throw CompressionError.encoderFailed }
            return CMSampleBufferGetPresentationTimeStamp(sample)
        }
    }
}

private struct VideoFrameLimiter {
    let rate: Int
    let end: CMTime
    private var origin: Double?
    private var lastSlot = -1.0
    private var pending: CMSampleBuffer?

    init(rate: Int, end: CMTime) {
        self.rate = rate
        self.end = end
    }

    mutating func appendNext(_ output: AVAssetReaderTrackOutput, to input: AVAssetWriterInput) throws -> CMTime? {
        try autoreleasepool {
            guard let sample = output.copyNextSampleBuffer() else {
                if let pending { try append(pending, endingAt: end, to: input) }
                pending = nil
                input.markAsFinished()
                return nil
            }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
            guard timestamp.seconds.isFinite else { throw CompressionError.invalidOutput }
            if origin == nil { origin = timestamp.seconds }
            let slot = floor((timestamp.seconds - (origin ?? timestamp.seconds)) * Double(rate) + 0.000_001)
            if slot > lastSlot {
                if let pending { try append(pending, endingAt: timestamp, to: input) }
                pending = sample
                lastSlot = slot
            }
            return timestamp
        }
    }

    private func append(_ sample: CMSampleBuffer, endingAt end: CMTime, to input: AVAssetWriterInput) throws {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = end - timestamp
        guard duration.isNumeric, duration > .zero else { throw CompressionError.invalidOutput }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var adjusted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                           sampleBufferOut: &adjusted)
        guard status == noErr, let adjusted, input.append(adjusted) else { throw CompressionError.encoderFailed }
    }
}
