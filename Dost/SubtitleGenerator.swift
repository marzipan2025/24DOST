import AVFoundation
import CryptoKit
import Foundation

/// 파이프라인 추적용 파일 로거.
/// 통합 로그(os.Logger)는 info 레벨이 기본으로 안 남고 프로세스 이름 매칭도 까다로워서
/// 개발 중 추적에는 파일이 훨씬 확실하다. DOST_DEBUG_LOG 환경변수로만 켜진다.
enum DostLog {
    private static let handle: FileHandle? = {
        guard ProcessInfo.processInfo.environment["DOST_DEBUG_LOG"] != nil else { return nil }
        let url = URL(fileURLWithPath: "/tmp/dost-debug.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        try? h?.seekToEnd()
        return h
    }()

    static func log(_ message: String) {
        guard let handle else { return }
        let stamp = String(format: "%.1f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000))
        handle.write(Data("[\(stamp)] \(message)\n".utf8))
    }
}

// MARK: - Settings keys (SettingsWindowView 와 공유)

enum SubtitleDefaults {
    static let autoGenerate     = "24dost.subtitle.autoGenerate"
    static let sourceLanguage   = "24dost.subtitle.sourceLanguage"   // BCP-47
    static let targetLanguage   = "24dost.subtitle.targetLanguage"   // BCP-47
    static let backend          = "24dost.subtitle.backend"          // TranslationBackend.rawValue
    static let claudeModel      = "24dost.subtitle.claudeModel"
    /// 저장 키는 그대로 둔다 — 바꾸면 기존 설정을 잃는다.
    static let fastResponseSeconds = "24dost.subtitle.lookAhead"

    static let defaultTarget = "ko"
    /// 인식 언어 기본값. 예전 "auto" 는 감지가 아니라 시스템 언어를 쓰는 것이어서 없앴다.
    static let defaultSourceLanguage = "en-US"

    /// 고를 수 있는 인식 언어. 시스템은 30개를 지원하지만 지역 변종이 대부분이라
    /// 목록만 길고 고르기 어렵다. 인식 결과가 실제로 갈리는 것만 남겨 추렸다.
    static let sourceLanguageChoices: [(value: String, label: String)] = [
        ("en-GB",  "English (UK)"),
        ("en-US",  "English (US)"),
        ("fr-FR",  "French"),
        ("de-DE",  "German"),
        ("it-IT",  "Italian"),
        ("ja-JP",  "Japanese"),
        ("ko-KR",  "Korean"),
        ("pt-BR",  "Portuguese (Brazil)"),
        ("pt-PT",  "Portuguese (Portugal)"),
        ("es-ES",  "Spanish (Spain)"),
        ("es-MX",  "Spanish (Mexico)"),
        ("yue-CN", "Cantonese"),
        ("zh-CN",  "Mandarin")
    ]

    /// 저장된 값이 목록에 있는지 확인하고, 아니면 기본값으로 바꿔 돌려준다.
    /// 예전 "auto" 나 사라진 지역 변종이 남아 있을 수 있는데, 그대로 쓰면
    /// Locale(identifier: "auto") 같은 엉터리 로케일이 인식기로 들어간다.
    /// 설정 탭을 열지 않아도 통하도록 **쓰는 지점에서** 걸러야 한다.
    static func normalizedSourceLanguage(_ stored: String) -> String {
        sourceLanguageChoices.contains { $0.value == stored } ? stored : defaultSourceLanguage
    }

    /// BCP-47 → 사람이 읽는 이름. 목록에 없으면 식별자를 그대로 돌려준다.
    static func sourceLanguageLabel(_ bcp47: String) -> String {
        sourceLanguageChoices.first { $0.value.caseInsensitiveCompare(bcp47) == .orderedSame }?.label ?? bcp47
    }
    static let defaultClaudeModel = "claude-haiku-4-5"
    static let defaultFastResponse: Double = 40
}

// MARK: - Generator

/// 영상의 음성을 인식하고 번역해 자막 큐를 만든다.
///
/// "실시간"이 아니라 **재생 헤드보다 앞서 달리는** 방식이다. 파일 재생에서는 이게
/// 실시간보다 쉽고 결과도 낫다 — 자막이 타임스탬프에 맞춰 정확히 뜨므로 사용자
/// 눈에는 지연이 0이다.
///
/// 화면에 무엇을 그릴지는 전혀 모른다. 자막 소스 선택과 표시는 VideoSampler 가
/// 내장/외부 자막과 똑같은 방식으로 처리한다.
@MainActor
final class SubtitleGenerator: ObservableObject {

    enum Status: Equatable {
        case idle
        case working                // 앞서 달리는 중
        case caughtUp               // 필요한 만큼 다 만듦
        case failed(String)
    }

    // MARK: 공개 상태

    @Published private(set) var cues: [SubtitleCue] = []
    @Published private(set) var status: Status = .idle
    /// 생성된 자막이 재생 헤드보다 얼마나 앞서 있는지(초).
    @Published private(set) var leadSeconds: TimeInterval = 0
    /// 생성이 켜져 있는지. 끄면 진행 중 작업을 멈추지만 이미 만든 큐는 남는다.
    private(set) var isRunning = false

    /// 오디오를 읽을 대상이 준비돼 있는지.
    var canGenerate: Bool { asset != nil && sourceURL != nil }

    // MARK: 설정 (ContentView 가 UserDefaults 에서 읽어 넣어준다)

    var sourceLocale: Locale? = nil          // nil = 자동(시스템 선호 언어)
    var targetLanguage: Locale.Language = Locale.Language(identifier: SubtitleDefaults.defaultTarget)
    var backend: TranslationBackend = .apple
    var claudeModel: String = SubtitleDefaults.defaultClaudeModel
    /// 재생 위치에서 이만큼 앞까지는 **빠른 응답을 우선**한다(짧은 창). 그 밖은 품질 우선.
    ///
    /// 예전 이름은 lookAhead 였고 "이만큼 앞서면 생성을 멈춘다"는 뜻이었다. 전체 미리
    /// 생성을 넣으면서 그 역할은 사라졌는데 이름만 남아, 값을 올리면 "더 많이 준비된다"고
    /// 오해하기 딱 좋았다. 실제로는 짧은 창 구간만 넓어져 품질이 나빠진다.
    var fastResponseRange: TimeInterval = SubtitleDefaults.defaultFastResponse

    // MARK: 내부 상태

    private var asset: AVAsset?
    private var sourceURL: URL?
    private var mediaDuration: TimeInterval = 0

    private let transcriber: any SpeechTranscribing = AppleSpeechTranscriber()

    /// 이미 생성이 끝난 구간들 (시작 오름차순, 겹치지 않게 병합 유지).
    /// 스칼라 하나로는 표현할 수 없다 — 사용자가 타임라인을 뛰어다니면 커버리지가
    /// 조각나기 때문이다. "여기까지 만들었다"를 숫자 하나로 들고 있으면 뒤로 되감았을 때
    /// 그 값이 그대로 남아 "이미 다 만들었다"고 판단해 버린다.
    private var coveredRanges: [(start: TimeInterval, end: TimeInterval)] = []
    /// 인식 결과가 비어 있어 "덮었다"고만 쳐 둔 구간. 이 세션 안에서는 다시 읽지 않지만
    /// 캐시에는 쓰지 않아서, 파일을 다시 열면 한 번 더 시도한다.
    private var provisionalRanges: [(start: TimeInterval, end: TimeInterval)] = []

    /// 최고 등급보다 낮은 창으로 만든 구간. 만들 게 다 떨어지면 여기를 300초 창으로
    /// 다시 만든다. 등급이 낮은 것부터 처리한다 — 60초로 급조한 쪽이 제일 아쉬우니까.
    ///
    /// coveredRanges 에 등급을 섞지 않고 따로 두는 이유는, 그쪽 병합 규칙이 탐색 정확성의
    /// 핵심이라 건드리지 않기 위해서다. 다시 만든 구간은 목록에서 빠지므로 언젠가 비고,
    /// 비면 더 할 일이 없다 — 영원히 도는 일은 없다.
    private var pendingRefine: [(start: TimeInterval, end: TimeInterval, tier: Int)] = []
    private var currentJob: Task<Void, Never>?
    /// 작업 세대 번호. 취소는 협조적이라, 취소를 알아채지 못한 옛 작업이 완료 블록까지
    /// 도달할 수 있다. 그때 currentJob 을 nil 로 덮으면 그 사이 시작된 새 작업의 핸들이
    /// 사라져 추적이 끊기고, pump 가 또 불려 작업이 둘로 늘어난다. 완료 블록은 자기
    /// 세대가 아직 현재인지 확인하고 나서만 상태를 건드린다.
    private var jobGeneration = 0
    private var lastPersistedCount = 0
    /// 직전 tick 의 재생 시각. 시각이 불연속으로 뛰면 탐색으로 본다.
    private var lastTickTime: TimeInterval?

    /// 창 하나의 길이. 급한 자리냐 아니냐에 따라 둘로 나뉜다.
    ///
    /// 창마다 SpeechAnalyzer 를 새로 만들기 때문에 창 경계는 전부 콜드 스타트다 —
    /// 앞 문맥이 없는 상태에서 다시 시작하니 경계 근처 인식이 가장 나쁘고, 경계에
    /// 걸친 세그먼트는 잘렸을 가능성 때문에 버려진다. 그래서 창은 길수록 좋다.
    ///
    /// 그런데 창이 길면 그 창이 끝나야 자막이 나오므로, **사용자가 기다리는 자리**
    /// 에서는 손해다. 파일을 막 열었거나 안 만든 지점으로 점프했을 때가 그렇다.
    /// 반대로 재생 위치보다 한참 앞을 채우는 중이라면 아무도 기다리지 않는다.
    /// 그 둘을 나눠서, 급할 땐 짧게 응답하고 여유로울 땐 길게 잡아 품질을 올린다.
    private let urgentWindowLength: TimeInterval = 60
    private let relaxedWindowLength: TimeInterval = 180
    /// 할 일이 없을 때 다시 만들며 쓰는 창. 경계를 가장 적게 만드는 대신 오래 읽는다.
    private let fineWindowLength: TimeInterval = 300

    /// 이 창을 사용자가 기다리고 있는지.
    ///
    /// "look-ahead 안쪽"만 보면 안 된다 — 백필(재생 위치보다 **뒤쪽** 빈 구간 메우기)은
    /// frontier 가 playhead 보다 작아서 그 조건을 항상 통과해 버린다. 세상에서 제일
    /// 안 급한 작업인데 전부 짧은 창으로 처리하게 된다. 재생 헤드 근처이면서 앞쪽일
    /// 때만 급한 것으로 본다.
    private func isUrgent(frontier: TimeInterval, playhead: TimeInterval) -> Bool {
        frontier >= playhead - 5 && frontier <= playhead + fastResponseRange
    }

    /// 등급이 뜻하는 창 길이.
    private func windowLength(forTier tier: Int) -> TimeInterval {
        switch tier {
        case SubtitleTier.urgent: return urgentWindowLength
        case SubtitleTier.fine:   return fineWindowLength
        default:                  return relaxedWindowLength
        }
    }

    private func windowLength(frontier: TimeInterval, playhead: TimeInterval) -> TimeInterval {
        isUrgent(frontier: frontier, playhead: playhead) ? urgentWindowLength : relaxedWindowLength
    }
    /// 창 앞에 덧대는 오디오. 분석기가 달리기 시작할 구간을 줘서 경계 첫 마디가
    /// 잘리는 걸 막는다. 이 구간에서 나온 세그먼트는 경계 필터가 걷어내므로
    /// 자막이 겹치지는 않는다.
    private let windowOverlap: TimeInterval = 2.5

    // MARK: - 미디어 연결

    /// 새 미디어가 열릴 때 호출. 캐시가 있으면 통째로 복원한다.
    func attach(sourceURL: URL?, asset: AVAsset?) {
        currentJob?.cancel()
        currentJob = nil
        cues = []
        coveredRanges = []
        provisionalRanges = []
        pendingRefine = []
        lastPersistedCount = 0
        leadSeconds = 0
        lastTickTime = nil
        mediaDuration = 0
        status = .idle
        self.sourceURL = sourceURL
        self.asset = asset

        // 캐시된 자막이 있으면 복원 — 두 번째 재생은 즉시 뜬다.
        // 어떤 구간을 만들었는지도 함께 복원한다. 큐의 시각에서 역산하면 말이 없어서
        // 큐가 안 생긴 구간을 "아직 안 만든 곳"으로 오해한다.
        if let cached = loadCache() {
            cues = cached.cues
            coveredRanges = cached.covered
            pendingRefine = cached.pending
            lastPersistedCount = cached.cues.count
        }
        // 지금 언어 조합으로 만든 게 없을 때만, 다른 언어로 만든 게 있는지 본다.
        otherLanguageCache = cues.isEmpty ? findOtherLanguageCache() : nil
        DostLog.log("attach url=\(sourceURL?.lastPathComponent ?? "nil") asset=\(asset != nil) cached=\(cues.count) other=\(otherLanguageCache.map { "\($0.source)_\($0.target)" } ?? "none")")
    }

    func detach() {
        flushCache()
        currentJob?.cancel()
        currentJob = nil
        cues = []
        coveredRanges = []
        provisionalRanges = []
        pendingRefine = []
        asset = nil
        sourceURL = nil
        mediaDuration = 0
        isRunning = false
        leadSeconds = 0
        lastTickTime = nil
        status = .idle
    }

    /// 생성 시작/재개.
    ///
    /// 다른 언어로 만들어 둔 캐시가 있으면 **사용자가 답할 때까지 시작하지 않는다.**
    /// 언어 설정이 잘못된 채로 만들면 쓰레기 자막이 쌓이고, 그걸 나중에 알아채도
    /// 이미 만들어진 것을 되돌리는 게 번거롭다. 만들기 전에 멈추는 게 맞다.
    func start() {
        guard canGenerate, otherLanguageCache == nil else { return }
        isRunning = true
        pump()
    }

    /// 다른 언어 캐시 프롬프트에 답한다. 무시하면 지금 설정 그대로 생성을 시작한다.
    /// (쓰겠다고 하면 호출부가 언어 설정을 바꾸고, 그 변경이 다시 attach 를 부른다.)
    func dismissOtherLanguagePrompt() {
        otherLanguageCache = nil
        start()
    }

    /// 생성 중지. 이미 만든 큐는 그대로 남는다.
    func stop() {
        isRunning = false
        currentJob?.cancel()
        currentJob = nil
        if case .working = status { status = .idle }
    }

    /// 만든 걸 버리고 처음부터 다시 만든다.
    func regenerate() {
        currentJob?.cancel()
        currentJob = nil
        cues = []
        coveredRanges = []
        provisionalRanges = []
        pendingRefine = []
        lastPersistedCount = 0
        if let url = cacheURL() { try? FileManager.default.removeItem(at: url) }
        status = .idle
        if isRunning { pump() }
    }

    // MARK: - 커버리지 구간 집합

    /// 구간을 덮은 것으로 기록하고, 맞닿거나 겹치는 것들을 병합한다.
    private func markCovered(from start: TimeInterval, to end: TimeInterval) {
        guard end > start else { return }
        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        var new = (start: start, end: end)
        for range in coveredRanges {
            // 0.5초 이내로 붙어 있으면 같은 구간으로 본다 (창 경계의 미세한 틈 흡수).
            if range.end < new.start - 0.5 {
                merged.append(range)
            } else if range.start > new.end + 0.5 {
                merged.append(new)
                new = range
            } else {
                new = (start: Swift.min(range.start, new.start), end: Swift.max(range.end, new.end))
            }
        }
        merged.append(new)
        coveredRanges = merged.sorted { $0.start < $1.start }
    }

    /// `t` 이상에서 아직 안 덮인 첫 지점. 전부 덮여 있으면 nil.
    /// 1초 미만의 틈은 덮인 것으로 친다 — 그걸 메우겠다고 1초짜리 창을 도는 건 낭비다.
    private func firstUncovered(from t: TimeInterval) -> TimeInterval? {
        var probe = t
        for range in coveredRanges where range.end > probe {
            if range.start > probe + 1.0 { return probe }
            probe = Swift.max(probe, range.end)
        }
        if mediaDuration > 0 && probe >= mediaDuration - 0.5 { return nil }
        return probe
    }

    /// `t` 뒤에 있는 다음 덮인 구간의 시작. 없으면 nil.
    private func nextCoveredStart(after t: TimeInterval) -> TimeInterval? {
        coveredRanges.first { $0.start > t }?.start
    }

    /// `t` 부터 이어지는 커버리지가 끝나는 지점. 안 덮여 있으면 t 자신.
    private func coveredEnd(from t: TimeInterval) -> TimeInterval {
        var probe = t
        for range in coveredRanges where range.end > probe {
            if range.start > probe + 1.0 { break }
            probe = Swift.max(probe, range.end)
        }
        return probe
    }

    // MARK: - 시간 진행

    /// 재생 시각이 바뀔 때마다 호출 (VideoSampler 의 time observer 에서).
    func tick(currentTime: TimeInterval, duration: TimeInterval) {
        if duration > 0 { mediaDuration = duration }
        guard isRunning else { return }

        let previous = lastTickTime
        lastTickTime = currentTime
        // 탐색(두 tick 사이 시각이 불연속으로 뜀)이면 진행 중이던 창은 엉뚱한 위치를 읽고
        // 있으므로 버린다. 단순히 생성이 뒤처진 거라면 그대로 두고 끝까지 마치게 한다.
        // 어디를 채울지는 pump 가 재생 헤드 기준으로 다시 고른다.
        if let previous, abs(currentTime - previous) > 2.0 {
            currentJob?.cancel()
            currentJob = nil
        }
        leadSeconds = max(0, coveredEnd(from: currentTime) - currentTime)
        pump(now: currentTime)
    }

    /// 필요하면 다음 창 작업을 시작한다.
    ///
    /// 채울 자리는 두 단계로 고른다.
    ///  1. **재생 헤드 이후의 첫 빈 구간.** 지금 보고 있는 자리가 언제나 먼저다. 그래서
    ///     뒤로 되감아도, 앞으로 건너뛰어도 그 자리부터 다시 만들어진다.
    ///  2. 재생 헤드부터 끝까지 다 찼으면 **앞쪽으로 돌아가 건너뛴 구간**을 메운다.
    ///
    /// look-ahead 만큼 앞서면 멈추는 게 아니라 파일 끝까지 계속 만든다. 재생 몇 분이면
    /// 전체가 캐시에 차서, 그 뒤로는 타임라인을 어디로 옮겨도 자막이 즉시 뜬다.
    /// (look-ahead 는 "이만큼은 확보돼야 한다"는 하한선으로 남아, leadSeconds 표시와
    /// 탐색 직후 우선순위 판단에 쓰인다.)
    private func pump(now: TimeInterval? = nil) {
        // 다른 언어 캐시 프롬프트가 떠 있으면 한 창도 만들지 않는다.
        // start() 에만 걸면 새지 않는다 — attach 보다 start 가 먼저 불리는 경로가 있어서,
        // 그때 isRunning 이 true 로 남아 이후 tick 에서 계속 돌아 버린다.
        guard isRunning, otherLanguageCache == nil, currentJob == nil, let asset else { return }
        let playhead = now ?? lastTickTime ?? 0

        // 재생 헤드 뒤가 다 찼으면 처음부터 다시 훑어 건너뛴 구간을 찾는다.
        let fillFrontier = firstUncovered(from: playhead) ?? firstUncovered(from: 0)
        let atEnd = fillFrontier.map { mediaDuration > 0 && $0 >= mediaDuration - 0.5 } ?? true

        let windowStart: TimeInterval
        var windowEnd: TimeInterval
        let boundary: TimeInterval
        /// 정교화 대상 구간. nil 이면 평소처럼 빈 곳을 채우는 중이다.
        let refining: (start: TimeInterval, end: TimeInterval, tier: Int)?
        let label: String

        if let frontier = fillFrontier, !atEnd {
            refining = nil
            boundary = frontier
            windowStart = max(0, frontier - windowOverlap)
            windowEnd = frontier + windowLength(frontier: frontier, playhead: playhead)
            if mediaDuration > 0 { windowEnd = min(windowEnd, mediaDuration) }
            // 이미 만들어 둔 다음 구간을 다시 읽지 않도록 창을 거기서 끊는다.
            if let nextCovered = nextCoveredStart(after: frontier) {
                windowEnd = min(windowEnd, nextCovered)
            }
            label = isUrgent(frontier: frontier, playhead: playhead) ? "urgent" : "relaxed"
        } else if let target = nextRefineTarget() {
            // 채울 곳이 없다 — 짧은 창으로 만들어 둔 구간을 긴 창으로 다시 만든다.
            //
            // 창을 대상 구간 **앞에서부터** 연다. 대상 자리에서 창을 시작하면 거기가
            // 콜드 스타트가 돼서 다시 만드는 의미가 없다. 앞쪽 오디오를 미리 흘려보내
            // 인식기가 문맥을 쥔 상태로 대상 구간에 도달하게 한다.
            //
            // 여기서는 "이미 덮인 구간에서 창을 끊는" 처리를 하지 않는다. 정교화는
            // 정의상 이미 만든 데를 다시 읽는 일이라, 끊으면 창이 도로 짧아져 아무것도
            // 나아지지 않는다.
            refining = target
            boundary = target.start
            windowStart = max(0, target.start - refineLeadIn)
            windowEnd = min(windowStart + windowLength(forTier: target.tier + 1),
                            mediaDuration > 0 ? mediaDuration : .greatestFiniteMagnitude)
            label = "refine"
        } else {
            status = .caughtUp
            persistCacheIfNeeded(force: true)
            return
        }

        guard windowEnd > windowStart + 0.5 else {
            if let target = refining { dropPending(target) }
            status = .caughtUp
            return
        }

        DostLog.log(String(format: "pump: window %.1f-%.1fs (%@) frontier=%.1f now=%.1f ranges=%d coarse=%d",
                           windowStart, windowEnd, label, boundary, playhead,
                           coveredRanges.count, pendingRefine.count))
        let locale = resolvedSourceLocale()
        let target = targetLanguage
        let translator = makeTranslator()
        // 정교화 창은 대상 구간을 한참 지나 끝나므로, 창 끝 세그먼트를 버리는 처리는
        // 필요 없다 (어차피 대상 구간 밖이라 채택하지 않는다).
        let isLastWindow = refining != nil || (mediaDuration > 0 && windowEnd >= mediaDuration - 0.01)

        status = .working
        jobGeneration &+= 1
        let generation = jobGeneration
        currentJob = Task { [weak self] in
            guard let self else { return }
            do {
                let range = CMTimeRange(
                    start: CMTime(seconds: windowStart, preferredTimescale: 600),
                    duration: CMTime(seconds: windowEnd - windowStart, preferredTimescale: 600)
                )
                let raw = try await self.transcriber.transcribe(asset: asset,
                                                                timeRange: range,
                                                                locale: locale)
                // 여기서부터는 취소를 확인하지 않는다.
                //
                // 인식이 끝난 순간 그 결과는 재생 위치와 무관하게 유효한 데이터다. 탐색
                // 때문에 취소됐다고 버리면, 비싼 작업을 다 해놓고 결과만 내다 버리는 셈이다.
                // 번역이 4~13초까지 걸리는 동안 사용자가 한 번만 움직여도 그 창이 통째로
                // 날아가서, 자주 탐색하면 자막이 아예 안 쌓인다.
                //
                // 밀려난 작업인지는 아래 MainActor 블록에서 세대 번호로 가린다. 결과는
                // 저장하되 다음 창을 고르는 흐름만 건드리지 않는다.
                DostLog.log(String(format: "transcribed %d segments for %.1f-%.1fs", raw.count, windowStart, windowEnd))

                // 겹침 구간에서 이미 만든 큐와 중복되는 세그먼트를 버린다.
                var segments = raw.filter { $0.end > boundary + 0.05 }

                // 창 끝에 딱 붙어 끝나는 세그먼트는 말이 잘렸을 가능성이 크다.
                // 마지막 창이 아니면 버리고, 다음 창을 그 세그먼트 시작점부터 다시 읽는다.
                var nextCovered = windowEnd
                if !isLastWindow, let last = segments.last, last.end >= windowEnd - 0.35 {
                    segments.removeLast()
                    nextCovered = max(boundary + 1.0, last.start)
                }

                let translated = try await self.translateIfNeeded(segments,
                                                                  translator: translator,
                                                                  locale: locale,
                                                                  target: target)

                await MainActor.run {
                    // 내 세대가 아니면 이미 밀려난 작업이다. 결과만 챙기고 흐름은 건드리지 않는다.
                    guard generation == self.jobGeneration else {
                        if refining == nil {
                            for cue in translated where !self.isDuplicate(cue) {
                                self.cues.insertSorted(cue)
                            }
                            if !translated.isEmpty { self.markCovered(from: boundary, to: nextCovered) }
                        }
                        DostLog.log("stale job gen=\(generation): 결과는 저장, 흐름은 현재 작업(gen=\(self.jobGeneration))에 맡김")
                        return
                    }

                    if let target = refining {
                        self.adoptRefined(translated, for: target)
                        self.currentJob = nil
                        self.persistCacheIfNeeded(force: true)
                        self.pump()
                        return
                    }

                    let tier = (label == "urgent") ? SubtitleTier.urgent : SubtitleTier.relaxed
                    for cue in translated where !self.isDuplicate(cue) {
                        var marked = cue
                        marked.tier = tier
                        self.cues.insertSorted(marked)
                    }
                    DostLog.log("+\(translated.count) cues (first: \(translated.first?.text.prefix(24) ?? ""))")
                    self.markCovered(from: boundary, to: nextCovered)
                    // 말이 하나도 안 나온 창은 "확인했고 자막 없음"으로 굳히지 않는다.
                    // 진짜 무음일 수도 있지만 디코딩이 잠깐 어긋나 빈 결과가 나왔을 수도 있는데,
                    // 둘을 구분할 방법이 없다. 이 세션에서는 덮인 것으로 쳐서 앞으로 나아가되
                    // (안 그러면 같은 창을 무한히 다시 읽는다) 캐시에는 남기지 않아서,
                    // 다음에 이 파일을 열면 한 번 더 시도한다.
                    if translated.isEmpty { self.provisionalRanges.append((boundary, nextCovered)) }
                    // 최고 등급이 아닌 구간은 나중에 300초 창으로 다시 만들 대상으로 남긴다.
                    if tier < SubtitleTier.max, !translated.isEmpty {
                        self.pendingRefine.append((boundary, nextCovered, tier))
                        self.sortPendingRefine()
                    }
                    self.currentJob = nil
                    self.persistCacheIfNeeded(force: false)
                    self.pump()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard generation == self.jobGeneration else { return }
                    self.currentJob = nil
                }
            } catch {
                DostLog.log("window FAILED: \(error.localizedDescription)")
                await MainActor.run {
                    guard generation == self.jobGeneration else { return }
                    self.currentJob = nil
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// 번역이 필요하면 번역해서, 아니면 원문 그대로 큐로 만든다.
    private nonisolated func translateIfNeeded(_ segments: [TranscriptSegment],
                                               translator: (any SubtitleTranslating)?,
                                               locale: Locale,
                                               target: Locale.Language) async throws -> [SubtitleCue] {
        guard !segments.isEmpty else { return [] }
        let sourceLang = locale.language

        // 같은 언어면 번역 생략 — 인식된 원문을 그대로 자막으로 쓴다.
        let sameLanguage = sourceLang.languageCode?.identifier == target.languageCode?.identifier
        guard let translator, !sameLanguage else {
            DostLog.log("translate skipped: translator=\(translator == nil ? "nil" : "ok") sameLanguage=\(sameLanguage)")
            return segments.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }
        }

        let lines = segments.map(\.text)
        let context = await MainActor.run { self.recentSourceContext(before: segments[0].start) }
        do {
            let translated = try await translator.translate(lines: lines,
                                                            context: context,
                                                            from: sourceLang,
                                                            to: target)
            guard translated.count == segments.count else {
                DostLog.log("translate count mismatch: \(translated.count) vs \(segments.count)")
                // 개수가 안 맞으면 매칭이 어긋난 자막을 보여주느니 원문을 쓴다.
                return segments.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }
            }
            return zip(segments, translated).map {
                SubtitleCue(start: $0.0.start, end: $0.0.end, text: $0.1, sourceText: $0.0.text)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DostLog.log("translate FAILED: \(error.localizedDescription)")
            // 번역 실패는 치명적이지 않다 — 원문 자막이라도 보여준다.
            return segments.map { SubtitleCue(start: $0.start, end: $0.end, text: $0.text) }
        }
    }

    /// 같은 대사가 시작 시각만 몇십 밀리초 다른 채로 여러 번 들어오는 경우가 있다.
    /// 분석기가 같은 구간을 다듬어 다시 내보내거나 창이 겹칠 때 생기는데, 상류에서
    /// 완벽히 막기 어려우니 큐 단위에서 한 번 더 거른다. 한쪽이 다른 쪽을 포함하는
    /// 경우("これがこれが最後か" vs "これが最後か")도 같은 대사로 본다.
    /// 분석기가 같은 구간을 다듬어 두 번 내보낸 큐를 걸러낸다.
    ///
    /// 포함 관계(`contains`)까지 보는 이유는 다듬어진 결과가 앞선 결과보다 길어지는
    /// 경우가 있어서인데, 짧은 문자열에 그대로 적용하면 안 된다 — "네." "응." "Yes."
    /// 같은 맞장구는 2초 안의 아무 긴 대사에나 포함돼 버려서, 대사가 촘촘한 구간일수록
    /// 멀쩡한 자막이 통째로 사라진다. 그래서 포함 판정은 짧은 쪽이 충분히 길 때만 쓴다.
    private func isDuplicate(_ cue: SubtitleCue) -> Bool {
        let window: TimeInterval = 2.0
        /// 이보다 짧은 문자열은 포함 관계를 중복의 근거로 삼지 않는다.
        let minLengthForContainment = 10
        let candidate = cue.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return true }
        return cues.contains { existing in
            guard abs(existing.start - cue.start) < window else { return false }
            let other = existing.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if other == candidate { return true }
            guard min(other.count, candidate.count) >= minLengthForContainment else { return false }
            return other.contains(candidate) || candidate.contains(other)
        }
    }

    /// 번역 문맥으로 넘길 직전 원문 몇 줄.
    private func recentSourceContext(before start: TimeInterval, count: Int = 3) -> [String] {
        cues.filter { $0.start < start }.suffix(count).map(\.sourceText)
    }

    private func makeTranslator() -> (any SubtitleTranslating)? {
        switch backend {
        case .apple:
            return AppleTranslator()
        case .claude:
            guard let key = ClaudeAPIKeyStore.load() else { return nil }
            return ClaudeTranslator(model: claudeModel, apiKey: key)
        }
    }

    private func resolvedSourceLocale() -> Locale {
        if let sourceLocale { return sourceLocale }
        if let first = Locale.preferredLanguages.first { return Locale(identifier: first) }
        return Locale(identifier: "en-US")
    }

    // MARK: - 캐시

    /// 캐시는 SRT 가 아니라 JSON 이다. SRT 로 저장하면 "어디까지 만들었는지"를 담을 수 없어서
    /// 중간에 구멍이 뚫린 캐시가 전체 커버리지를 주장해 버린다(그러면 재생해도 영영 안 채워진다).
    /// version 은 생성 알고리즘이 바뀔 때 올린다 — 옛 결과가 눌러앉는 걸 막는다.
    private struct CachedSubtitles: Codable {
        var version: Int
        /// 만들어 둔 구간들. [[start, end], …]
        var covered: [[TimeInterval]]
        var cues: [SubtitleCue]
        /// 아직 최고 등급으로 다시 만들지 않은 구간. [시작, 끝, 등급] 형태.
        var pending: [[Double]]?
    }
    /// 2: 창 길이 60초 + 중복 판정 완화. 형식은 그대로지만 1로 만든 캐시는 품질이
    ///    떨어져서, 그대로 두면 이미 본 파일에서는 개선이 보이지 않는다. 버전을 올려
    ///    다시 재생할 때 재생성되게 한다 (재생 위치 앞쪽부터 필요한 만큼만).
    private static let cacheFormatVersion = 4

    /// 캐시 위치: ~/Library/Application Support/24dost/subtitles/<hash>.<lang>.<engine>.json
    /// 원본 폴더를 건드리지 않으려고 앱 지원 폴더에 둔다.
    private func cacheURL() -> URL? {
        guard let sourceURL else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = base?.appendingPathComponent("24dost/subtitles", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 경로 + 파일 크기로 키를 만든다 (같은 이름 다른 파일 구분).
        var keySource = sourceURL.absoluteString
        if sourceURL.isFileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
           let size = attrs[.size] as? NSNumber {
            keySource += "|\(size.int64Value)"
        }
        let digest = SHA256.hash(data: Data(keySource.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined().prefix(20)
        // **인식 언어도 키에 넣는다.** 대상 언어와 엔진은 원래 들어 있었는데 인식 언어만
        // 빠져 있었다. 그래서 언어를 잘못 잡고 만든 쓰레기 자막이, 설정을 고쳐도 같은
        // 파일에서 그대로 다시 읽혀 남아 있었다(커버리지가 "다 만듦"이라 재생성도 안 된다).
        // 지우지 않고 키를 가르는 이유는 되돌릴 수 있게 하기 위해서다 — 언어를 되돌리면
        // 예전에 제대로 만든 자막이 그대로 돌아온다.
        //
        // 설정 문자열이 아니라 **해석된 실제 로케일**을 쓴다. 지역까지 포함해야 한다
        // (en-GB 와 en-US 는 인식 결과가 다르다).
        let src = resolvedSourceLocale().identifier(.bcp47)
        let dst = targetLanguage.languageCode?.identifier ?? "xx"
        return dir.appendingPathComponent("\(hash).\(src)_\(dst).\(backend.rawValue).json")
    }

    private func loadCache() -> (cues: [SubtitleCue],
                                covered: [(start: TimeInterval, end: TimeInterval)],
                                pending: [(start: TimeInterval, end: TimeInterval, tier: Int)])? {
        guard let url = cacheURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CachedSubtitles.self, from: data),
              decoded.version == Self.cacheFormatVersion,
              !decoded.cues.isEmpty else { return nil }
        let covered = decoded.covered
            .filter { $0.count == 2 && $0[1] > $0[0] }
            .map { (start: $0[0], end: $0[1]) }
        let pending = (decoded.pending ?? [])
            .filter { $0.count == 3 && $0[1] > $0[0] }
            .map { (start: $0[0], end: $0[1], tier: Int($0[2])) }
        return (decoded.cues, covered, pending)
    }

    /// 정교화 창이 대상 구간 앞에서부터 열리는 길이. 인식기가 문맥을 쥔 상태로
    /// 대상 구간에 도달하게 하는 게 목적이라, 대상보다 넉넉히 앞서야 한다.
    private let refineLeadIn: TimeInterval = 60

    /// 다음에 다시 만들 구간. 등급이 낮은 것부터, 같으면 앞쪽부터.
    private func nextRefineTarget() -> (start: TimeInterval, end: TimeInterval, tier: Int)? {
        pendingRefine.first
    }

    private func sortPendingRefine() {
        pendingRefine.sort { ($0.tier, $0.start) < ($1.tier, $1.start) }
    }

    /// 정교화 결과를 받아들일지 판단하고, 받아들이면 그 구간의 큐를 갈아끼운다.
    ///
    /// **더 나빠질 수 있으면 안 된다.** 다시 만든 결과가 비었거나 원래보다 줄었으면
    /// 옛것을 그대로 둔다. 개선한다면서 멀쩡한 자막을 지우는 건 안 하느니만 못하다.
    /// 채택 여부와 무관하게 대상은 목록에서 뺀다 — 안 그러면 같은 구간을 계속 다시 만든다.
    private func adoptRefined(_ produced: [SubtitleCue],
                              for target: (start: TimeInterval, end: TimeInterval, tier: Int)) {
        defer { dropPending(target) }

        // 창은 대상보다 길지만, 채택하는 건 대상 구간 안쪽뿐이다. 바깥은 이미 긴 창으로
        // 만들어 둔 자리라 건드릴 이유가 없다.
        let fresh = produced.filter { $0.start >= target.start && $0.start < target.end }
        let existing = cues.filter { $0.start >= target.start && $0.start < target.end }
        let freshChars = fresh.reduce(0) { $0 + $1.text.count }
        let existingChars = existing.reduce(0) { $0 + $1.text.count }
        DostLog.log(String(format: "  refine 후보 %.1f-%.1fs: 큐 %d→%d, 글자 %d→%d",
                           target.start, target.end,
                           existing.count, fresh.count, existingChars, freshChars))
        // 개수만 보면 구멍이 있다 — 줄 수는 같은데 내용이 줄어든 결과가 통과한다.
        // 실측에서 6→6 인데 글자가 65→60 으로 준 경우가 있었다. 둘 다 안 줄어야 채택한다.
        guard !fresh.isEmpty, fresh.count >= existing.count, freshChars >= existingChars else {
            DostLog.log(String(format: "refine %.1f-%.1fs tier%d→%d 기각 (큐 %d→%d, 글자 %d→%d)",
                               target.start, target.end, target.tier, target.tier + 1,
                               existing.count, fresh.count, existingChars, freshChars))
            return
        }
        let newTier = target.tier + 1
        cues.removeAll { $0.start >= target.start && $0.start < target.end }
        for cue in fresh {
            var marked = cue
            marked.tier = newTier
            cues.insertSorted(marked)
        }
        // 한 칸씩만 올린다 — 단계별 결과를 눈으로 비교할 수 있어야 하기 때문이다.
        // 아직 최고 등급이 아니면 다음 차례를 위해 대기열에 되돌린다.
        if newTier < SubtitleTier.max {
            pendingRefine.append((target.start, target.end, newTier))
            sortPendingRefine()
        }
        DostLog.log(String(format: "refine %.1f-%.1fs tier%d→%d 채택 (큐 %d→%d, 글자 %d→%d)",
                           target.start, target.end, target.tier, newTier,
                           existing.count, fresh.count, existingChars, freshChars))
    }

    /// 방금 처리한 항목만 대기열에서 뺀다.
    /// **등급까지 비교해야 한다** — 채택 뒤 같은 구간을 한 칸 올려 다시 넣는데,
    /// 시작·끝만 보고 지우면 그 새 항목까지 같이 날아가 다음 단계가 사라진다.
    private func dropPending(_ target: (start: TimeInterval, end: TimeInterval, tier: Int)) {
        pendingRefine.removeAll {
            abs($0.start - target.start) < 0.01
                && abs($0.end - target.end) < 0.01
                && $0.tier == target.tier
        }
    }

    /// 이 영상에 대해 **다른 언어 조합으로 만들어 둔 캐시**가 있으면 그 조합.
    /// 지금 설정으로는 자막이 없는데 예전에 다른 언어로 만든 게 있을 때만 값이 있다.
    @Published private(set) var otherLanguageCache: (source: String, target: String)? = nil

    /// 같은 영상(해시)의 다른 언어 캐시를 찾는다. 파일명은
    /// `<해시>.<인식>_<대상>.<엔진>.json` 이라 가운데 칸만 다르다.
    private func findOtherLanguageCache() -> (source: String, target: String)? {
        guard let current = cacheURL() else { return nil }
        let dir = current.deletingLastPathComponent()
        let hash = String(current.lastPathComponent.prefix(while: { $0 != "." }))
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil) else { return nil }
        for f in files where f.pathExtension == "json" && f.lastPathComponent != current.lastPathComponent {
            let parts = f.lastPathComponent.split(separator: ".")
            // [해시, 인식_대상, 엔진, json]
            guard parts.count == 4, parts[0] == hash else { continue }
            let langs = parts[1].split(separator: "_")
            guard langs.count == 2 else { continue }   // 옛 형식(<해시>.<대상>.<엔진>)은 건너뛴다
            // 내용이 비어 있으면 물어볼 값이 없다.
            guard let data = try? Data(contentsOf: f),
                  let decoded = try? JSONDecoder().decode(CachedSubtitles.self, from: data),
                  !decoded.cues.isEmpty else { continue }
            return (String(langs[0]), String(langs[1]))
        }
        return nil
    }

    /// 생성 자막 캐시 폴더를 통째로 비운다. 지운 파일 수를 돌려준다.
    static func clearAllCaches() -> Int {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let dir = base?.appendingPathComponent("24dost/subtitles", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for f in files where f.pathExtension == "json" {
            if (try? FileManager.default.removeItem(at: f)) != nil { removed += 1 }
        }
        return removed
    }

    /// 캐시에 남길 커버리지. 잠정 구간(인식 결과가 비었던 창)은 빼고 준다.
    /// 그래야 다음에 이 파일을 열 때 그 구간을 한 번 더 시도한다.
    private func persistableCoveredRanges() -> [(start: TimeInterval, end: TimeInterval)] {
        guard !provisionalRanges.isEmpty else { return coveredRanges }
        var result: [(start: TimeInterval, end: TimeInterval)] = []
        for range in coveredRanges {
            // 이 구간에서 잠정 부분을 잘라낸다.
            var pieces = [range]
            for hole in provisionalRanges {
                var next: [(start: TimeInterval, end: TimeInterval)] = []
                for piece in pieces {
                    if hole.end <= piece.start || hole.start >= piece.end {
                        next.append(piece)
                        continue
                    }
                    if hole.start > piece.start { next.append((piece.start, hole.start)) }
                    if hole.end < piece.end { next.append((hole.end, piece.end)) }
                }
                pieces = next
            }
            result += pieces.filter { $0.end - $0.start > 0.5 }
        }
        return result
    }

    /// 일정 개수 이상 쌓였을 때만 디스크에 쓴다 (매 창마다 쓰면 I/O 낭비).
    /// 임계값이 높으면 대사가 드문 영상에서 앱을 닫을 때 만든 걸 통째로 날린다.
    private func persistCacheIfNeeded(force: Bool) {
        guard !cues.isEmpty, let url = cacheURL() else { return }
        let grown = cues.count - lastPersistedCount
        guard force || grown >= 4 else { return }
        let payload = CachedSubtitles(version: Self.cacheFormatVersion,
                                      covered: persistableCoveredRanges().map { [$0.start, $0.end] },
                                      cues: cues,
                                      pending: pendingRefine.map { [$0.start, $0.end, Double($0.tier)] })
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: url, options: .atomic)
            lastPersistedCount = cues.count
        }
    }

    /// 세션이 끝날 때 남은 자막을 디스크에 밀어 넣는다.
    func flushCache() { persistCacheIfNeeded(force: true) }

    /// 생성된 자막을 영상 옆에 .srt 로 내보낸다 (⇧⌘E).
    @discardableResult
    func exportSRT() -> URL? {
        guard !cues.isEmpty, let sourceURL, sourceURL.isFileURL else { return nil }
        let lang = targetLanguage.languageCode?.identifier ?? "sub"
        // 확장자 바로 앞에 .autosub 를 붙여 사람이 만든 자막과 구분한다.
        // 영상과 같은 폴더에 나란히 놓이므로 이름만으로 출처를 알 수 있어야 한다.
        let out = sourceURL.deletingPathExtension()
            .appendingPathExtension("\(lang).autosub.srt")
        do {
            try SubtitleFile.srtString(from: cues).write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }
}
