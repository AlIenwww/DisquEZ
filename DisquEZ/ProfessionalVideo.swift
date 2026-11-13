import AVFoundation

struct ProfessionalVideoSettings: Codable, Equatable {
    enum RateMode: String, Codable, CaseIterable, Identifiable {
        case automatic = "按档位", bitrate = "视频码率", target = "目标大小"
        var id: Self { self }
    }

    enum AudioMode: String, Codable, CaseIterable, Identifiable {
        case preserve = "保留原音轨", compress = "压缩音频", mute = "移除声音"
        var id: Self { self }
    }

    static let audioSampleRates = [32_000, 44_100, 48_000]
    static func audioBitrates(channels: Int) -> [Int] {
        channels == 1 ? [48, 64, 96, 128] : [64, 96, 128, 160, 192, 256]
    }

    var preset: CompressionPreset = .balanced
    var encoding: VideoEncoding = .hevc
    var customResolution = false
    var longEdge = 1_920
    var limitFrameRate = false
    var framesPerSecond = 30
    var rateMode: RateMode = .automatic
    var videoKbps = 2_000
    var targetMB = 10
    var audioMode: AudioMode = .preserve
    var audioKbps = 96
    var audioSampleRate = 44_100
    var audioChannels = 2

    var validation: String? {
        if customResolution, !(256...3_840).contains(longEdge) { return "长边上限须为 256–3840 像素。" }
        if limitFrameRate, !(1...120).contains(framesPerSecond) { return "帧率上限须为 1–120 fps。" }
        if rateMode == .bitrate, !(100...60_000).contains(videoKbps) { return "视频码率须为 100–60000 kbps。" }
        if rateMode == .target, !(1...20_000).contains(targetMB) { return "目标大小须为 1–20000 MB。" }
        if audioMode == .compress, !((1...2).contains(audioChannels)
            && Self.audioSampleRates.contains(audioSampleRate)
            && Self.audioBitrates(channels: audioChannels).contains(audioKbps)) { return "请选择支持的 AAC 参数。" }
        return nil
    }

    var summary: String {
        var parts = [encoding.title, customResolution ? "长边 ≤ \(longEdge) px" : preset.rawValue]
        if limitFrameRate { parts.append("最高 \(framesPerSecond) fps") }
        switch rateMode {
        case .automatic: break
        case .bitrate: parts.append("\(videoKbps) kbps")
        case .target: parts.append("目标 \(targetMB) MB")
        }
        if audioMode == .compress {
            let rate = (Double(audioSampleRate) / 1_000).formatted(.number.precision(.fractionLength(0...1)))
            parts.append("AAC \(audioKbps) kbps / \(rate) kHz / \(audioChannels) 声道")
        } else { parts.append(audioMode.rawValue) }
        return parts.joined(separator: " · ")
    }

    var audioNotice: String? {
        switch audioMode {
        case .mute: "成品将移除声音。"
        case .compress: "现有音轨将有损转换为 AAC。采样率和声道会按所选参数转换。"
        case .preserve where encoding == .h264: "H.264 兼容输出直接保留 AAC。其他受支持的音轨会有损转换为 AAC，无法转换时会停止。"
        case .preserve: nil
        }
    }
}

struct VideoAudioPlan {
    enum Treatment: String, Codable {
        case none, preserved, encoded, muted
        var title: String {
            switch self {
            case .none: "原片无音轨"
            case .preserved: "保留原音轨"
            case .encoded: "重新编码为 AAC"
            case .muted: "已移除声音"
            }
        }
    }

    let treatment: Treatment
    var rate = 0.0
    var sampleRate: Double?
    var channels: Int?
    var explicitConversion = false
    var hasTrack: Bool { treatment == .preserved || treatment == .encoded }

    static func resolve(_ source: VideoSource, encoding: VideoEncoding, settings: ProfessionalVideoSettings?) throws -> Self {
        guard let format = source.audioFormat, source.audioTrack != nil else { return .init(treatment: .none) }
        if settings?.audioMode == .mute { return .init(treatment: .muted) }
        let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        let aac = CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC
        if settings?.audioMode != .compress, encoding == .hevc || aac {
            let rate = source.audioBitrate.isFinite && source.audioBitrate > 0 ? source.audioBitrate : 256_000
            return .init(treatment: .preserved, rate: rate, sampleRate: stream?.mSampleRate, channels: stream.map { Int($0.mChannelsPerFrame) })
        }
        guard let stream, (1...2).contains(stream.mChannelsPerFrame), stream.mSampleRate.isFinite, stream.mSampleRate > 0 else {
            throw CompressionError.unsupported("AAC 转换支持单声道或双声道原音轨。可改为保留音轨或移除声音。")
        }
        if let settings, settings.audioMode == .compress {
            return .init(treatment: .encoded, rate: Double(settings.audioKbps * 1_000),
                         sampleRate: Double(settings.audioSampleRate), channels: settings.audioChannels, explicitConversion: true)
        }
        return .init(treatment: .encoded, rate: stream.mChannelsPerFrame == 1 ? 96_000 : 160_000,
                     sampleRate: stream.mSampleRate, channels: Int(stream.mChannelsPerFrame))
    }
}

struct VideoOutputDetails: Codable {
    let framesPerSecond: Double
    let videoBitrate: Double
    let audioTreatment: VideoAudioPlan.Treatment
    let audioBitrate: Double?
    let audioSampleRate: Double?
    let audioChannels: Int?
    let targetBytes: Int64?

    var audioDescription: String {
        var parts = [audioTreatment.title]
        if let audioBitrate, audioBitrate > 0 { parts.append("\((audioBitrate / 1_000).formatted(.number.precision(.fractionLength(0)))) kbps") }
        if let audioSampleRate, audioSampleRate > 0 { parts.append("\((audioSampleRate / 1_000).formatted(.number.precision(.fractionLength(0...1)))) kHz") }
        if let audioChannels { parts.append("\(audioChannels) 声道") }
        return parts.joined(separator: " · ")
    }
}

struct VideoEncodePlan {
    let encoding: VideoEncoding
    let size: CGSize
    let bitrate: Int
    let frameRateLimit: Int?
    let audio: VideoAudioPlan
    let targetBytes: Int64?

    init(source: VideoSource, preset: CompressionPreset, encoding: VideoEncoding, professional: ProfessionalVideoSettings?) throws {
        if let reason = professional?.validation { throw CompressionError.unsupported(reason) }
        self.encoding = professional?.encoding ?? encoding
        audio = try VideoAudioPlan.resolve(source, encoding: self.encoding, settings: professional)
        let base = professional?.preset ?? preset
        if let professional, professional.customResolution {
            let nativeLongEdge = max(source.size.width, source.size.height)
            let shortEdge = min(source.size.width, source.size.height)
            let scale = min(1, CGFloat(professional.longEdge) / nativeLongEdge, 2_160 / shortEdge)
            size = CGSize(width: (source.size.width * scale / 2).rounded(.down) * 2,
                          height: (source.size.height * scale / 2).rounded(.down) * 2)
        } else { size = base.dimensions(for: source.size) }
        guard size.width >= 16, size.height >= 16 else {
            throw CompressionError.unsupported("这段视频的画面比例暂不支持缩小。")
        }
        if let professional, professional.limitFrameRate, Double(professional.framesPerSecond) < source.frameRate {
            frameRateLimit = professional.framesPerSecond
        } else { frameRateLimit = nil }
        switch professional?.rateMode {
        case .bitrate:
            bitrate = (professional?.videoKbps ?? 2_000) * 1_000
            targetBytes = nil
        case .target:
            let requested = Int64(professional?.targetMB ?? 10) * 1_000_000
            let budget = min(Double(requested), Double(source.bytes))
            let rate = (budget * 0.96 - 32_768) * 8 / source.duration.seconds - audio.rate
            guard rate.isFinite, rate >= 100_000 else {
                throw CompressionError.unsupported("目标大小不足以容纳当前画面和音轨。请增大目标，或调整音频参数。")
            }
            bitrate = Int(min(60_000_000, rate, source.videoBitrate))
            targetBytes = requested
        default:
            let fps = frameRateLimit.map(Double.init) ?? source.frameRate
            bitrate = base.bitrate(videoBitrate: source.videoBitrate, frameRate: fps, output: size)
            targetBytes = nil
        }
    }

    func retryBitrate(after bytes: Int64) -> Int? {
        guard let targetBytes, bytes > targetBytes, bitrate > 100_000 else { return nil }
        let reduced = Int(Double(bitrate) * Double(targetBytes) / Double(bytes) * 0.9)
        return max(100_000, min(reduced, bitrate - 1))
    }
}
