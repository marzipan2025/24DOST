import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Window Drag

struct WindowDragArea: NSViewRepresentable {
    var onSingleClick: () -> Void
    var onDoubleClick: () -> Void
    var onRightClick: ((CGPoint) -> Void)?
    var onScrollUp: (() -> Void)?
    var onScrollDown: (() -> Void)?
    /// 확대 중이면 ⌘ 드래그가 "보는 위치 이동"이라 창이 따라 움직이면 안 된다.
    var isContentZoomed: Bool = false

    func makeNSView(context: Context) -> WindowDragNSView {
        let view = WindowDragNSView()
        
        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(doubleClick)
        
        let singleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleClick))
        singleClick.numberOfClicksRequired = 1
        singleClick.delaysPrimaryMouseButtonEvents = false
        singleClick.delegate = context.coordinator
        view.addGestureRecognizer(singleClick)
        
        return view
    }
    
    func updateNSView(_ nsView: WindowDragNSView, context: Context) {
        context.coordinator.onSingleClick = onSingleClick
        context.coordinator.onDoubleClick = onDoubleClick
        nsView.onRightClick = onRightClick
        nsView.onScrollUp = onScrollUp
        nsView.onScrollDown = onScrollDown
        nsView.isContentZoomed = isContentZoomed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleClick: onSingleClick, onDoubleClick: onDoubleClick)
    }

    class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var onSingleClick: () -> Void
        var onDoubleClick: () -> Void

        init(onSingleClick: @escaping () -> Void, onDoubleClick: @escaping () -> Void) {
            self.onSingleClick = onSingleClick
            self.onDoubleClick = onDoubleClick
        }

        @objc func handleSingleClick() { onSingleClick() }
        @objc func handleDoubleClick() { onDoubleClick() }
        
        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: NSGestureRecognizer) -> Bool {
            if let click1 = gestureRecognizer as? NSClickGestureRecognizer, let click2 = otherGestureRecognizer as? NSClickGestureRecognizer {
                if click1.numberOfClicksRequired == 1 && click2.numberOfClicksRequired == 2 {
                    return true // 싱글클릭은 더블클릭이 실패할 때까지 대기
                }
            }
            return false
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolve(window)
            }
        }
    }
}

class WindowDragNSView: NSView {
    var onRightClick: ((CGPoint) -> Void)?
    var onScrollUp: (() -> Void)?
    var onScrollDown: (() -> Void)?
    
    private var scrollAccumulator: CGFloat = 0
    
    override var isFlipped: Bool { true }

    /// 확대 중일 때만 유효. ⌘ 드래그를 창 이동이 아니라 화면 이동으로 넘긴다.
    var isContentZoomed: Bool = false

    /// 창 이동은 여기서 시작된다 — AppKit 이 mouseDown 시점에 이 값을 물어본다.
    /// 확대 상태의 ⌘ 드래그는 보는 위치를 옮기는 동작이라 창까지 끌리면 안 된다.
    override var mouseDownCanMoveWindow: Bool {
        !(isContentZoomed && NSEvent.modifierFlags.contains(.command))
    }

    // mouseDown 에서 performDrag를 즉시 호출하면 모바일 터치이벤트루프를 먹어버리므로,
    // 실제로 드래그가 발생할 때만 넘겨 싱글/더블 클릭 제스처가 씹히지 않게 함.
    override func mouseDragged(with event: NSEvent) {
        // performDrag 는 자체 이벤트 루프를 돌려 이후 마우스 이벤트를 전부 먹는다.
        // ⌘ 드래그(화면 이동)에서 이게 걸리면 SwiftUI 제스처가 첫 몇 이벤트만 받고 끊긴다.
        if isContentZoomed, event.modifierFlags.contains(.command) { return }
        window?.performDrag(with: event)
    }
    
    override func rightMouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        onRightClick?(loc)
    }
    
    override func scrollWheel(with event: NSEvent) {
        scrollAccumulator += event.scrollingDeltaY
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 15.0 : 0.5
        
        if scrollAccumulator > threshold {
            onScrollDown?()
            scrollAccumulator = 0
        } else if scrollAccumulator < -threshold {
            onScrollUp?()
            scrollAccumulator = 0
        }
    }
}

// MARK: - AV Player Layer (peek 실제 영상 표시)

/// AVPlayer 를 AVPlayerLayer 로 띄우는 NSViewRepresentable.
/// 피크 중에만 body 에 삽입되며, isFullscreen 에 따라 videoGravity 가 전환됨.
///   일반 모드: .resizeAspectFill (비율 유지 + 꽉 채움, 넘치는 부분 크롭)
///   전체화면:  .resizeAspect     (비율 유지 + 레터박스)
/// 클릭은 외부에서 이미 처리하므로 히트테스트 차단.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    let isFullscreen: Bool

    func makeNSView(context: Context) -> PlayerLayerNSView {
        let v = PlayerLayerNSView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = isFullscreen ? .resizeAspect : .resizeAspectFill
        return v
    }

    func updateNSView(_ nsView: PlayerLayerNSView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
        let gravity: AVLayerVideoGravity = isFullscreen ? .resizeAspect : .resizeAspectFill
        if nsView.playerLayer.videoGravity != gravity {
            nsView.playerLayer.videoGravity = gravity
        }
    }
}

final class PlayerLayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // 줌·리사이즈로 이 뷰의 크기가 매 단계 바뀐다(영상 전체 크기로 잡으므로).
        // CALayer 는 frame 변경에 0.25초짜리 암시적 애니메이션을 붙이는데 — 레이어를
        // 직접 만들어 붙인 서브레이어라 AppKit 이 막아주지 않는다 — 그러면 확대할 때마다
        // 영상이 모서리에서 밀려 들어오는 모션이 생긴다. 즉시 반영해야 도트와 어긋나지 않는다.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    // 피크 영역 위로 마우스가 지나가도 드래그나 다른 제스처를 막지 않도록 히트테스트 투과.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 영상↔인식 언어 동기화용. 본 뷰 체인에 onChange 를 하나 더 붙이면 타입 체커가
/// 터져서 별도 modifier 로 뺐다 (MenuCommandObservers 와 같은 이유).
private struct SourceLanguageSync: ViewModifier {
    let signature: String
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: signature) { _, _ in onChange() }
    }
}

// MARK: - Menu command observers
//
// ContentView.body 가 .onReceive 를 너무 많이 붙여 Swift 타입체커가 타임아웃하는 것을 방지하기
// 위해 메뉴 관련 Notification 구독을 별도 ViewModifier 로 추출. 동작은 동일.
private struct MenuCommandObservers: ViewModifier {
    let onOpenFile:             () -> Void
    let onExternalOpenURLs:     (Notification) -> Void
    let onExternalOpenMediaURL: (Notification) -> Void
    let onOpenURLRequested:     (Notification) -> Void
    let onOpenPlaybackInfoRequested: (Notification) -> Void
    let onExportImage:          () -> Void
    let onCycleBackgroundStyle: () -> Void
    let onToggleAlwaysOnTop:    (Notification) -> Void
    let onPlaybackEnded:        () -> Void
    let onOpenRecent:           (Notification) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openFileRequested))    { _ in onOpenFile() }
            .onReceive(NotificationCenter.default.publisher(for: .externalOpenURLs),     perform: onExternalOpenURLs)
            .onReceive(NotificationCenter.default.publisher(for: .externalOpenMediaURL), perform: onExternalOpenMediaURL)
            .onReceive(NotificationCenter.default.publisher(for: .openURLRequested),     perform: onOpenURLRequested)
            .onReceive(NotificationCenter.default.publisher(for: .openPlaybackInfoRequested), perform: onOpenPlaybackInfoRequested)
            .onReceive(NotificationCenter.default.publisher(for: .exportImageRequested))  { _ in onExportImage() }
            .onReceive(NotificationCenter.default.publisher(for: .cycleBackgroundStyle)) { _ in onCycleBackgroundStyle() }
            .onReceive(NotificationCenter.default.publisher(for: .toggleAlwaysOnTop),    perform: onToggleAlwaysOnTop)
            .onReceive(NotificationCenter.default.publisher(for: .playbackEnded))        { _ in onPlaybackEnded() }
            .onReceive(NotificationCenter.default.publisher(for: .openRecentRequested),  perform: onOpenRecent)
    }
}

// MARK: - Overlay colors

private let indicatorColorPlay  = Color.white                                        // 흰색 100%

/// 도트 격자를 그릴 도형.
///
/// **크기는 두 모양이 공유한다** — `dotDiameter` 가 원의 지름이자 사각형의 한 변이다.
/// 같은 설정값이 모양에 따라 다른 크기를 뜻하면 W/S 로 맞춰 둔 화면이 전환할 때마다
/// 어긋난다. 사각형이 원보다 넓이가 4/π(약 27%) 크게 보이는 건 의도된 결과다.
enum DotShape: String, CaseIterable, Identifiable {
    static let storageKey = "24dost.dotShape"
    static let defaultChoice: DotShape = .circle

    case circle
    case square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .circle: return "Circle"
        case .square: return "Square"
        }
    }

    static func choice(for raw: String) -> DotShape {
        DotShape(rawValue: raw) ?? defaultChoice
    }

    /// 간격 0 으로 맞붙은 사각형의 이음매를 지우는 여유(포인트).
    ///
    /// 인접한 두 사각형이 경계를 정확히 공유하면 격자 원점이 소수점이라 그 경계가 픽셀
    /// 한가운데 걸린다. 각자 절반씩 덮은 걸 합성하면 75% 만 차서 **배경색 격자선이 옅게
    /// 비친다.** 살짝 키워 겹쳐 그리면 사라진다. 원은 접점에서만 닿아 해당이 없고,
    /// 간격이 1 이상 남아 있으면 겹칠 일이 없으므로 0 이다.
    func seamOutset(gridSize: CGFloat, dotDiameter: CGFloat) -> CGFloat {
        guard self == .square, gridSize - dotDiameter <= 0 else { return 0 }
        return 0.5
    }

    /// 화면 Canvas 와 PNG 내보내기가 **같은 경로**를 쓰도록 여기 한 곳에서만 만든다.
    /// 렌더 경로가 둘이라 각자 그리면 한쪽만 모양이 바뀌는 사고가 난다.
    func path(in rect: CGRect) -> Path {
        switch self {
        case .circle: return Path(ellipseIn: rect)
        case .square: return Path(rect)     // 라운딩 없음 — 원과 대비가 분명해야 한다
        }
    }

    /// 자막 배경 색면의 모서리 반경. 도트와 **같은 규칙**을 따른다 — 원이면 알약,
    /// 사각형이면 각진 직사각형(사각 도트에 라운딩을 주지 않는 것과 같다).
    ///
    /// 색면의 여백은 모양이 바뀌어도 그대로 둔다. 사각형은 모서리가 없으니 좌우 여백을
    /// 줄일 수도 있지만, 그러면 같은 자막이 모양을 바꿀 때마다 다른 크기로 보인다 —
    /// `dotDiameter` 를 두 모양이 공유하는 것과 같은 이유다.
    ///
    /// - Parameter oneLineHeight: **한 줄짜리** 색면의 높이. 줄 수가 늘어도 라운딩은
    ///   한 줄(반원)일 때와 같아야 하므로 색면의 실제 높이를 쓰면 안 된다.
    func backdropCornerRadius(oneLineHeight: CGFloat) -> CGFloat {
        switch self {
        case .circle: return oneLineHeight / 2
        case .square: return 0
        }
    }
}

enum AppAccentColor: String, CaseIterable, Identifiable {
    static let storageKey = "24dost.accentColor"
    static let defaultChoice: AppAccentColor = .pink

    case pink
    case yellow
    case blue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pink: return "Pink"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        }
    }

    var color: Color {
        switch self {
        case .pink: return Color(red: 255.0/255.0, green: 41.0/255.0, blue: 135.0/255.0)   // #FF2987
        case .blue: return Color(red: 41.0/255.0, green: 70.0/255.0, blue: 255.0/255.0)    // #2946FF
        case .yellow: return Color(red: 255.0/255.0, green: 196.0/255.0, blue: 0.0/255.0)  // #FFC400
        }
    }

    var nsColor: NSColor {
        switch self {
        case .pink: return NSColor(red: 255.0/255.0, green: 41.0/255.0, blue: 135.0/255.0, alpha: 1)
        case .blue: return NSColor(red: 41.0/255.0, green: 70.0/255.0, blue: 255.0/255.0, alpha: 1)
        case .yellow: return NSColor(red: 255.0/255.0, green: 196.0/255.0, blue: 0.0/255.0, alpha: 1)
        }
    }

    static func choice(for rawValue: String) -> AppAccentColor {
        AppAccentColor(rawValue: rawValue) ?? defaultChoice
    }

    static var current: AppAccentColor {
        choice(for: UserDefaults.standard.string(forKey: storageKey) ?? defaultChoice.rawValue)
    }
}

/// 자막 웨이트가 굵어지는 경계. **영문·한글이 이 값 하나를 공유한다.**
/// 크기가 이 값을 넘으면 Bold, 이하면 Regular — 두 단계뿐이고 Light 는 쓰지 않는다.
/// 자막 크기는 18pt 부터 4pt 씩 올라가므로(§VideoSampler) 실제 분기는 34 / 38 사이다.
let subtitleBoldThreshold: CGFloat = 34

/// 자막 폰트 크기에 따라 적절한 폰트 웨이트를 반환.
/// 큰 크기일수록 굵게 간다 — 크게 키운 자막은 존재감을 주려는 것이므로 무게도 따라가야 한다.
///   ≤ 34pt → Regular
///   > 34pt → Bold
/// PostScript 이름 주의: Regular 는 접미사 없이 "BPdotsUnicase" 로 등록되어 있음.
private func dotsFontName(forSize size: CGFloat) -> String {
    size > subtitleBoldThreshold ? "BPdotsUnicase-Bold" : "BPdotsUnicase"
}

/// 자막에 한글이 한 글자라도 있으면 한글 자막으로 본다.
/// 완성형 음절 · 자모 · 호환 자모 · 확장 영역을 모두 본다.
private func containsHangul(_ text: String) -> Bool {
    text.unicodeScalars.contains { s in
        (0xAC00...0xD7A3).contains(s.value) ||   // 완성형 음절
        (0x1100...0x11FF).contains(s.value) ||   // 자모
        (0x3130...0x318F).contains(s.value) ||   // 호환 자모
        (0xA960...0xA97F).contains(s.value) ||   // 자모 확장 A
        (0xD7B0...0xD7FF).contains(s.value)      // 자모 확장 B
    }
}

/// 자막 본문을 그릴 폰트와 크기.
///
/// BPdots 에는 한글 글리프가 없어서 한글 자막은 시스템 폰트로 폴백되는데,
/// 그러면 BPdots 기준으로 맞춰 놓은 크기에서 한글만 유난히 크게 나온다.
/// 그래서 한글이 섞인 자막은 코레일체를 줄인 크기로 쓴다.
/// 측정(줄바꿈·폭)과 렌더가 같은 값을 써야 글자 뒤 도트 숨김 영역이 어긋나지 않으므로,
/// 폰트 선택은 반드시 이 한 곳을 통한다.
struct SubtitleTypeface {
    let fontName: String
    /// 실제로 그릴 글자 크기.
    let size: CGFloat
    /// 줄 상자 높이. **글자 크기와 무관하게 항상 기준 크기로 잡는다.**
    /// 이 값이 글자 뒤 도트를 비우는 영역의 높이가 되기 때문에, 글자 크기에 비례시키면
    /// 작은 한글 자막에서 여백만 좁아져 위아래 도트가 글자에 바짝 붙는다.
    let lineHeight: CGFloat

    var nsFont: NSFont {
        NSFont(name: fontName, size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    /// 그릴 때 위에서 얼마나 내릴지. BPdots 였다면 베이스라인이 놓였을 자리에
    /// 이 폰트의 베이스라인을 맞추기 위한 값이다. 상자 중앙에 놓으면 자막 소스가
    /// 바뀔 때마다 글자가 위아래로 튄다.
    let baselineOffset: CGFloat
}

/// 한글 자막을 BPdots 자막 옆에 놓았을 때 비슷한 크기로 읽히게 하는 배율.
///
/// 잉크 높이를 실제로 재면 0.543 에서 정확히 같아진다 (100pt 에서 BPdots "HELLO" 47.5,
/// 코레일 Light "한글자막" 87.4). 그런데 그 값은 눈으로 보면 한글이 작고 답답하다 —
/// 한글은 획이 조밀해서 같은 높이라도 라틴 대문자보다 작게 읽히고, BPdots 쪽은
/// 도트 매트릭스라 글자가 두툼해 더 커 보인다. 그래서 기하학적 일치보다 위로 올려 잡았다.
/// 실제 값은 화면에서 보고 맞춘 것 — 기하학적 일치의 1.38배다.
/// 재보고 싶으면 CTLineGetBoundsWithOptions(.useGlyphPathBounds).
private let hangulSubtitleScale: CGFloat = 0.75

/// 문자열이 **실제로** 차지하는 세로 범위(베이스라인 기준 위/아래).
///
/// 예전에는 이걸 cap-height(위) ~ 베이스라인(아래)로 가정했다. 영문 도트 폰트에서는
/// 정확히 맞는다 — BPdots 26pt 는 잉크가 베이스라인 위 12.35, 아래 0 이고 capHeight 가
/// 그대로 12.35 다. 그런데 한글은 cap 개념이 없어서 capHeight 가 실제 잉크보다 한참
/// 작고(코레일 19.5pt: 가정 9.75 vs 실제 15.07), 받침이 베이스라인 **아래로** 3.71 내려간다.
/// 그래서 자막 배경 캡슐이 글자를 못 감싸고 위쪽에 딱 붙어 보였다.
///
/// 글리프 패스 바운즈는 비싸므로 (폰트, 크기, 문자열)로 캐시한다. 자막은 초당 몇 번이
/// 아니라 몇 초에 한 번 바뀌므로 이걸로 충분하다.
@MainActor
private enum SubtitleInk {
    private static var cache: [String: (above: CGFloat, below: CGFloat, left: CGFloat, right: CGFloat)] = [:]

    /// above/below 는 베이스라인 기준 위/아래, left/right 는 그리기 원점 기준 가로 잉크 범위.
    static func extent(of text: String, fontName: String, size: CGFloat)
        -> (above: CGFloat, below: CGFloat, left: CGFloat, right: CGFloat) {
        let key = "\(fontName)|\(size)|\(text)"
        if let hit = cache[key] { return hit }
        guard let font = NSFont(name: fontName, size: size) else { return (size, 0, 0, 0) }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        // CoreText 는 베이스라인이 원점이고 위쪽이 양수.
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let advance = (text as NSString).size(withAttributes: [.font: font]).width
        var result = (above: max(0, bounds.maxY), below: max(0, -bounds.minY),
                      left: bounds.minX, right: bounds.maxX)
        // 공백뿐이면 잉크가 없다. 캡슐이 납작해지지 않게 예전 기준으로 되돌린다.
        if result.above <= 0 && result.below <= 0 {
            result = (above: font.capHeight, below: 0, left: 0, right: advance)
        }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

private func subtitleTypeface(for text: String, baseSize: CGFloat) -> SubtitleTypeface {
    let lineHeight = baseSize * 1.08
    let dotName = dotsFontName(forSize: baseSize)
    guard containsHangul(text) else {
        return SubtitleTypeface(fontName: dotName, size: baseSize,
                                lineHeight: lineHeight, baselineOffset: 0)
    }
    let size = baseSize * hangulSubtitleScale
    // 영문과 **같은 규칙·같은 경계**다. 비교는 축소 전 크기(baseSize)로 한다 — 사용자가
    // 조절하는 값이 그것이고, 축소 배율이 바뀌어도 경계가 따라 움직이면 안 되기 때문이다.
    // 코레일체에는 Regular 가 없어서 그 자리는 Medium 이 대신한다(Light 는 쓰지 않는다).
    let name = baseSize > subtitleBoldThreshold ? "KorailB" : "KorailM"
    // BPdots 였다면 베이스라인이 놓였을 자리에 맞춘다. 두 폰트의 ascender 차이만큼 내린다.
    let dotAscender = NSFont(name: dotName, size: baseSize)?.ascender ?? baseSize
    let hangulAscender = NSFont(name: name, size: size)?.ascender ?? size
    return SubtitleTypeface(fontName: name, size: size, lineHeight: lineHeight,
                            baselineOffset: dotAscender - hangulAscender)
}

/// 대기 화면 업데이트 안내 레이블. 화살표는 BPdots에 있는 "»" 글리프를 악센트 색으로 렌더.
/// (BPdots에 "→" 글리프는 없음.)
private let updatePlaceholderLabel = "Update"
private let updateArrowGlyph = "»"

/// "Update" 텍스트 rect 뒤에 이어 그리는 "»" 프레임. 렌더와 히트박스가 공유한다.
@MainActor
private func updateArrowFrame(afterTextRect sr: CGRect, fontSize: CGFloat) -> CGRect {
    let nsFont = NSFont(name: dotsFontName(forSize: fontSize), size: fontSize)
        ?? NSFont.boldSystemFont(ofSize: fontSize)
    let w = (updateArrowGlyph as NSString).size(withAttributes: [.font: nsFont]).width
    return CGRect(x: sr.maxX + fontSize * 0.45, y: sr.minY,
                  width: w, height: sr.height)
}

// MARK: - Background style

/// ⌘B로 4단 순환. 디폴트는 .blur (ultraThinMaterial).
enum BackgroundStyle: Int, CaseIterable {
    case blur              = 0  // 프로스트 블러
    case liquidGlass       = 1  // 리퀴드 글래스
    case blurBlack         = 2  // 블러 + 검정 94%
    case liquidGlassBlack  = 3  // 리퀴드 글래스 + 검정 78%

    var next: BackgroundStyle {
        BackgroundStyle(rawValue: (rawValue + 1) % BackgroundStyle.allCases.count) ?? .blur
    }
    var isGlass: Bool        { self == .liquidGlass || self == .liquidGlassBlack }
    var hasBlackOverlay: Bool { self == .blurBlack   || self == .liquidGlassBlack }
    /// 검정 오버레이 농도. 블러+검정은 94%, 리퀴드+검정은 78%.
    var blackOverlayOpacity: Double {
        switch self {
        case .blurBlack:        return 0.94
        case .liquidGlassBlack: return 0.78
        default:                return 0
        }
    }
    var displayName: String {
        switch self {
        case .blur:             return "BLUR MODE"
        case .liquidGlass:      return "LIQUID MODE"
        case .blurBlack:        return "BLUR BLACK MODE"
        case .liquidGlassBlack: return "LIQUID BLACK MODE"
        }
    }
}

/// 풀스크린 전용 배경 스타일. ⌘B로 BLACK(디폴트) ↔ WHITE 토글.
/// 일반 모드의 BackgroundStyle과 완전히 독립된 상태이며 UserDefaults로 영속.
enum FullscreenBackgroundStyle: Int, CaseIterable {
    case black = 0  // 디폴트
    case white = 1

    var next: FullscreenBackgroundStyle {
        FullscreenBackgroundStyle(rawValue: (rawValue + 1) % FullscreenBackgroundStyle.allCases.count) ?? .black
    }
    var displayName: String {
        switch self {
        case .black: return "BLACK MODE"
        case .white: return "WHITE MODE"
        }
    }
    /// 텍스트/자막 적응형 색상이 밝은 톤을 써야 하는지.
    /// BLACK 배경 → 밝은 텍스트, WHITE 배경 → 어두운 텍스트.
    var needsBrightText: Bool { self == .black }
}

// MARK: - Overlay hit test

private func isOverlayDot(
    effect: VideoSampler.OverlayEffect,
    row: Int, col: Int,
    layout: DotGridLayout
) -> Bool {
    switch effect {
    case .none:         return false
    case .border:       return layout.isOutlineDot(row: row, col: col)
    case .row(let n):   return row == n
    case .col(let n):   return col == n
    }
}

// MARK: - Fullscreen cursor auto-hide

/// 풀스크린 중 마우스가 N초간 멈춰 있으면 커서를 숨김.
/// (움직이면 OS가 setHiddenUntilMouseMoves 규칙으로 자동 복원)
final class CursorAutoHider {
    private var timer: Timer?
    private var monitor: Any?
    private let idle: TimeInterval

    init(idleSeconds: TimeInterval = 2.0) { self.idle = idleSeconds }
    deinit { stop() }

    func start() {
        stop()
        NSApplication.shared.windows.first?.acceptsMouseMovedEvents = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.schedule()
            return event
        }
        schedule()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
    /// 마우스 이동이 아닌 이유로 커서를 다시 보여줘야 할 때(핀치 줌 앵커 확인).
    /// 숨김 규칙은 mouseMoved 로만 풀리므로, 손가락만 움직이는 핀치에서는 직접 풀어야 한다.
    func reveal() {
        NSCursor.setHiddenUntilMouseMoves(false)
        schedule()
    }
    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: idle, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

// MARK: - Remuxing Indicator

/// 최신 점 크기/간격을 그대로 사용. 점 개수는 호출자가 결정(짝수=4, 홀수=3).
/// `DotShape` 를 SwiftUI 뷰로 쓰기 위한 얇은 래퍼 — 경로는 `DotShape.path(in:)` 그대로다.
/// 격자 밖에서 도트를 그리는 곳이 자기 모양을 따로 만들면, 설정에서 사각형을 골라도
/// 그 자리만 원으로 남는다. 로딩 인디케이터와 설정 스와치가 함께 쓴다(파일이 달라 internal).
///
/// `InsettableShape` 까지 채우는 건 `strokeBorder` 때문이다 — `stroke` 는 선이 경로 위에
/// 걸쳐 절반이 틀 밖으로 나가서, 같은 22pt 로 맞춰도 악센트 스와치보다 커 보인다.
struct DotMark: Shape, InsettableShape {
    let shape: DotShape
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path { shape.path(in: rect.insetBy(dx: inset, dy: inset)) }
    func inset(by amount: CGFloat) -> DotMark { DotMark(shape: shape, inset: inset + amount) }
}

private struct RemuxingIndicator: View {
    let dotDiameter: CGFloat
    let gap: CGFloat
    let count: Int
    let accentColor: Color
    let shape: DotShape
    @State private var activeIndex = 0

    var body: some View {
        HStack(spacing: gap) {
            ForEach(0..<count, id: \.self) { i in
                // 이음매 여유(`DotShape.seamOutset`)는 여기서만 쓰지 않는다. 격자의 도트는
                // 불투명이라 겹쳐 그려도 티가 안 나지만, 꺼진 도트는 15% 반투명이라 겹친
                // 띠만 두 번 합성돼 되레 **밝은 선**이 생긴다 — 15% 알파에서 배경이 살짝
                // 비치는 쪽이 눈에 덜 띈다.
                DotMark(shape: shape)
                    .fill(i == activeIndex ? accentColor : accentColor.opacity(0.15))
                    .frame(width: dotDiameter, height: dotDiameter)
                    .animation(.easeInOut(duration: 0.2), value: activeIndex)
            }
        }
        .task(id: count) {
            activeIndex = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                activeIndex = (activeIndex + 1) % max(1, count)
            }
        }
    }
}

// MARK: - Dot grid layout (shared by Canvas & URL button overlay)

/// 현재 창 크기/그리드 설정을 바탕으로 계산한 도트 격자 정보.
/// - Canvas 렌더와 URL 버튼 오버레이가 같은 앵커·코너마스크 규칙을 공유하기 위해 추출.
private struct DotGridLayout {
    let totalRows: Int
    let totalCols: Int
    let offsetX: CGFloat
    let offsetY: CGFloat
    let grid: CGFloat
    let half: CGFloat
    let applyMask: Bool
    let tlX: CGFloat
    let tlY: CGFloat
    let brX: CGFloat
    let brY: CGFloat
    let innerR2: CGFloat

    func center(row: Int, col: Int) -> CGPoint {
        CGPoint(x: offsetX + CGFloat(col) * grid + grid / 2,
                y: offsetY + CGFloat(row) * grid + grid / 2)
    }

    func isCornerMasked(_ cx: CGFloat, _ cy: CGFloat) -> Bool {
        if !applyMask { return false }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if cx < tlX { dx = tlX - cx } else if cx > brX { dx = cx - brX }
        if cy < tlY { dy = tlY - cy } else if cy > brY { dy = cy - brY }
        return dx * dx + dy * dy > innerR2
    }

    /// 실제로 보이는 영역의 가장 바깥 테두리 도트인지.
    ///
    /// 재생/일시정지 테두리를 "행 1, 열 1, 마지막 행, 마지막 열"로 잡으면 안 된다 —
    /// 간격을 좁히면 inset(30) 안쪽으로 들어온 그 줄이 통째로 마스크돼 사라져서,
    /// 테두리 깜빡임이 아예 안 보인다. 마스크를 통과한 도트 중 이웃이 마스크됐거나
    /// 격자 밖인 것을 테두리로 본다. 라운드 모서리도 자연히 따라간다.
    func isOutlineDot(row: Int, col: Int) -> Bool {
        let c = center(row: row, col: col)
        if isCornerMasked(c.x, c.y) { return false }
        for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let r = row + dr, cc = col + dc
            if r < 1 || r > totalRows - 2 || cc < 1 || cc > totalCols - 2 { return true }
            let n = center(row: r, col: cc)
            if isCornerMasked(n.x, n.y) { return true }
        }
        return false
    }

    /// 자막 앵커: 최좌하단 visible 도트.
    func findBottomLeftAnchor() -> (row: Int, col: Int)? {
        for rowIdx in stride(from: totalRows - 2, through: 1, by: -1) {
            for colIdx in 1..<(totalCols - 1) {
                let c = center(row: rowIdx, col: colIdx)
                if !isCornerMasked(c.x, c.y) { return (rowIdx, colIdx) }
            }
        }
        return nil
    }

    /// 주어진 행의 최우측 visible 컬럼.
    func findRightmostCol(in row: Int, from col: Int) -> Int {
        for colIdx in stride(from: totalCols - 2, through: col, by: -1) {
            let c = center(row: row, col: colIdx)
            if !isCornerMasked(c.x, c.y) { return colIdx }
        }
        return col
    }

    /// 종료 히트박스 앵커: 최좌상단 visible 도트. (위에서 아래로, 각 행의 왼쪽부터 탐색)
    func findTopLeftAnchor() -> (row: Int, col: Int)? {
        for rowIdx in 1..<(totalRows - 1) {
            for colIdx in 1..<(totalCols - 1) {
                let c = center(row: rowIdx, col: colIdx)
                if !isCornerMasked(c.x, c.y) { return (rowIdx, colIdx) }
            }
        }
        return nil
    }

    /// 피크 히트박스 앵커: 최우상단 visible 도트. (위에서 아래로, 각 행의 오른쪽부터 탐색)
    func findTopRightAnchor() -> (row: Int, col: Int)? {
        for rowIdx in 1..<(totalRows - 1) {
            for colIdx in stride(from: totalCols - 2, through: 1, by: -1) {
                let c = center(row: rowIdx, col: colIdx)
                if !isCornerMasked(c.x, c.y) { return (rowIdx, colIdx) }
            }
        }
        return nil
    }

    /// 피크 영상 rect = 가시 도트 영역(행/열 1..totalRows-2, 1..totalCols-2)의 바운딩 박스.
    /// 동심원 라운딩에 쓸 창 가장자리까지의 최소 거리도 반환.
    func visibleDotBounds() -> (rect: CGRect, edgeGap: CGFloat) {
        let x = offsetX + grid
        let y = offsetY + grid
        let w = CGFloat(totalCols - 2) * grid
        let h = CGFloat(totalRows - 2) * grid
        return (CGRect(x: x, y: y, width: w, height: h), min(x, y))
    }
}

private func makeDotGridLayout(
    size: CGSize,
    grid: CGFloat,
    dotDiameter: CGFloat,
    rowsOverride: Int?,
    colsOverride: Int?,
    isFullscreen: Bool
) -> DotGridLayout {
    let totalCols = colsOverride ?? max(3, Int(size.width  / grid))
    let totalRows = rowsOverride ?? max(3, Int(size.height / grid))
    let offsetX = (size.width  - CGFloat(totalCols) * grid) / 2
    let offsetY = (size.height - CGFloat(totalRows) * grid) / 2
    let appCornerRadius: CGFloat = 32
    let minPadding: CGFloat = 30
    let inset = max(minPadding, grid)
    let innerR = max(0, appCornerRadius - inset)
    let mask = !isFullscreen && innerR > 0
    return DotGridLayout(
        totalRows: totalRows, totalCols: totalCols,
        offsetX: offsetX, offsetY: offsetY,
        grid: grid, half: dotDiameter / 2,
        applyMask: mask,
        tlX: inset + innerR, tlY: inset + innerR,
        brX: size.width - inset - innerR,
        brY: size.height - inset - innerR,
        innerR2: innerR * innerR
    )
}

// MARK: - URL Input Geometry

/// URL 편집 모드의 우측 버튼 블록 레이아웃.
/// - 입력 없음: "CANCEL" 한 덩어리 (전체가 취소 히트박스)
/// - 입력 있음: "X  GO" (왼쪽 절반 = 취소, 오른쪽 절반 = 제출)
///
/// 레이블 텍스트와 `rightBlockRect` 를 Canvas 렌더가 그대로 사용해서
/// 시각적 위치와 클릭 히트박스가 항상 일치하도록 한 곳에서 관리한다.
private struct URLInputGeometry {
    let rightText: String           // "CANCEL" 또는 "X  GO"
    let rightBlockRect: CGRect      // 렌더링 원점(topLeading) + 도트 숨김에 쓰이는 rect
    let cancelTapRect: CGRect       // 취소(="CANCEL" 전체 또는 "X" 절반)
    let commitTapRect: CGRect?      // 제출(="GO" 절반). 입력 없을 땐 nil.
}

/// 우측 블록의 레이블·히트박스를 계산. nil 이면 앵커를 찾지 못한 것.
/// `rightText` 와 `twoButton` 조합으로 URL 편집("CANCEL"/"X  GO")과 자막 프롬프트("X  USE") 모두 커버.
@MainActor
private func computeURLInputGeometry(
    size: CGSize,
    sampler: VideoSampler,
    isFullscreen: Bool,
    rightText: String,
    twoButton: Bool
) -> URLInputGeometry? {
    let grid = sampler.gridSize
    let fontSize = sampler.subtitleFontSize
    let lineH = fontSize * 1.08

    // dotColors 가 채워져 있으면 그 차원을, 아니면 size/grid 로.
    let rows = sampler.dotColors.count
    let cols = sampler.dotColors.first?.count ?? 0
    let layout = makeDotGridLayout(
        size: size, grid: grid, dotDiameter: sampler.dotDiameter,
        rowsOverride: rows > 0 ? rows : nil,
        colsOverride: cols > 0 ? cols : nil,
        isFullscreen: isFullscreen
    )

    guard let a = layout.findBottomLeftAnchor() else { return nil }
    let anchorC  = layout.center(row: a.row, col: a.col)
    let anchorBottom = anchorC.y + layout.half
    let rightCol = layout.findRightmostCol(in: a.row, from: a.col)
    let anchorRight  = layout.center(row: a.row, col: rightCol).x + layout.half

    let nsFont = NSFont(name: dotsFontName(forSize: fontSize), size: fontSize)
        ?? NSFont.boldSystemFont(ofSize: fontSize)
    let rightWidth = (rightText as NSString).size(withAttributes: [.font: nsFont]).width
    let topY = anchorBottom - lineH
    let rightBlockRect = CGRect(x: anchorRight - rightWidth, y: topY,
                                width: rightWidth, height: lineH)

    if twoButton {
        // "X  GO" / "X  USE" → 가로 절반으로 분할.
        let halfW = rightWidth / 2
        let cancelTap = CGRect(x: rightBlockRect.minX, y: topY, width: halfW, height: lineH)
        let commitTap = CGRect(x: rightBlockRect.minX + halfW, y: topY, width: halfW, height: lineH)
        return URLInputGeometry(rightText: rightText, rightBlockRect: rightBlockRect,
                                cancelTapRect: cancelTap, commitTapRect: commitTap)
    } else {
        // "CANCEL" → 블록 전체가 취소.
        return URLInputGeometry(rightText: rightText, rightBlockRect: rightBlockRect,
                                cancelTapRect: rightBlockRect, commitTapRect: nil)
    }
}

/// 대기 화면 "Update »" 의 클릭 히트박스 rect. nil 이면 앵커를 찾지 못한 것.
/// 렌더 쪽(draw)과 동일하게 bottom-left 앵커 + "Update" 폭 기준으로 계산한다.
@MainActor
private func computeUpdateArrowGeometry(
    size: CGSize,
    sampler: VideoSampler,
    isFullscreen: Bool
) -> CGRect? {
    let grid = sampler.gridSize
    let fontSize = sampler.subtitleFontSize
    let lineH = fontSize * 1.08
    // 대기 화면에서만 쓰이므로 dotColors 없이 size/grid 기준 레이아웃.
    let layout = makeDotGridLayout(
        size: size, grid: grid, dotDiameter: sampler.dotDiameter,
        rowsOverride: nil, colsOverride: nil,
        isFullscreen: isFullscreen
    )
    guard let a = layout.findBottomLeftAnchor() else { return nil }
    let anchorC = layout.center(row: a.row, col: a.col)
    let anchorLeft   = anchorC.x - layout.half
    let anchorBottom = anchorC.y + layout.half
    let nsFont = NSFont(name: dotsFontName(forSize: fontSize), size: fontSize)
        ?? NSFont.boldSystemFont(ofSize: fontSize)
    let textWidth = (updatePlaceholderLabel as NSString)
        .size(withAttributes: [.font: nsFont]).width
    let textRect = CGRect(x: anchorLeft, y: anchorBottom - lineH,
                          width: textWidth, height: lineH)
    // "Update" 글자와 화살표를 통째로 히트박스로 잡는다. 화살표만 잡아 두면
    // 글자를 누른 클릭이 배경으로 흘러가 직전 영상이 재생돼 버린다.
    let arrowRect = updateArrowFrame(afterTextRect: textRect, fontSize: fontSize)
    return textRect.union(arrowRect)
        .insetBy(dx: -fontSize * 0.35, dy: -fontSize * 0.2)
}

// MARK: - Dots Overlay (the big Canvas)

/// 도트 격자 + 자막/URL/모드 레이블/플레이스홀더를 모두 그리는 메인 Canvas.
/// ContentView 본체에서 분리해 SwiftUI 타입체커 부담을 줄임.
private struct DotsOverlayView: View {
    @ObservedObject var sampler: VideoSampler
    let isFullscreen: Bool
    let backgroundStyle: BackgroundStyle
    /// 풀스크린 배경 스타일. brightTextMode 계산 시 참조. 비풀스크린 모드에서는 무시됨.
    let fullscreenBackgroundStyle: FullscreenBackgroundStyle
    let adaptiveSubtitleColor: Bool
    /// 도트를 원으로 그릴지 사각형으로 그릴지. (설정 Appearance)
    let dotShape: DotShape
    /// peek 중 자막 아래에 반투명 캡슐 색면을 까는 옵션. (설정 Appearance)
    let subtitleBackdropWhilePeeking: Bool
    let backgroundStyleLabel: String?
    let isEditingURL: Bool
    let urlBuffer: String
    /// 프롬프트 활성 여부. true 면 하단에 안내 문구와 "X  USE" 노출.
    let subtitlePromptActive: Bool
    /// 프롬프트 문구. 사이드카 자막 검출이면 "SUBTITLE FOUND",
    /// 다른 언어로 만들어 둔 자막이 있으면 그 언어를 알린다.
    let promptMessage: String
    /// 확인 버튼에 쓸 동사. 자막 프롬프트는 "USE", 삭제 확인은 "DELETE".
    /// 되돌릴 수 없는 동작에 "USE" 가 뜨면 무엇에 동의하는지 흐려진다.
    let promptConfirmLabel: String
    /// 재생 정보 오버레이. 파일명/시간 정보를 2줄로 표시한다.
    let playbackInfoTitle: String?
    let playbackInfoActive: Bool
    /// 피크 중엔 도트를 전부 스킵(실제 영상이 뒤에서 보이도록). 자막/레이블은 그대로 렌더.
    let isPeeking: Bool
    let accentColor: Color
    /// 새 릴리스가 있으면 그 버전 문자열. 대기 화면 "24Dost"가 업데이트 표기로 바뀐다.
    let updateAvailableVersion: String?

    var body: some View {
        Canvas { context, size in
            draw(context: &context, size: size)
        }
        .allowsHitTesting(false)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { sampler.currentDisplaySize = geo.size }
                    .onChange(of: geo.size) { _, s in sampler.currentDisplaySize = s }
            }
        )
    }

    // MARK: Draw

    /// 플레이스홀더: 첫 프레임 샘플링 전(= dotColors 비어있음)까지 유지.
    /// 단 remux(로딩) 중에는 모든 placeholder 요소를 숨겨 인디케이터가 단독으로 보이게.
    private var isPlaceholder: Bool {
        sampler.dotColors.isEmpty && !sampler.isLoadingMedia
    }

    private func draw(context: inout GraphicsContext, size: CGSize) {
        let grid = sampler.gridSize
        let dotD = sampler.dotDiameter
        // 간격 0 인 사각형만 값이 붙는다. 세 군데 도트가 모두 같은 사각형을 써야
        // 앵커·테두리 도트만 이음매가 남는 일이 없다.
        let seam = dotShape.seamOutset(gridSize: grid, dotDiameter: dotD)

        // 그리드 차원 결정
        let rows = sampler.dotColors.count
        let cols = sampler.dotColors.first?.count ?? 0
        let layout: DotGridLayout
        if !isPlaceholder && rows > 0 && cols > 0 {
            layout = makeDotGridLayout(
                size: size, grid: grid, dotDiameter: dotD,
                rowsOverride: rows, colsOverride: cols, isFullscreen: isFullscreen)
        } else if isPlaceholder {
            layout = makeDotGridLayout(
                size: size, grid: grid, dotDiameter: dotD,
                rowsOverride: nil, colsOverride: nil, isFullscreen: isFullscreen)
        } else {
            return
        }

        // 깜빡(overlayEffect)
        let effect = sampler.overlayEffect
        let hasOverlay = effect != VideoSampler.OverlayEffect.none
        let blinkPhase = Int(sampler.overlayProgress * Double(sampler.overlayBlinks * 2))
        let isBlinkOn = blinkPhase % 2 == 0

        let isBlackFullscreen = isFullscreen && fullscreenBackgroundStyle == .black
        let targetAlpha = isBlackFullscreen ? 0.10 : 0.40
        let placeholderColor = Color(red: 201/255, green: 207/255, blue: 229/255).opacity(targetAlpha) // #C9CFE5

        // 오버레이 텍스트 소스 결정.
        // 우선순위(높→낮): URL 편집 → 재생 정보 → 자막 프롬프트 → 모드 레이블 → 플레이스홀더 → 자막
        var overlayRawText: String
        let overlayIsSubtitle: Bool
        let preserveLineBreaks: Bool
        if isEditingURL {
            overlayRawText = urlBuffer + "|"
            overlayIsSubtitle = true
            preserveLineBreaks = false
        } else if playbackInfoActive, let title = playbackInfoTitle, !title.isEmpty {
            overlayRawText = "\(title)\n\(playbackTimingLine())"
            overlayIsSubtitle = true
            preserveLineBreaks = true
        } else if subtitlePromptActive {
            overlayRawText = promptMessage
            overlayIsSubtitle = true
            preserveLineBreaks = false
        } else if let modeLabel = backgroundStyleLabel {
            overlayRawText = modeLabel
            overlayIsSubtitle = false
            preserveLineBreaks = false
        } else if isPlaceholder {
            overlayRawText = updateAvailableVersion == nil ? "24Dost" : updatePlaceholderLabel
            overlayIsSubtitle = false
            preserveLineBreaks = false
        } else if sampler.hasSubtitles && sampler.showSubtitles && !sampler.currentSubtitle.isEmpty {
            overlayRawText = sampler.currentSubtitle
            overlayIsSubtitle = true
            preserveLineBreaks = false
        } else {
            overlayRawText = ""
            overlayIsSubtitle = false
            preserveLineBreaks = false
        }

        // 한글을 완성형으로 모아 준다.
        //
        // APFS 는 파일명을 **자모 분해(NFD)** 로 저장한다 — "시간제" 가 파일명에서는
        // U+1109 U+1175 U+1100 U+1161 U+11AB U+110C U+1166 일곱 개로 들어 있다.
        // 코레일체에는 조합용 자모(U+1100–11FF) 글리프가 아예 없어서 시스템 폴백으로
        // 넘어가고, 그 폰트는 자모를 합치지 않고 낱자로 그린다. ⌘I 파일명이
        // "ㅅㅣㄱㅏㄴㅈㅔ" 로 흩어져 보이던 원인이다.
        //
        // 폭 측정과 렌더가 같은 문자열을 써야 하므로 **여기 한 곳에서** 정규화한다.
        // 이미 완성형인 문자열에는 아무 영향이 없다.
        overlayRawText = overlayRawText.precomposedStringWithCanonicalMapping

        // 우측 블록 레이블.
        // - URL 편집: 입력 없음 "CANCEL" / 입력 있음 "X  GO"
        // - 재생 정보: "CLOSE"
        // - 자막 프롬프트: "X  USE"
        // - 그 외: 없음
        let rightText: String
        if isEditingURL {
            rightText = urlBuffer.isEmpty ? "CANCEL" : "X  GO"
        } else if playbackInfoActive {
            rightText = "CLOSE"
        } else if subtitlePromptActive {
            rightText = "X  \(promptConfirmLabel)"
        } else {
            rightText = ""
        }

        // 자막/URL 레이아웃
        let (subtitleRect, subtitleLines, rightBlockRect)
            = resolveTextLayout(layout: layout, overlayRawText: overlayRawText, rightText: rightText,
                                preserveLineBreaks: preserveLineBreaks)

        // 도트 숨김용 확장 rect (업데이트 "»"가 있으면 그 폭까지 포함)
        let showsUpdateArrow = isPlaceholder && updateAvailableVersion != nil
        let subtitleHideRect: CGRect? = subtitleRect.map {
            let arrowPad: CGFloat = showsUpdateArrow
                ? updateArrowFrame(afterTextRect: $0, fontSize: sampler.subtitleFontSize).maxX - $0.maxX
                : 0
            return CGRect(x: $0.minX, y: $0.minY, width: $0.width + grid + arrowPad, height: $0.height)
        }
        let rightBlockHideRect: CGRect? = rightBlockRect.map {
            CGRect(x: $0.minX - grid, y: $0.minY, width: $0.width + grid, height: $0.height)
        }
        
        // 색상 샘플링용 rect
        // - 폰트 크기/웨이트에 따라 텍스트 rect가 작아지면 도트 중심점이 rect에 하나도 안 들어가
        //   sampN == 0 → adaptiveColor가 순백/순흑으로 폴백하는 케이스가 생길 수 있음.
        // - 샘플링은 약간 더 넓은 범위를 쓰되, 실제 도트 "숨김" 영역은 기존 hideRect 유지.
        let samplePad = max(grid, 24)
        let subtitleSampleRect = subtitleHideRect?.insetBy(dx: -samplePad, dy: -samplePad)
        let rightBlockSampleRect = rightBlockHideRect?.insetBy(dx: -samplePad, dy: -samplePad)

        // 도트 렌더 + 색상 샘플링
        var sampR = 0.0, sampG = 0.0, sampB = 0.0, sampN = 0
        var sampR2 = 0.0, sampG2 = 0.0, sampB2 = 0.0, sampN2 = 0
        let peekAnchor = isPeeking ? layout.findTopRightAnchor() : nil

        for rowIdx in 1..<(layout.totalRows - 1) {
            for colIdx in 1..<(layout.totalCols - 1) {
                let c = layout.center(row: rowIdx, col: colIdx)
                if layout.isCornerMasked(c.x, c.y) { continue }

                // 자막 색 샘플 (overlayIsSubtitle 일 때만)
                if overlayIsSubtitle, let sr = subtitleSampleRect,
                   c.x >= sr.minX, c.x <= sr.maxX, c.y >= sr.minY, c.y <= sr.maxY,
                   rowIdx < rows, colIdx < cols,
                   let comps = sampler.dotColors[rowIdx][colIdx].components,
                   comps.count >= 3 {
                    sampR += Double(comps[0]); sampG += Double(comps[1]); sampB += Double(comps[2])
                    sampN += 1
                }
                // "NO" 블록 색 샘플
                if let rr = rightBlockSampleRect,
                   c.x >= rr.minX, c.x <= rr.maxX, c.y >= rr.minY, c.y <= rr.maxY,
                   rowIdx < rows, colIdx < cols,
                   let comps = sampler.dotColors[rowIdx][colIdx].components,
                   comps.count >= 3 {
                    sampR2 += Double(comps[0]); sampG2 += Double(comps[1]); sampB2 += Double(comps[2])
                    sampN2 += 1
                }

                // 피크 중엔 실제 영상을 드러내되, 피크 토글을 되돌릴 우상단 도트는 남긴다.
                // anchor는 동일 레이아웃에서 계산하므로 도트 크기/간격 변화에 그대로 따라간다.
                if isPeeking {
                    // 깜빡임이 켜져 있는 동안은 앵커도 같은 색으로 간다. 한계치 알림처럼
                    // 악센트 색으로 깜빡일 때 앵커만 흰 점으로 남으면 눈에 거슬린다.
                    let blinkColor = (sampler.overlayIsAlert || !sampler.isPlaying)
                        ? accentColor : indicatorColorPlay
                    if let peekAnchor, rowIdx == peekAnchor.row, colIdx == peekAnchor.col {
                        let dotRect = CGRect(x: c.x - layout.half, y: c.y - layout.half, width: dotD, height: dotD)
                            .insetBy(dx: -seam, dy: -seam)
                        // 깜빡임이 꺼진 위상에서도 앵커는 계속 보여야 한다 — 피크를 되돌릴
                        // 유일한 표적이라서 사라지면 안 된다.
                        context.fill(dotShape.path(in: dotRect),
                                     with: .color(hasOverlay && isBlinkOn ? blinkColor : indicatorColorPlay))
                        continue
                    }
                    // 볼륨/탐색 직선은 피크 중에도 그린다. 조작은 피크 중에도 먹히는데
                    // 도트를 통째로 건너뛰면 확인할 방법이 없다.
                    // 글자 영역은 도트 모드와 똑같이 파낸다 — 안 그러면 재생/일시정지
                    // 테두리가 좌하단 자막 위에 겹쳐 찍힌다.
                    if hasOverlay, isBlinkOn,
                       isOverlayDot(effect: effect, row: rowIdx, col: colIdx, layout: layout),
                       !shouldHideDot(at: c, rect: subtitleHideRect, half: layout.half),
                       !shouldHideDot(at: c, rect: rightBlockHideRect, half: layout.half) {
                        let dotRect = CGRect(x: c.x - layout.half, y: c.y - layout.half, width: dotD, height: dotD)
                            .insetBy(dx: -seam, dy: -seam)
                        context.fill(dotShape.path(in: dotRect), with: .color(blinkColor))
                    }
                    continue
                }

                // 텍스트 rect와 깊이(penetration) 2px 이상 겹치면 숨김
                if shouldHideDot(at: c, rect: subtitleHideRect, half: layout.half) { continue }
                if shouldHideDot(at: c, rect: rightBlockHideRect, half: layout.half) { continue }

                let dotRect = CGRect(x: c.x - layout.half, y: c.y - layout.half, width: dotD, height: dotD)
                            .insetBy(dx: -seam, dy: -seam)
                let color = dotColor(
                    row: rowIdx, col: colIdx, rows: rows, cols: cols,
                    layout: layout,
                    effect: effect, hasOverlay: hasOverlay, isBlinkOn: isBlinkOn,
                    placeholderColor: placeholderColor
                )
                context.fill(dotShape.path(in: dotRect), with: .color(color))
            }
        }

        // 오버레이 텍스트 색상
        // 풀스크린: BLACK 모드에서만 밝은 텍스트, WHITE 모드는 어두운 텍스트로 반전.
        // 비풀스크린: 기존과 동일 (black overlay 여부).
        let brightTextMode = isFullscreen
            ? fullscreenBackgroundStyle.needsBrightText
            : backgroundStyle.hasBlackOverlay
        let fixedOverlayColor = brightTextMode
            ? Color.white.opacity(0.95)
            : Color.black.opacity(0.95)
        let overlayColor: Color
        if backgroundStyleLabel != nil {
            overlayColor = adaptiveSubtitleColor ? accentColor : fixedOverlayColor
        } else if isPlaceholder {
            if isEditingURL || subtitlePromptActive {
                // 대기화면에서 URL 편집/자막 프롬프트 시 버튼(X, GO 등)과 동일한 색상 사용
                overlayColor = adaptiveSubtitleColor
                    ? adaptiveColor(sR: sampR, sG: sampG, sB: sampB, n: sampN,
                                    brightMode: brightTextMode)
                    : fixedOverlayColor
            } else {
                overlayColor = placeholderColor
            }
        } else if overlayIsSubtitle {
            if sampler.isAudioMode || sampler.urlLoadError != nil {
                // 오디오/에러 모드 등 백그라운드가 도트로 덮인 상태에서는 배경 점 색상(C9CFE5)으로 고정.
                overlayColor = adaptiveSubtitleColor
                    ? Color(red: 201/255, green: 207/255, blue: 229/255)
                    : fixedOverlayColor
            } else if !adaptiveSubtitleColor {
                overlayColor = fixedOverlayColor
            } else {
                overlayColor = adaptiveColor(sR: sampR, sG: sampG, sB: sampB, n: sampN,
                                             brightMode: brightTextMode)
            }
        } else {
            overlayColor = .clear
        }

        // 자막/URL 본문 렌더.
        // resolveTextLayout 이 폭을 잴 때 쓴 것과 반드시 같은 폰트여야 한다 —
        // 어긋나면 글자 뒤 도트가 남거나 과하게 지워진다.
        let bodyFace = subtitleTypeface(for: overlayRawText, baseSize: sampler.subtitleFontSize)
        if let sr = subtitleRect, !subtitleLines.isEmpty {
            // 캡슐이 그려질 때만 0 이 아니게 된다 — dot 모드·peek 아닌 상태는 전혀 영향받지 않는다.
            var backdropTextShift: CGFloat = 0
            // peek 중 자막 배경 캡슐 색면. 설정 ON + 실제 자막(캡션)일 때만.
            // 텍스트 바로 뒤에 깔리도록 본문 렌더 직전에 그린다.
            let isRealSubtitle = sampler.hasSubtitles && sampler.showSubtitles
                && !sampler.currentSubtitle.isEmpty
            if isPeeking, subtitleBackdropWhilePeeking, isRealSubtitle {
                let lineH = bodyFace.lineHeight
                let nsFont = bodyFace.nsFont
                let n = max(1, subtitleLines.count)
                // 여백은 **기준 크기**로 잡는다. 한글은 0.75 로 줄여 그리는데 그 줄어든
                // 크기로 여백까지 줄이면, 같은 자막 크기인데 한글 캡슐만 빡빡해진다.
                // 좌우가 0.5 였을 때 글자가 캡슐 옆면에 밭게 붙어 보였다. 캡슐이 알약이라
                // corner radius 가 높이의 절반인데, 한글은 캡슐이 높아져 radius(17.2)가
                // 좌우 여백(13)보다 커진다 — 글자 시작점이 둥근 모서리 안쪽에 들어간다.
                // 그래서 0.72 로 올렸는데, 이번엔 한글에서 우측이 글자에 거의 닿아 보인다는
                // 지적이 있었다. 가로 폭 측정(advance width)이 실제 잉크보다 되레 살짝 넉넉한
                // 것을 확인했으므로(세로 때와 반대 — 측정 버그 아님) 순수하게 시각적 밀도
                // 차이다. 좌우를 비대칭으로 나눈다: 좌는 0.72 의 60%, 우는 (좌+우)/2 가
                // "0.5→0.72 로 늘렸던 폭의 절반만" 늘린 값(0.61)이 되도록 역산한다.
                let padXLeft: CGFloat = sampler.subtitleFontSize * 0.432   // 0.72 × 0.6
                let padXRight: CGFloat = sampler.subtitleFontSize * 0.788  // 평균이 0.61 되도록
                let padY = sampler.subtitleFontSize * 0.30
                // 줄마다 실제 잉크 범위를 재서 캡슐이 글자를 확실히 감싸게 한다.
                // (cap-height 가정으로는 한글을 못 잰다 — SubtitleInk 주석 참고)
                func baseline(_ i: Int) -> CGFloat {
                    sr.minY + bodyFace.baselineOffset + CGFloat(i) * lineH + nsFont.ascender
                }
                var inkTop = CGFloat.greatestFiniteMagnitude
                var inkBottom = -CGFloat.greatestFiniteMagnitude
                var inkLeft = CGFloat.greatestFiniteMagnitude
                var inkRight = -CGFloat.greatestFiniteMagnitude
                var tallestLine: CGFloat = 0
                for (i, line) in subtitleLines.enumerated() {
                    let ink = SubtitleInk.extent(of: line, fontName: bodyFace.fontName, size: bodyFace.size)
                    inkTop = min(inkTop, baseline(i) - ink.above)
                    inkBottom = max(inkBottom, baseline(i) + ink.below)
                    inkLeft = min(inkLeft, ink.left)
                    inkRight = max(inkRight, ink.right)
                    tallestLine = max(tallestLine, ink.above + ink.below)
                }
                let inkCenterY = (inkTop + inkBottom) / 2
                let capH = (inkBottom - inkTop) + padY * 2
                // 모서리는 도트 모양을 따라간다(원=알약, 사각형=각진 직사각형).
                // 한 줄 기준 높이를 넘겨 → 줄 수가 늘어도 라운딩은 한 줄(반원)일 때와 같다.
                let oneLineH = tallestLine + padY * 2
                let cornerR = dotShape.backdropCornerRadius(oneLineHeight: oneLineH)
                // 가로도 세로와 같이 **실제 잉크**를 기준으로 잡는다. advance width 로 잡으면
                // SwiftUI 가 그리는 폭과 미세하게 어긋나 우측 여백만 잠식된다.
                // 이러면 좌/우 여백이 padXLeft / padXRight 그대로 나온다.
                let capLeftX  = sr.minX + inkLeft  - padXLeft
                let capRightX = sr.minX + inkRight + padXRight
                let capRectUnshifted = CGRect(x: capLeftX, y: inkCenterY - capH / 2,
                                              width: capRightX - capLeftX, height: capH)

                // 왼쪽 여백을 하단 여백만큼 벌린다.
                //
                // 하단 여백(창 바닥 ~ 캡슐 바닥)은 grid 앵커가 이미 넉넉하고 잉크 기반이라
                // 커서, 왼쪽 여백은 padXLeft 가 그대로 깎아 먹어 훨씬 좁다
                // (실측: 960×540/26pt 예시에서 좌 21.3 vs 하 44.3, 2배 이상 차이). padXLeft 를
                // 그대로 두고 좌 여백만 늘리려면 캡슐이 텍스트보다 왼쪽으로 밀려나야 하는데
                // 그건 음수 padXLeft, 즉 글자가 캡슐 밖으로 나가야 한다는 뜻이라 불가능하다.
                // 그래서 **캡슐과 텍스트를 함께 오른쪽으로 민다** — 도트 모드·peek 이 아닌
                // 상태는 이 블록에 들어오지 않으므로 전혀 영향받지 않는다.
                let bottomMargin = size.height - capRectUnshifted.maxY
                let originalLeftMargin = capRectUnshifted.minX
                let idealShift = max(0, bottomMargin - originalLeftMargin)
                // 줄바꿈은 절대 다시 하지 않는다 — peek 을 켜고 끌 때 자막 줄 수가 바뀌면
                // 안 된다. 그래서 "얼마나 밀어도 되는지"를 오른쪽 텍스트 폭으로 다시
                // 재는 대신, **밀어도 오른쪽 여백이 원래 왼쪽 여백보다 좁아지지 않는
                // 선까지만** 허용한다. 긴 줄은 밀 수 있는 만큼만 밀린다.
                let maxShift = max(0, (size.width - originalLeftMargin) - capRectUnshifted.maxX)
                let shift = min(idealShift, maxShift)

                let capRect = capRectUnshifted.offsetBy(dx: shift, dy: 0)
                // 자막 뒤 장면색(샘플 평균)을 색면 hue 소스로 전달 → 유채색 색면.
                let sceneColor: Color? = sampN > 0
                    ? Color(.sRGB, red: sampR / Double(sampN),
                            green: sampG / Double(sampN), blue: sampB / Double(sampN))
                    : nil
                context.fill(
                    Path(roundedRect: capRect, cornerRadius: cornerR),
                    with: .color(subtitleBackdropColor(from: overlayColor, scene: sceneColor))
                )
                backdropTextShift = shift
            }
            let lineH = bodyFace.lineHeight
            for (i, line) in subtitleLines.enumerated() {
                let resolved = context.resolve(
                    Text(line)
                        .font(.custom(bodyFace.fontName, size: bodyFace.size))
                        .foregroundColor(overlayColor)
                )
                // 줄 상자는 기준 크기로 잡혀 있으므로, 작은 글자는 그 안에서 중앙에 놓는다.
                // backdropTextShift 는 캡슐이 그려질 때만 0 이 아니다.
                context.draw(resolved,
                             at: CGPoint(x: sr.minX + backdropTextShift,
                                         y: sr.minY + CGFloat(i) * lineH + bodyFace.baselineOffset),
                             anchor: .topLeading)
            }
        }

        // 대기 화면 "Update »" — 텍스트 뒤에 "»" 글리프를 악센트 컬러로 그린다.
        if showsUpdateArrow, let sr = subtitleRect {
            let fontSize = sampler.subtitleFontSize
            let arrow = updateArrowFrame(afterTextRect: sr, fontSize: fontSize)
            let resolved = context.resolve(
                Text(updateArrowGlyph)
                    .font(.custom(dotsFontName(forSize: fontSize), size: fontSize))
                    .foregroundColor(accentColor)
            )
            context.draw(resolved, at: CGPoint(x: arrow.minX, y: sr.minY), anchor: .topLeading)
        }

        // "CANCEL" 또는 "X  GO" — 모두 같은 적응형 색으로 렌더 (단일 Text).
        if let rr = rightBlockRect, !rightText.isEmpty {
            let color = adaptiveSubtitleColor
                ? adaptiveColor(sR: sampR2, sG: sampG2, sB: sampB2, n: sampN2,
                                brightMode: brightTextMode)
                : fixedOverlayColor
            let resolved = context.resolve(
                Text(rightText)
                    .font(.custom(dotsFontName(forSize: sampler.subtitleFontSize), size: sampler.subtitleFontSize))
                    .foregroundColor(color)
            )
            context.draw(resolved, at: CGPoint(x: rr.minX, y: rr.minY), anchor: .topLeading)
        }
    }

    // MARK: Helpers

    /// 자막/URL 텍스트의 wrap + 앵커링 계산.
    /// `rightText` 가 비어있지 않으면 그만큼 우측에 블록 영역을 예약하고 그 rect를 돌려준다.
    /// 반환: (자막 rect, 줄 배열, 우측 블록 rect)
    private func resolveTextLayout(
        layout: DotGridLayout,
        overlayRawText: String,
        rightText: String,
        preserveLineBreaks: Bool = false
    ) -> (CGRect?, [String], CGRect?) {
        guard !overlayRawText.isEmpty else { return (nil, [], nil) }
        let normalizedText = overlayRawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return (nil, [], nil) }

        guard let a = layout.findBottomLeftAnchor() else { return (nil, [], nil) }
        let anchorC = layout.center(row: a.row, col: a.col)
        let anchorLeft   = anchorC.x - layout.half
        let anchorBottom = anchorC.y + layout.half
        let rightCol = layout.findRightmostCol(in: a.row, from: a.col)
        let anchorRight = layout.center(row: a.row, col: rightCol).x + layout.half

        // 본문 폰트는 내용에 따라 달라진다(한글이면 코레일체 축소 크기).
        // 여기서 정한 폰트로 폭을 재야 줄바꿈과 도트 숨김 영역이 렌더와 일치한다.
        let face = subtitleTypeface(for: normalizedText, baseSize: sampler.subtitleFontSize)
        let lineH = face.lineHeight
        let nsFont = face.nsFont
        func measure(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: nsFont]).width
        }

        // 우측 블록(CANCEL / X GO)은 항상 라틴이라 BPdots 를 유지한다.
        let rightFontSize = sampler.subtitleFontSize
        let rightFont = NSFont(name: dotsFontName(forSize: rightFontSize), size: rightFontSize)
            ?? NSFont.boldSystemFont(ofSize: rightFontSize)
        func measureRight(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: rightFont]).width
        }

        let rawMaxWidth = max(1, anchorRight - anchorLeft)
        let rightWidth: CGFloat = rightText.isEmpty ? 0 : measureRight(rightText)
        let rightGap:   CGFloat = rightText.isEmpty ? 0 : layout.grid * 2
        let maxWidth = rightText.isEmpty ? rawMaxWidth : max(1, rawMaxWidth - rightWidth - rightGap)

        let sourceLines: [String]
        if preserveLineBreaks {
            sourceLines = normalizedText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
        } else {
            sourceLines = [normalizedText.replacingOccurrences(of: "\n", with: " ")]
        }

        // 1) 공백 기준 단어 wrap
        var lines: [String] = []
        for sourceLine in sourceLines {
            if sourceLine.isEmpty {
                lines.append("")
                continue
            }
            var current = ""
            for word in sourceLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
                let candidate = current.isEmpty ? word : "\(current) \(word)"
                if measure(candidate) > maxWidth && !current.isEmpty {
                    lines.append(current)
                    current = word
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty {
                lines.append(current)
            } else {
                lines.append("")
            }
        }

        // 2) 단일 단어가 폭을 넘으면 글자 단위 분할
        var wrapped: [String] = []
        for line in lines {
            if line.isEmpty || measure(line) <= maxWidth { wrapped.append(line); continue }
            var buf = ""
            for ch in line {
                let trial = buf + String(ch)
                if measure(trial) > maxWidth && !buf.isEmpty {
                    wrapped.append(buf); buf = String(ch)
                } else {
                    buf = trial
                }
            }
            if !buf.isEmpty { wrapped.append(buf) }
        }

        let availableHeight = max(lineH, anchorBottom - layout.grid)
        let maxVisibleLines = max(1, Int(floor(availableHeight / lineH)))
        if wrapped.count > maxVisibleLines {
            wrapped = Array(wrapped.suffix(maxVisibleLines))
        }

        let subtitleRect: CGRect?
        if wrapped.isEmpty {
            subtitleRect = nil
        } else {
            let textWidth  = wrapped.map(measure).max() ?? 0
            let textHeight = CGFloat(wrapped.count) * lineH
            subtitleRect = CGRect(x: anchorLeft, y: anchorBottom - textHeight,
                                  width: textWidth, height: textHeight)
        }

        let rightBlockRect: CGRect? = rightText.isEmpty
            ? nil
            : CGRect(x: anchorRight - rightWidth, y: anchorBottom - rightFontSize * 1.08,
                     width: rightWidth, height: rightFontSize * 1.08)

        return (subtitleRect, wrapped, rightBlockRect)
    }

    private func playbackTimingLine() -> String {
        let currentSeconds = max(0, sampler.previewPlayer?.currentTime().seconds ?? 0)
        let durationSeconds = sampler.previewPlayer?.currentItem?.duration.seconds ?? 0
        let hasDuration = durationSeconds.isFinite && durationSeconds > 0
        let totalString = hasDuration ? formatPlaybackTime(durationSeconds) : "--:--"
        return "\(formatPlaybackTime(currentSeconds)) / \(totalString)"
    }

    private func formatPlaybackTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private func shouldHideDot(at c: CGPoint, rect: CGRect?, half: CGFloat) -> Bool {
        guard let r = rect else { return false }
        let hideRadius = max(0, half - 2)
        
        // Fast AABB intersection check to bypass heavy calculations for distant dots
        if c.x + hideRadius <= r.minX || c.x - hideRadius >= r.maxX ||
           c.y + hideRadius <= r.minY || c.y - hideRadius >= r.maxY {
            return false
        }
        
        let closestX = max(r.minX, min(c.x, r.maxX))
        let closestY = max(r.minY, min(c.y, r.maxY))
        let dx = c.x - closestX
        let dy = c.y - closestY
        return dx * dx + dy * dy < hideRadius * hideRadius
    }

    /// 특정 위치의 도트 색.
    private func dotColor(
        row: Int, col: Int, rows: Int, cols: Int,
        layout: DotGridLayout,
        effect: VideoSampler.OverlayEffect,
        hasOverlay: Bool, isBlinkOn: Bool,
        placeholderColor: Color
    ) -> Color {
        // 오버레이가 켜져 있고 깜빡임 주기라면, 플레이스홀더 여부와 상관없이 오버레이 색상을 우선 반환.
        if hasOverlay && isBlinkOn &&
            isOverlayDot(effect: effect, row: row, col: col, layout: layout) {
            let pause = sampler.overlayIsAlert || !sampler.isPlaying
            return pause ? accentColor : indicatorColorPlay
        }
        
        if isPlaceholder { return placeholderColor }
        
        if row < rows, col < cols {
            return Color(cgColor: sampler.dotColors[row][col])
        }
        return placeholderColor
    }

    /// 주변 도트 RGB 평균 + 모드 기반 기반색 블렌딩. (35% 흰/검 + 30% 채도 강화 평균)
    /// 주변 도트 색상을 기반으로 자막 색을 결정.
    /// chroma boost 4배로 채도 극대화 후, 가독성을 위해 흰/검을 최소한으로 혼합.
    ///   brightMode=true  (어두운 배경) → 흰색 +0.2 가산 (텍스트 밝기 확보)
    ///   brightMode=false (밝은 배경)  → 검은색 −0.06 감산
    /// 반환 Color의 alpha는 1.0 — 글자 자체는 완전히 불투명.
    private func adaptiveColor(sR: Double, sG: Double, sB: Double, n: Int, brightMode: Bool) -> Color {
        guard n > 0 else { return brightMode ? .white : .black }
        let r = sR / Double(n), g = sG / Double(n), b = sB / Double(n)
        // Rec.709 luminance를 축으로 chroma를 4배로 확장 → 색감 극대화
        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let boost = 4.0
        let br = max(0.0, min(1.0, lum + (r - lum) * boost))
        let bg = max(0.0, min(1.0, lum + (g - lum) * boost))
        let bb = max(0.0, min(1.0, lum + (b - lum) * boost))
        if brightMode {
            // 어두운 배경: 흰색 0.2 혼합 → 텍스트가 배경 위로 부각
            return Color(
                red:   min(1.0, br * 0.6 + 0.2),
                green: min(1.0, bg * 0.6 + 0.2),
                blue:  min(1.0, bb * 0.6 + 0.2)
            )
        } else {
            // 밝은 배경: 검은색 0.06 혼합 → 텍스트가 어둡게 대비
            return Color(
                red:   max(0.0, br * 0.6 - 0.06),
                green: max(0.0, bg * 0.6 - 0.06),
                blue:  max(0.0, bb * 0.6 - 0.06)
            )
        }
    }

    /// peek 자막 배경 캡슐 색면. (유채색 유지가 목표)
    /// - 색상(hue)은 자막 뒤 장면색에서 가져오고, 장면이 무채색이면 accent 색으로 폴백 →
    ///   흰/검 글씨처럼 글씨가 무채색이어도 색면은 항상 유채색이 된다.
    /// - 검정/흰색으로 섞지 않고 HSB에서 채도(S)는 최대로 둔 채 밝기(V)만(또는 V=1 고정 후 S만)
    ///   조정해, "대비를 만족하는 가장 선명한 색"을 고른다.
    /// - 캡슐이 반투명이라 뒤 영상이 비치므로 "영상이 글씨색으로 비치는 최악의 경우"
    ///   (= α·배경 + (1−α)·글씨)까지 가정해 대비비 ≥ 3:1(WCAG 2.0 AA 큰 텍스트)을 확보한다.
    private func subtitleBackdropColor(from textColor: Color, scene sceneColor: Color?) -> Color {
        let ns = NSColor(textColor).usingColorSpace(.sRGB) ?? NSColor(textColor)
        let tr = Double(ns.redComponent), tg = Double(ns.greenComponent), tb = Double(ns.blueComponent)
        let target = 3.0            // WCAG 2.0 AA (큰 텍스트) 3:1
        let baseAlpha = 0.55        // 기본 반투명도

        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ c: (Double, Double, Double)) -> Double {
            0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
        }

        // Adaptive OFF: 글씨가 고정 흰/검이므로 색면도 그 반대(검/흰)로 고정.
        // 아래 hue-추종 로직(유채색 색면 생성)은 건너뛴다.
        if !adaptiveSubtitleColor {
            let lText = luminance((tr, tg, tb))
            let textIsBright = lText > 0.5
            let opposite: (Double, Double, Double) = textIsBright ? (0, 0, 0) : (1, 1, 1)
            func contrastWorstMono(_ alpha: Double) -> Double {
                let eff = (alpha * opposite.0 + (1 - alpha) * tr,
                           alpha * opposite.1 + (1 - alpha) * tg,
                           alpha * opposite.2 + (1 - alpha) * tb)
                let lBg = luminance(eff)
                let hi = Swift.max(lText, lBg), lo = Swift.min(lText, lBg)
                return (hi + 0.05) / (lo + 0.05)
            }
            if contrastWorstMono(baseAlpha) >= target {
                return rgba(opposite, baseAlpha)
            }
            var lo = baseAlpha, hi = 1.0
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                if contrastWorstMono(mid) >= target { hi = mid } else { lo = mid }
            }
            return rgba(opposite, hi)
        }
        func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
            if s <= 0 { return (v, v, v) }
            let h6 = (h - floor(h)) * 6
            let i = floor(h6), f = h6 - i
            let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
            switch Int(i) % 6 {
            case 0:  return (v, t, p)
            case 1:  return (q, v, p)
            case 2:  return (p, v, t)
            case 3:  return (p, q, v)
            case 4:  return (t, p, v)
            default: return (v, p, q)
            }
        }
        let lText = luminance((tr, tg, tb))
        // base 색면을 α로 합성하되, 뒤 영상이 글씨색이라는 최악 가정으로 유효색을 만든다.
        func contrastWorst(_ b: (Double, Double, Double), _ alpha: Double) -> Double {
            let eff = (alpha * b.0 + (1 - alpha) * tr,
                       alpha * b.1 + (1 - alpha) * tg,
                       alpha * b.2 + (1 - alpha) * tb)
            let lBg = luminance(eff)
            let hi = Swift.max(lText, lBg), lo = Swift.min(lText, lBg)
            return (hi + 0.05) / (lo + 0.05)
        }

        // 색상(hue) 소스 우선순위:
        //  1) 폰트색이 유채색(=adaptive on)이면 그 hue → 색면이 폰트 색 변화와 실시간 동기.
        //  2) 폰트가 무채색(흰/검, adaptive off)이면 장면색 hue.
        //  3) 둘 다 무채색이면 accent 색.
        // 폰트색은 adaptiveColor 가 채도를 부스트한 값이라 장면을 그대로 추종하므로,
        // 이를 기준으로 삼아야 폰트와 배경면이 같은 타이밍에 함께 바뀐다.
        func hue(of color: Color?) -> (h: Double, s: Double)? {
            guard let color, let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
            return (Double(c.hueComponent), Double(c.saturationComponent))
        }
        let textHue = hue(of: textColor)
        let sceneHueV = hue(of: sceneColor)
        let pickedHue: Double
        if let th = textHue, th.s > 0.15 {
            pickedHue = th.h
        } else if let sh = sceneHueV, sh.s > 0.15 {
            pickedHue = sh.h
        } else {
            pickedHue = hue(of: accentColor)?.h ?? 0
        }

        // 어두운 글씨면 밝은 색면, 밝은 글씨면 어두운 색면 쪽이 대비를 더 키운다.
        let darkDirection = (lText + 0.05) / 0.05 >= 1.05 / (lText + 0.05)

        // 가장 선명한(채도 최대) 색을 유지하면서 대비를 맞춘다.
        //  - 밝은 글씨(어두운 색면): S=1 고정, 대비를 만족하는 "가장 밝은(=가장 선명한) V" 선택.
        //  - 어두운 글씨(밝은 색면): V=1 고정, 대비를 만족하는 "가장 채도 높은 S" 선택.
        let satScale = 0.7          // 채도 = 최대치의 70% (과채도 완화)
        let extreme = darkDirection ? hsvToRgb(pickedHue, satScale, 0)   // 검정 (V=0)
                                    : hsvToRgb(pickedHue, 0, 1)          // 흰색
        if contrastWorst(extreme, baseAlpha) >= target {
            var lo = 0.0, hi = 1.0
            for _ in 0..<18 {
                let mid = (lo + hi) / 2
                let candidate = darkDirection ? hsvToRgb(pickedHue, satScale, mid)
                                              : hsvToRgb(pickedHue, mid, 1)
                // darkDirection: V↑ → 밝아져 대비↓ → 만족하면 더 밝게(lo=mid)로 가장 선명한 V 탐색.
                // lightDirection: S↑ → 진해져 대비↓ → 만족하면 더 진하게(lo=mid)로 가장 선명한 S 탐색.
                if contrastWorst(candidate, baseAlpha) >= target { lo = mid } else { hi = mid }
            }
            // darkDirection: S 는 satScale(=70%) 고정. lightDirection: 찾은 최대 S 의 70%
            // (채도를 줄이면 흰색 쪽이라 대비는 오히려 늘어 안전).
            let base = darkDirection ? hsvToRgb(pickedHue, satScale, lo)
                                     : hsvToRgb(pickedHue, lo * satScale, 1)
            return rgba(base, baseAlpha)
        }

        // 반투명만으론 부족한 중간톤 글씨 → 극단색(검정/흰)으로 두고 불투명도만 최소한 올린다.
        var lo = baseAlpha, hi = 1.0
        for _ in 0..<16 {
            let mid = (lo + hi) / 2
            if contrastWorst(extreme, mid) >= target { hi = mid } else { lo = mid }
        }
        return rgba(extreme, hi)
    }

    private func rgba(_ c: (Double, Double, Double), _ a: Double) -> Color {
        Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: a)
    }
}

// MARK: - Content View

struct ContentView: View {
    private static let playbackPositionsKey = "24dost.playbackPositions.v1"

    @StateObject private var sampler = VideoSampler()
    @EnvironmentObject private var recents: RecentsStore
    @Environment(\.openWindow) private var openWindow
    @State private var hostWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var magnifyMonitor: Any?
    @State private var cursorHider = CursorAutoHider()
    @State private var isFullscreen = false
    @State private var isEditingURL = false
    @State private var isShowingPlaybackInfo = false
    @State private var urlBuffer = ""
    /// 같은 폴더에서 자동 검출된 자막 파일. 값이 있으면 "SUBTITLE FOUND" 프롬프트 활성.
    /// 우선순위: URL 편집 > 자막 프롬프트 > 그밖의 것.
    @State private var subtitlePromptURL: URL? = nil
    /// 다른 언어로 만들어 둔 자막이 있을 때의 프롬프트. 생성은 답할 때까지 멈춘다.
    @State private var languagePrompt: (source: String, target: String)? = nil
    /// ⌘X 삭제 확인 대기 중. 되돌릴 수 없으므로 반드시 한 번 묻는다.
    @State private var mediaDataDeletePrompt = false

    /// 파일별로 마지막에 쓴 인식 언어. 인식 언어는 본래 **영상의 속성**인데 설정은
    /// 앱 전역이라, 언어가 다른 영상을 번갈아 보면 열 때마다 물어보게 된다.
    /// 영상마다 기억해 두고 열 때 맞춰 주면 그 질문이 사라진다.
    /// 설정창의 항목은 "기록이 없는 새 영상의 기본값" 성격이 된다.
    @AppStorage("24dost.subtitleSourceLanguages.v1") private var sourceLanguagesData: String = ""

    private var rememberedSourceLanguages: [String: String] {
        get {
            guard let data = sourceLanguagesData.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return map
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue),
               let encoded = String(data: data, encoding: .utf8) {
                sourceLanguagesData = encoded
            }
        }
    }

    /// 다른 언어 캐시를 두고 물어볼 상황인지.
    ///
    /// **이 영상에 대해 이미 언어를 고른 적이 있으면 묻지 않는다.** 안 그러면
    /// 설정에서 방금 일본어로 바꾼 직후에 "USE ENGLISH?" 가 떠서, 방금 내린 결정을
    /// 되묻는 꼴이 된다. 프롬프트는 "아직 아무 선택도 안 한 영상"에서만 의미가 있다.
    private var shouldAskAboutOtherLanguage: Bool {
        guard let key = currentPlaybackPositionKey else { return true }
        return rememberedSourceLanguages[key] == nil
    }

    /// 직전에 언어를 맞춰 준 영상. 같은 영상 안에서 사용자가 언어를 바꾼 것과
    /// 영상이 바뀐 것을 구분하는 데 쓴다.
    @State private var lastSyncedMediaKey: String? = nil

    /// 영상 키와 인식 언어를 하나로 묶은 값. 둘 중 하나만 바뀌어도 동기화가 돈다.
    private var sourceLanguageSyncSignature: String {
        "\(currentPlaybackPositionKey ?? "")|\(subtitleSourceLanguage)"
    }

    /// 영상이 바뀌었으면 기억해 둔 언어로 맞추고, 언어가 바뀌었으면 지금 영상에 기록한다.
    /// 한 곳에서 처리하는 이유는 뷰 체인에 onChange 를 더 붙이면 타입 체커가 터지기 때문.
    private func syncSourceLanguageWithMedia() {
        guard let key = currentPlaybackPositionKey else { return }

        // 영상이 바뀐 경우: 기억해 둔 게 있으면 그 언어로 맞춘다.
        // **기억이 없으면 아무것도 하지 않는다.** 여기서 현재 언어를 기록해 버리면
        // 사용자가 고른 적 없는 값이 그 영상에 굳어, 잘못된 설정으로 한 번 열었을 때
        // 다음부터 프롬프트조차 안 뜨게 된다. 기록은 "사용자가 이 영상에 대해 골랐다"는
        // 뜻이어야 한다.
        if lastSyncedMediaKey != key {
            lastSyncedMediaKey = key
            if let remembered = rememberedSourceLanguages[key],
               remembered != subtitleSourceLanguage,
               SubtitleDefaults.normalizedSourceLanguage(remembered) == remembered {
                subtitleSourceLanguage = remembered
            }
            return
        }

        // 같은 영상을 보는 중에 언어가 바뀌었다 = 사용자가 고른 것. 기록한다.
        rememberSourceLanguage(subtitleSourceLanguage)
    }

    private func rememberSourceLanguage(_ language: String) {
        guard let key = currentPlaybackPositionKey else { return }
        var map = rememberedSourceLanguages
        guard map[key] != language else { return }
        map[key] = language
        rememberedSourceLanguages = map
    }

    /// 프롬프트가 떠 있는지. 두 종류가 같은 자리를 쓴다.
    private var isPromptActive: Bool {
        subtitlePromptURL != nil || languagePrompt != nil || mediaDataDeletePrompt
    }

    private var promptConfirmLabel: String { mediaDataDeletePrompt ? "DELETE" : "USE" }

    private var promptMessage: String {
        if mediaDataDeletePrompt { return "DELETE DATA?" }
        if let p = languagePrompt {
            // "SUBTITLE IN JAPANESE" 는 자막 글자가 일본어라는 뜻으로 읽힌다. 실제로는
            // 자막은 한국어이고 **인식에 쓴 언어**가 일본어다. 질문 형태로 두면
            // USE/X 가 무엇에 대한 답인지 분명해진다.
            return "USE \(SubtitleDefaults.sourceLanguageLabel(p.source).uppercased())?"
        }
        return "SUBTITLE FOUND"
    }
    /// 우상단 도트를 누르고 있는 동안 true. onChanged가 연속 발생하므로 idempotent하게 갱신.
    @State private var isPeeking = false
    /// 피크 도트 한 칸의 화면 좌표(캔버스 기준, 좌상단 원점).
    @State private var peekDotRect: CGRect = .zero
    /// 롤아웃 감시용 마우스 이동 모니터.
    @State private var peekRolloutMonitor: Any? = nil
    /// 항상 위 (floating window level). 풀스크린 중에는 시각적으로 비활성.
    @State private var isAlwaysOnTop = false
    /// 풀스크린 재생 중 잠자기 방지 토큰. nil = 방지 비활성.
    @State private var sleepAssertion: NSObjectProtocol?
    /// 파일 다이얼로그로 연 파일 목록 (이름순 정렬). URL/드래그드롭은 단일 항목으로 세팅.
    @State private var playlist: [URL] = []
    @State private var playlistIndex: Int = 0

    // 런칭 시 GitHub 최신 릴리스 조회 결과. 새 버전이 있으면 대기 화면
    // 플레이스홀더("24Dost")가 업데이트 표기로 바뀐다.
    @State private var updateAvailableVersion: String? = nil
    @AppStorage("loopMultiFilePlayback") private var loopMultiFilePlayback = false
    @AppStorage("tapToPeek") private var tapToPeek = false
    @AppStorage("preventFullscreenDisplaySleep") private var preventFullscreenDisplaySleep = false
    @AppStorage("rememberPlaybackPosition") private var rememberPlaybackPosition = false
    @AppStorage("autoResizeWindowToVideo") private var autoResizeWindowToVideo = true
    @AppStorage("adaptiveSubtitleColor") private var adaptiveSubtitleColor = true
    @AppStorage(DotShape.storageKey) private var dotShapeRaw = DotShape.defaultChoice.rawValue
    // 자동 생성 자막 설정 — 값이 바뀌면 generator 에 그대로 밀어 넣는다.
    @AppStorage(SubtitleDefaults.autoGenerate)     private var autoGenerateSubtitles = false
    @AppStorage(SubtitleDefaults.sourceLanguage)   private var subtitleSourceLanguage = SubtitleDefaults.defaultSourceLanguage
    @AppStorage(SubtitleDefaults.targetLanguage)   private var subtitleTargetLanguage = SubtitleDefaults.defaultTarget
    @AppStorage(SubtitleDefaults.backend)          private var subtitleBackendRaw = TranslationBackend.apple.rawValue
    @AppStorage(SubtitleDefaults.claudeModel)      private var claudeModel = SubtitleDefaults.defaultClaudeModel
    @AppStorage(SubtitleDefaults.fastResponseSeconds) private var fastResponseSeconds = SubtitleDefaults.defaultFastResponse
    @AppStorage("subtitleBackdropWhilePeeking") private var subtitleBackdropWhilePeeking = false
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue
    @AppStorage("24dost.backgroundStyle") private var backgroundStyleRaw: Int = BackgroundStyle.blur.rawValue
    /// 풀스크린 전용 배경 모드. 일반 모드와 독립적으로 영속.
    @AppStorage("24dost.fullscreenBackgroundStyle") private var fullscreenBackgroundStyleRaw: Int = FullscreenBackgroundStyle.black.rawValue
    @AppStorage(Self.playbackPositionsKey) private var playbackPositionsData: String = ""
    @State private var backgroundStyleLabel: String? = nil
    @State private var backgroundStyleLabelTask: Task<Void, Never>? = nil
    /// 대기 상태에서 파일 드래그 호버 중일 때 true. 악센트 테두리 시각 피드백용.
    @State private var isDropTargeted = false

    /// 파일 열기 시 창 자동 리사이즈 대기 플래그.
    /// open 시점에는 videoSize 가 아직 0x0 이므로, open 경로에서 true 로 세워두고
    /// sampler.videoSize onChange 에서 실제 크기 확보 후 1회 실행, 즉시 clear.
    @State private var pendingAutoResize: Bool = false
    
    @State private var dragAccumulator: CGSize = .zero
    /// 캔버스 드래그가 무슨 동작인지. 제스처가 시작될 때 정해 끝날 때까지 유지한다.
    private enum CanvasDragMode { case dotSettings, panContent }
    @State private var canvasDragMode: CanvasDragMode?
    @State private var currentPlaybackPositionKey: String?
    @State private var restorePlaybackPositionTask: Task<Void, Never>?

    // 마지막 재생 기억: 대기상태에서 Space 누르면 이걸 재로드 (처음부터 재생).
    // 이미지는 저장 대상이 아님. 내부 임시 스트림도 저장 안 함.
    //   kind = "file"  → value = 로컬 파일 경로 (샌드박스 OFF라 경로로 충분)
    //   kind = "url"   → value = 사용자가 입력한 원본 URL 문자열
    @AppStorage("24dost.lastMedia.kind")  private var lastMediaKind: String = ""
    @AppStorage("24dost.lastMedia.value") private var lastMediaValue: String = ""
    @AppStorage("24dost.lastMedia.paths") private var lastMediaPathsData: String = ""
    @AppStorage("24dost.lastMedia.title") private var lastMediaTitle: String = ""

    /// 자막 설정 중 하나라도 바뀌면 값이 달라지는 문자열. onChange 트리거용.
    private var subtitleSettingsSignature: String {
        [String(autoGenerateSubtitles), subtitleSourceLanguage, subtitleTargetLanguage,
         subtitleBackendRaw, claudeModel, String(fastResponseSeconds)].joined(separator: "|")
    }

    /// 자막 설정이 바뀌었을 때. 결과물에 영향을 주는 항목(엔진·언어·모델)이 바뀌었다면
    /// 옛 설정으로 만든 큐를 버리고 새 조합의 캐시를 읽어야 한다. 안 그러면 커버리지가
    /// "다 만듦"이라 재생성도 안 되고 옛 자막이 계속 보인다 — 엔진을 Claude 로 바꿨다가
    /// 되돌렸을 때 번역 안 된 원문이 그대로 굳던 원인이다.
    /// look-ahead 는 결과물과 무관하므로 서명의 마지막 칸으로 두고 비교에서 뺀다.
    private func handleSubtitleSettingsChange(from oldValue: String, to newValue: String) {
        applySubtitleSettings()
        guard outputAffectingPart(of: oldValue) != outputAffectingPart(of: newValue) else { return }
        sampler.reloadGeneratorForSettingsChange()
    }

    private func outputAffectingPart(of signature: String) -> String {
        signature.split(separator: "|").dropLast().joined(separator: "|")
    }

    private func applySubtitleSettings() {
        sampler.autoGenerateSubtitles = autoGenerateSubtitles
        let g = sampler.generator
        let src = SubtitleDefaults.normalizedSourceLanguage(subtitleSourceLanguage)
        if src != subtitleSourceLanguage { subtitleSourceLanguage = src }   // 옛 값 정리
        g.sourceLocale = Locale(identifier: src)
        g.targetLanguage = Locale.Language(identifier: subtitleTargetLanguage)
        g.backend = TranslationBackend(rawValue: subtitleBackendRaw) ?? .apple
        g.claudeModel = claudeModel
        g.fastResponseRange = fastResponseSeconds
    }

    /// ⇧⌘E — 생성된 자막을 영상 옆에 .srt 로 저장.
    private func exportGeneratedSubtitles() {
        if let url = sampler.generator.exportSRT() {
            showTransientAccentLabel("EXPORTED \(url.lastPathComponent)")
        } else {
            showTransientAccentLabel("NOTHING TO EXPORT")
        }
    }

    private var backgroundStyle: BackgroundStyle {
        BackgroundStyle(rawValue: backgroundStyleRaw) ?? .blur
    }

    private var fullscreenBackgroundStyle: FullscreenBackgroundStyle {
        FullscreenBackgroundStyle(rawValue: fullscreenBackgroundStyleRaw) ?? .black
    }

    private var accentColor: Color {
        AppAccentColor.choice(for: accentColorRaw).color
    }

    private var dotShape: DotShape { DotShape.choice(for: dotShapeRaw) }

    private var urlLoadErrorPresented: Binding<Bool> {
        Binding(
            get: { sampler.urlLoadError != nil },
            set: { newValue in
                if !newValue {
                    sampler.urlLoadError = nil
                }
            }
        )
    }

    private var playbackPositions: [String: Double] {
        get {
            guard let data = playbackPositionsData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: Double].self, from: data) else {
                return [:]
            }
            return decoded
        }
        nonmutating set {
            if newValue.isEmpty {
                playbackPositionsData = ""
            } else if let data = try? JSONEncoder().encode(newValue),
                      let encoded = String(data: data, encoding: .utf8) {
                playbackPositionsData = encoded
            } else {
                playbackPositionsData = ""
            }
        }
    }

    /// 피크 가능 조건: 실제 영상이 로드되어 있고, URL 편집 중이 아니며, 로딩 중이 아님.
    /// 정적 이미지는 제외(재생 의미 없음).
    /// 좌상단 도트로 종료할 수 있는 상태.
    ///
    /// **실제 도트가 그려질 때(= 도트 모드/피크 모드)만**이다. 대기 화면과 로딩 중에는
    /// 격자가 영상이 아니라 제외하고, 무언가 묻고 있을 때(URL 입력·재생 정보·프롬프트)도
    /// 뺀다 — 보이지 않는 버튼이라 그런 상태에서 눌리면 실수로 꺼지는 것과 구별되지 않는다.
    private var canQuitByCornerDot: Bool {
        !sampler.dotColors.isEmpty
            && !sampler.isLoadingMedia
            && !isEditingURL
            && !isShowingPlaybackInfo
            && !isPromptActive
    }

    private var canPeek: Bool {
        sampler.previewPlayer != nil
            && sampler.videoSize != .zero
            && !sampler.isLoadingMedia
            && !sampler.isStaticContent
            && !sampler.isAudioMode
            && !isEditingURL
            && !isShowingPlaybackInfo
    }

    /// 대기 상태: 앱 기동 후 아무것도 로드되지 않았거나 cleanup된 직후.
    /// 이미지 로드 중이나 영상 로드 중/완료 상태는 제외.
    private var isStandby: Bool {
        sampler.previewPlayer == nil
            && !sampler.isStaticContent
            && !sampler.isLoadingMedia
    }

    private var currentPlaybackInfoTitle: String? {
        if !playlist.isEmpty, playlist.indices.contains(playlistIndex) {
            return playlist[playlistIndex].lastPathComponent
        }
        switch lastMediaKind {
        case "file":
            return URL(fileURLWithPath: lastMediaValue).lastPathComponent
        case "fileGroup":
            guard let data = lastMediaPathsData.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data),
                  let first = paths.first else { return nil }
            return URL(fileURLWithPath: first).lastPathComponent
        case "url":
            guard !lastMediaValue.isEmpty else { return nil }
            let normalizedTitle = lastMediaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedTitle.isEmpty {
                return normalizedTitle
            }
            var text = lastMediaValue
            if text.hasPrefix("https://") { text.removeFirst(8) }
            else if text.hasPrefix("http://") { text.removeFirst(7) }
            return "> " + text
        default:
            return nil
        }
    }

    private var hasPlaybackInfoContent: Bool {
        currentPlaybackInfoTitle?.isEmpty == false && sampler.previewPlayer != nil
    }

    // MARK: 마지막 재생 기억

    /// 사용자 직접 선택(openFile/URL 커밋) 시에만 호출. 이미지는 제외.
    /// Recents 에도 기록(LRU, 최대 10). lastMedia 는 대기 Space 복원용으로 별도 유지.
    private func rememberLastFile(_ url: URL, addToRecents: Bool = true) {
        lastMediaKind = "file"
        lastMediaValue = url.path
        lastMediaPathsData = ""
        lastMediaTitle = ""
        if addToRecents { recents.addFile(url) }
    }
    private func rememberLastFileGroup(_ urls: [URL], addToRecents: Bool = true) {
        let paths = urls.map(\.path)
        guard let first = paths.first else { return }
        lastMediaKind = "fileGroup"
        lastMediaValue = first
        lastMediaTitle = ""
        if let data = try? JSONEncoder().encode(paths),
           let encoded = String(data: data, encoding: .utf8) {
            lastMediaPathsData = encoded
        } else {
            lastMediaPathsData = ""
        }
        if addToRecents { recents.addFileGroup(urls) }
    }
    private func rememberLastURL(_ urlString: String, title: String? = nil) {
        lastMediaKind = "url"
        lastMediaValue = urlString
        lastMediaPathsData = ""
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastMediaTitle = normalizedTitle
        recents.addURL(urlString, title: normalizedTitle.isEmpty ? nil : normalizedTitle)
    }

    private func prepareForURLPlayback() {
        playlist = []
        playlistIndex = 0
    }

    /// 대기 상태 + 저장값 존재하면 복원. 아니면 false.
    /// 복원 실패(파일 이동/삭제, URL 오류)는 sampler 내부 urlLoadError 경유로 알림 —
    /// 저장값은 건드리지 않음(일시적 오프라인 가능성).
    @discardableResult
    private func resumeLastMedia() -> Bool {
        guard !lastMediaValue.isEmpty else { return false }
        persistCurrentPlaybackPositionIfNeeded()
        endPeekIfNeeded()
        switch lastMediaKind {
        case "file":
            let url = URL(fileURLWithPath: lastMediaValue)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            playlist = [url]
            playlistIndex = 0
            // openPlaylistItem 과 동일하게 직전 파일 복원 시에도 사이드카 자막 검출.
            subtitlePromptURL = findSiblingSubtitle(for: url)
            let key = playbackPositionKey(forFileURL: url)
            currentPlaybackPositionKey = key
            pendingAutoResize = true
            sampler.open(url: url)
            preloadSiblingSubtitle()
            restorePlaybackPositionIfNeeded(for: key)
            return true
        case "fileGroup":
            guard let data = lastMediaPathsData.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else { return false }
            let urls = paths.map { URL(fileURLWithPath: $0) }
            guard let first = urls.first, FileManager.default.fileExists(atPath: first.path) else { return false }
            openFiles(urls, recordRecent: false, rememberAsLast: false)
            return true
        case "url":
            prepareForURLPlayback()
            let key = playbackPositionKey(forURLString: lastMediaValue)
            currentPlaybackPositionKey = key
            pendingAutoResize = true
            sampler.openURL(lastMediaValue)
            restorePlaybackPositionIfNeeded(for: key)
            return true
        default:
            return false
        }
    }

    private var rootCanvas: some View {
        ZStack {
            WindowDragArea(
                onSingleClick: {
                    // peek 중에도 탭 재생/일시정지는 허용 (전체화면/일반 공통).
                    if isEditingURL || isShowingPlaybackInfo || isPromptActive { return }
                    if isStandby {
                        _ = resumeLastMedia()
                    } else {
                        sampler.togglePlayPause()
                    }
                },
                onDoubleClick: {
                    if isEditingURL || isShowingPlaybackInfo || isPromptActive || isPeeking { return }
                    toggleMainAppFullscreen()
                },
                onRightClick: { point in
                    // 피크 중에도 허용 — 세로줄 클릭 탐색은 실제 영상을 보면서 쓸 때 오히려 유용하다.
                    // (우상단 도트는 피크 토글이라 아래에서 따로 제외한다.)
                    if isEditingURL || isShowingPlaybackInfo || isPromptActive { return }
                    if isStandby { return }
                    if sampler.isLoadingMedia || sampler.isStaticContent { return }
                    
                    let size = sampler.currentDisplaySize
                    let grid = sampler.gridSize
                    // 현재 재생 그리드의 도트 데이터
                    guard let firstRow = sampler.dotColors.first else { return }
                    let cols = firstRow.count
                    guard cols > 2 else { return }
                    let rows = sampler.dotColors.count
                    guard rows > 2 else { return }
                    
                    let visibleCols = cols - 2
                    let offsetX = (size.width - CGFloat(cols) * grid) / 2
                    let offsetY = (size.height - CGFloat(rows) * grid) / 2
                    
                    let clickedColIdx = Int((point.x - offsetX) / grid)
                    let clickedRowIdx = Int((point.y - offsetY) / grid)
                    
                    if clickedColIdx >= 1 && clickedColIdx <= visibleCols {
                        // 피크 도트 자리는 점프시키지 않는다. 위치를 (1, cols-2) 로 가정하면
                        // 안 된다 — 도트 간격을 30 아래로 좁히면 모서리 마스크가 켜지면서
                        // 실제 앵커가 안쪽으로 밀린다. 렌더와 같은 계산을 그대로 쓴다.
                        let layout = makeDotGridLayout(
                            size: size, grid: grid, dotDiameter: sampler.dotDiameter,
                            rowsOverride: rows, colsOverride: cols, isFullscreen: isFullscreen
                        )
                        if let anchor = layout.findTopRightAnchor(),
                           clickedColIdx == anchor.col, clickedRowIdx == anchor.row {
                            return
                        }
                        // 1부터 visibleCols 까지의 값을 해당 컬럼의 정중앙 시간(0.5 오프셋)으로 매핑하여 깜빡임과 인덱싱 일치
                        let fraction = (Double(clickedColIdx) - 0.5) / Double(visibleCols)
                        sampler.seek(toFraction: fraction)
                    }
                },
                onScrollUp: {
                    if isEditingURL || isShowingPlaybackInfo || isPromptActive { return }
                    sampler.volumeUp()
                },
                onScrollDown: {
                    if isEditingURL || isShowingPlaybackInfo || isPromptActive { return }
                    sampler.volumeDown()
                },
                isContentZoomed: sampler.isContentZoomed
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if sampler.isLoadingMedia {
                GeometryReader { geo in
                    // 가로 가시 도트 개수와 같은 패리티(짝수=4, 홀수=3)로
                    // 인디케이터를 창 중앙축에 자연스럽게 정렬.
                    let g = sampler.gridSize
                    let visibleCols = max(1, Int(geo.size.width / g) - 2)
                    let count = visibleCols.isMultiple(of: 2) ? 4 : 3
                    RemuxingIndicator(
                        dotDiameter: sampler.dotDiameter,
                        gap: g - sampler.dotDiameter,
                        count: count,
                        accentColor: accentColor,
                        shape: dotShape
                    )
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
            }

            // 피크 영상: DotsOverlayView 뒤에 놓여, 도트가 스킵될 때 실제 영상이 드러남.
            // 도트 그리드의 visible 영역에 정확히 맞추고 앱 모서리와 동심원 라운딩.
            if isPeeking, let player = sampler.previewPlayer {
                GeometryReader { geo in
                    peekVideoLayer(size: geo.size, player: player)
                }
                .allowsHitTesting(false)
            }

            DotsOverlayView(
                sampler: sampler,
                isFullscreen: isFullscreen,
                backgroundStyle: backgroundStyle,
                fullscreenBackgroundStyle: fullscreenBackgroundStyle,
                adaptiveSubtitleColor: adaptiveSubtitleColor,
                dotShape: dotShape,
                subtitleBackdropWhilePeeking: subtitleBackdropWhilePeeking,
                backgroundStyleLabel: backgroundStyleLabel,
                isEditingURL: isEditingURL,
                urlBuffer: urlBuffer,
                subtitlePromptActive: isPromptActive,
                promptMessage: promptMessage,
                promptConfirmLabel: promptConfirmLabel,
                playbackInfoTitle: currentPlaybackInfoTitle,
                playbackInfoActive: isShowingPlaybackInfo,
                isPeeking: isPeeking,
                accentColor: accentColor,
                updateAvailableVersion: updateAvailableVersion
            )

            // URL 편집 모드: "CANCEL"/"X  GO" 클릭 히트박스 (투명).
            // Canvas 는 allowsHitTesting(false)라 텍스트만으론 눌리지 않음.
            if isEditingURL {
                GeometryReader { geo in
                    urlButtonOverlay(size: geo.size)
                }
            } else if isShowingPlaybackInfo {
                GeometryReader { geo in
                    playbackInfoButtonOverlay(size: geo.size)
                }
            } else if isPromptActive {
                // 프롬프트 "X  USE" 클릭 히트박스.
                GeometryReader { geo in
                    subtitlePromptButtonOverlay(size: geo.size)
                }
            }

            // 대기 화면 "Update »" 클릭 히트박스 (글자와 화살표 모두).
            if isStandby, updateAvailableVersion != nil {
                GeometryReader { geo in
                    updateArrowHitArea(size: geo.size)
                }
            }

            // 피크 히트박스: 우상단 visible 도트 1개 영역. 누르고 있는 동안 영상 노출.
            if canPeek {
                GeometryReader { geo in
                    peekHitArea(size: geo.size)
                }
            }

            // 종료 히트박스: 좌상단 visible 도트 1개 영역. 눌러서 앱 종료.
            // 우상단 피크 도트와 대칭인 숨은 조작 — 눈에 보이는 버튼은 없다.
            if canQuitByCornerDot {
                GeometryReader { geo in
                    quitHitArea(size: geo.size)
                }
            }

            // Always on Top 표시: 2px 여백 + 1px 악센트 테두리.
            // 앱 라운딩(32pt)과 동심원으로, 창 안쪽 2.5pt(= 2px gap + 0.5px 선 반폭) 위치에 렌더.
            if isAlwaysOnTop && !isFullscreen {
                // 창 CALayer 코너는 circular arc(기본값). style 지정 없이 동일하게 맞춤.
                // 선 중심 = 가장자리에서 2.5pt 안쪽 → 코너 반경 = 32 − 2.5 = 29.5pt.
                RoundedRectangle(cornerRadius: 29.5)
                    .stroke(accentColor, lineWidth: 1)
                    .padding(2.5)
                    .allowsHitTesting(false)
            }

            // Apple 번역 세션을 만들어 주는 보이지 않는 호스트.
            AppleTranslationHost(bridge: AppleTranslationBridge.shared)

            // 드롭 타겟 피드백: 드래그 호버 중일 때 1px 악센트 테두리 (대기/재생 모두).
            // Always on Top 표시와 동일한 기하(padding 2.5 / radius 29.5)로 겹쳐도 위화감 없음.
            if isDropTargeted && !isFullscreen {
                RoundedRectangle(cornerRadius: 29.5)
                    .stroke(accentColor, lineWidth: 1)
                    .padding(2.5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var interactiveCanvas: some View {
        rootCanvas
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if isFullscreen {
                fullscreenBackgroundStyle == .white ? Color.white : Color.black
            } else {
                ZStack {
                    if backgroundStyle.isGlass {
                        Color.clear.glassEffect(.clear, in: .rect(cornerRadius: 32))
                    } else {
                        Color.clear.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32))
                    }
                    if backgroundStyle.hasBlackOverlay {
                        Color.black.opacity(backgroundStyle.blackOverlayOpacity)
                            .clipShape(RoundedRectangle(cornerRadius: 31))
                            .padding(-1)
                    }
                }
            }
        }
        .ignoresSafeArea()
        // 파일 드롭: 대기/재생 상태 무관하게 수락. 재생 중 드롭은 현재 파일을 교체.
        // URL 편집 중이면 openFiles 진입 시 자동으로 편집 모드 취소.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            performDrop(providers: providers)
        }
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    // ⌘ 를 누른 채 시작했으면 확대해서 보고 있는 위치를 옮긴다.
                    // 판정은 제스처 시작 때 한 번만 — 끄는 도중 ⌘ 를 놓았다고 도트 크기가
                    // 변하기 시작하면 곤란하다. (DragGesture 값에는 수식 키가 없어서
                    // 현재 키 상태를 직접 읽는다.)
                    if canvasDragMode == nil {
                        canvasDragMode = (sampler.isContentZoomed
                                          && NSEvent.modifierFlags.contains(.command))
                            ? .panContent : .dotSettings
                    }
                    if canvasDragMode == .panContent {
                        sampler.panBy(dx: value.translation.width  - dragAccumulator.width,
                                      dy: value.translation.height - dragAccumulator.height)
                        dragAccumulator = value.translation
                        return
                    }

                    guard isFullscreen else { return }

                    let deltaX = value.translation.width - dragAccumulator.width
                    let deltaY = value.translation.height - dragAccumulator.height
                    
                    // X축: 좌우 간격 (A, D)
                    if deltaX > 15 {
                        sampler.increaseGap()
                        dragAccumulator.width = value.translation.width
                    } else if deltaX < -15 {
                        sampler.decreaseGap()
                        dragAccumulator.width = value.translation.width
                    }
                    
                    // Y축: 상하 크기 (W, S)
                    if deltaY > 15 { // 아래로 내리면 작아짐
                        sampler.decreaseDotSize()
                        dragAccumulator.height = value.translation.height
                    } else if deltaY < -15 { // 위로 올리면 커짐
                        sampler.increaseDotSize()
                        dragAccumulator.height = value.translation.height
                    }
                }
                .onEnded { _ in
                    dragAccumulator = .zero
                    canvasDragMode = nil
                }
        )
        .background(
            WindowAccessor { window in
                guard hostWindow !== window else { return }
                hostWindow = window
                if let delegate = NSApplication.shared.delegate as? AppDelegate {
                    window.delegate = delegate
                }
                AppDelegate.applyStyle(window)
                _ = AppDelegate.deliverPendingExternalMediaOpenRequestIfPossible()
            }
        )
    }

    private var configuredCanvas: some View {
        interactiveCanvas
        .onAppear {
            applySubtitleSettings()
            // 권한은 앱을 켤 때 한 번 받는다. 재생 도중 첫 자막을 만들려는 순간에
            // 물으면 흐름이 끊긴다. 이미 허용/거부가 정해져 있으면 시스템이 다시 묻지 않으므로
            // 매 실행 호출해도 실제 팝업은 최초 1회(그리고 앱이 새로 서명된 뒤)뿐이다.
            Task { await AppleSpeechTranscriber.requestAuthorizationIfNeeded() }
            installKeyMonitor()
            // 종료 정리를 앱 델리게이트에 건다. 아래 onDisappear 에도 같은 정리가 있지만
            // 그건 앱이 꺼질 때 도는 게 보장되지 않는다 — 이걸 걸지 않으면 ⌘Q·⌘W·좌상단
            // 도트 어느 쪽으로 꺼도 생성한 자막 캐시와 재생 위치를 잃는다.
            AppDelegate.willTerminateCleanup = {
                sampler.generator.flushCache()
                persistCurrentPlaybackPositionIfNeeded()
            }
            Task { updateAvailableVersion = await UpdateChecker.availableUpdateVersion() }
            DispatchQueue.main.async {
                if let hostWindow {
                    AppDelegate.applyStyle(hostWindow)
                    hostWindow.makeKeyAndOrderFront(nil)
                } else {
                    AppDelegate.applyStyleToCurrentWindowIfNeeded()
                }
                _ = AppDelegate.deliverPendingExternalMediaOpenRequestIfPossible()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let hostWindow {
                    AppDelegate.applyStyle(hostWindow)
                } else {
                    AppDelegate.applyStyleToCurrentWindowIfNeeded()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let hostWindow {
                    AppDelegate.applyStyle(hostWindow)
                } else {
                    AppDelegate.applyStyleToCurrentWindowIfNeeded()
                }
            }
        }
        .onDisappear {
            // 앱이 닫힐 때 아직 캐시에 안 쓴 생성 자막을 잃지 않도록 강제로 저장한다.
            sampler.generator.flushCache()
            persistCurrentPlaybackPositionIfNeeded()
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            if let m = magnifyMonitor { NSEvent.removeMonitor(m); magnifyMonitor = nil }
            cursorHider.stop()
            releaseSleepAssertion()
            restorePlaybackPositionTask?.cancel()
        }
        .onChange(of: isFullscreen)     { _, _ in
            updateSleepPrevention()
            // 줌 1.0 의 기준 화면이 모드마다 다르다(전체화면 fit / 창 fill). 배율을 들고
            // 넘어가면 같은 숫자가 다른 크기를 뜻해 화면이 튄다 — 양방향 모두 되돌린다.
            sampler.zoomToFit()
        }
        .onChange(of: sampler.isPlaying) { _, _ in updateSleepPrevention() }
        .onChange(of: sampler.isPlaying) { _, isPlaying in
            if !isPlaying {
                persistCurrentPlaybackPositionIfNeeded()
            }
        }
        .onChange(of: preventFullscreenDisplaySleep) { _, _ in updateSleepPrevention() }
        .onChange(of: tapToPeek) { _, enabled in
            if !enabled { endPeekIfNeeded() }
        }
        .onChange(of: sampler.videoSize) { _, newSize in
            // 오픈 경로에서 세운 플래그가 켜진 상태에서 실제 크기 확보되면 1회 실행.
            if pendingAutoResize && newSize.width > 0 && newSize.height > 0 {
                if autoResizeWindowToVideo {
                    autoResizeForVideo()
                }
                pendingAutoResize = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resizeToHalfVideoSize)) { _ in
            resizeWindowToVideo(scale: 0.5)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomWindowOut)) { _ in
            zoomWindow(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .zoomWindowIn)) { _ in
            zoomWindow(direction: +1)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullscreen = true
            sampler.isFullscreen = true
            cursorHider.start()
            sampler.backgroundDotAlpha = (fullscreenBackgroundStyle == .black) ? 0.10 : 0.40
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // 롤아웃 모드에서만 끝낸다. 그쪽은 "커서가 도트를 벗어나면 종료"인데 다른 앱으로
            // 넘어가면 마우스 이동 이벤트가 안 와서, 안 끝내면 peek 에 갇힌다.
            //
            // tap to peek 은 반대다. 한 번 눌러 켜고 다시 눌러 끄는 **명시적 토글**이라
            // 커서 위치에 의존하지 않는다. 여기서 같이 끝내면 다른 앱을 잠깐 보고 돌아왔을 때
            // 멋대로 도트로 돌아가 있다.
            guard !tapToPeek else { return }
            endPeekIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullscreen = false
            sampler.isFullscreen = false
            cursorHider.stop()
            // 전체화면을 나오면 피크도 끝낸다 — 도트로 돌아가며 멈춘다(peekEnd 가 항상 pause).
            // Esc 키가 아니라 여기에 거는 이유: Return·더블클릭·초록 버튼으로 나갈 때도
            // 같아야 한다. 키에만 걸면 나가는 경로마다 결과가 달라진다.
            endPeekIfNeeded()
            // 풀스크린 전에 항상 위가 켜져 있었다면 복원
            if isAlwaysOnTop { applyAlwaysOnTop(true) }
            sampler.backgroundDotAlpha = 0.40
        }
        .onChange(of: fullscreenBackgroundStyle) { _, newStyle in
            sampler.backgroundDotAlpha = (isFullscreen && newStyle == .black) ? 0.10 : 0.40
        }
        .modifier(MenuCommandObservers(
            onOpenFile:             openFile,
            onExternalOpenURLs:     handleExternalOpenURLs,
            onExternalOpenMediaURL: handleExternalOpenMediaURL,
            onOpenURLRequested:     handleOpenURLRequested,
            onOpenPlaybackInfoRequested: handleOpenPlaybackInfoRequested,
            onExportImage:          exportCurrentDotImage,
            onCycleBackgroundStyle: cycleBackgroundStyle,
            onToggleAlwaysOnTop:    handleToggleAlwaysOnTop,
            onPlaybackEnded:        advancePlaylist,
            onOpenRecent:           handleOpenRecentNotification
        ))
        .onReceive(sampler.generator.$otherLanguageCache) { pair in
            languagePrompt = shouldAskAboutOtherLanguage ? pair : nil
            if pair != nil && !shouldAskAboutOtherLanguage {
                // 물어볼 필요가 없으면 생성 잠금을 바로 푼다.
                sampler.generator.dismissOtherLanguagePrompt()
            }
        }
        .modifier(SourceLanguageSync(signature: sourceLanguageSyncSignature,
                                     onChange: syncSourceLanguageWithMedia))
        .onChange(of: subtitleSettingsSignature) { oldValue, newValue in
            handleSubtitleSettingsChange(from: oldValue, to: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearCurrentMediaDataRequested)) { _ in
            requestClearCurrentMediaData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSubtitleCacheRequested)) { _ in
            let n = sampler.clearAllSubtitleCaches()
            showTransientAccentLabel(n > 0 ? "CACHE CLEARED" : "NO CACHE")
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportSubtitleRequested)) { _ in
            exportGeneratedSubtitles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .regenerateSubtitleRequested)) { _ in
            sampler.generator.regenerate()
            showTransientAccentLabel("REGENERATING")
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetAppStateRequested)) { _ in
            handleResetAppStateRequested()
        }
    }

    var body: some View {
        configuredCanvas
        .alert("URL 재생 실패", isPresented: urlLoadErrorPresented) {
            Button("확인", role: .cancel) { sampler.urlLoadError = nil }
        } message: {
            Text(sampler.urlLoadError ?? "")
        }
    }

    // MARK: URL 편집 오버레이 / 커밋·취소

    /// 대기 화면 "Update »" 히트박스(글자+화살표). 클릭하면 설정 창 Software Update 섹션을 연다.
    @ViewBuilder
    private func updateArrowHitArea(size: CGSize) -> some View {
        if let rect = computeUpdateArrowGeometry(
            size: size, sampler: sampler, isFullscreen: isFullscreen
        ) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .onTapGesture { revealSoftwareUpdateSettings() }
                .position(x: rect.midX, y: rect.midY)
        }
    }

    /// 설정 창을 열고 Software Update 섹션으로 스크롤 + 업데이트 확인까지 트리거.
    private func revealSoftwareUpdateSettings() {
        openWindow(id: "settings-window")
        // 창이 새로 열리는 경우 뷰가 마운트될 시간을 준 뒤 알림 전송.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            NotificationCenter.default.post(name: .revealSoftwareUpdate, object: nil)
        }
    }

    @ViewBuilder
    private func urlButtonOverlay(size: CGSize) -> some View {
        let hasInput = !urlBuffer.isEmpty
        if let g = computeURLInputGeometry(
            size: size, sampler: sampler,
            isFullscreen: isFullscreen,
            rightText: hasInput ? "X  GO" : "CANCEL",
            twoButton: hasInput
        ) {
            ZStack(alignment: .topLeading) {
                // 취소 히트박스 — "CANCEL" 전체 또는 "X  GO"의 왼쪽 절반.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: g.cancelTapRect.width, height: g.cancelTapRect.height)
                    .onTapGesture { cancelURLEdit() }
                    .position(x: g.cancelTapRect.midX, y: g.cancelTapRect.midY)
                // 제출 히트박스 — "X  GO"의 오른쪽 절반 (입력 있을 때만).
                if let commit = g.commitTapRect {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: commit.width, height: commit.height)
                        .onTapGesture { commitURLEdit() }
                        .position(x: commit.midX, y: commit.midY)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    // MARK: 자막 자동 검출 프롬프트

    /// 새 영상 로드 직후 같은 폴더에서 동일 basename 의 자막 파일을 찾음.
    /// 우선순위 .srt > .smi. 이미지나 스트림에서는 nil.
    private func findSiblingSubtitle(for videoURL: URL) -> URL? {
        guard !VideoSampler.isImageFile(url: videoURL) else { return nil }
        let fm = FileManager.default
        let dir = videoURL.deletingLastPathComponent()
        let baseLower = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        var srtMatch: URL? = nil
        var smiMatch: URL? = nil
        for name in entries {
            let e = URL(fileURLWithPath: name)
            let nameBase = e.deletingPathExtension().lastPathComponent.lowercased()
            guard nameBase == baseLower else { continue }
            switch e.pathExtension.lowercased() {
            case "srt" where srtMatch == nil: srtMatch = dir.appendingPathComponent(name)
            case "smi" where smiMatch == nil: smiMatch = dir.appendingPathComponent(name)
            default: break
            }
        }
        return srtMatch ?? smiMatch
    }

    private func playbackPositionKey(forFileURL url: URL) -> String? {
        guard !VideoSampler.isImageFile(url: url) else { return nil }
        return "file:\(url.path)"
    }

    private func playbackPositionKey(forURLString value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "url:\(trimmed)"
    }

    private func clearStoredPlaybackPosition(for key: String?) {
        guard let key else { return }
        var positions = playbackPositions
        positions.removeValue(forKey: key)
        playbackPositions = positions
    }

    private func persistCurrentPlaybackPositionIfNeeded() {
        guard rememberPlaybackPosition, let key = currentPlaybackPositionKey else { return }
        guard let player = sampler.previewPlayer else {
            clearStoredPlaybackPosition(for: key)
            return
        }

        let current = player.currentTime().seconds
        guard current.isFinite, current >= 1 else {
            clearStoredPlaybackPosition(for: key)
            return
        }

        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0, current >= max(duration - 1, duration * 0.98) {
            clearStoredPlaybackPosition(for: key)
            return
        }

        var positions = playbackPositions
        positions[key] = current
        playbackPositions = positions
    }

    private func restorePlaybackPositionIfNeeded(for key: String?) {
        restorePlaybackPositionTask?.cancel()
        guard rememberPlaybackPosition,
              let key,
              let savedSeconds = playbackPositions[key],
              savedSeconds.isFinite,
              savedSeconds >= 1 else { return }

        restorePlaybackPositionTask = Task {
            for _ in 0..<30 {
                if Task.isCancelled { return }
                if sampler.previewPlayer?.currentItem != nil {
                    sampler.seek(toSeconds: savedSeconds)
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// 사용자가 USE 수락 → 자막 로드. 실패 시 기존 악센트 레이블로 알림.
    /// 같은 폴더에서 찾은 자막을 화면은 바꾸지 않고 미리 읽어 둔다.
    /// 프롬프트에서 X 를 눌러도 p 순환에 남아 있어야 하기 때문이다 —
    /// 안 그러면 "파일 자막 / 생성 자막 / 끄기" 세 단계가 두 단계로 줄어든다.
    private func preloadSiblingSubtitle() {
        guard let url = subtitlePromptURL else { return }
        _ = sampler.loadExternalSubtitle(url: url, activate: false)
    }

    private func acceptSubtitlePrompt() {
        if mediaDataDeletePrompt {
            mediaDataDeletePrompt = false
            performClearCurrentMediaData()
            return
        }
        // 다른 언어 자막을 쓰겠다고 한 경우: 언어 설정을 그쪽으로 옮긴다.
        // 설정이 바뀌면 생성기가 그 조합으로 다시 붙으면서 해당 캐시를 읽는다.
        if let p = languagePrompt {
            languagePrompt = nil
            subtitleSourceLanguage = p.source
            subtitleTargetLanguage = p.target
            return
        }
        guard let url = subtitlePromptURL else { return }
        subtitlePromptURL = nil
        if !sampler.loadExternalSubtitle(url: url) {
            showTransientAccentLabel("SUBTITLE LOAD FAILED")
        }
    }

    /// 사용자가 X 거절 → 단순히 프롬프트만 닫음 (이번 세션 한정, 다음 파일 로드 시 재평가).
    private func dismissSubtitlePrompt() {
        if mediaDataDeletePrompt {
            mediaDataDeletePrompt = false
            return
        }
        if languagePrompt != nil {
            // 무시하고 지금 설정 그대로 생성을 시작한다.
            languagePrompt = nil
            sampler.generator.dismissOtherLanguagePrompt()
            return
        }
        subtitlePromptURL = nil
    }

    @ViewBuilder
    private func subtitlePromptButtonOverlay(size: CGSize) -> some View {
        if let g = computeURLInputGeometry(
            size: size, sampler: sampler,
            isFullscreen: isFullscreen,
            rightText: "X  \(promptConfirmLabel)",
            twoButton: true
        ) {
            ZStack(alignment: .topLeading) {
                // 좌측 절반 = X (거절)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: g.cancelTapRect.width, height: g.cancelTapRect.height)
                    .onTapGesture { dismissSubtitlePrompt() }
                    .position(x: g.cancelTapRect.midX, y: g.cancelTapRect.midY)
                // 우측 절반 = USE (수락)
                if let commit = g.commitTapRect {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: commit.width, height: commit.height)
                        .onTapGesture { acceptSubtitlePrompt() }
                        .position(x: commit.midX, y: commit.midY)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    @ViewBuilder
    private func playbackInfoButtonOverlay(size: CGSize) -> some View {
        if let g = computeURLInputGeometry(
            size: size, sampler: sampler,
            isFullscreen: isFullscreen,
            rightText: "CLOSE",
            twoButton: false
        ) {
            Color.clear
                .contentShape(Rectangle())
                .frame(width: g.cancelTapRect.width, height: g.cancelTapRect.height)
                .onTapGesture { dismissPlaybackInfo() }
                .position(x: g.cancelTapRect.midX, y: g.cancelTapRect.midY)
                .frame(width: size.width, height: size.height)
        }
    }

    // MARK: 잠자기 방지 (풀스크린 재생 중)

    /// 풀스크린 + 재생 중일 때만 디스플레이/시스템 잠자기 방지. 그 외엔 즉시 해제.
    private func updateSleepPrevention() {
        if preventFullscreenDisplaySleep && isFullscreen && sampler.isPlaying {
            guard sleepAssertion == nil else { return }
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "24DOST fullscreen video playback"
            )
        } else {
            releaseSleepAssertion()
        }
    }

    private func releaseSleepAssertion() {
        guard let a = sleepAssertion else { return }
        ProcessInfo.processInfo.endActivity(a)
        sleepAssertion = nil
    }

    // MARK: Always on Top

    /// 창 레벨 직접 설정. 풀스크린 진입/복귀 시에도 호출됨.
    private func applyAlwaysOnTop(_ on: Bool) {
        guard let window = NSApp.windows.first else { return }
        window.level = on ? .floating : .normal
    }

    // MARK: 플레이리스트

    /// 지정 인덱스 파일을 열고 playlistIndex 갱신.
    /// 멀티 파일에서는 대상 파일을 열기 직전에만 존재 확인한다.
    /// 새 파일마다 자막 자동 검출 프롬프트 상태 재평가.
    private func openPlaylistItem(at index: Int, searchStep: Int = 1) {
        guard !playlist.isEmpty, searchStep != 0 else { return }

        var candidate = index
        while candidate >= 0, candidate < playlist.count {
            let url = playlist[candidate]
            if !url.isFileURL || FileManager.default.fileExists(atPath: url.path) {
                persistCurrentPlaybackPositionIfNeeded()
                endPeekIfNeeded()
                playlistIndex = candidate
                subtitlePromptURL = findSiblingSubtitle(for: url)
                if playlist.count == 1, !VideoSampler.isImageFile(url: url) {
                    rememberLastFile(url, addToRecents: false)
                }
                let key = playbackPositionKey(forFileURL: url)
                currentPlaybackPositionKey = key
                pendingAutoResize = true
                sampler.open(url: url)
                preloadSiblingSubtitle()
                sampler.isPlaying = true
                restorePlaybackPositionIfNeeded(for: key)
                return
            }

            playlist.remove(at: candidate)
            sampler.triggerBorderBlink()
            if playlist.isEmpty {
                playlistIndex = 0
                return
            }
            candidate = (searchStep > 0) ? candidate : (candidate - 1)
        }

        playlistIndex = min(max(0, playlistIndex), max(0, playlist.count - 1))
        sampler.triggerBorderBlink()
    }

    /// 플레이리스트 자동 전진 (재생 종료 시). 루프가 켜져 있으면 단일 파일도 포함해 마지막에서 처음으로 돌아간다.
    private func advancePlaylist() {
        clearStoredPlaybackPosition(for: currentPlaybackPositionKey)
        let next = playlistIndex + 1
        if next < playlist.count {
            openPlaylistItem(at: next, searchStep: 1)
        } else if loopMultiFilePlayback && !playlist.isEmpty {
            openPlaylistItem(at: 0, searchStep: 1)
        }
    }

    /// Shift+← : 이전 파일. 없으면 악센트 깜빡임.
    private func playlistPrev() {
        guard !playlist.isEmpty else { 
            sampler.triggerBorderBlink()
            return 
        }
        let prev = playlistIndex - 1
        if prev >= 0 { 
            openPlaylistItem(at: prev, searchStep: -1) 
        } else { 
            sampler.triggerBorderBlink() 
        }
    }

    /// Shift+→ : 다음 파일. 없으면 악센트 깜빡임.
    private func playlistNext() {
        guard !playlist.isEmpty else { 
            sampler.triggerBorderBlink()
            return 
        }
        let next = playlistIndex + 1
        if next < playlist.count { 
            openPlaylistItem(at: next, searchStep: 1) 
        } else { 
            sampler.triggerBorderBlink() 
        }
    }

    // MARK: 피크 (우상단 도트 프레스 = 실제 영상 노출)

    /// 피크 영상 컨테이너. 창 전체를 채운다. 모서리 곡률은 여기서 만들지 않는다 —
    /// 창 자체 마스크(`contentView.layer` cornerRadius 32 + masksToBounds)가 이미 자른다.
    @ViewBuilder
    private func peekVideoLayer(size: CGSize, player: AVPlayer) -> some View {
        // 콘텐츠 줌을 피크 원본 영상에도 동일 적용.
        //
        // **영상 전체가 들어가는 사각형을 그 크기 그대로** 만들고, 창 중앙 기준으로 옮긴 뒤,
        // 창 밖으로 나가는 부분을 잘라낸다.
        //
        // 창 크기 레이어에 scaleEffect + offset 을 거는 방식은 쓰면 안 된다. 창 모드의
        // .resizeAspectFill 은 넘치는 부분을 **레이어가 이미 잘라 버려서**, 옮겨도 잘려나간
        // 영상이 드러나는 게 아니라 뒤의 검은 배경이 나온다(전체화면은 .resizeAspect 라
        // 영상 전체가 레이어 안에 있어 우연히 멀쩡했다).
        //
        // 확대하지 않았을 때는 이 사각형이 예전 그대로다 — 창 모드면 창을 덮는 크기,
        // 전체화면이면 레터박스 포함 fit 크기.
        let layout = sampler.peekContentLayout(displaySize: size)

        PlayerLayerView(player: player, isFullscreen: isFullscreen)
            .frame(width:  layout?.size.width  ?? size.width,
                   height: layout?.size.height ?? size.height)
            .offset(x: layout?.offset.width ?? 0, y: layout?.offset.height ?? 0)
            .frame(width: size.width, height: size.height)
            // 여기서는 **직사각형으로만** 자른다(확대하면 위 사각형이 창보다 커지므로 잘라야 한다).
            // 모서리 곡률을 여기서 또 주면 안 된다 — 창 자체 마스크와 이중으로 겹치는데,
            // 영상 레이어는 GPU 가 따로 합성해서 그 위에 씌운 곡선 마스크가 계단처럼 나온다.
            // 곡률은 창 마스크 하나에만 맡기면 배경·도트와 같은 경계를 그대로 쓴다.
            .clipped()
    }

    /// 종료 히트 영역: 좌상단 visible 도트 한 칸 크기의 투명 영역.
    /// 우상단 피크 도트와 같은 방식의 숨은 조작이고, 도트·피크 모드 모두에서 동작한다.
    @ViewBuilder
    private func quitHitArea(size: CGSize) -> some View {
        let grid = sampler.gridSize
        let rows = sampler.dotColors.count
        let cols = sampler.dotColors.first?.count ?? 0
        let layout = makeDotGridLayout(
            size: size, grid: grid, dotDiameter: sampler.dotDiameter,
            rowsOverride: rows > 0 ? rows : nil,
            colsOverride: cols > 0 ? cols : nil,
            isFullscreen: isFullscreen
        )
        // 격자가 아주 좁으면(작은 창 + 넓은 간격) 좌상단과 우상단 앵커가 같은 도트가 된다.
        // 그때는 그 자리를 피크에 양보한다 — 종료는 ⌘Q 로도 되지만 피크를 부를 데는 여기뿐이다.
        let peekAnchor = canPeek ? layout.findTopRightAnchor() : nil
        if let anchor = layout.findTopLeftAnchor(),
           !(peekAnchor?.row == anchor.row && peekAnchor?.col == anchor.col) {
            let c = layout.center(row: anchor.row, col: anchor.col)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: grid, height: grid)
                .position(x: c.x, y: c.y)
                .onTapGesture { quitApp() }
        }
    }

    /// 좌상단 도트 = 앱 종료.
    /// 저장은 `AppDelegate.applicationWillTerminate` 가 한다 — ⌘Q·⌘W 와 같은 경로다.
    private func quitApp() {
        NSApp.terminate(nil)
    }

    /// 피크 히트 영역: 우상단 visible 도트 한 칸 크기의 투명 영역.
    /// 기본 모드는 프레스/릴리즈, Tap to Peek 모드는 탭 토글로 동작한다.
    @ViewBuilder
    private func peekHitArea(size: CGSize) -> some View {
        let grid = sampler.gridSize
        let rows = sampler.dotColors.count
        let cols = sampler.dotColors.first?.count ?? 0
        let layout = makeDotGridLayout(
            size: size, grid: grid, dotDiameter: sampler.dotDiameter,
            rowsOverride: rows > 0 ? rows : nil,
            colsOverride: cols > 0 ? cols : nil,
            isFullscreen: isFullscreen
        )
        if let anchor = layout.findTopRightAnchor() {
            let c = layout.center(row: anchor.row, col: anchor.col)
            if tapToPeek {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: grid, height: grid)
                    .position(x: c.x, y: c.y)
                    .onTapGesture { togglePeek() }
            } else {
                // 누르면 시작, **커서가 도트를 벗어나면** 끝난다.
                //
                // 예전에는 버튼을 놓을 때 끝났는데, 보는 내내 누르고 있어야 해서 불편했다.
                // 이제 한 번 누르면 손을 떼도 계속 보이고, 커서를 치우면 도트로 돌아온다.
                //
                // 끝나는 조건을 롤아웃 하나에만 맡기면 갇힌다 — 전체화면에서는 커서가 2초 뒤
                // 자동으로 숨는데, 숨은 채 도트 위에 있으면 hover 가 안 빠져서 영영 peek 이다.
                // 그래서 커서가 이미 밖에 있는 상태의 릴리즈도 종료로 친다.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: grid, height: grid)
                    .position(x: c.x, y: c.y)
                    .onAppear { peekDotRect = CGRect(x: c.x - grid / 2, y: c.y - grid / 2,
                                                     width: grid, height: grid) }
                    .onChange(of: c) { _, p in
                        peekDotRect = CGRect(x: p.x - grid / 2, y: p.y - grid / 2,
                                             width: grid, height: grid)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                // onChanged는 연속 발생 → idempotent하게 처리.
                                if !isPeeking {
                                    isPeeking = true
                                    sampler.peekStart()
                                    startPeekRolloutWatch()
                                }
                            }
                        // onEnded 없음 — 릴리즈로는 끝나지 않는다. 커서가 도트를 벗어나야 끝난다.
                    )
            }
        }
    }

    private func togglePeek() {
        if isPeeking {
            endPeekIfNeeded()
        } else {
            isPeeking = true
            sampler.peekStart()
        }
    }

    /// 커서가 피크 도트를 벗어나는지 감시한다.
    ///
    /// SwiftUI 의 onHover 로는 안 된다 — 도트 색이 초당 30번 바뀌면서 이 뷰가 계속 다시
    /// 만들어지고, 그때마다 hover 추적 영역이 초기화돼 상태가 남지 않는다. 뷰 재생성과
    /// 무관한 이벤트 모니터로 커서 위치를 직접 본다 (커서 자동 숨김이 쓰는 것과 같은 방식).
    private func startPeekRolloutWatch() {
        stopPeekRolloutWatch()
        NSApplication.shared.windows.first?.acceptsMouseMovedEvents = true
        peekRolloutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            guard isPeeking, peekDotRect != .zero else { return event }
            let h = sampler.currentDisplaySize.height
            // locationInWindow 는 좌하단 원점, 캔버스 좌표는 좌상단 원점.
            let point = CGPoint(x: event.locationInWindow.x, y: h - event.locationInWindow.y)
            if !peekDotRect.contains(point) { endPeekIfNeeded() }
            return event
        }
    }

    private func stopPeekRolloutWatch() {
        if let m = peekRolloutMonitor { NSEvent.removeMonitor(m) }
        peekRolloutMonitor = nil
    }

    private func endPeekIfNeeded() {
        stopPeekRolloutWatch()
        guard isPeeking else { return }
        isPeeking = false
        sampler.peekEnd()
    }

    /// URL 편집 제출: 공백 제거 후 비어있지 않으면 재생 시도. 편집 상태는 무조건 종료.
    private func commitURLEdit() {
        let trimmed = urlBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingURL = false
        urlBuffer = ""
        if !trimmed.isEmpty {
            // 사용자 입력 원본을 기억. 추출된 스트림 URL은 만료되므로 부적절.
            persistCurrentPlaybackPositionIfNeeded()
            endPeekIfNeeded()
            rememberLastURL(trimmed)
            prepareForURLPlayback()
            let key = playbackPositionKey(forURLString: trimmed)
            currentPlaybackPositionKey = key
            pendingAutoResize = true
            sampler.openURL(trimmed)
            restorePlaybackPositionIfNeeded(for: key)
        }
    }

    /// URL 편집 취소: 입력을 버리고 이전 상태로 복귀.
    /// 재생/일시정지 등 sampler 상태는 손대지 않으므로 "이전과 동일한 상태"로 자연 복귀.
    private func cancelURLEdit() {
        isEditingURL = false
        urlBuffer = ""
    }

    private func dismissPlaybackInfo() {
        isShowingPlaybackInfo = false
    }

    // MARK: 메뉴 notification 핸들러 (body 타입체커 부담 줄이려고 메서드로 분리)

    private func handleExternalOpenURLs(_ note: Notification) {
        // Finder "Open With…" / `open` 커맨드 / 파일 더블클릭 경로.
        // 외부 진입은 대기/재생 상태 무관하게 항상 수락 (⌘O 와 동일 정책).
        guard let urls = note.userInfo?["urls"] as? [URL], !urls.isEmpty else { return }
        openFiles(urls)
    }

    private func handleExternalOpenMediaURL(_ note: Notification) {
        guard let value = (note.userInfo?["url"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        let displayTitle = (note.userInfo?["displayTitle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        if isEditingURL { isEditingURL = false; urlBuffer = "" }
        dismissPlaybackInfo()
        persistCurrentPlaybackPositionIfNeeded()
        endPeekIfNeeded()
        rememberLastURL(value, title: displayTitle)
        prepareForURLPlayback()
        let key = playbackPositionKey(forURLString: value)
        currentPlaybackPositionKey = key
        pendingAutoResize = true
        sampler.openURL(value)
        restorePlaybackPositionIfNeeded(for: key)
    }

    private func handleOpenURLRequested(_ note: Notification) {
        // 자막 영역을 URL 입력창으로 전환. 재생/일시정지 상태는 그대로 유지.
        // 창을 확실히 key 로 만들어 첫 키스트로크부터 local 모니터가 받도록 함.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        dismissPlaybackInfo()
        urlBuffer = ""
        isEditingURL = true
    }

    private func handleOpenPlaybackInfoRequested(_ note: Notification) {
        guard !isEditingURL, hasPlaybackInfoContent else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        if isShowingPlaybackInfo {
            dismissPlaybackInfo()
        } else {
            isShowingPlaybackInfo = true
        }
    }

    private func handleToggleAlwaysOnTop(_ note: Notification) {
        guard !isFullscreen else { return }  // 풀스크린 중 무시
        isAlwaysOnTop.toggle()
        applyAlwaysOnTop(isAlwaysOnTop)
    }

    // MARK: Open Recent

    /// NotificationCenter publisher closure (body 타입체커 부담 줄이려고 메서드 분리).
    private func handleOpenRecentNotification(_ note: Notification) {
        guard let info = note.userInfo,
              let kindRaw = info["kind"]  as? String,
              let value   = info["value"] as? String,
              let kind    = RecentItem.Kind(rawValue: kindRaw) else { return }
        let paths = info["paths"] as? [String]
        let title = (info["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        openRecentItem(kind: kind, value: value, paths: paths, title: title)
    }

    /// 메인 앱 윈도우를 가장 확실하게 찾아 전체화면 전환을 수행하는 헬퍼.
    /// 패널 열림/닫힘 등의 이벤트 과정에서 keyWindow 가 꼬이는 문제를 차단합니다.
    /// Always on Top(.floating) 상태에서는 macOS가 toggleFullScreen을 거부하므로
    /// 전환 직전에 .normal로 내린 뒤 호출합니다. 복원은 didExitFullScreen에서 처리.
    private func toggleMainAppFullscreen() {
        // 1) delegate 기반 탐색 → 2) keyWindow → 3) 첫 번째 윈도우 순으로 fallback
        let window: NSWindow?
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let w = NSApplication.shared.windows.first(where: { $0.delegate === appDelegate }) {
            window = w
        } else {
            window = NSApplication.shared.keyWindow
                ?? NSApplication.shared.windows.first(where: { $0.isKeyWindow })
                ?? NSApplication.shared.windows.first
        }
        guard let window else { return }

        // Always on Top 활성 시 .floating 레벨이 풀스크린 전환을 차단하므로 임시 해제
        if isAlwaysOnTop {
            window.level = .normal
        }
        window.toggleFullScreen(nil)
    }

    /// File → Open Recent 메뉴 클릭 처리.
    /// 파일: 존재 여부 확인 후 단일 항목 플레이리스트로 열기. 없으면 recents 에서 제거 + 보더 깜빡.
    /// URL : 바로 재생(네트워크 실패는 기존 urlLoadError 경로 사용).
    private func openRecentItem(kind: RecentItem.Kind, value: String, paths: [String]?, title: String?) {
        switch kind {
        case .file:
            let url = URL(fileURLWithPath: value)
            guard FileManager.default.fileExists(atPath: url.path) else {
                recents.remove(kind: .file, value: value)
                sampler.triggerBorderBlink()
                return
            }
            // openFiles 가 URL 편집 해제 + 플레이리스트/index 세팅 + rememberLastFile 까지 처리.
            openFiles([url])
        case .fileGroup:
            let playlistURLs = (paths ?? []).map { URL(fileURLWithPath: $0) }
            guard let first = playlistURLs.first else {
                recents.remove(kind: .fileGroup, value: value)
                sampler.triggerBorderBlink()
                return
            }
            guard FileManager.default.fileExists(atPath: first.path) else {
                recents.remove(kind: .fileGroup, value: value)
                sampler.triggerBorderBlink()
                return
            }
            openFiles(playlistURLs)
        case .url:
            if isEditingURL { isEditingURL = false; urlBuffer = "" }
            dismissPlaybackInfo()
            persistCurrentPlaybackPositionIfNeeded()
            endPeekIfNeeded()
            rememberLastURL(value, title: title)
            prepareForURLPlayback()
            let key = playbackPositionKey(forURLString: value)
            currentPlaybackPositionKey = key
            pendingAutoResize = true
            sampler.openURL(value)
            restorePlaybackPositionIfNeeded(for: key)
        }
    }

    private func handleResetAppStateRequested() {
        restorePlaybackPositionTask?.cancel()
        endPeekIfNeeded()
        dismissPlaybackInfo()
        subtitlePromptURL = nil
        isEditingURL = false
        urlBuffer = ""
        isDropTargeted = false
        pendingAutoResize = false
        dragAccumulator = .zero
        if isAlwaysOnTop {
            applyAlwaysOnTop(false)
        }
        isAlwaysOnTop = false

        recents.clear()

        let defaults = UserDefaults.standard
        ["autoPlayOnOpen", "rememberPlaybackPosition", "autoResizeWindowToVideo", "adaptiveSubtitleColor", "loopMultiFilePlayback", "tapToPeek", "preventFullscreenDisplaySleep"]
            .forEach { defaults.removeObject(forKey: $0) }
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("24dost.") || key.hasPrefix("dost.") {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        // 생성 자막 캐시도 지운다. UserDefaults 밖(Application Support)에 있어서
        // 위 루프로는 안 지워진다 — 설명 문구는 "cache" 를 지운다고 하는데 실제로는
        // 남아 있었다.
        _ = SubtitleGenerator.clearAllCaches()
        sampler.generator.regenerate()

        AppDelegate.clearPendingExternalMediaOpenRequest()

        playlist = []
        playlistIndex = 0
        currentPlaybackPositionKey = nil
        loopMultiFilePlayback = false
        tapToPeek = false
        preventFullscreenDisplaySleep = false
        rememberPlaybackPosition = false
        autoResizeWindowToVideo = true
        adaptiveSubtitleColor = true
        accentColorRaw = AppAccentColor.defaultChoice.rawValue
        dotShapeRaw = DotShape.defaultChoice.rawValue
        backgroundStyleRaw = BackgroundStyle.blur.rawValue
        fullscreenBackgroundStyleRaw = FullscreenBackgroundStyle.black.rawValue
        lastMediaKind = ""
        lastMediaValue = ""
        lastMediaPathsData = ""
        lastMediaTitle = ""
        playbackPositionsData = ""

        sampler.resetAppState()
        releaseSleepAssertion()
    }

    // MARK: 키 모니터

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            // URL 편집 모드: 텍스트 입력 전용. 재생 단축키는 전부 무시.
            if isEditingURL { return handleURLEditingKey(event) }
            return handlePlaybackKey(event)
        }
        // 트랙패드 핀치 (콘텐츠 줌, 창·전체화면 공통). 뷰 히트테스트에 의존하지 않도록
        // 키와 동일하게 로컬 이벤트 모니터로 받는다. magnification 은 이벤트당 증분값.
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [self] event in
            guard !isEditingURL else { return event }
            // 로컬 모니터는 앱 전체 이벤트를 받는다. 설정 창 위에서의 핀치까지 먹으면
            // 보이지도 않는 뒤쪽 영상이 확대된다.
            if let w = event.window, let host = hostWindow, w !== host { return event }
            let anchor = zoomAnchor(for: event)
            // 커서 자동 숨김은 전체화면에서만 돈다. 창 모드에서 부르면 오히려 숨김
            // 타이머를 새로 걸어 커서가 사라진다.
            if anchor != nil, isFullscreen { cursorHider.reveal() }
            sampler.zoomBy(magnification: event.magnification, anchor: anchor)
            return nil
        }
    }

    /// 핀치 앵커 = 커서 위치. AppKit 은 좌하단 원점이라 y 를 뒤집어 캔버스 좌표에 맞춘다.
    /// 캔버스는 창 전체를 덮으므로(ignoresSafeArea) 그 밖의 변환은 없다.
    private func zoomAnchor(for event: NSEvent) -> CGPoint? {
        let size = sampler.currentDisplaySize
        guard size.width > 0, size.height > 0 else { return nil }
        let height = (event.window ?? hostWindow)?.contentView?.bounds.height ?? size.height
        let loc = event.locationInWindow
        return CGPoint(x: loc.x, y: height - loc.y)
    }

    /// URL 편집 모드 전용 키 처리. Command 조합은 메뉴로 패스스루하되 ⌘V만 직접 처리.
    /// 편집 모드에서는 모든 재생 단축키(space/↵/w/a/s/d/c/…)가 비활성화된다.
    private func handleURLEditingKey(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) {
            // 한글입력기(IME) 상태에선 charactersIgnoringModifiers 가 "ㅍ" 등 타 언어 문자로 반환될 수 있음
            // v의 하드웨어 물리 키코드인 9번을 함께 검사해 어떤 환경이든 붙여넣기가 강제 적용되게 함
            if event.charactersIgnoringModifiers?.lowercased() == "v" || event.keyCode == 9 {
                if let s = NSPasteboard.general.string(forType: .string) {
                    urlBuffer += s.replacingOccurrences(of: "\n", with: "")
                                  .replacingOccurrences(of: "\r", with: "")
                }
                return nil
            }
            return event   // 다른 ⌘ 조합(⌘Q/⌘O/⌘B/⌘0/⌘1)은 메뉴로 전달
        }
        switch event.keyCode {
        case 53:                cancelURLEdit(); return nil     // Escape
        case 36, 76:            commitURLEdit(); return nil     // Return / Enter
        case 51:                                                  // Backspace
            if !urlBuffer.isEmpty { urlBuffer.removeLast() }
            return nil
        // 편집 모드에선 버퍼를 오염시키지 않도록 기능키들을 전부 "소비(return nil)".
        // ← 이전에는 default 분기의 characters 에 Private Use 영역(0xF700+)이 그대로
        //    들어가 urlBuffer 에 쓰레기 문자가 붙는 버그가 있었음.
        case 48:                return nil                       // Tab
        case 117:               return nil                       // Forward Delete
        case 115, 116, 119, 121: return nil                      // Home / PgUp / End / PgDn
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80:
            return nil                                            // F1–F20
        case 123, 124, 125, 126: return nil                      // ← → ↓ ↑ (나중에 커서 이동용 예약)
        default:
            if let chars = event.characters, !chars.isEmpty {
                // 제어문자(0x00–0x1F, 0x7F) + Private Use Area(0xE000–0xF8FF) 제외.
                // macOS 는 화살표·펑션 키를 PUA 로 인코딩하므로 이걸 걸러야
                // 예외 케이스에서도 urlBuffer 에 끼어드는 쓰레기 문자를 원천 차단한다.
                let filtered = chars.unicodeScalars.filter { s in
                    s.value >= 0x20 && s.value != 0x7F &&
                        !(s.value >= 0xE000 && s.value <= 0xF8FF)
                }
                if !filtered.isEmpty {
                    urlBuffer += String(String.UnicodeScalarView(filtered))
                }
            }
            return nil
        }
    }

    /// space, ↵, Esc, t, b, p, z — 한 번 눌렀을 때 한 번만 실행돼야 하는 키들.
    private static let nonRepeatingKeyCodes: Set<UInt16> = [49, 36, 76, 53, 17, 11, 35, 6]

    /// 평시(재생) 모드 키 처리.
    private func handlePlaybackKey(_ event: NSEvent) -> NSEvent? {
        if event.modifierFlags.contains(.command) {
            if event.keyCode == 35 { // ⌘P
                openSubtitleFile()
                return nil
            }
            // 전체화면 콘텐츠 줌: ⌘0 = fit, ⌘1 = fill.
            // 창 모드의 ⌘0(Half Video Size) 메뉴보다 먼저 가로챈다.
            if isFullscreen, let chars = event.charactersIgnoringModifiers {
                if chars == "0" { sampler.zoomToFit();  return nil }
                if chars == "1" { sampler.zoomToFill(); return nil }
            }
            // ⌘E(Export Image)는 File 메뉴 항목이 단축키를 소유하므로 여기선 메뉴로 패스.
            return event
        }

        // 토글류는 키를 누르고 있을 때 반복 실행되면 안 된다.
        // (p 를 살짝 길게 누르면 자막 소스가 초당 몇 번씩 순환해 버린다)
        // 탐색·볼륨·도트 크기는 반복이 오히려 자연스러우므로 그대로 둔다.
        if event.isARepeat, Self.nonRepeatingKeyCodes.contains(event.keyCode) { return nil }

        if isShowingPlaybackInfo {
            switch event.keyCode {
            case 53:
                dismissPlaybackInfo()
                return nil
            default:
                break
            }
        }

        // 프롬프트 활성 시 Enter = USE, Esc = X. 다른 키는 평시대로.
        if isPromptActive {
            switch event.keyCode {
            case 36, 76: acceptSubtitlePrompt(); return nil   // Enter → USE
            case 53:     dismissSubtitlePrompt(); return nil  // Esc   → X
            default:     break
            }
        }
        switch event.keyCode {
        case 49:                                                              // space
            // 대기 상태(아무것도 로드되지 않음) + 마지막 재생 기록 있으면 복원.
            // 기록 없거나 복원 불가하면 기존대로 no-op (togglePlayPause도 player nil이라 no-op).
            if isStandby {
                _ = resumeLastMedia()
            } else {
                sampler.togglePlayPause()
            }
            return nil
        case 53:                                                              // Esc
            // Esc 의 도착지는 언제나 "창 + 도트 + 정지" 하나다.
            // 전체화면이면 나가는 것만으로 피크까지 정리된다(didExitFullScreen).
            if isFullscreen {
                toggleMainAppFullscreen()
                return nil
            }
            // tap to peek 은 명시적 토글이라 커서를 치워도 안 꺼진다. 키보드 탈출구를 준다.
            // (누르고 있기 모드는 커서가 도트를 벗어나면 알아서 끝나므로 건드리지 않는다.)
            if tapToPeek, isPeeking {
                endPeekIfNeeded()
                return nil
            }
            return event
        case 36, 76:                                                          // ↵
            toggleMainAppFullscreen()
            return nil
        case 123:                                                             // ←
            if event.modifierFlags.contains(.shift) { playlistPrev() }
            else { sampler.seek(by: -10) }
            return nil
        case 124:                                                             // →
            if event.modifierFlags.contains(.shift) { playlistNext() }
            else { sampler.seek(by: 10) }
            return nil
        case 43:                                                              // ,
            if event.modifierFlags.contains(.command) { return event }        // ⌘, 는 메뉴(설정)로 패스
            sampler.seekByColumn(delta: -1)
            return nil
        case 47:                                                              // .
            if event.modifierFlags.contains(.command) { return event }        // ⌘. 는 시스템/메뉴로 패스
            sampler.seekByColumn(delta:  1)
            return nil
        case 126:      sampler.volumeUp();    return nil                    // ↑
        case 125:      sampler.volumeDown();  return nil                    // ↓
        case 13:       sampler.increaseDotSize();     return nil            // w
        case 1:        sampler.decreaseDotSize();     return nil            // s
        case 0:        sampler.decreaseGap();         return nil            // a
        case 2:        sampler.increaseGap();         return nil            // d
        case 6:        sampler.resetDotSettings();    return nil            // z
        case 17:                                                             // t
            if !isFullscreen {
                isAlwaysOnTop.toggle()
                applyAlwaysOnTop(isAlwaysOnTop)
            }
            return nil
        case 11:       cycleBackgroundStyle();        return nil            // b
        case 35:                                                             // p
            toggleSubtitlesWithLabel(); return nil                           // p   캡션 온/오프
        case 33:       sampler.decreaseSubtitleSize(); return nil           // [
        case 30:       sampler.increaseSubtitleSize(); return nil           // ]
        default:
            // ⌘+숫자는 메뉴(⌘0) 전용. 숫자 단독(0~9)만 타임라인 시킹.
            //   0 → 0% (맨 앞),  1 → 10%, ... , 9 → 90%
            if !event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers,
               let num = Int(chars), num >= 0, num <= 9 {
                sampler.seek(toFraction: Double(num) * 0.1)
                return nil
            }
            return event
        }
    }

    // MARK: 도트 이미지 내보내기 (⌘E)

    /// 현재 화면의 도트 격자를 PNG로 ~/Downloads 에 저장한다.
    /// - 파일명: "<원본파일명> <시각> by DOPL.png" (영상), 정지 이미지는 시각 생략.
    /// - 자막/모드 레이블/배경효과는 제외하고 순수 도트 격자만 렌더한다.
    /// - 로드된 미디어가 없으면(dotColors 비어있음) 아무 동작도 하지 않는다(no-op).
    private func exportCurrentDotImage() {
        // peek 중에는 도트화 전 원본 프레임을 그대로 내보낸다.
        let pngData: Data?
        if isPeeking {
            pngData = renderOriginalFramePNGData()
        } else {
            guard !sampler.dotColors.isEmpty else { return }
            pngData = renderDotGridPNGData()
        }
        guard let pngData else { return }

        let fileURL = uniqueDownloadsURL(baseName: exportFileBaseName())
        do {
            try pngData.write(to: fileURL)
            showTransientAccentLabel("EXPORTED")
        } catch {
            showTransientAccentLabel("EXPORT FAILED")
        }
    }

    /// dotColors(2D 색상 격자)를 투명 배경 PNG 로 렌더.
    /// 화면 Canvas와 동일하게 바깥 테두리 링(인덱스 0 / 마지막)은 그리지 않는다.
    private func renderDotGridPNGData() -> Data? {
        let grid = sampler.gridSize
        let dotD = sampler.dotDiameter
        let rows = sampler.dotColors.count
        let cols = sampler.dotColors.first?.count ?? 0
        guard rows > 2, cols > 2, grid > 0, dotD > 0 else { return nil }

        let scale: CGFloat = 2          // 레티나 품질로 약간 상향
        let pxW = Int((CGFloat(cols) * grid * scale).rounded())
        let pxH = Int((CGFloat(rows) * grid * scale).rounded())
        guard pxW > 0, pxH > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let r = dotD / 2 * scale
        // 화면과 같은 규칙 — 내보낸 PNG 에만 격자선이 남으면 안 된다.
        let seam = dotShape.seamOutset(gridSize: grid, dotDiameter: dotD) * scale
        for row in 1..<(rows - 1) {
            let line = sampler.dotColors[row]
            guard line.count == cols else { continue }
            for col in 1..<(cols - 1) {
                let cx = (CGFloat(col) * grid + grid / 2) * scale
                // CGContext 는 좌하단 원점 → 위아래를 뒤집어 row 0 이 상단에 오게 한다.
                let cy = CGFloat(pxH) - (CGFloat(row) * grid + grid / 2) * scale
                ctx.setFillColor(line[col])
                // 화면 Canvas 와 같은 경로 생성기를 쓴다 — 렌더러가 둘이라
                // 각자 그리면 화면만 사각형이고 내보낸 PNG 는 원으로 남는다.
                ctx.addPath(dotShape.path(in: CGRect(x: cx - r, y: cy - r,
                                                     width: r * 2, height: r * 2)
                                             .insetBy(dx: -seam, dy: -seam)).cgPath)
                ctx.fillPath()
            }
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// peek 중 표시되는 원본 영상 프레임을 PNG 로 렌더(도트화 없음).
    private func renderOriginalFramePNGData() -> Data? {
        guard let cgImage = sampler.currentFrameCGImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// 내보내기 파일의 기본 이름(확장자 제외).
    ///   "<원본파일명> <시각> by DOPL"  (영상/오디오 — 재생 위치 포함)
    ///   "<원본파일명> by DOPL"         (정지 이미지 — 시각 생략)
    private func exportFileBaseName() -> String {
        let source = sanitizedFileName(currentSourceDisplayName())
        var timePart = ""
        if !sampler.isStaticContent,
           let secs = sampler.previewPlayer?.currentTime().seconds,
           secs.isFinite, secs >= 0 {
            timePart = " " + fileTimeStamp(secs)
        }
        return "\(source)\(timePart) by DOPL"
    }

    /// 현재 소스의 표시 이름(확장자 제외). 파일/그룹/URL 모두 커버.
    private func currentSourceDisplayName() -> String {
        if !playlist.isEmpty, playlist.indices.contains(playlistIndex) {
            return playlist[playlistIndex].deletingPathExtension().lastPathComponent
        }
        let title = (currentPlaybackInfoTitle ?? "DOPL").replacingOccurrences(of: "> ", with: "")
        return (title as NSString).deletingPathExtension
    }

    /// 재생 위치를 파일명용 시각 문자열로. ':' 는 파일명에 못 쓰므로 '_' 사용.
    ///   1시간 미만 → "MM_SS", 이상 → "H_MM_SS".
    private func fileTimeStamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d_%02d_%02d", h, m, s)
                     : String(format: "%02d_%02d", m, s)
    }

    /// 파일 시스템에서 금지/위험한 문자를 '_' 로 치환하고 공백을 정리.
    private func sanitizedFileName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "DOPL" : trimmed
    }

    /// ~/Downloads 안에서 충돌하지 않는 URL. 이미 있으면 " (1)", " (2)" … 로 회피.
    private func uniqueDownloadsURL(baseName: String) -> URL {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        var candidate = dir.appendingPathComponent("\(baseName).png")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(baseName) (\(n)).png")
            n += 1
        }
        return candidate
    }

    // MARK: 전역 트랜지언트 레이블

    /// 자막 파이프라인을 타고 0.6초간 노출되는 악센트 레이블.
    /// 모드 변경, 자막 OFF 등 일시적 알림에 공용.
    /// ⌘X — 이 영상에 대해 앱이 기록한 것을 전부 지운다.
    ///
    /// 지우는 것: 만들어 둔 생성 자막(언어·엔진 조합 전부), 저장된 재생 위치,
    /// 이 영상에 대해 기억해 둔 인식 언어.
    /// **최근 항목은 건드리지 않는다** — 그건 캐시가 아니라 무엇을 봤는지의 기록이고,
    /// 지금 재생 중인 파일이라 지워도 곧바로 다시 들어간다.
    private func requestClearCurrentMediaData() {
        // 다른 프롬프트나 URL 입력 중이면 끼어들지 않는다.
        guard !isEditingURL, !isPromptActive, !isShowingPlaybackInfo else { return }
        guard sampler.currentSourceURL != nil else {
            showTransientAccentLabel("NO VIDEO")
            return
        }
        mediaDataDeletePrompt = true
    }

    private func performClearCurrentMediaData() {
        let removedFiles = sampler.clearSubtitleCachesForCurrentMedia()

        var removedOther = 0
        if let key = currentPlaybackPositionKey {
            if playbackPositions[key] != nil {
                clearStoredPlaybackPosition(for: key)
                removedOther += 1
            }
            var languages = rememberedSourceLanguages
            if languages.removeValue(forKey: key) != nil {
                rememberedSourceLanguages = languages
                removedOther += 1
            }
        }

        // 지운 결과는 화면에 드러나지 않는다. 이 문구가 유일한 확인이라 넉넉히 띄운다.
        let feedbackSeconds = 1.6
        if removedFiles == 0 && removedOther == 0 {
            showTransientAccentLabel("NOTHING TO CLEAR", seconds: feedbackSeconds)
        } else if removedFiles > 0 {
            let unit = removedFiles == 1 ? "FILE" : "FILES"
            showTransientAccentLabel("DATA CLEARED (\(removedFiles) \(unit))", seconds: feedbackSeconds)
        } else {
            showTransientAccentLabel("DATA CLEARED", seconds: feedbackSeconds)
        }
    }

    /// 짧게 떴다 사라지는 안내 문구.
    ///
    /// 기본 0.6초는 배경 스타일 순환처럼 **방금 누른 것의 결과가 화면에 바로 보이는**
    /// 경우에 맞춘 값이다. 결과가 화면에 안 보이는 동작(파일 삭제 같은)은 이 문구가
    /// 유일한 확인이라 더 오래 둔다.
    private func showTransientAccentLabel(_ text: String, seconds: Double = 0.6) {
        backgroundStyleLabel = text
        backgroundStyleLabelTask?.cancel()
        backgroundStyleLabelTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { backgroundStyleLabel = nil }
        }
    }

    // MARK: 창 리사이즈 / 배경 / 자막 토글

    /// 파일/URL/이미지 오픈 시 자동 창 리사이즈.
    /// - videoWidth/2 >= 480 이면 영상의 50% 크기,
    /// - 그 미만이면 너비 480 고정 + 비례 높이.
    /// 좌상단 고정. 풀스크린 중엔 skip. 화면 visibleFrame 초과 시 비율 유지하며 clamp.
    private func autoResizeForVideo() {
        guard !isFullscreen else { return }
        let vs = sampler.videoSize
        guard vs.width > 0, vs.height > 0 else { return }
        guard let window = NSApplication.shared.windows.first else { return }

        let baseWidth: CGFloat = 480
        var newW: CGFloat
        var newH: CGFloat
        if vs.width / 2 >= baseWidth {
            newW = vs.width * 0.5
            newH = vs.height * 0.5
        } else {
            newW = baseWidth
            newH = baseWidth * (vs.height / vs.width)
        }

        // 화면 visibleFrame 까지 비율 유지하며 clamp.
        let screen = window.screen ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let ratio = min(vf.size.width / newW, vf.size.height / newH, 1.0)
            if ratio < 1.0 {
                newW *= ratio
                newH *= ratio
            }
        }

        let oldFrame = window.frame
        let newOrigin = CGPoint(
            x: oldFrame.origin.x,
            y: oldFrame.origin.y + oldFrame.size.height - newH
        )
        window.setFrame(CGRect(origin: newOrigin, size: CGSize(width: newW, height: newH)),
                        display: true, animate: false)
    }

    /// ⌘0: 영상 원본의 0.5배로 창 리사이즈. 좌상단 고정. 이 크기가 zoom 의 "기준값(baseline)".
    private func resizeWindowToVideo(scale: CGFloat) {
        guard !isFullscreen else { return }
        let vs = sampler.videoSize
        guard vs.width > 0, vs.height > 0 else { return }
        guard let window = NSApplication.shared.windows.first else { return }
        let newSize = CGSize(width: vs.width * scale, height: vs.height * scale)
        let oldFrame = window.frame
        // NSWindow 원점은 좌하단 → top-left 고정 위해 y 보정.
        let newOrigin = CGPoint(
            x: oldFrame.origin.x,
            y: oldFrame.origin.y + oldFrame.size.height - newSize.height
        )
        window.setFrame(CGRect(origin: newOrigin, size: newSize), display: true, animate: false)
    }

    /// ⌘- / ⌘=: 기준값(원본 × 0.5) 의 25% 만큼 현재 창 크기에서 차감/가산.
    ///   direction = -1 → shrink, +1 → enlarge. 좌상단 고정.
    /// 제약:
    ///   shrink: 너비 또는 높이 중 하나라도 120px 미만이 되면 실행 안 함.
    ///   enlarge: 창이 놓인 화면의 visibleFrame 크기를 초과하면 실행 안 함.
    /// 단계마다 (baseline × 0.25) 를 더하거나 빼므로 ⌘0 상태에서 시작했다면 비율 유지.
    private func zoomWindow(direction: Int) {
        guard !isFullscreen else { return }
        let vs = sampler.videoSize
        guard vs.width > 0, vs.height > 0 else { return }
        guard let window = NSApplication.shared.windows.first else { return }

        // 창을 임의 비율로 늘려 놨어도, 크기를 조절하는 순간 **영상 비율로 되돌린다.**
        //
        // 예전에는 현재 창 크기에 영상 비율만큼의 증분을 더했다. 그래서 한 번 비뚤어진
        // 비율이 그대로 유지된 채 커지고 작아졌다. 이제 배율 하나로만 크기를 정한다 —
        // 창 크기 = 영상 크기 × 배율. 비율은 언제나 영상과 같아진다.
        //
        // 현재 배율은 창 안에 들어가는 가장 큰 영상 비율 상자에서 뽑는다(min). 그래야
        // 비뚤어진 창에서 스냅할 때 화면 밖으로 갑자기 커지지 않는다.
        let step: CGFloat = 0.5 * 0.25        // 기준(절반 크기)의 1/4
        let current = window.frame.size
        let fitted = min(current.width / vs.width, current.height / vs.height)
        // 가장 가까운 칸으로 스냅한 뒤 한 칸 이동.
        let snapped = (fitted / step).rounded() * step
        let scale = max(step, snapped + CGFloat(direction) * step)

        let newW = vs.width  * scale
        let newH = vs.height * scale

        if direction < 0 {
            // 축소: 너비/높이 둘 중 하나라도 120 미만이면 거부.
            guard newW >= 120, newH >= 120 else { return }
        } else {
            // 확대: 창이 속한 화면의 visibleFrame 을 초과하면 거부.
            let screen = window.screen ?? NSScreen.main
            let maxSize = screen?.visibleFrame.size ?? CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                              height: CGFloat.greatestFiniteMagnitude)
            guard newW <= maxSize.width, newH <= maxSize.height else { return }
        }

        let oldFrame = window.frame
        let newOrigin = CGPoint(
            x: oldFrame.origin.x,
            y: oldFrame.origin.y + oldFrame.size.height - newH
        )
        window.setFrame(CGRect(origin: newOrigin, size: CGSize(width: newW, height: newH)),
                        display: true, animate: false)
    }

    /// ⌘B: 모드별 배경 스타일 순환. 일반=4단(blur/liquid/±black), 풀스크린=2단(BLACK/WHITE).
    /// 두 상태는 독립적이며 각자 UserDefaults로 영속.
    private func cycleBackgroundStyle() {
        if isFullscreen {
            let next = fullscreenBackgroundStyle.next
            fullscreenBackgroundStyleRaw = next.rawValue
            showTransientAccentLabel(next.displayName)
        } else {
            let next = backgroundStyle.next
            backgroundStyleRaw = next.rawValue
            showTransientAccentLabel(next.displayName)
        }
    }

    /// c: 자막 토글. 트랙이 있고 ON→OFF일 때만 SUBTITLE OFF 악센트 레이블.
    private func toggleSubtitlesWithLabel() {
        sampler.toggleSubtitles()
        if let label = sampler.subtitleModeLabel {
            showTransientAccentLabel(label)
        }
    }

    // MARK: 외부 자막 열기 (Shift+C)

    /// .srt / .smi 파일을 선택해 외부 자막을 로드한다. 내장 자막보다 우선.
    /// 영상이 로드되지 않은 상태(대기/이미지)에서는 동작하지 않음.
    /// 자동 검출 프롬프트가 떠 있었다면 사용자 능동 선택으로 간주하고 dismiss.
    private func openSubtitleFile() {
        guard sampler.previewPlayer != nil, !sampler.isStaticContent else { return }
        subtitlePromptURL = nil
        let panel = NSOpenPanel()
        var types: [UTType] = []
        for ext in ["srt", "smi"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !sampler.loadExternalSubtitle(url: url) {
            showTransientAccentLabel("SUBTITLE LOAD FAILED")
        }
    }

    // MARK: 파일 열기

    private func openFile() {
        let panel = NSOpenPanel()
        // AVFoundation 네이티브 지원 + ffmpeg remux 대상 + 정적 이미지까지 허용
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .image, .audio]
        let extraExts = ["mkv", "webm", "avi", "flv", "wmv", "ogv", "ogg",
                         "rmvb", "rm", "ts", "m2ts", "mts", "vob", "asf", "divx", "xvid",
                         "heic", "heif", "webp",
                         "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif", "wma"]
        for ext in extraExts {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true   // 복수 선택 → 연속재생
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        openFiles(panel.urls)
    }

    /// ⌘O, Finder Open With, 드래그&드롭, Open Recent 공통 진입점.
    /// 단일/복수 URL 모두 이름순 플레이리스트로 구성하고 첫 항목부터 재생.
    /// 최근 항목은 최초 진입 1회만 갱신하고, 실제 파일 존재 여부는 재생 시점마다 확인한다.
    private func openFiles(_ urls: [URL], recordRecent: Bool = true, rememberAsLast: Bool = true) {
        let sorted = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sorted.isEmpty else { return }
        // URL 편집 중이면 취소하고 재생으로 전환.
        if isEditingURL { isEditingURL = false; urlBuffer = "" }
        dismissPlaybackInfo()
        if rememberAsLast {
            if sorted.count == 1 { rememberLastFile(sorted[0], addToRecents: recordRecent) }
            else { rememberLastFileGroup(sorted, addToRecents: recordRecent) }
        } else if recordRecent {
            if sorted.count == 1 { recents.addFile(sorted[0]) }
            else { recents.addFileGroup(sorted) }
        }
        playlist = sorted
        playlistIndex = 0
        openPlaylistItem(at: 0, searchStep: 1)
    }

    // MARK: 드래그&드롭

    /// 대기 상태든 재생 중이든 드롭을 수락. 재생 중 드롭은 현재 파일을 교체.
    /// openFiles 내부에서 URL 편집 모드 해제까지 처리.
    private func performDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }

        let group = DispatchGroup()
        var collected: [URL] = []
        let lock = NSLock()

        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { obj, _ in
                defer { group.leave() }
                guard let url = obj, url.isFileURL else { return }
                lock.lock()
                collected.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            openFiles(collected)
        }
        return true
    }
}
