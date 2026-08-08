import AVFoundation
// AVAudioPCMBuffer 는 Sendable 이 아니지만 AVAudioConverter 의 입력 블록은
// 같은 스레드에서 동기 호출되므로 실제 경쟁은 없다.
@preconcurrency import AVFAudio
import Foundation
import Speech

/// 인식 결과 한 토막. 시간은 전달한 오디오 구간의 **절대 시각**(에셋 기준 초).
struct TranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum TranscriberError: LocalizedError {
    case notAuthorized
    case localeUnsupported(String)
    case modelUnavailable(String)
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "음성 인식 권한이 없습니다. 시스템 설정 → 개인정보 보호 및 보안 → 음성 인식에서 24dost를 허용하세요."
        case .localeUnsupported(let id):
            return "이 시스템의 음성 인식이 \(id) 언어를 지원하지 않습니다."
        case .modelUnavailable(let id):
            return "\(id) 음성 인식 모델을 설치하지 못했습니다."
        case .noAudioTrack:
            return "오디오 트랙이 없습니다."
        case .readerFailed(let why):
            return "오디오를 읽지 못했습니다: \(why)"
        }
    }
}

/// 오디오 구간 → 타임스탬프 붙은 텍스트. 백엔드 교체를 위해 프로토콜로 분리.
/// (지금은 Apple SpeechAnalyzer 하나, 나중에 whisper.cpp를 같은 자리에 끼울 수 있다.)
protocol SpeechTranscribing: Sendable {
    /// 지정 구간을 인식한다. 반환 시간은 에셋 기준 절대 초.
    func transcribe(asset: AVAsset,
                    timeRange: CMTimeRange,
                    locale: Locale) async throws -> [TranscriptSegment]

    /// 해당 언어를 지금 쓸 수 있는지(모델 설치 포함) 확인하고, 필요하면 설치한다.
    func prepare(locale: Locale) async throws
}

// MARK: - Apple SpeechAnalyzer

/// macOS 26의 SpeechAnalyzer / SpeechTranscriber 기반 온디바이스 인식.
/// 오디오는 파일로 떨구지 않고 AVAssetReader에서 바로 버퍼로 흘려보낸다.
actor AppleSpeechTranscriber: SpeechTranscribing {

    /// 자막 한 줄의 상한. 이 둘 중 하나라도 넘으면 끊는다.
    private let maxSegmentDuration: TimeInterval = 6.0
    private let maxSegmentCharacters = 84

    private var preparedLocales: Set<String> = []

    // MARK: 권한 / 모델

    func prepare(locale: Locale) async throws {
        let id = locale.identifier(.bcp47)
        if preparedLocales.contains(id) { return }

        try await Self.requestAuthorization()

        let supported = await SpeechTranscriber.supportedLocales
        guard Self.matches(locale, in: supported) else {
            throw TranscriberError.localeUnsupported(id)
        }

        // installedLocales 를 직접 보는 것보다 status(forModules:) 가 정확하다
        // (모델이 부분 설치·다운로드 중인 상태까지 구분해 준다).
        let module = Self.makeTranscriber(locale: locale)
        var status = await AssetInventory.status(forModules: [module])
        if status != .installed {
            guard status != .unsupported else { throw TranscriberError.localeUnsupported(id) }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            status = await AssetInventory.status(forModules: [module])
            guard status == .installed else { throw TranscriberError.modelUnavailable(id) }
        }
        preparedLocales.insert(id)
    }

    private static func matches(_ locale: Locale, in list: [Locale]) -> Bool {
        let target = locale.identifier(.bcp47).lowercased()
        let lang = locale.language.languageCode?.identifier.lowercased()
        return list.contains { candidate in
            let c = candidate.identifier(.bcp47).lowercased()
            if c == target { return true }
            // ko-KR 요청에 ko 만 설치돼 있거나 그 반대인 경우도 허용.
            if let lang, candidate.language.languageCode?.identifier.lowercased() == lang { return true }
            return false
        }
    }

    private static func requestAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied, .restricted:
            throw TranscriberError.notAuthorized
        case .notDetermined:
            let granted: Bool = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            if !granted { throw TranscriberError.notAuthorized }
        @unknown default:
            throw TranscriberError.notAuthorized
        }
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    // MARK: 인식

    func transcribe(asset: AVAsset,
                    timeRange: CMTimeRange,
                    locale: Locale) async throws -> [TranscriptSegment] {
        try await prepare(locale: locale)

        let module = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [module])

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.modelUnavailable(locale.identifier(.bcp47))
        }

        let (inputStream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        // 결과 수집을 먼저 띄운다. 입력이 끝나야 results 스트림도 닫힌다.
        //
        // 분석기는 같은 구간을 여러 번 다듬어 내보낸다 — 앞선 결과의 단어들이
        // 다음 결과에 다시 나온다. 그대로 이어붙이면 같은 문장이 자막에 서너 번 반복된다.
        // 시작 시각을 키로 쓰는 방식은 안 통한다: 결과가 다듬어질 때 단어 타임스탬프가
        // 5.200 → 6.300 처럼 미세하게 움직여서 같은 단어가 다른 키가 돼버린다.
        // 그래서 시간축을 한 방향으로만 소비한다 — 이미 지나온 지점보다 앞서 시작하는
        // run 만 받아들인다.
        let collector = Task { () -> [(CMTimeRange, String)] in
            var accepted: [(CMTimeRange, String)] = []
            var consumedUntil = -Double.infinity
            for try await result in module.results {
                for (range, text) in Self.timedRuns(from: result.text) {
                    let start = range.start.seconds
                    guard start.isFinite, start > consumedUntil else { continue }
                    accepted.append((range, text))
                    consumedUntil = start
                }
            }
            return accepted
        }

        try await analyzer.start(inputSequence: inputStream)

        // 오디오를 읽어 흘려보낸다. 실패해도 continuation은 반드시 닫아야 collector가 끝난다.
        do {
            try await Self.streamAudio(asset: asset,
                                       timeRange: timeRange,
                                       format: analyzerFormat,
                                       into: continuation)
        } catch {
            continuation.finish()
            collector.cancel()
            _ = try? await analyzer.finalizeAndFinishThroughEndOfInput()
            throw error
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let runs = try await collector.value
        let offset = timeRange.start.seconds
        return Self.groupIntoSegments(runs,
                                      offset: offset.isFinite ? offset : 0,
                                      maxDuration: maxSegmentDuration,
                                      maxCharacters: maxSegmentCharacters)
    }

    // MARK: 오디오 스트리밍

    /// AVAssetReader로 구간을 읽어 analyzer 포맷의 PCM 버퍼로 변환해 밀어넣는다.
    nonisolated private static func streamAudio(
        asset: AVAsset,
        timeRange: CMTimeRange,
        format: AVAudioFormat,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw TranscriberError.noAudioTrack }

        // 리더에서 곧바로 analyzer 포맷(보통 16k/48k mono float32)으로 받아 변환 단계를 없앤다.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw TranscriberError.readerFailed("출력을 추가할 수 없습니다.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscriberError.readerFailed(reader.error?.localizedDescription ?? "startReading 실패")
        }

        // 리더가 주는 포맷(mono float32 interleaved)에 맞춘 버퍼 포맷.
        guard let readFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            throw TranscriberError.readerFailed("PCM 포맷을 만들 수 없습니다.")
        }
        let converter = readFormat.isEqual(format) ? nil : AVAudioConverter(from: readFormat, to: format)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
            guard let pcm = makePCMBuffer(from: sampleBuffer, format: readFormat) else { continue }
            let outBuffer: AVAudioPCMBuffer
            if let converter {
                guard let converted = convert(pcm, with: converter, to: format) else { continue }
                outBuffer = converted
            } else {
                outBuffer = pcm
            }
            continuation.yield(AnalyzerInput(buffer: outBuffer))
        }

        if reader.status == .failed {
            throw TranscriberError.readerFailed(reader.error?.localizedDescription ?? "읽기 실패")
        }
    }

    nonisolated private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer,
                                                  format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }

    nonisolated private static func convert(_ input: AVAudioPCMBuffer,
                                            with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, statusPtr in
            if consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPtr.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: 결과 → 세그먼트

    /// AttributedString의 run들에서 (시간범위, 텍스트) 쌍을 뽑는다.
    /// audioTimeRange 속성이 없는 run은 시간 정보가 없으므로 버린다.
    nonisolated private static func timedRuns(from text: AttributedString) -> [(CMTimeRange, String)] {
        var result: [(CMTimeRange, String)] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            result.append((range, piece))
        }
        return result
    }

    /// run 단위 조각들을 자막 한 줄 크기로 묶는다.
    /// 문장부호에서 끊고, 그 전에 길이/시간 상한에 걸리면 거기서 끊는다.
    nonisolated private static func groupIntoSegments(
        _ runs: [(CMTimeRange, String)],
        offset: TimeInterval,
        maxDuration: TimeInterval,
        maxCharacters: Int
    ) -> [TranscriptSegment] {
        guard !runs.isEmpty else { return [] }
        let sentenceEnders: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]

        var segments: [TranscriptSegment] = []
        var buffer = ""
        var segStart: TimeInterval? = nil
        var segEnd: TimeInterval = 0

        /// 문장부호와 공백을 걷어냈을 때 남는 게 있는지. "。" 나 "…" 하나짜리 조각을 거른다.
        func hasContent(_ s: String) -> Bool {
            !s.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0)
                    || CharacterSet.whitespacesAndNewlines.contains($0)
                    || CharacterSet.symbols.contains($0)
            }
        }

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = segStart, !trimmed.isEmpty, hasContent(trimmed), segEnd > s {
                segments.append(TranscriptSegment(start: s + offset, end: segEnd + offset, text: trimmed))
            }
            buffer = ""
            segStart = nil
            segEnd = 0
        }

        for (range, piece) in runs {
            let start = range.start.seconds
            let end = range.end.seconds
            guard start.isFinite, end.isFinite else { continue }
            if segStart == nil { segStart = start }
            buffer += piece
            // 말이 거의 없는 구간에서는 run 하나의 시간 범위가 수십 초까지 벌어진다.
            // 그대로 두면 단어 하나짜리 자막이 30초씩 화면에 붙어 있게 되므로 상한을 건다.
            segEnd = max(segEnd, min(end, (segStart ?? start) + maxDuration))

            let tooLong = buffer.count >= maxCharacters
            let tooOld = (segEnd - (segStart ?? segEnd)) >= maxDuration
            let endsSentence = buffer.trimmingCharacters(in: .whitespaces).last.map { sentenceEnders.contains($0) } ?? false
            if endsSentence || tooLong || tooOld {
                flush()
            }
        }
        flush()

        // 앞 자막이 다음 자막 시작을 넘어 살아 있으면 두 줄이 겹쳐 보인다. 여기서 잘라 준다.
        for i in segments.indices.dropLast() {
            let nextStart = segments[i + 1].start
            if segments[i].end > nextStart {
                segments[i] = TranscriptSegment(start: segments[i].start,
                                                end: max(segments[i].start + 0.3, nextStart),
                                                text: segments[i].text)
            }
        }
        return segments
    }
}
