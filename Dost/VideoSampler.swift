import AVFoundation
import AppKit
import Accelerate
import CoreImage

/// Pre-analyzed audio energy frame for audio visualization.
struct AudioEnergyFrame {
    let rms: Float       // Overall RMS level (0–1)
}

@MainActor
class VideoSampler: ObservableObject {
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private var subtitleDelegate: SubtitleDelegate?
    private var timer: Timer?
    private var lastPixelBuffer: CVPixelBuffer?
    private var endObserver: Any?   // AVPlayerItem 재생 종료 알림 토큰
    private var videoFrameGeneration: UInt64 = 0
    private var lastRenderSignature: RenderSignature?

    private struct RenderSignature: Equatable {
        let gridSize: Int
        let displayW: Int
        let displayH: Int
        let frameGeneration: UInt64
        let zoomPermille: Int
    }

    // 전체화면 콘텐츠 줌 (fit 대비 배율).
    //   fit    = 화면 안에 비율 유지로 맞춤(기본, 여백 발생 가능)
    //   fill   = 비율 유지로 화면을 꽉 채움(넘치는 부분 중앙 크롭)
    //   custom = 핀치 제스처로 만든 임의 배율 (1.0 = fit)
    enum ContentZoom: Equatable {
        case fit
        case fill
        case custom(CGFloat)
    }
    @Published var contentZoom: ContentZoom = .fit

    static let maxContentZoom: CGFloat = 8.0

    /// fit 대비 fill 배율. 디스플레이/비디오 비율이 같으면 1.
    private func fillScale(dispW: CGFloat, dispH: CGFloat, videoAspect: CGFloat) -> CGFloat {
        let displayAspect = dispW / dispH
        return displayAspect > videoAspect
            ? displayAspect / videoAspect
            : videoAspect / displayAspect
    }

    /// 현재 모드의 실효 배율 (fit 기준 1.0).
    private func effectiveZoom(dispW: CGFloat, dispH: CGFloat, videoAspect: CGFloat) -> CGFloat {
        switch contentZoom {
        case .fit:              return 1.0
        case .fill:             return fillScale(dispW: dispW, dispH: dispH, videoAspect: videoAspect)
        case .custom(let z):    return z
        }
    }

    /// 현재 표시 상태의 실효 콘텐츠 줌 (fit=1). 피크 레이어 등 외부 뷰 동기화용.
    func currentEffectiveZoom() -> CGFloat {
        let dispW = currentDisplaySize.width, dispH = currentDisplaySize.height
        guard dispW > 0, dispH > 0, videoSize.width > 0, videoSize.height > 0 else { return 1 }
        return effectiveZoom(dispW: dispW, dispH: dispH,
                             videoAspect: videoSize.width / videoSize.height)
    }

    /// 핀치 제스처 증분 적용. 현재 실효 배율에서 이어서 커스텀 배율로 전환.
    func zoomBy(magnification delta: CGFloat) {
        guard currentDisplaySize.width > 0, currentDisplaySize.height > 0,
              videoSize.width > 0, videoSize.height > 0 else { return }
        let next = min(max(currentEffectiveZoom() * (1 + delta), 1.0), Self.maxContentZoom)
        contentZoom = next <= 1.0 ? .fit : .custom(next)
    }

    func zoomToFit()  { contentZoom = .fit }
    func zoomToFill() { contentZoom = .fill }

    @Published var dotColors: [[CGColor]] = []
    @Published var videoSize: CGSize = .zero
    @Published var isPlaying = false
    @Published var urlLoadError: String?     // URL 또는 ffmpeg 처리 실패 등
    @Published var isLoadingMedia: Bool = false   // remux 진행 중 표시용
    @Published var isStaticContent: Bool = false  // 이미지 모드 — 플레이 기능 비활성화
    @Published var isAudioMode: Bool = false      // 오디오 전용 모드 — 영상 없이 시각화
    @Published var backgroundDotAlpha: Double = 0.40
    
    // 볼륨 영속성 (0.0 ~ 1.2)
    private static let volumeKey = "dost.volume"
    private var lastVolume: Float = 1.0

    private var activeRemuxTempURL: URL?
    /// remux 전 원본 URL. 자막 캐시 키와 .srt 내보내기 경로에 쓴다
    /// (remux 임시 파일 경로를 쓰면 매번 캐시가 어긋난다).
    private(set) var currentSourceURL: URL?
    /// 진행 중인 탐색의 목표 시각. 주기 관찰자가 탐색 완료 전 옛 위치를 한 번 더
    /// 보고하는데, 그걸 그대로 넘기면 생성기가 또 다른 탐색으로 읽고 방금 시작한
    /// 작업을 취소해 버린다.
    private var seekTarget: TimeInterval?

    /// 탐색을 시작했다고 표시. 완료 콜백이 없는 경로도 있어 시간으로도 해제한다.
    private func noteSeek(to seconds: TimeInterval, _ who: String = #function) {
        DostLog.log(String(format: "SEEK from %@ -> %.1fs", who, seconds))
        seekTarget = seconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if self?.seekTarget == seconds { self?.seekTarget = nil }
        }
    }
    // 오디오 시각화용 사전 분석 데이터
    private var audioEnergyFrames: [AudioEnergyFrame] = []
    private var audioAnalysisRate: Double = 30.0
    private var audioAnalysisTask: Task<Void, Never>?

    // 자막
    @Published var hasSubtitles: Bool = false
    @Published var showSubtitles: Bool = true
    @Published var currentSubtitle: String = ""
    @Published var hasExternalSubtitle: Bool = false
    private enum SubtitleMode: Equatable {
        case off
        case embedded
        case external
        case generated      // 음성 인식 + 번역으로 직접 만든 자막
    }
    private var subtitleMode: SubtitleMode = .off
    private var legibleGroup: AVMediaSelectionGroup?
    private var firstLegibleOption: AVMediaSelectionOption?
    private var hasEmbeddedSubtitle: Bool = false
    // 외부 자막(.srt, .smi). 로드 시 embedded 보다 우선.
    private var externalCues: [SubtitleCue] = []
    /// 외부/생성 자막을 재생 시각에 맞춰 갱신하는 관찰자. 내장 자막은 플레이어가 밀어준다.
    private var subtitleTimeObserver: Any?

    /// 음성 인식 + 번역으로 자막을 만드는 생성기. 표시는 여기(VideoSampler)가 하고,
    /// 생성기는 큐만 만들어 준다.
    let generator = SubtitleGenerator()
    @Published var hasGeneratedSubtitle: Bool = false
    /// 자동 생성이 설정에서 켜져 있는지. ContentView 가 넣어 준다.
    var autoGenerateSubtitles: Bool = false

    // 오버레이 효과
    enum OverlayEffect: Equatable {
        case none
        case border       // play/pause: 테두리 전체
        case row(Int)     // 볼륨: 1-based visible row (위=1)
        case col(Int)     // seek: 1-based visible col (왼쪽=1)
    }
    @Published var overlayEffect: OverlayEffect = .none
    @Published var overlayProgress: Double = 0.0
    @Published var overlayBlinks: Int = 1
    @Published var overlayIsAlert: Bool = false   // 한계치 도달 시 true -> 악센트 색상으로 강제
    private var overlayStartTime: Date?
    private let overlayDuration: TimeInterval = 0.5

    var currentDisplaySize: CGSize = .zero

    // 점 크기/간격 (w,s,a,d,z 키로 조절)
    // 제약: dotDiameter ≥ 8, gridSize ≥ dotDiameter + minGap
    //       (gap = gridSize − dotDiameter ≥ 1 → 점끼리 붙지 않음)
    // 마지막 값은 UserDefaults에 저장되어 다음 실행 시 복원. z 초기화는 기본값으로 되돌림.
    private let defaultGridSize: CGFloat = 40
    private let defaultDotDiameter: CGFloat = 16
    private let dotDiameterMin: CGFloat = 8
    private let minGap: CGFloat = 1
    private static let gridSizeKey    = "dost.gridSize"
    private static let dotDiameterKey = "dost.dotDiameter"
    @Published var gridSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(gridSize), forKey: Self.gridSizeKey) }
    }
    @Published var dotDiameter: CGFloat {
        didSet { UserDefaults.standard.set(Double(dotDiameter), forKey: Self.dotDiameterKey) }
    }

    // 자막 글자 크기 ([/] 키로 조절). 기본 18pt, 최소 18pt, 4pt씩 최대 54pt까지.
    // 값이 바뀌면 Canvas가 re-render되어 도트 숨김 영역이 즉시 갱신됨.
    let subtitleFontMin: CGFloat = 18
    let subtitleFontDefault: CGFloat = 18
    let subtitleFontStep: CGFloat = 4
    let subtitleFontMaxSteps: Int = 9
    private static let subtitleFontSizeKey = "dost.subtitleFontSize"
    @Published var subtitleFontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(subtitleFontSize), forKey: Self.subtitleFontSizeKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        var d = (defaults.object(forKey: Self.dotDiameterKey) as? Double).map { CGFloat($0) } ?? defaultDotDiameter
        var g = (defaults.object(forKey: Self.gridSizeKey)    as? Double).map { CGFloat($0) } ?? defaultGridSize
        // 저장된 값이 현재 제약을 위반할 수 있으니 방어적으로 clamp
        d = max(dotDiameterMin, d)
        g = max(d + minGap, g)
        self.dotDiameter = d
        self.gridSize = g

        let subMin = 18 as CGFloat
        let subDefault = 18 as CGFloat
        let subStep = 4 as CGFloat
        let subMaxSteps = 9
        let subMax = subMin + subStep * CGFloat(subMaxSteps)
        var s = (defaults.object(forKey: Self.subtitleFontSizeKey) as? Double).map { CGFloat($0) } ?? subDefault
        s = max(subMin, min(subMax, s))
        // 스텝 경계로 스냅 (저장값이 오염됐을 경우 방어)
        let steps = (s - subMin) / subStep
        s = subMin + subStep * CGFloat(Int(steps.rounded()))
        self.subtitleFontSize = s
        
        // 저장된 볼륨 복원 (기본값 1.0)
        self.lastVolume = (defaults.object(forKey: Self.volumeKey) as? Float) ?? 1.0
    }

    func increaseDotSize() {
        // 점 크기는 gridSize - minGap 까지만 (gap ≥ 1)
        dotDiameter = min(gridSize - minGap, dotDiameter + 2)
    }

    func decreaseDotSize() {
        dotDiameter = max(dotDiameterMin, dotDiameter - 2)
    }

    func increaseGap() {
        gridSize += 2
    }

    func decreaseGap() {
        // gridSize는 dotDiameter + minGap 아래로 내려갈 수 없음 (gap ≥ 1)
        gridSize = max(dotDiameter + minGap, gridSize - 2)
    }

    func resetDotSettings() {
        gridSize = defaultGridSize
        dotDiameter = defaultDotDiameter
    }

    func increaseSubtitleSize() {
        let maxSize = subtitleFontMin + subtitleFontStep * CGFloat(subtitleFontMaxSteps)
        subtitleFontSize = min(maxSize, subtitleFontSize + subtitleFontStep)
    }

    func decreaseSubtitleSize() {
        subtitleFontSize = max(subtitleFontMin, subtitleFontSize - subtitleFontStep)
    }

    // MARK: - Open

    /// 외부 진입점. AVFoundation이 지원 안 하는 컨테이너(mkv/webm/avi 등)는 ffmpeg로 remux 후 재생.
    /// 이미지 확장자면 정적 이미지 모드로 로드 (플레이 관련 기능은 비활성).
    func open(url: URL) {
        startTimerIfNeeded()
        // 이미지 파일은 별도 경로로 처리
        if url.isFileURL && Self.isImageFile(url: url) {
            openImage(url: url)
            return
        }

        cleanup()
        // 기존 remux 임시 파일 제거
        if let prev = activeRemuxTempURL {
            try? FileManager.default.removeItem(at: prev)
            activeRemuxTempURL = nil
        }
        currentSourceURL = url

        // 로컬 파일이고 AVFoundation이 지원 안 하는 확장자면 remux
        if url.isFileURL && Self.needsRemux(url: url) {
            isLoadingMedia = true
            Task.detached { [weak self] in
                let outcome = await Self.remuxToMP4(source: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingMedia = false
                    switch outcome {
                    case .success(let tempURL):
                        self.activeRemuxTempURL = tempURL
                        self.loadPlayable(url: tempURL)
                    case .failure(let message):
                        self.urlLoadError = message
                    }
                }
            }
        } else {
            loadPlayable(url: url)
        }
    }

    /// AVPlayer가 바로 재생 가능한 URL을 로드
    private func loadPlayable(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        item.add(output)
        videoOutput = output

        // 자막 출력(attributed string 푸시). 플레이어 렌더링은 억제하고 우리가 직접 그린다.
        let legible = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        legible.suppressesPlayerRendering = true
        let delegate = SubtitleDelegate { [weak self] strings in
            Task { @MainActor in
                guard let self else { return }
                // showSubtitles가 꺼져 있으면 갱신만 받아서 버리지 않고 비운다.
                let text = strings
                    .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                self.currentSubtitle = text
            }
        }
        legible.setDelegate(delegate, queue: .main)
        item.add(legible)
        self.legibleOutput = legible
        self.subtitleDelegate = delegate

        player = AVPlayer(playerItem: item)
        player?.volume = lastVolume

        // 자막 초기 상태 리셋
        hasSubtitles = false
        currentSubtitle = ""
        legibleGroup = nil
        firstLegibleOption = nil
        hasEmbeddedSubtitle = false
        seekTarget = nil

        // 생성기에 새 미디어를 물린다. 캐시가 있으면 즉시 복원된다.
        // remux 된 파일이어도 오디오 타임라인은 원본과 같으므로 그대로 읽으면 된다.
        generator.attach(sourceURL: currentSourceURL ?? url, asset: asset)
        hasGeneratedSubtitle = generator.canGenerate
        installSubtitleTimeObserver()

        // 오디오 파일은 즉시 오디오 모드 진입 (타이머 시작 전 placeholder 방지)
        if url.isFileURL && Self.isAudioFile(url: url) {
            isAudioMode = true
        }

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    // 비디오 트랙 있음 → 비디오 모드
                    self.isAudioMode = false
                    let naturalSize = try await track.load(.naturalSize)
                    let transform   = try await track.load(.preferredTransform)
                    let transformed = naturalSize.applying(transform)
                    let absSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                    self.videoSize = (absSize.width > 0 && absSize.height > 0) ? absSize : naturalSize
                } else {
                    // 비디오 트랙 없음 → 오디오 전용 모드
                    self.isAudioMode = true
                }
                // 오디오 모드일 때 로컬 파일이면 빠른 볼륨 추출 후 재생
                if self.isAudioMode && url.isFileURL {
                    let fileURL = url
                    self.audioAnalysisTask = Task.detached { [weak self] in
                        let result = VideoSampler.analyzeAudioFile(url: fileURL)
                        await MainActor.run { [weak self] in
                            self?.audioEnergyFrames = result.frames
                            self?.audioAnalysisRate = result.rate
                            
                            // 분석이 눈 깜짝할 새 끝나므로 곧바로 재생 시작
                            self?.player?.play()
                            self?.isPlaying = true
                        }
                    }
                } else {
                    // 비디오이거나 외부 URL 오디오인 경우 바로 재생
                    self.player?.play()
                    self.isPlaying = true
                }
            } catch {
                print("Failed to load video track: \(error)")
                self.player?.play()
                self.isPlaying = true
            }
        }

        // legible(자막) 트랙 탐지 및 자동 선택.
        // 트랙이 없어도(group == nil) 여기서 빠져나가면 안 된다 — 자동 생성 자막을 켤지
        // 정하는 것도, hasSubtitles 를 갱신하는 것도 이 블록이라서, 예전처럼 guard 로
        // 조기 반환하면 "내장 자막 없는 파일에서는 자동 생성이 아예 안 켜지는" 상태가 된다.
        Task { [weak self] in
            guard let self else { return }
            do {
                let group = try? await asset.loadMediaSelectionGroup(for: .legible)
                await MainActor.run {
                    let options = group?.options.filter {
                        !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                    } ?? []
                    self.legibleGroup = group
                    self.firstLegibleOption = options.first
                    self.hasEmbeddedSubtitle = !options.isEmpty
                    self.updateHasSubtitlesFlag()
                    if self.hasExternalSubtitle {
                        self.subtitleMode = .external
                    } else if self.showSubtitles && !options.isEmpty {
                        self.subtitleMode = .embedded
                    } else if self.autoGenerateSubtitles && self.generator.canGenerate {
                        self.subtitleMode = .generated
                    } else {
                        self.subtitleMode = .off
                    }
                    self.applySubtitleMode()
                }
            } catch {
                // legible 그룹이 없는 자산은 정상(자막 없음)
            }
        }

        // 재생 종료 감지 → ContentView 에 알림. 이전 observer 가 있으면 먼저 제거.
        if let prev = endObserver { NotificationCenter.default.removeObserver(prev) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPlaying = false
                NotificationCenter.default.post(name: .playbackEnded, object: nil)
            }
        }

        // 재생 시작(play / isPlaying)은 위 Task 내부 조건(분석 완료 후 등)으로 이동됨.

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleCurrentFrame() }
        }
        // .common 모드로 등록 → 마우스 홀드(일반 peek) 등 이벤트 트래킹 중에도 계속 샘플링.
        // (.default 모드 타이머는 마우스를 누르고 있는 동안 멈춰 dotColors가 동결됨)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 자막 표시 토글. 자막 트랙(내장/외장 어느 쪽이든)이 없으면 아무 일도 하지 않음.
    /// 외부/내장 자막이 모두 있으면 외부 → 내장 → OFF 순서로 순환한다.
    func toggleSubtitles() {
        let modes = availableSubtitleModesInCycleOrder()
        guard !modes.isEmpty else { return }

        let current = effectiveSubtitleMode()
        let nextIndex = modes.firstIndex(of: current).map { ($0 + 1) % modes.count } ?? 0
        subtitleMode = modes[nextIndex]
        applySubtitleMode()
    }

    // MARK: - External Subtitle (.srt / .smi)

    /// Shift+C 로 선택된 외부 자막 파일 로드. 성공 시 true, 실패 시 false.
    /// 이미 내장 자막이 선택되어 있더라도 외부 자막이 우선한다.
    func loadExternalSubtitle(url: URL) -> Bool {
        guard let cues = SubtitleFile.parse(url: url) else { return false }
        externalCues = cues
        hasExternalSubtitle = true
        updateHasSubtitlesFlag()
        subtitleMode = .external
        showSubtitles = true
        applySubtitleMode()
        return true
    }

    private func clearExternalSubtitleState() {
        externalCues = []
        hasExternalSubtitle = false
        updateHasSubtitlesFlag()
        if subtitleMode == .external {
            subtitleMode = hasEmbeddedSubtitle && showSubtitles ? .embedded : .off
        }
        applySubtitleMode()
    }

    private func updateHasSubtitlesFlag() {
        hasSubtitles = hasEmbeddedSubtitle || hasExternalSubtitle || generator.canGenerate
    }

    var subtitleModeLabel: String? {
        switch effectiveSubtitleMode() {
        case .off:
            return hasSubtitles ? "SUBTITLE OFF" : nil
        case .embedded:
            return "EMBEDDED SUB"
        case .external:
            return "EXTERNAL SUB"
        case .generated:
            return "AUTO SUB"
        }
    }

    /// 순환 순서: 끄기 → 외부 → 내장 → 자동 생성.
    private func availableSubtitleModesInCycleOrder() -> [SubtitleMode] {
        var modes: [SubtitleMode] = [.off]
        if hasExternalSubtitle { modes.append(.external) }
        if hasEmbeddedSubtitle { modes.append(.embedded) }
        if generator.canGenerate { modes.append(.generated) }
        return modes.count > 1 ? modes : []
    }

    private func effectiveSubtitleMode() -> SubtitleMode {
        switch subtitleMode {
        case .embedded where hasEmbeddedSubtitle:
            return .embedded
        case .external where hasExternalSubtitle:
            return .external
        case .generated where generator.canGenerate:
            return .generated
        default:
            return .off
        }
    }

    private func applySubtitleMode() {
        let mode = effectiveSubtitleMode()
        DostLog.log("applySubtitleMode: requested=\(subtitleMode) effective=\(mode) canGen=\(generator.canGenerate) hasEmb=\(hasEmbeddedSubtitle) hasExt=\(hasExternalSubtitle)")
        subtitleMode = mode
        showSubtitles = mode != .off

        if let item = player?.currentItem, let group = legibleGroup {
            switch mode {
            case .embedded:
                if let opt = firstLegibleOption {
                    item.select(opt, in: group)
                } else {
                    item.select(nil, in: group)
                }
                currentSubtitle = ""

            case .external:
                item.select(nil, in: group)
                if let current = player?.currentTime().seconds {
                    updateExternalSubtitle(at: current)
                } else {
                    currentSubtitle = ""
                }

            case .generated:
                item.select(nil, in: group)
                if let current = player?.currentTime().seconds {
                    updateGeneratedSubtitle(at: current)
                } else {
                    currentSubtitle = ""
                }

            case .off:
                item.select(nil, in: group)
                currentSubtitle = ""
            }
        } else if mode == .external, let current = player?.currentTime().seconds {
            updateExternalSubtitle(at: current)
        } else if mode == .generated, let current = player?.currentTime().seconds {
            updateGeneratedSubtitle(at: current)
        } else {
            currentSubtitle = ""
        }

        // 생성기는 이 모드일 때만 돌린다 — 안 보는 자막을 만드느라 CPU 를 쓰지 않는다.
        if mode == .generated { generator.start() } else { generator.stop() }
    }

    private func removeSubtitleTimeObserver() {
        if let obs = subtitleTimeObserver {
            player?.removeTimeObserver(obs)
            subtitleTimeObserver = nil
        }
    }

    /// 재생 내내 돌아간다. 외부/생성 자막 표시와 생성기 진행을 모두 여기서 몰아 준다.
    private func installSubtitleTimeObserver() {
        removeSubtitleTimeObserver()
        guard let player else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        subtitleTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self, seconds.isFinite else { return }
                // 탐색이 아직 안 끝났으면 목표에서 먼 보고는 옛 위치다 — 버린다.
                // 그대로 두면 생성기가 그걸 또 다른 탐색으로 읽고 방금 시작한 작업을 취소한다.
                if let target = self.seekTarget, abs(seconds - target) > 1.0 { return }
                let duration = self.player?.currentItem?.duration.seconds ?? 0
                self.generator.tick(currentTime: seconds,
                                    duration: duration.isFinite ? duration : 0)
                switch self.effectiveSubtitleMode() {
                case .external:  self.updateExternalSubtitle(at: seconds)
                case .generated: self.updateGeneratedSubtitle(at: seconds)
                default:         break
                }
            }
        }
    }

    /// 생성된 큐에서 현재 시각에 해당하는 자막을 고른다.
    private func updateGeneratedSubtitle(at seconds: TimeInterval) {
        guard showSubtitles else {
            DostLog.log("updateGenerated: showSubtitles=false")
            return
        }
        let text = generator.cues.cue(at: seconds)?.text ?? ""
        if currentSubtitle != text {
            DostLog.log(String(format: "cue @%.1fs hasSub=%@ show=%@ -> %@", seconds,
                               hasSubtitles ? "Y" : "N", showSubtitles ? "Y" : "N",
                               text.isEmpty ? "(empty)" : String(text.prefix(20))))
            currentSubtitle = text
        }
    }

    private func updateExternalSubtitle(at seconds: TimeInterval) {
        guard hasExternalSubtitle, showSubtitles else { return }
        let text = externalCues.cue(at: seconds)?.text ?? ""
        if currentSubtitle != text { currentSubtitle = text }
    }

    // MARK: - Image Open

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

    /// 이미지 확장자 판별. ContentView가 "마지막 재생" 기록 대상 여부 결정에 사용.
    static func isImageFile(url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// 오디오 전용 파일 확장자. AVFoundation 네이티브 재생 가능한 것만.
    /// ogg/wma는 unsupportedExtensions 경유로 remux 후 재생.
    private static let audioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif"
    ]

    /// 오디오 확장자 판별.
    static func isAudioFile(url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// 정적 이미지 로드 — 한 번만 샘플링하고, 크기/간격 변경에 대응하도록 타이머만 유지.
    private func openImage(url: URL) {
        cleanup()
        if let prev = activeRemuxTempURL {
            try? FileManager.default.removeItem(at: prev)
            activeRemuxTempURL = nil
        }

        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            urlLoadError = "이미지를 열 수 없습니다: \(url.lastPathComponent)"
            return
        }
        guard let buffer = Self.makePixelBuffer(from: cgImage) else {
            urlLoadError = "이미지 변환에 실패했습니다."
            return
        }

        lastPixelBuffer = buffer
        isStaticContent = true
        isPlaying = false
        videoSize = CGSize(width: cgImage.width, height: cgImage.height)

        // 이미지 모드에서는 AVPlayer/videoOutput 없이 캐시된 버퍼를 반복 샘플링.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleCurrentFrame() }
        }
        // .common 모드로 등록 → 마우스 홀드(일반 peek) 등 이벤트 트래킹 중에도 계속 샘플링.
        // (.default 모드 타이머는 마우스를 누르고 있는 동안 멈춰 dotColors가 동결됨)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// CGImage → CVPixelBuffer(BGRA). 기존 샘플링 경로(`sampleCurrentFrame`)와 호환되는 포맷.
    private static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Remux (ffmpeg)

    /// AVFoundation이 지원 안 하는 컨테이너 목록
    private static let unsupportedExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "ogv", "ogg", "wma",
        "rmvb", "rm", "ts", "m2ts", "mts", "vob", "asf", "divx", "xvid"
    ]

    private static func needsRemux(url: URL) -> Bool {
        unsupportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static func remuxToMP4(source: URL) async -> ResolveOutcome {
        var candidates: [String] = []
        // 번들 내 임베드된 ffmpeg 우선 탐색
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ]
        guard let ffmpegPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .failure("ffmpeg이 설치되어 있지 않습니다.\n터미널에서 실행하세요:\n  brew install ffmpeg")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dost-remux-\(UUID().uuidString).mp4")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // ffprobe로 비디오/오디오 코덱을 먼저 확인.
                // AVFoundation이 MP4 컨테이너에서 디코드 가능한 코덱만 copy,
                // 그 외(VP9/VP8/AV1/Theora 등)는 재인코딩이 필요.
                // 이전엔 stream copy가 "성공"하지만 AVFoundation이 화면을 못 그려
                // 오디오만 들리는 버그가 있었음.
                let videoCodec = probeCodec(path: source.path, streamType: "v", ffmpegPath: ffmpegPath)
                let audioCodec = probeCodec(path: source.path, streamType: "a", ffmpegPath: ffmpegPath)
                let subtitleCodec = probeCodec(path: source.path, streamType: "s", ffmpegPath: ffmpegPath)

                let mp4SafeVideo: Set<String> = ["h264", "hevc", "mpeg4", "mjpeg", "prores"]
                let mp4SafeAudio: Set<String> = ["aac", "mp3", "ac3", "alac", "eac3"]
                // mov_text 변환은 텍스트 기반 자막만 가능. PGS/VobSub 등 비트맵 자막을
                // mov_text로 지정하면 remux 전체가 실패해 재인코딩 fallback으로 빠지므로
                // (BluRay 립 mkv가 통째로 못 열리던 원인) 비트맵 자막은 드롭한다.
                let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt"]

                // probe 실패(nil) 시엔 기존 동작 유지(copy 시도). 확실히 비호환일 때만 재인코딩.
                let copyVideo = (videoCodec == nil) || mp4SafeVideo.contains(videoCodec!)
                let copyAudio = (audioCodec == nil) || mp4SafeAudio.contains(audioCodec!)
                let convertSubtitle = subtitleCodec.map { textSubtitles.contains($0) } ?? false

                func baseArgs(subtitle: Bool) -> [String] {
                    var args = ["-y", "-i", source.path]
                    args += copyVideo ? ["-c:v", "copy"] : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]
                    // HEVC를 MP4로 stream copy 할 때, ffmpeg은 기본으로 hev1 태그를 쓴다.
                    // Apple AVFoundation은 hev1은 디코드 못하고 hvc1만 받아들여서
                    // "오디오만 나오고 영상은 안 보임" 현상이 발생. 태그를 hvc1로 강제.
                    if copyVideo && videoCodec == "hevc" {
                        args += ["-tag:v", "hvc1"]
                    }
                    args += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
                    args += subtitle ? ["-c:s", "mov_text"] : ["-sn"]
                    // 로컬 임시 파일 재생이라 +faststart(moov 앞으로 옮기는 2차 패스) 불필요.
                    // 대용량 파일에서 remux 시간을 절반으로 줄인다.
                    args += [tempURL.path]
                    return args
                }

                if runFFmpeg(path: ffmpegPath, args: baseArgs(subtitle: convertSubtitle)) {
                    continuation.resume(returning: .success(tempURL))
                    return
                }

                // 자막 변환이 문제였을 수 있으므로, 여전히 stream copy 유지한 채 자막만 드롭 후 재시도
                if convertSubtitle {
                    try? FileManager.default.removeItem(at: tempURL)
                    if runFFmpeg(path: ffmpegPath, args: baseArgs(subtitle: false)) {
                        continuation.resume(returning: .success(tempURL))
                        return
                    }
                }

                // 최후 수단: 전체 재인코딩 (느림)
                try? FileManager.default.removeItem(at: tempURL)
                let fallbackArgs = [
                    "-y", "-i", source.path,
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                    "-c:a", "aac", "-b:a", "192k",
                    "-sn",
                    tempURL.path
                ]

                if runFFmpeg(path: ffmpegPath, args: fallbackArgs) {
                    continuation.resume(returning: .success(tempURL))
                    return
                }

                try? FileManager.default.removeItem(at: tempURL)
                continuation.resume(returning: .failure("ffmpeg 변환에 실패했습니다. 파일이 손상됐거나 지원하지 않는 형식일 수 있습니다."))
            }
        }
    }

    /// ffprobe로 스트림 코덱 이름을 반환. streamType: "v" (비디오) or "a" (오디오).
    /// ffprobe가 없거나 해당 스트림이 없으면 nil.
    nonisolated private static func probeCodec(path: String, streamType: String, ffmpegPath: String) -> String? {
        let dir = (ffmpegPath as NSString).deletingLastPathComponent
        let ffprobePath = "\(dir)/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: ffprobePath) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffprobePath)
        task.arguments = [
            "-v", "error",
            "-select_streams", "\(streamType):0",
            "-show_entries", "stream=codec_name",
            "-of", "default=nw=1:nk=1",
            path
        ]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let codec = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return (codec?.isEmpty == false) ? codec : nil
        } catch {
            return nil
        }
    }

    nonisolated private static func runFFmpeg(path: String, args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - URL Open

    enum ResolveOutcome {
        case success(URL)
        case failure(String)
    }

    /// URL 문자열로 열기. 직접 재생 가능한 URL만 연다.
    func openURL(_ urlString: String) {
        startTimerIfNeeded()
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            urlLoadError = "잘못된 URL입니다."
            return
        }

        open(url: url)
    }

    // MARK: - Controls

    func seek(toSeconds seconds: Double) {
        guard let player else { return }
        let safeSeconds = max(0, seconds)
        if let item = player.currentItem {
            let duration = item.duration.seconds
            let clamped: Double
            if duration.isFinite && duration > 0 {
                clamped = min(safeSeconds, max(0, duration - 0.25))
            } else {
                clamped = safeSeconds
            }
            noteSeek(to: clamped)
            player.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        } else {
            player.seek(to: CMTime(seconds: safeSeconds, preferredTimescale: 600))
        }
        startTimerIfNeeded()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        startTimerIfNeeded()
        showOverlay(.border, blinks: 2)
    }

    // MARK: - Peek (우상단 도트 누르고 있는 동안 실제 영상 재생)

    /// 피크 전용 AVPlayerLayer 부착용. 읽기 전용. 외부에서 play()/pause() 직접 호출 금지 —
    /// 반드시 peekStart()/peekEnd()를 통해 상태 일관성 유지.
    var previewPlayer: AVPlayer? { player }

    /// 현재 원본 프레임을 CGImage로 반환(도트화 전 원본 픽셀).
    /// 비디오는 출력에서 가장 최신 프레임을 받아오고, 실패 시 마지막 픽셀버퍼로 폴백.
    /// 이미지 모드는 openImage에서 세팅한 lastPixelBuffer를 그대로 사용.
    func currentFrameCGImage() -> CGImage? {
        var buffer = lastPixelBuffer
        if let output = videoOutput, let player {
            let time = player.currentTime()
            if time.isValid, !time.isIndefinite,
               let fresh = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                buffer = fresh
            }
        }
        guard let pixelBuffer = buffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    /// 피크 시작: 강제 재생. 이전 상태(play/pause)와 무관하게 재생 시작.
    func peekStart() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    /// 피크 종료: 무조건 일시정지. 사양상 뗀 후엔 항상 pause.
    func peekEnd() {
        player?.pause()
        isPlaying = false
    }

    // 숫자키: fraction = 0.1 ~ 0.9
    func seek(toFraction fraction: Double) {
        guard let player, let item = player.currentItem else { return }
        Task {
            let duration = try? await item.asset.load(.duration)
            guard let d = duration, d.isValid, !d.isIndefinite, d.seconds > 0 else { return }
            let target = CMTime(seconds: d.seconds * fraction, preferredTimescale: 600)
            noteSeek(to: target.seconds)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            startTimerIfNeeded()
            showOverlay(.col(seekCol(fraction: fraction)), blinks: 1)
        }
    }

    // 콤마/마침표: 가로 한 칸 단위 이동
    func seekByColumn(delta: Int) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration
        guard duration.isValid && !duration.isIndefinite && duration.seconds > 0 else { return }

        let visibleCols = max(1, (dotColors.first?.count ?? 2) - 2)
        let colWidth    = duration.seconds / Double(visibleCols)
        let current     = player.currentTime().seconds
        let rawTarget   = current + Double(delta) * colWidth

        let atStart = delta < 0 && rawTarget <= 0
        let atEnd   = delta > 0 && rawTarget >= duration.seconds
        let clamped = min(max(0, rawTarget), duration.seconds)

        noteSeek(to: clamped)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        let fraction = clamped / duration.seconds
        startTimerIfNeeded()
        showOverlay(.col(seekCol(fraction: fraction)),
                    blinks: (atStart || atEnd) ? 2 : 1,
                    alert: atStart || atEnd)
    }

    // 방향키: ±seconds
    func seek(by seconds: Double) {
        guard let player, let item = player.currentItem else { return }
        let current = player.currentTime()
        let target  = CMTimeAdd(current, CMTime(seconds: seconds, preferredTimescale: 600))
        noteSeek(to: target.seconds)
        player.seek(to: target,
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
        
        Task {
            let duration = try? await item.asset.load(.duration)
            guard let d = duration, d.isValid, !d.isIndefinite, d.seconds > 0 else { return }
            let fraction = target.seconds / d.seconds
            startTimerIfNeeded()
            showOverlay(.col(seekCol(fraction: fraction)), blinks: 1)
        }
    }

    // 볼륨 위 (최대 120%)
    func volumeUp() {
        guard let player else { return }
        let visibleRows = max(1, dotColors.count - 2)
        let step = Float(1.0) / Float(visibleRows)
        let maxVol: Float = 1.2
        let atMax = player.volume >= maxVol - step * 0.5  // 엡실론: 반 칸 이내면 최대로 간주
        if !atMax { 
            player.volume = min(maxVol, player.volume + step)
            lastVolume = player.volume
            UserDefaults.standard.set(lastVolume, forKey: Self.volumeKey)
        }
        startTimerIfNeeded()
        showOverlay(.row(volumeRow(volume: Double(player.volume), visibleRows: visibleRows)),
                    blinks: atMax ? 2 : 1, alert: atMax)
    }

    // 볼륨 아래
    func volumeDown() {
        guard let player else { return }
        let visibleRows = max(1, dotColors.count - 2)
        let step = Float(1.0) / Float(visibleRows)
        let atMin = player.volume <= step * 0.5           // 엡실론: 반 칸 이내면 최소로 간주
        if !atMin { 
            player.volume = max(0.0, player.volume - step)
            lastVolume = player.volume
            UserDefaults.standard.set(lastVolume, forKey: Self.volumeKey)
        }
        startTimerIfNeeded()
        showOverlay(.row(volumeRow(volume: Double(player.volume), visibleRows: visibleRows)),
                    blinks: atMin ? 2 : 1, alert: atMin)
    }

    // MARK: - Helpers

    // 볼륨 % → 가장 가까운 가로 줄 (1-based, 위=120%)
    // 120%(1.2) → row 1, 0% → row visibleRows.
    // 기본값(100%) 은 전체의 1/6 지점(위에서 visibleRows/6 번째 줄).
    private func volumeRow(volume: Double, visibleRows: Int) -> Int {
        let maxVol = 1.2
        let fraction = (maxVol - max(0, min(maxVol, volume))) / maxVol
        let r = Int(fraction * Double(visibleRows) + 0.5)
        return max(1, min(visibleRows, r == 0 ? 1 : r))
    }

    // seek 목표 fraction → 가장 가까운 세로 줄 (1-based, 왼쪽=0%)
    private func seekCol(fraction: Double) -> Int {
        let visibleCols = max(1, (dotColors.first?.count ?? 2) - 2)
        let c = Int(fraction * Double(visibleCols) + 0.5)
        return max(1, min(visibleCols, c == 0 ? 1 : c))
    }

    // MARK: - Overlay

    /// 플레이리스트 경계(처음/마지막)에서 더 이상 이동할 수 없을 때 악센트 테두리 깜빡임.
    func triggerBorderBlink() {
        startTimerIfNeeded()
        showOverlay(.border, blinks: 2, alert: true)
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleCurrentFrame() }
        }
        // .common 모드로 등록 → 마우스 홀드(일반 peek) 등 이벤트 트래킹 중에도 계속 샘플링.
        // (.default 모드 타이머는 마우스를 누르고 있는 동안 멈춰 dotColors가 동결됨)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func showOverlay(_ effect: OverlayEffect, blinks: Int, alert: Bool = false) {
        overlayEffect = effect
        overlayBlinks = blinks
        overlayProgress = 0
        overlayIsAlert = alert
        overlayStartTime = Date()
    }

    private func updateOverlay() {
        guard let startTime = overlayStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= overlayDuration {
            overlayProgress = 0
            overlayEffect = .none
            overlayIsAlert = false
            overlayStartTime = nil
        } else {
            overlayProgress = elapsed / overlayDuration
        }
    }

    // MARK: - Audio Analysis & Visualization

    /// 로컬 오디오 파일의 주파수 에너지를 사전 분석.
    /// ~30 frames/sec 해상도의 AudioEnergyFrame 배열과 실제 분석 레이트를 반환.
    /// 메모리 효율을 위해 스트리밍 방식으로 청크 단위 처리.
    nonisolated private static func analyzeAudioFile(url: URL) -> (frames: [AudioEnergyFrame], rate: Double) {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return ([], 30) }
        let format = audioFile.processingFormat
        let sampleRate = Float(format.sampleRate)
        guard audioFile.length > 0, sampleRate > 0 else { return ([], 30) }

        let hopSize = max(1, Int(sampleRate / 30.0))
        let chunkCapacity: AVAudioFrameCount = 65536
        guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { return ([], 30) }

        var frames: [AudioEnergyFrame] = []
        var residual: [Float] = []
        var startIndex = 0
        let rmsWindowSize = 2048

        while audioFile.framePosition < audioFile.length {
            do { try audioFile.read(into: chunkBuffer) } catch { break }
            guard let channelData = chunkBuffer.floatChannelData, chunkBuffer.frameLength > 0 else { break }
            let count = Int(chunkBuffer.frameLength)
            residual.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))

            while startIndex + rmsWindowSize <= residual.count {
                var rms: Float = 0
                residual.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    vDSP_rmsqv(base.advanced(by: startIndex), 1, &rms, vDSP_Length(rmsWindowSize))
                }

                frames.append(AudioEnergyFrame(rms: rms))
                startIndex += hopSize
            }

            // 앞부분을 매번 당기면 O(n) 비용이 커서, 충분히 누적됐을 때만 한 번에 정리.
            if startIndex >= residual.count {
                residual.removeAll(keepingCapacity: true)
                startIndex = 0
            } else if startIndex > 65536 {
                residual.removeFirst(startIndex)
                startIndex = 0
            }
        }

        guard !frames.isEmpty else { return ([], 30) }

        let maxRms = frames.map(\.rms).max()!

        let normalized = frames.map { f in
            AudioEnergyFrame(rms: maxRms > 0 ? f.rms / maxRms : 0)
        }

        return (normalized, Double(sampleRate) / Double(hopSize))
    }

    /// 오디오 모드에서 호출: 일반적인 바 형태의 이퀄라이저 렌더링.
    /// 배경은 디폴트 C9CFE5 색상을, 바(세로줄)는 사용자가 고른 악센트 색상 사용.
    private func generateAudioDotColors() {
        guard let player else { return }
        let currentTime = max(0, player.currentTime().seconds)
        let dispW = currentDisplaySize.width  > 0 ? currentDisplaySize.width  : 480
        let dispH = currentDisplaySize.height > 0 ? currentDisplaySize.height : 320
        let cols = max(3, Int(dispW / gridSize))
        let rows = max(3, Int(dispH / gridSize))

        let rate: Double
        if !audioEnergyFrames.isEmpty {
            rate = audioAnalysisRate
        } else {
            rate = 30.0
        }

        // 100ms 간격으로 우측으로 파형이 이동 (크롤 속도 100ms)
        let timerInterval = 0.100
        var barHeights = [Int](repeating: 0, count: cols)

        // quantizedTime을 사용해 100ms 구간 동안은 시간 값을 완전히 고정시켜
        // 프레임 사이사이의 스무딩(슬라이딩)으로 인한 깜빡임 방지
        let step = floor(currentTime / timerInterval)
        let quantizedTime = step * timerInterval

        for col in 0..<cols {
            let t = quantizedTime - Double(col) * timerInterval
            var rms: Float = 0
            
            if t >= 0 && !audioEnergyFrames.isEmpty {
                let idx = Int(t * rate)
                let clamped = max(0, min(audioEnergyFrames.count - 1, idx))
                rms = audioEnergyFrames[clamped].rms
            }
            
            // 음악의 볼륨에 따른 기본 높이 계산 (최대 높이를 rows-1로 제한하여 +1 여유를 둠)
            var h = Int(Double(rms) * Double(max(0, rows - 1)))
            
            // 재생 중이라면 (과거/미래/분석완료 여부를 떠나) 모든 위치에 무조건 1칸을 강제로 더함
            if self.isPlaying {
                h += 1
            }
            
            barHeights[col] = min(rows, h)
        }

        var newColors: [[CGColor]] = []
        newColors.reserveCapacity(rows)

        // 지정색상 (배경 점들은 외부에서 정해진 backgroundDotAlpha 적용)
        let baseBg = NSColor(red: 201.0/255.0, green: 207.0/255.0, blue: 229.0/255.0, alpha: CGFloat(self.backgroundDotAlpha)).cgColor
        let accentColor = AppAccentColor.current.nsColor.cgColor

        for row in 0..<rows {
            var rowColors: [CGColor] = []
            rowColors.reserveCapacity(cols)

            // SwiftUI Coordinate 관점에서 row 0은 화면의 맨 위, rows-1은 화면의 맨 아래.
            // 아래에서부터 100분위만큼 찹니다.
            for col in 0..<cols {
                let h = barHeights[col]
                // barHeights가 0이면 불 안 들어옴. rows이면 꽉 참.
                if row >= rows - h {
                    rowColors.append(accentColor)
                } else {
                    rowColors.append(baseBg)
                }
            }
            newColors.append(rowColors)
        }

        dotColors = newColors
    }

    // MARK: - Frame Sampling

    private func sampleCurrentFrame() {
        updateOverlay()

        // 오디오 전용 모드: 주파수 분석 기반 시각화
        if isAudioMode {
            generateAudioDotColors()
            return
        }

        // 비디오 모드: 최신 프레임을 AVPlayerItemVideoOutput에서 가져온다.
        // 이미지 모드: videoOutput/player가 nil이므로 이 블록은 건너뛰고
        // `openImage`에서 세팅한 lastPixelBuffer를 재사용한다.
        var didAdvanceFrame = false
        if let output = videoOutput, let player {
            let hostTime = CACurrentMediaTime()
            let displayTime = output.itemTime(forHostTime: hostTime)
            let currentTime = player.currentTime()

            let candidateTimes: [CMTime] = [displayTime, currentTime]
            for time in candidateTimes where time.isValid && !time.isIndefinite {
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    lastPixelBuffer = buffer
                    videoFrameGeneration &+= 1
                    didAdvanceFrame = true
                    break
                }
            }

            if !didAdvanceFrame,
               let buffer = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
                lastPixelBuffer = buffer
            }
        }
        guard let pixelBuffer = lastPixelBuffer else { return }

        // 비디오가 멈춰 있거나(새 프레임 없음), 이미지 모드(프레임 고정)일 때는
        // gridSize/창 크기 변화가 없으면 동일 픽셀 버퍼를 반복 샘플링할 필요가 없다.
        let sigAspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 1
        let sigZoom = effectiveZoom(
            dispW: max(currentDisplaySize.width, 1),
            dispH: max(currentDisplaySize.height, 1),
            videoAspect: sigAspect
        )
        let sig = RenderSignature(
            gridSize: Int(gridSize.rounded()),
            displayW: Int(currentDisplaySize.width.rounded()),
            displayH: Int(currentDisplaySize.height.rounded()),
            frameGeneration: videoFrameGeneration,
            zoomPermille: Int((sigZoom * 1000).rounded())
        )
        if !didAdvanceFrame, sig == lastRenderSignature {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let bufWidth    = CVPixelBufferGetWidth(pixelBuffer)
        let bufHeight   = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let dispW = currentDisplaySize.width  > 0 ? currentDisplaySize.width  : CGFloat(bufWidth)  / 2
        let dispH = currentDisplaySize.height > 0 ? currentDisplaySize.height : CGFloat(bufHeight) / 2

        // 원본 비율 보존: 디스플레이 영역 안에 비디오를 fit-inside로 맞춘 뒤 그 영역으로 셀 수를 계산.
        // cols/rows 비율이 원본에 맞춰지므로 가로/세로 샘플링 stride가 같아져 왜곡 없음.
        // 남는 공간은 자동 레터박스(여백).
        let videoAspect = CGFloat(bufWidth) / CGFloat(bufHeight)
        let fittedW: CGFloat
        let fittedH: CGFloat
        if dispW / dispH > videoAspect {
            // 창이 비디오보다 가로로 넓음 → 좌우에 여백(필러박스)
            fittedH = dispH
            fittedW = fittedH * videoAspect
        } else {
            // 창이 비디오보다 세로로 김 → 상하에 여백(레터박스)
            fittedW = dispW
            fittedH = fittedW / videoAspect
        }

        // 콘텐츠 줌: fit 대비 배율만큼 확대하고, 화면 밖으로 넘치는 부분은 중앙 크롭.
        // 확대되어도 그리드/도트 크기는 그대로 — 버퍼에서 샘플링하는 소스 영역만 줄어든다.
        let zoom = effectiveZoom(dispW: dispW, dispH: dispH, videoAspect: videoAspect)
        let scaledW = fittedW * zoom
        let scaledH = fittedH * zoom
        let visibleW = min(dispW, scaledW)
        let visibleH = min(dispH, scaledH)

        let cols = max(1, Int(visibleW / gridSize))
        let rows = max(1, Int(visibleH / gridSize))

        let srcW = CGFloat(bufWidth)  * (visibleW / scaledW)
        let srcH = CGFloat(bufHeight) * (visibleH / scaledH)
        let srcX0 = (CGFloat(bufWidth)  - srcW) / 2
        let srcY0 = (CGFloat(bufHeight) - srcH) / 2

        let strideX = max(1.0, srcW / CGFloat(cols))
        let strideY = max(1.0, srcH / CGFloat(rows))

        var newColors: [[CGColor]] = []
        newColors.reserveCapacity(rows)

        for row in 0..<rows {
            let sampleY = min(max(0, Int(srcY0 + (CGFloat(row) + 0.5) * strideY)), bufHeight - 1)
            var rowColors: [CGColor] = []
            rowColors.reserveCapacity(cols)

            for col in 0..<cols {
                let sampleX = min(max(0, Int(srcX0 + (CGFloat(col) + 0.5) * strideX)), bufWidth - 1)
                let offset  = sampleY * bytesPerRow + sampleX * 4
                let ptr = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)

                let b = CGFloat(ptr[0]) / 255.0
                let g = CGFloat(ptr[1]) / 255.0
                let r = CGFloat(ptr[2]) / 255.0
                rowColors.append(CGColor(red: r, green: g, blue: b, alpha: 1.0))
            }
            newColors.append(rowColors)
        }

        dotColors = newColors
        lastRenderSignature = sig
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        videoFrameGeneration = 0
        lastRenderSignature = nil
        // time observer 는 player 가 nil 이 되기 전에 제거해야 한다.
        removeSubtitleTimeObserver()
        generator.detach()
        currentSourceURL = nil
        hasGeneratedSubtitle = false
        seekTarget = nil
        externalCues = []
        hasExternalSubtitle = false
        subtitleMode = .off
        player?.pause()
        player = nil
        videoOutput = nil
        legibleOutput = nil
        subtitleDelegate = nil
        legibleGroup = nil
        firstLegibleOption = nil
        hasEmbeddedSubtitle = false
        lastPixelBuffer = nil
        dotColors = []
        videoSize = .zero
        contentZoom = .fit
        isPlaying = false
        isStaticContent = false
        isAudioMode = false
        audioEnergyFrames = []
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        hasSubtitles = false
        currentSubtitle = ""
    }

    func resetAppState() {
        cleanup()
        if let prev = activeRemuxTempURL {
            try? FileManager.default.removeItem(at: prev)
            activeRemuxTempURL = nil
        }
        urlLoadError = nil
        overlayEffect = .none
        overlayProgress = 0
        overlayBlinks = 1
        overlayIsAlert = false
        overlayStartTime = nil
        showSubtitles = true
        backgroundDotAlpha = 0.40
        gridSize = defaultGridSize
        dotDiameter = defaultDotDiameter
        subtitleFontSize = subtitleFontDefault
        lastVolume = 1.0
    }
}

// MARK: - Subtitle delegate

/// AVPlayerItemLegibleOutput 푸시 델리게이트. 별도 NSObject로 분리한 이유:
/// 프로토콜 콜백이 메인 액터 격리가 아니기 때문에, @MainActor인 VideoSampler에서 직접 구현 불가.
final class SubtitleDelegate: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let onSamples: ([NSAttributedString]) -> Void
    init(_ cb: @escaping ([NSAttributedString]) -> Void) {
        self.onSamples = cb
    }
    func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                       didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any],
                       forItemTime itemTime: CMTime) {
        onSamples(strings)
    }
}
