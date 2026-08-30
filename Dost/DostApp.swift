import SwiftUI
import AppKit

extension Notification.Name {
    static let openFileRequested     = Notification.Name("openFileRequested")
    static let openURLRequested      = Notification.Name("openURLRequested")
    static let openPlaybackInfoRequested = Notification.Name("openPlaybackInfoRequested")
    static let exportImageRequested  = Notification.Name("exportImageRequested")
    static let cycleBackgroundStyle  = Notification.Name("cycleBackgroundStyle")
    static let resizeToHalfVideoSize = Notification.Name("resizeToHalfVideoSize")
    static let zoomWindowOut         = Notification.Name("zoomWindowOut")
    static let zoomWindowIn          = Notification.Name("zoomWindowIn")
    static let toggleAlwaysOnTop     = Notification.Name("toggleAlwaysOnTop")
    static let playbackEnded         = Notification.Name("playbackEnded")
    /// Finder "Open With…" / 외부 open 이벤트. userInfo["urls"] = [URL]
    static let externalOpenURLs      = Notification.Name("externalOpenURLs")
    static let externalOpenMediaURL = Notification.Name("externalOpenMediaURL")
    /// 최근 항목 메뉴 클릭. userInfo["kind"], ["value"], ["paths"], ["title"] 를 사용.
    static let openRecentRequested   = Notification.Name("openRecentRequested")
    static let resetAppStateRequested = Notification.Name("resetAppStateRequested")
    /// 자동 생성 자막 내보내기 / 다시 만들기
    static let exportSubtitleRequested     = Notification.Name("exportSubtitleRequested")
    static let regenerateSubtitleRequested = Notification.Name("regenerateSubtitleRequested")
    /// 대기 화면 "Update →" 클릭 → 설정 창 Software Update 섹션 노출.
    static let revealSoftwareUpdate  = Notification.Name("revealSoftwareUpdate")
    static let clearSubtitleCacheRequested = Notification.Name("clearSubtitleCacheRequested")
    /// ⌘X — 지금 보고 있는 영상에 대해 앱이 기록한 것을 전부 삭제.
    static let clearCurrentMediaDataRequested = Notification.Name("clearCurrentMediaDataRequested")
    /// 설정 창이 스크롤을 마친 뒤 업데이트 확인(check)을 트리거.
    static let performSoftwareUpdateCheck = Notification.Name("performSoftwareUpdateCheck")
}

struct ExternalMediaOpenRequest {
    let url: String
    let displayTitle: String?
}

private enum PendingExternalMediaOpenStore {
    static let appDomain = "com.dost.app"
    static let urlKey = "24dost.pendingExternalMediaOpen.url"
    static let titleKey = "24dost.pendingExternalMediaOpen.title"
    static let titleFileURL = URL(fileURLWithPath: "/tmp/24dost.pendingExternalMediaOpen.title")

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appDomain) ?? .standard
    }

    static func persistedTitle() -> String? {
        let defaultsTitle = defaults.string(forKey: titleKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let defaultsTitle, !defaultsTitle.isEmpty {
            return defaultsTitle
        }
        guard let fileTitle = try? String(contentsOf: titleFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !fileTitle.isEmpty else {
            return nil
        }
        return fileTitle
    }

    static func persistTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: titleKey)
            try? trimmed.write(to: titleFileURL, atomically: true, encoding: .utf8)
        } else {
            defaults.removeObject(forKey: titleKey)
            try? FileManager.default.removeItem(at: titleFileURL)
        }
        defaults.synchronize()
    }
}

// MARK: - Recents (최근 재생)

/// UserDefaults 에 저장되는 최근 재생 항목. LRU (신규/중복 시 맨 위로), 최대 10개.
/// 이미지 / remux 임시 / 임시 원격 스트림은 기록 대상이 아님 — 호출부에서 필터링.
struct RecentItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case file, fileGroup, url }
    let kind: Kind
    /// file: 절대 경로, url: 사용자 입력 원본 URL 문자열
    let value: String
    let addedAt: Date
    /// URL 항목에 보강해서 표시할 제목. nil 이면 기본 URL 축약 표시.
    var title: String?
    /// fileGroup: 재생 순서대로 저장된 절대 경로 목록. 단일 file/url 에서는 nil.
    var paths: [String]?

    var id: String {
        if kind == .fileGroup, let paths, !paths.isEmpty {
            return "\(kind.rawValue)|\(paths.joined(separator: "\n"))"
        }
        return "\(kind.rawValue)|\(value)"
    }

    /// 메뉴에 표시할 이름.
    ///   파일 → lastPathComponent
    ///   URL → "▶︎ " 접두어 + title 또는 scheme 제거된 URL
    var displayName: String {
        switch kind {
        case .file:
            return URL(fileURLWithPath: value).lastPathComponent
        case .fileGroup:
            let groupPaths = paths ?? [value]
            let firstName = URL(fileURLWithPath: groupPaths.first ?? value).lastPathComponent
            let extraCount = max(0, groupPaths.count - 1)
            if extraCount > 0 {
                return "\(firstName) (+\(extraCount))"
            }
            return firstName
        case .url:
            let prefix = "▶︎ "
            var s = value
            if s.hasPrefix("https://") { s.removeFirst(8) }
            else if s.hasPrefix("http://")  { s.removeFirst(7) }
            if let t = title, !t.isEmpty {
                let total = 50
                let titleMax = max(1, total - prefix.count)
                return prefix + RecentItem.middleEllipsis(t, max: titleMax)
            }
            let maxLen = 60
            if s.count > maxLen {
                let keep = maxLen - 1
                let headLen = keep / 2
                let tailLen = keep - headLen
                let head = s.prefix(headLen)
                let tail = s.suffix(tailLen)
                s = "\(head)…\(tail)"
            }
            return prefix + s
        }
    }

    /// 문자열을 최대 `max` 글자 이내로 자르되 초과 시 가운데를 … 로 대체.
    /// grapheme cluster 단위(`.count`)로 세므로 한글/이모지 안전.
    static func middleEllipsis(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let keep = max - 1  // … 한 글자
        let headLen = keep / 2
        let tailLen = keep - headLen
        return "\(s.prefix(headLen))…\(s.suffix(tailLen))"
    }
}

@MainActor
final class RecentsStore: ObservableObject {
    @Published private(set) var items: [RecentItem] = []

    private let key = "24dost.recents.v1"
    private let maxCount = 10

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RecentItem].self, from: data) else {
            return
        }
        items = Array(decoded.prefix(maxCount))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func addFile(_ url: URL) {
        push(RecentItem(kind: .file, value: url.path, addedAt: Date(), title: nil))
    }

    func addFileGroup(_ urls: [URL]) {
        let paths = urls.map(\.path)
        guard let first = paths.first else { return }
        push(RecentItem(kind: .fileGroup, value: first, addedAt: Date(), title: nil, paths: paths))
    }

    func addURL(_ urlString: String, title: String? = nil) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        push(RecentItem(
            kind: .url,
            value: trimmed,
            addedAt: Date(),
            title: (normalizedTitle?.isEmpty == false) ? normalizedTitle : nil
        ))
    }

    /// 누락된 파일을 리스트에서 제거. 클릭 시 파일 존재 확인 실패 경로에서 호출.
    func remove(kind: RecentItem.Kind, value: String) {
        let before = items.count
        items.removeAll { $0.kind == kind && $0.value == value }
        if items.count != before { persist() }
    }

    func clear() {
        items.removeAll()
        persist()
    }

    func moveToFront(_ item: RecentItem) {
        push(RecentItem(
            kind: item.kind,
            value: item.value,
            addedAt: Date(),
            title: item.title,
            paths: item.paths
        ))
    }

    private func push(_ item: RecentItem) {
        // LRU 재삽입 시 동일 (kind, value) 엔트리에 title 이 이미 있었으면 이어받기.
        var toInsert = item
        if toInsert.title == nil,
           let existing = items.first(where: { $0.id == item.id }),
           let oldTitle = existing.title, !oldTitle.isEmpty {
            toInsert.title = oldTitle
        }
        items.removeAll { $0.id == item.id }
        items.insert(toInsert, at: 0)
        if items.count > maxCount { items = Array(items.prefix(maxCount)) }
        persist()
    }
}

@main
struct DostApp: App {
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var recents = RecentsStore()

    var body: some Scene {
        // 재생 창은 하나만 쓴다. 여분의 창은 AppDelegate 가 즉시 닫는다 (enforceSingle...).
        //
        // 이 앱은 창을 여러 개 띄울 수 있는 구조가 아니다. 키 입력은 NSEvent 로컬 모니터로
        // 받는데 그게 창이 아니라 **앱 단위**라 창마다 설치된 모니터가 모든 키를 다 받고,
        // 파일 열기 요청도 알림 방송이라 모든 창이 같이 받아 전부 같은 영상으로 갈아탄다.
        // 최근 항목·재생 위치·자막 설정도 전부 앱 단위다.
        //
        // Scene 을 Window 로 바꾸면 구조적으로 막히지만, 그렇게 하니 앱이 아예 뜨지
        // 않았다(크래시 없이 조용히 종료). WindowGroup 을 그대로 두고 여분만 닫는다.
        // **WindowGroup 이 아니라 Window** — 재생 창은 구조적으로 하나만 존재한다.
        //
        // WindowGroup 이면 Finder 에서 파일을 열 때마다 SwiftUI 가 창을 새로 만든다.
        // 이 앱은 창이 여럿인 걸 감당하지 못한다: 키 입력을 받는 NSEvent 로컬 모니터가
        // 창이 아니라 **앱 단위**라 창마다 달린 모니터가 모든 키를 다 받고, 파일 열기도
        // 알림 방송이라 모든 창이 같은 영상으로 갈아탄다. ⌘W 도 어느 창을 닫는지 엉킨다.
        // 나중에 생긴 창을 닫는 방식도 시도했지만, SwiftUI 가 닫은 창을 즉시 되살려
        // 닫기/되살리기가 무한히 반복됐다. 그래서 창 생성 자체를 막는다.
        Window("24DOST", id: "player-window") {
            // .onOpenURL 을 달면 안 된다. 그걸 다는 순간 이 씬이 "파일 열기를 내가
            // 처리한다"고 선언하는 셈이라, Finder 에서 파일을 열 때마다 SwiftUI 가 창을
            // 하나씩 새로 만든다 — 창이 여럿이면 앱 단위인 키 모니터와 알림 방송 때문에
            // 컨트롤이 뒤엉킨다. 파일 열기는 AppDelegate.application(_:open:) 이 받아
            // 알림으로 뿌리므로, 열려 있던 창이 그대로 새 영상으로 갈아탄다.
            ContentView()
                .environmentObject(recents)
        }
        .windowStyle(.hiddenTitleBar)
        // 이게 없으면 이전 실행의 "창 닫힘" 상태가 복원되어, 창이 하나도 없는 채로 떠서
        // applicationShouldTerminateAfterLastWindowClosed 로 앱이 즉시 조용히 종료된다.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        Window("Settings", id: "settings-window") {
            SettingsWindowView()
        }
        .defaultSize(width: 640, height: 444)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .openFileRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open URL…") {
                    NotificationCenter.default.post(name: .openURLRequested, object: nil)
                }
                .keyboardShortcut("u", modifiers: .command)

                Button("Playback Info") {
                    NotificationCenter.default.post(name: .openPlaybackInfoRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                // 현재 도트 이미지를 PNG로 ~/Downloads 에 저장. (미디어 미로드 시 no-op)
                Button("Export Image") {
                    NotificationCenter.default.post(name: .exportImageRequested, object: nil)
                }
                .keyboardShortcut("e", modifiers: .command)

                // 도트 이미지 내보내기(⌘E)와 같은 계열이라 ⇧⌘E 로 짝지었다.
                Button("Export Auto Subtitles as .srt") {
                    NotificationCenter.default.post(name: .exportSubtitleRequested, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Clear Data for This Video…") {
                    NotificationCenter.default.post(name: .clearCurrentMediaDataRequested, object: nil)
                }
                .keyboardShortcut("x", modifiers: .command)

                Button("Regenerate Auto Subtitles") {
                    NotificationCenter.default.post(name: .regenerateSubtitleRequested, object: nil)
                }

                Divider()

                // Open Recent — 최대 10개, LRU. Clear History 로 리스트 삭제.
                Menu("Open Recent") {
                    if recents.items.isEmpty {
                        Button("No Recent Items") {}.disabled(true)
                    } else {
                        ForEach(recents.items) { item in
                            Button(item.displayName) {
                                NotificationCenter.default.post(
                                    name: .openRecentRequested,
                                    object: nil,
                                    userInfo: [
                                        "kind":  item.kind.rawValue,
                                        "value": item.value,
                                        "paths": item.paths ?? [],
                                        "title": item.title ?? ""
                                    ]
                                )
                            }
                        }
                        Divider()
                        Button("Clear History") { recents.clear() }
                    }
                }

                Divider()

                // 재생 창은 타이틀바를 숨겨 쓰기 때문에 SwiftUI 가 File > Close 를 붙여주지
                // 않는다. 창을 여러 개 띄웠을 때 하나만 닫을 방법이 없어서 직접 넣는다.
                // keyWindow 우선 — 설정 창이 앞이면 설정 창이 닫힌다.
                Button("Close Window") {
                    let target = NSApp.keyWindow ?? NSApp.mainWindow
                    // 설정 창이 앞이면 그것만 닫는다. 재생 창은 하나뿐이라 닫는 것 = 앱 종료.
                    // (마지막 창이 닫혀도 앱이 살아남게 해 뒀으므로 직접 종료시켜야 한다.)
                    if let target, AppDelegate.isSettingsWindow(target) {
                        target.performClose(nil)
                    } else {
                        NSApp.terminate(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // macOS 표준 설정 메뉴 위치 (App Menu)에 배치
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: "settings-window")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Background Styles") {
                    NotificationCenter.default.post(name: .cycleBackgroundStyle, object: nil)
                }
                .keyboardShortcut("b", modifiers: [])

                Button("Always on Top") {
                    NotificationCenter.default.post(name: .toggleAlwaysOnTop, object: nil)
                }
                .keyboardShortcut("t", modifiers: [])
            }

            CommandGroup(after: .windowSize) {
                Button("Half Video Size") {
                    NotificationCenter.default.post(name: .resizeToHalfVideoSize, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomWindowOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomWindowIn, object: nil)
                }
                .keyboardShortcut("=", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("settings-window")

    static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier == settingsWindowIdentifier
    }

    static func isPlaybackWindow(_ window: NSWindow) -> Bool {
        !isSettingsWindow(window) && window.contentView != nil
    }

    /// 유일한 재생 창.
    static weak var primaryPlaybackWindow: NSWindow?

    /// 재생 창을 다시 화면에 올린다.
    ///
    /// Window 씬은 실행 중에 파일 열기 요청을 받으면 창을 화면 밖으로 내려버린다
    /// (내용은 멀쩡히 새 영상으로 갈아탄 상태다). 그대로 두면 창이 사라진 것처럼 보이고,
    /// 마지막 창이 닫힌 것으로 쳐서 앱이 종료되기까지 한다. 그래서 다시 올려준다.
    @MainActor
    static func presentPlaybackWindow() {
        let window = primaryPlaybackWindow
            ?? NSApplication.shared.windows.first { isPlaybackWindow($0) && !$0.title.isEmpty }
        guard let window else { return }
        primaryPlaybackWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// 닫아도 되는 "진짜" 재생 창인지. isPlaybackWindow 는 스타일 적용용이라 느슨해서
    /// (설정창이 아니고 contentView 만 있으면 참) 시스템 보조 창까지 걸릴 수 있다.
    /// 창을 **닫는** 판단에는 이 엄격한 쪽만 쓴다.


    @MainActor
    static func applyStyleToCurrentWindowIfNeeded() {
        if let window = NSApplication.shared.keyWindow
            ?? NSApplication.shared.mainWindow
            ?? NSApplication.shared.windows.first(where: isPlaybackWindow) {
            guard isPlaybackWindow(window) else { return }
            applyStyle(window)
        }
        applyStyleToAllWindows()
    }

    @MainActor
    static func applyStyleToAllWindows() {
        for window in NSApplication.shared.windows where isPlaybackWindow(window) {
            applyStyle(window)
        }
    }

    static func queueExternalMediaOpenRequest(_ request: ExternalMediaOpenRequest) {
        let defaults = PendingExternalMediaOpenStore.defaults
        defaults.set(request.url, forKey: PendingExternalMediaOpenStore.urlKey)
        if let displayTitle = request.displayTitle, !displayTitle.isEmpty {
            PendingExternalMediaOpenStore.persistTitle(displayTitle)
        } else if let existingTitle = PendingExternalMediaOpenStore.persistedTitle() {
            PendingExternalMediaOpenStore.persistTitle(existingTitle)
        } else {
            PendingExternalMediaOpenStore.persistTitle(nil)
        }
        defaults.synchronize()
    }

    static func pendingExternalMediaOpenRequest() -> ExternalMediaOpenRequest? {
        let defaults = PendingExternalMediaOpenStore.defaults
        defaults.synchronize()
        guard let url = defaults.string(forKey: PendingExternalMediaOpenStore.urlKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else {
            return nil
        }
        let displayTitle = PendingExternalMediaOpenStore.persistedTitle()
        return ExternalMediaOpenRequest(
            url: url,
            displayTitle: (displayTitle?.isEmpty == false) ? displayTitle : nil
        )
    }

    static func pendingExternalDisplayTitle() -> String? {
        PendingExternalMediaOpenStore.persistedTitle()
    }

    static func clearPendingExternalMediaOpenRequest() {
        let defaults = PendingExternalMediaOpenStore.defaults
        defaults.removeObject(forKey: PendingExternalMediaOpenStore.urlKey)
        PendingExternalMediaOpenStore.persistTitle(nil)
        defaults.synchronize()
    }

    static func postExternalMediaOpenRequest(_ request: ExternalMediaOpenRequest) {
        var userInfo: [String: Any] = ["url": request.url]
        if let displayTitle = request.displayTitle {
            userInfo["displayTitle"] = displayTitle
        }
        NotificationCenter.default.post(
            name: .externalOpenMediaURL,
            object: nil,
            userInfo: userInfo
        )
    }

    @discardableResult
    static func deliverPendingExternalMediaOpenRequestIfPossible() -> Bool {
        guard NSApp.windows.first?.contentView != nil,
              let request = pendingExternalMediaOpenRequest() else {
            return false
        }
        Task { @MainActor in
            applyStyleToCurrentWindowIfNeeded()
        }
        clearPendingExternalMediaOpenRequest()
        postExternalMediaOpenRequest(request)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: Self.isPlaybackWindow) else { return }
            window.delegate = self
            Self.primaryPlaybackWindow = window
            Self.applyStyle(window)
            // 매 실행마다 480x320으로 시작. 창은 화면 중앙에 배치.
            let size = CGSize(width: 480, height: 320)
            if let screen = NSScreen.main {
                let sf = screen.visibleFrame
                let origin = CGPoint(
                    x: sf.minX + (sf.width  - size.width)  / 2,
                    y: sf.minY + (sf.height - size.height) / 2
                )
                window.setFrame(CGRect(origin: origin, size: size), display: true, animate: false)
            } else {
                window.setContentSize(size)
                window.center()
            }
            _ = Self.deliverPendingExternalMediaOpenRequestIfPossible()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Self.applyStyleToAllWindows()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                Self.applyStyleToAllWindows()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow, Self.isPlaybackWindow(window) {
            Self.applyStyle(window)
        }
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           Self.isPlaybackWindow(window),
           let cv = window.contentView {
            cv.layer?.backgroundColor = .clear
            cv.layer?.cornerRadius = 32
            cv.layer?.masksToBounds = true
            
            // 시스템 ThemeFrame(최상위 뷰)에 그려지는 1px 테두리(글로우)가 튀어나오지 못하도록 강제 클리핑
            if let themeFrame = cv.superview {
                themeFrame.wantsLayer = true
                themeFrame.layer?.cornerRadius = 32
                themeFrame.layer?.masksToBounds = true
            }
        }
        // hasShadow=false 재확인 (시스템이 덮어쓸 수 있음)
        if let window = notification.object as? NSWindow {
            window.hasShadow = false
        }
    }

    static func restoreSettingsWindowStyle(_ window: NSWindow) {
        window.identifier = settingsWindowIdentifier
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.hasShadow = true
        window.collectionBehavior.remove(.fullScreenPrimary)

        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        observeSettingsWindowResizeIfNeeded(window)
        repositionSettingsWindowButtons(window)
        DispatchQueue.main.async {
            repositionSettingsWindowButtons(window)
        }

        if let cv = window.contentView {
            cv.wantsLayer = true
            cv.layer?.backgroundColor = NSColor.clear.cgColor
            cv.layer?.cornerRadius = 0
            cv.layer?.masksToBounds = false

            if let themeFrame = cv.superview {
                themeFrame.wantsLayer = true
                themeFrame.layer?.cornerRadius = 0
                themeFrame.layer?.masksToBounds = false
            }
        }
    }

    // 타이틀바가 다시 레이아웃될 때(리사이즈 등) 시스템이 신호등 버튼을 기본 위치로 되돌리므로,
    // 창 크기가 바뀔 때마다 우리 위치를 다시 적용한다. 설정 창은 SwiftUI가 delegate를 쥐고 있어
    // delegate 대신 알림으로 관찰한다.
    private static weak var observedSettingsWindow: NSWindow?
    private static var settingsWindowResizeObserver: NSObjectProtocol?

    private static func observeSettingsWindowResizeIfNeeded(_ window: NSWindow) {
        guard observedSettingsWindow !== window else { return }
        if let observer = settingsWindowResizeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        observedSettingsWindow = window
        settingsWindowResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            repositionSettingsWindowButtons(window)
        }
    }

    private static func repositionSettingsWindowButtons(_ window: NSWindow) {
        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let minimizeButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton),
            let titlebarView = closeButton.superview
        else { return }

        let closeFrame = closeButton.frame
        let minimizeOffset = minimizeButton.frame.minX - closeFrame.minX
        let zoomOffset = zoomButton.frame.minX - closeFrame.minX
        let leftInset: CGFloat = 17
        let topInset: CGFloat = 20
        let targetY: CGFloat

        if titlebarView.isFlipped {
            targetY = topInset
        } else {
            targetY = titlebarView.bounds.height - topInset - closeFrame.height
        }

        closeButton.setFrameOrigin(NSPoint(x: leftInset, y: targetY))
        minimizeButton.setFrameOrigin(NSPoint(x: leftInset + minimizeOffset, y: targetY))
        zoomButton.setFrameOrigin(NSPoint(x: leftInset + zoomOffset, y: targetY))
    }

    static func applyStyle(_ window: NSWindow) {
        guard isPlaybackWindow(window) else { return }
        // .titled를 유지해야 키보드(엔터, 스페이스바 등) 이벤트와 키 윈도우 포커스가 정상 작동합니다.
        // .closable 은 넣지 않는다. 넣으면 AppKit 이 File 메뉴에 Close / Close All 을
        // 끼워 넣는데, 그것들은 창을 내리기만 해서 창 없이 앱만 살아 있는 상태가 된다.
        // ⌘W 는 Close Window 명령이 직접 종료시키므로 .closable 이 필요 없다.
        var newStyleMask: NSWindow.StyleMask = [.titled, .fullSizeContentView, .resizable]
        if window.styleMask.contains(.fullScreen) {
            newStyleMask.insert(.fullScreen)
        }
        // 반복적인 styleMask 덮어쓰기 방지 (풀스크린 전환 중 충돌 방지)
        if window.styleMask != newStyleMask {
            window.styleMask = newStyleMask
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // 섀도우 연관 글로우가 강제 재생성되는 것을 방지하기 위해 비동기로 한 번 더 섀도우를 끕니다.
        DispatchQueue.main.async {
            window.hasShadow = false
            window.invalidateShadow()
        }
        window.isMovableByWindowBackground = false

        // 트래픽 라이트 버튼 숨기기
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        // 전체화면 토글 활성화
        window.collectionBehavior = [.fullScreenPrimary]

        if let cv = window.contentView {
            cv.wantsLayer = true
            cv.layer?.backgroundColor = .clear
            cv.layer?.cornerRadius = 32
            cv.layer?.masksToBounds = true
            
            // 시스템 ThemeFrame(최상위 뷰)에 그려지는 1px 테두리(글로우)가 튀어나오지 못하도록 강제 클리핑
            if let themeFrame = cv.superview {
                themeFrame.wantsLayer = true
                themeFrame.layer?.cornerRadius = 32
                themeFrame.layer?.masksToBounds = true
            }
        }
    }

    static func injectedMediaURL(from incomingURL: URL) -> ExternalMediaOpenRequest? {
        guard incomingURL.scheme?.lowercased() == "24dost" else { return nil }
        guard let components = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "url" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        let displayTitle = components.queryItems?.first(where: { $0.name == "title" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ExternalMediaOpenRequest(
            url: value,
            displayTitle: (displayTitle?.isEmpty == false) ? displayTitle : nil
        )
    }

    static func mediaOpenRequest(from value: String, displayTitle: String?) -> ExternalMediaOpenRequest? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        if let incomingURL = URL(string: trimmedValue),
           let injectedRequest = injectedMediaURL(from: incomingURL) {
            return injectedRequest
        }
        let normalizedTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExternalMediaOpenRequest(
            url: trimmedValue,
            displayTitle: (normalizedTitle?.isEmpty == false) ? normalizedTitle : nil
        )
    }

    static func handleIncomingURLs(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        let mediaRequests = urls.compactMap(Self.injectedMediaURL(from:))

        guard !fileURLs.isEmpty || !mediaRequests.isEmpty else { return }

        let post: () -> Void = {
            // 창을 다시 화면에 올린다. 두 번(즉시 + 조금 뒤) 하는 건 SwiftUI 가 이벤트를
            // 처리하면서 한 번 더 내려버리는 타이밍이 있기 때문.
            for delay in [0.0, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { presentPlaybackWindow() }
                }
            }
            if !fileURLs.isEmpty {
                NotificationCenter.default.post(
                    name: .externalOpenURLs,
                    object: nil,
                    userInfo: ["urls": fileURLs]
                )
            }
            for request in mediaRequests {
                queueExternalMediaOpenRequest(request)
                _ = deliverPendingExternalMediaOpenRequestIfPossible()
            }
        }

        if NSApp.windows.first?.contentView != nil {
            post()
        } else {
            // 콜드 기동: ContentView 가 onReceive 등록을 마칠 때까지 한 틱 대기.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: post)
        }
    }

    /// 여기서 true 를 주면 안 된다. Window 씬은 파일 열기 때 창을 잠깐 내리는데,
    /// 그 순간을 "마지막 창이 닫혔다"고 보고 앱이 통째로 종료돼 버린다.
    /// 사용자가 직접 닫는 경우(⌘W)는 Close Window 명령이 직접 종료시킨다.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 종료 직전에 돌려야 하는 정리. ContentView 가 등록한다 — 저장에 필요한 상태가 거기 있다.
    static var willTerminateCleanup: (() -> Void)?

    /// **모든 종료 경로가 여기를 지난다** — ⌘Q, ⌘W(Close Window), 좌상단 도트, Dock 종료.
    /// SwiftUI 의 onDisappear 는 앱이 꺼질 때 도는 게 보장되지 않아서, 정리를 거기에만
    /// 두면 생성한 자막 캐시와 재생 위치를 잃는다.
    func applicationWillTerminate(_ notification: Notification) {
        Self.willTerminateCleanup?()
    }

    /// Dock 아이콘 클릭 등으로 되돌아왔을 때 창이 내려가 있으면 다시 올린다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.presentPlaybackWindow() }
        return true
    }

    /// Finder "Open With…" / 파일 더블클릭 / `open` 커맨드 / 커스텀 URL 스킴 진입점.
    /// 파일 URL 은 플레이리스트 로직으로, 앱 전용 스킴은 직접 재생 가능한 미디어 URL 문자열로 브로드캐스트한다.
    /// 앱 기동 중이면 `applicationDidFinishLaunching` 이후 ContentView 가 observer 를
    /// 등록하기 전일 수 있어, 짧게 딜레이 후 post.
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.handleIncomingURLs(urls)
    }
}
