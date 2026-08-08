import SwiftUI
import AppKit
import Speech

private let settingsWindowBackground = Color(nsColor: NSColor(calibratedWhite: 0.11, alpha: 1.0))
private let settingsSidebarBackground = Color(nsColor: NSColor(calibratedWhite: 0.095, alpha: 1.0))
private let settingsPanelStroke = Color.white.opacity(0.08)
private let settingsDividerColor = Color.white.opacity(0.08)
// 배경(0.07~0.11)보다 약간 밝은 비활성 텍스트, 활성 대비용 밝은 텍스트
private let settingsInactiveText = Color.white.opacity(0.30)
private let settingsRowText = Color.white.opacity(0.88)
private let settingsGroupTitleText = Color.white.opacity(0.52)
/// General 탭 Software Update 섹션의 스크롤 앵커 ID.
private let softwareUpdateScrollID = "software-update-section"

private enum SettingsFont {
    static func light(_ size: CGFloat) -> Font {
        .custom("BPdotsUnicase-Light", size: size)
    }

    static func regular(_ size: CGFloat) -> Font {
        .custom("BPdotsUnicase", size: size)
    }

    static func bold(_ size: CGFloat) -> Font {
        .custom("BPdotsUnicase-Bold", size: size)
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            AppDelegate.restoreSettingsWindowStyle(window)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0)
            window.minSize = NSSize(width: 408, height: 400)
            window.setContentSize(NSSize(
                width: max(window.frame.width, 408),
                height: 400
            ))
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            AppDelegate.restoreSettingsWindowStyle(window)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0)
            window.minSize = NSSize(width: 408, height: 400)
            window.setContentSize(NSSize(
                width: max(window.frame.width, 408),
                height: 400
            ))
        }
    }
}

struct SettingsWindowView: View {
    @State private var selectedTab: SettingsTab? = .general
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue

    private var accentColor: Color {
        AppAccentColor.choice(for: accentColorRaw).color
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case subtitles = "Subtitles"
        case shortcuts = "Shortcuts"
        case licences = "Licences"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .general:    return "gearshape.fill"
            case .subtitles:  return "captions.bubble.fill"
            case .shortcuts:  return "command"
            case .licences:   return "doc.text.fill"
            }
        }
    }
    
    var body: some View {
        ZStack {
            SettingsWindowConfigurator()

            HStack(spacing: 0) {
                sidebar
                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(width: 1)
                detailPane
            }
        }
        .frame(minWidth: 408, minHeight: 400)
        .background(settingsWindowBackground)
        .preferredColorScheme(.dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(SettingsFont.regular(16))
                            .foregroundStyle(selectedTab == tab ? accentColor : settingsInactiveText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 10)
                            .padding(.trailing, 6)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(width: 147)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(settingsSidebarBackground)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let tab = selectedTab {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.rawValue)
                        .font(SettingsFont.bold(26))
                        .foregroundStyle(accentColor)

                    Text(tab.subtitle)
                        .font(SettingsFont.light(14))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                .padding(.horizontal, 28)

                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(height: 1)
                    .padding(.top, 24)
                    .padding(.horizontal, 28)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            switch tab {
                            case .general:
                                GeneralSettingsView()
                            case .subtitles:
                                SubtitleSettingsView()
                            case .shortcuts:
                                ShortcutsSettingsView()
                            case .licences:
                                LicencesSettingsView()
                            }
                        }
                        .padding(.top, 20)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .revealSoftwareUpdate)) { _ in
                        // 대기 화면 "Update →" 클릭: General 탭으로 전환 후
                        // Software Update 섹션까지 스크롤하고, 업데이트 확인을 트리거.
                        selectedTab = .general
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(softwareUpdateScrollID, anchor: .center)
                            }
                            NotificationCenter.default.post(
                                name: .performSoftwareUpdateCheck, object: nil)
                        }
                    }
                }
            }
            .background(settingsWindowBackground)
        } else {
            ContentUnavailableView("Select a category", systemImage: "sidebar.left")
        }
    }
}

private extension SettingsWindowView.SettingsTab {
    var subtitle: String {
        switch self {
        case .subtitles:
            return "Automatic transcription and translation"
        case .general:
            return "Core app behavior and launch defaults"
        case .shortcuts:
            return "Key inputs and gestures"
        case .licences:
            return "Third-party Licenses and copyrights"
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(SettingsFont.bold(16))
                .tracking(2.4)
                .foregroundStyle(settingsGroupTitleText)

            VStack(spacing: 0) {
                content
            }
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    let caption: String?
    let content: Content
    let showDivider: Bool
    let extraVerticalPadding: CGFloat
    
    init(
        _ label: String,
        caption: String? = nil,
        showDivider: Bool = true,
        extraVerticalPadding: CGFloat = 4,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.caption = caption
        self.showDivider = showDivider
        self.extraVerticalPadding = extraVerticalPadding
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(SettingsFont.light(16))
                        .foregroundStyle(settingsRowText)
                    if let caption {
                        Text(caption)
                            .font(SettingsFont.light(12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                content
            }
            .padding(.vertical, 10 + extraVerticalPadding)

            if showDivider {
                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(height: 1)
            }
        }
    }
}

/// OS 스위치 대신 쓰는 텍스트 토글. 현재 상태 단어만 강조 (ON=accent, OFF=밝은 회색).
struct OnOffToggle: View {
    @Binding var isOn: Bool
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                Text("ON")
                    .foregroundStyle(isOn ? AppAccentColor.choice(for: accentColorRaw).color : settingsInactiveText)
                Text("/")
                    .foregroundStyle(settingsInactiveText)
                Text("OFF")
                    .foregroundStyle(isOn ? settingsInactiveText : Color.white.opacity(0.75))
            }
            .font(SettingsFont.bold(16))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct GeneralSettingsView: View {
    @AppStorage("rememberPlaybackPosition") private var rememberPlaybackPosition = false
    @AppStorage("autoResizeWindowToVideo") private var autoResizeWindowToVideo = true
    @AppStorage("adaptiveSubtitleColor") private var adaptiveSubtitleColor = true
    @AppStorage("subtitleBackdropWhilePeeking") private var subtitleBackdropWhilePeeking = false
    @AppStorage("loopMultiFilePlayback") private var loopMultiFilePlayback = false
    @AppStorage("tapToPeek") private var tapToPeek = false
    @AppStorage("preventFullscreenDisplaySleep") private var preventFullscreenDisplaySleep = false
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue
    @State private var isResetConfirmationVisible = false
    @StateObject private var updater = UpdateChecker()

    private var accentColor: Color { AppAccentColor.choice(for: accentColorRaw).color }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Behavior") {
                SettingsRow("Remember Playback Position") {
                    OnOffToggle(isOn: $rememberPlaybackPosition)
                }
                SettingsRow("Playback Loop") {
                    OnOffToggle(isOn: $loopMultiFilePlayback)
                }
                SettingsRow("Tap to Peek") {
                    OnOffToggle(isOn: $tapToPeek)
                }
                SettingsRow("Auto-resize Window to Video") {
                    OnOffToggle(isOn: $autoResizeWindowToVideo)
                }
                SettingsRow("Prevent Display Sleep in Fullscreen", showDivider: false) {
                    OnOffToggle(isOn: $preventFullscreenDisplaySleep)
                }
            }

            SettingsSection("Appearance") {
                SettingsRow("Accent Color", extraVerticalPadding: 4) {
                    HStack(spacing: 10) {
                        ForEach(AppAccentColor.allCases) { choice in
                            AccentColorSwatch(
                                choice: choice,
                                isSelected: AppAccentColor.choice(for: accentColorRaw) == choice
                            ) {
                                accentColorRaw = choice.rawValue
                            }
                        }
                    }
                }
                SettingsRow("Adaptive Subtitle Color") {
                    OnOffToggle(isOn: $adaptiveSubtitleColor)
                }
                SettingsRow("Subtitle Backdrop While Peeking", showDivider: false) {
                    OnOffToggle(isOn: $subtitleBackdropWhilePeeking)
                }
            }

            softwareUpdateSection
                .id(softwareUpdateScrollID)

            VStack(alignment: .leading, spacing: 18) {
                Text("This will permanently clear preferences, history, cache, and remembered app state. It cannot be undone.")
                    .font(SettingsFont.regular(14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        isResetConfirmationVisible.toggle()
                    } label: {
                        SettingsFooterButtonLabel(
                            title: isResetConfirmationVisible ? "Cancel" : "Reset Everything",
                            foregroundColor: .primary,
                            backgroundColor: Color.white.opacity(0.08),
                            strokeColor: settingsPanelStroke
                        )
                    }
                    .buttonStyle(.plain)

                    if isResetConfirmationVisible {
                        Button {
                            NotificationCenter.default.post(name: .resetAppStateRequested, object: nil)
                            isResetConfirmationVisible = false
                        } label: {
                            SettingsFooterButtonLabel(
                                title: "Are you sure?",
                                foregroundColor: .white,
                                backgroundColor: AppAccentColor.choice(for: accentColorRaw).color
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .performSoftwareUpdateCheck)) { _ in
            // 스크롤 완료 후 자동으로 업데이트 확인. 이후 설치는 사용자 클릭으로만 진행.
            if !updater.isBusy { updater.check() }
        }
    }

    // Inline update UI shown above the Reset block (this app has no toast
    // layer). One button whose title/action follow the checker's phase:
    // Check → Download & Install → Install & Relaunch, plus a status line.
    @ViewBuilder
    private var softwareUpdateSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(updateStatusText)
                .font(SettingsFont.regular(14))
                .foregroundStyle(updateStatusColor)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                updatePrimaryAction()
            } label: {
                SettingsFooterButtonLabel(
                    title: updateButtonTitle,
                    foregroundColor: updateButtonIsCTA ? .white : .primary,
                    backgroundColor: updateButtonIsCTA ? accentColor : Color.white.opacity(0.08),
                    strokeColor: updateButtonIsCTA ? nil : settingsPanelStroke
                )
            }
            .buttonStyle(.plain)
            .disabled(updater.isBusy)
            .opacity(updater.isBusy ? 0.6 : 1)
        }
    }

    private var updateStatusText: String {
        switch updater.postUpdateNote {
        case .success(let v)?: return "Updated to v \(v). You're on the latest version."
        case .failure?:        return "The last update didn't finish. Try checking again."
        case nil:              break
        }
        switch updater.phase {
        case .idle:                            return "You're on v \(updater.currentVersion)."
        case .checking:                        return "Checking for updates…"
        case .upToDate:                        return "You're up to date (v \(updater.currentVersion))."
        case .available(let v, _):             return "Version \(v) is available. You're on v \(updater.currentVersion)."
        case .downloading(let v):              return "Downloading v \(v)…"
        case .readyToInstall(let v, _, _, _):  return "Version \(v) is ready. 24dost will quit and reopen to finish."
        case .failed(let message):             return message
        }
    }

    private var updateStatusColor: Color {
        if case .success? = updater.postUpdateNote { return accentColor }
        switch updater.phase {
        case .available, .readyToInstall: return accentColor
        case .failed:                     return Color(red: 0.9, green: 0.36, blue: 0.36)
        default:                          return .secondary
        }
    }

    private var updateButtonTitle: String {
        switch updater.phase {
        case .checking:       return "Checking…"
        case .available:      return "Download & Install"
        case .downloading:    return "Downloading…"
        case .readyToInstall: return "Install & Relaunch"
        default:              return "Check for Update"
        }
    }

    private var updateButtonIsCTA: Bool {
        switch updater.phase {
        case .available, .readyToInstall: return true
        default:                          return false
        }
    }

    private func updatePrimaryAction() {
        switch updater.phase {
        case .available:              updater.download()
        case .readyToInstall:         updater.install()
        case .checking, .downloading: break
        default:                      updater.check()
        }
    }
}

private struct SettingsFooterButtonLabel: View {
    let title: String
    let foregroundColor: Color
    let backgroundColor: Color
    var strokeColor: Color? = nil

    var body: some View {
        Text(title)
            .font(SettingsFont.regular(14))
            .foregroundStyle(foregroundColor)
            .offset(y: -2)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay {
                if let strokeColor {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(strokeColor, lineWidth: 0.5)
                }
            }
    }
}

private struct AccentColorSwatch: View {
    let choice: AppAccentColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(choice.color)

                if isSelected {
                    Circle()
                        .stroke(Color.white, lineWidth: 0.5)
                        .padding(3)
                }
            }
            .frame(width: 22, height: 22)
            .overlay(
                Circle()
                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ShortcutItem: Identifiable {
    let id = UUID()
    let input: String
    let action: String
}

private struct ShortcutRow: View {
    let item: ShortcutItem
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Text(item.action)
                    .font(SettingsFont.light(16))
                    .foregroundStyle(settingsRowText)

                Spacer()

                Text(item.input)
                    .font(SettingsFont.regular(13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 12)

            if showDivider {
                Rectangle()
                    .fill(settingsDividerColor)
                    .frame(height: 1)
            }
        }
    }
}

struct ShortcutsSettingsView: View {
    private let generalKeyInputs: [ShortcutItem] = [
        .init(input: "Cmd + O", action: "Open file"),
        .init(input: "Cmd + U", action: "Open URL"),
        .init(input: "Cmd + I", action: "Open playback info"),
        .init(input: "Cmd + P", action: "Open subtitle file"),
        .init(input: "Cmd + E", action: "Export dot image as PNG"),
        .init(input: "Shift + Cmd + E", action: "Export auto subtitles as .srt"),
        .init(input: "Cmd + ,", action: "Open settings")
    ]

    private let playbackKeyInputs: [ShortcutItem] = [
        .init(input: "Space", action: "Play, pause, or resume last media"),
        .init(input: "Return", action: "Toggle fullscreen"),
        .init(input: "Left / Right", action: "Seek backward or forward by 10 seconds"),
        .init(input: "Shift + Left / Right", action: "Open previous or next file"),
        .init(input: ", / .", action: "Move one timeline column left or right"),
        .init(input: "0 to 9", action: "Jump to 0% through 90% of playback"),
        .init(input: "Up / Down", action: "Raise or lower volume"),
        .init(input: "W / S", action: "Increase or decrease dot size"),
        .init(input: "A / D", action: "Tighten or widen dot spacing"),
        .init(input: "Z", action: "Reset dot size and spacing"),
        .init(input: "B", action: "Background style"),
        .init(input: "T", action: "Toggle always on top"),
        .init(input: "P", action: "Cycle subtitles: off / external / embedded / auto-generated"),
        .init(input: "[ / ]", action: "Decrease or increase subtitle size"),
        .init(input: "Cmd + 0", action: "Resize video window"),
        .init(input: "Cmd + - / =", action: "Zoom window out or in")
    ]

    private let generalGestures: [ShortcutItem] = [
        .init(input: "Drop File on Window", action: "Open media or replace the current file"),
        .init(input: "Double Click", action: "Toggle fullscreen")
    ]

    private let playbackGestures: [ShortcutItem] = [
        .init(input: "Single Click", action: "Play, pause, or resume last media"),
        .init(input: "Right Click on Dots", action: "Jump to the clicked playback position"),
        .init(input: "Scroll", action: "Adjust volume"),
        .init(input: "Fullscreen Drag", action: "Adjust dot size and spacing"),
        .init(input: "Peek Dot", action: "Hold to peek, or tap-toggle when Tap to Peek is on")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("General Inputs") {
                ForEach(Array(generalKeyInputs.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < generalKeyInputs.count - 1)
                }
            }

            SettingsSection("Playback Inputs") {
                ForEach(Array(playbackKeyInputs.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < playbackKeyInputs.count - 1)
                }
            }

            SettingsSection("General Gestures") {
                ForEach(Array(generalGestures.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < generalGestures.count - 1)
                }
            }

            SettingsSection("Playback Gestures") {
                ForEach(Array(playbackGestures.enumerated()), id: \.element.id) { index, item in
                    ShortcutRow(item: item, showDivider: index < playbackGestures.count - 1)
                }
            }
        }
    }
}

struct LicencesSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.licenseText)
                .font(SettingsFont.regular(13))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 2)

            Link(Self.repositoryURL.absoluteString, destination: Self.repositoryURL)
                .font(SettingsFont.regular(13))
                .foregroundStyle(.blue)
                .padding(.top, 2)
                .padding(.leading, 2)

            Spacer()
                .frame(height: 42)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let repositoryURL = URL(string: "https://github.com/marzipan2025/24DOST")!

    private static let licenseText = """
    24dost third-party notices

    FFmpeg
    License: GPL-3.0-or-later
    Website: https://ffmpeg.org
    Bundled use: media probing, remuxing, and fallback transcoding for formats not handled directly by AVFoundation.

    FFmpeg libraries bundled in this app
    - libavdevice.62.dylib
    - libavfilter.11.dylib
    - libavformat.62.dylib
    - libavcodec.62.dylib
    - libswresample.6.dylib
    - libswscale.9.dylib
    - libavutil.60.dylib

    Additional bundled media libraries
    - libvmaf: BSD-2-Clause-Patent
    - OpenSSL 3: Apache-2.0
    - libvpx: BSD-3-Clause
    - dav1d: BSD-2-Clause
    - LAME: LGPL-2.0-or-later
    - Opus: BSD-3-Clause
    - SVT-AV1: BSD-3-Clause
    - x264: GPL-2.0-or-later
    - x265: GPL-2.0-or-later

    BPdots Unicase font family
    Copyright (c) 2007 George Triantafyllakos. All rights reserved.
    Website: http://www.backpacker.gr
    Bundled files:
    - bpdots.unicase-regular.otf
    - bpdots.unicase-light.otf
    - bpdots.unicase-bold.otf

    Apple frameworks
    This app also uses system frameworks provided by macOS, including SwiftUI, AppKit, AVFoundation, Speech, Translation, WebKit, UniformTypeIdentifiers, and Accelerate. Speech recognition and Apple translation run on device; no audio leaves your Mac.

    Anthropic Claude API
    Used only when the Claude translation engine is selected in Settings. In that mode the transcribed text of the lines being translated is sent to Anthropic's API. Audio is never sent.

    -----

    If you believe any required notice or license information is missing, need support, or would like to discuss professional collaboration related to this app, please contact us through the project repository on GitHub:
    """
}

// MARK: - Software update

// Self-contained updater against the public GitHub releases feed. A newer
// release is installed in one click: the dmg is downloaded to a temp dir and
// mounted silently (no Finder window), an "Install & Relaunch" step then lets a
// detached helper replace the running bundle in place, unmount, and relaunch —
// after which the fresh instance confirms via postUpdateNote. A process can't
// atomically replace and relaunch itself, so the copy/relaunch lives in the
// helper (the approach Sparkle's relauncher takes). State is published so the
// Settings view can render it inline (this app has no toast layer).
@MainActor
final class UpdateChecker: ObservableObject {

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, dmgURL: URL)
        case downloading(version: String)
        case readyToInstall(version: String, appSource: String, mountPoint: String, dmgPath: String)
        case failed(String)
    }

    enum PostUpdateNote: Equatable { case success(String), failure }

    @Published private(set) var phase: Phase = .idle
    // Set once at init if the installer helper relaunched us.
    @Published private(set) var postUpdateNote: PostUpdateNote?

    let currentVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

    private static let appBundleName = "24dost.app"
    static let releasesPageURL = URL(string: "https://github.com/marzipan2025/24DOST/releases")!
    private static let latestAPIURL =
        URL(string: "https://api.github.com/repos/marzipan2025/24DOST/releases/latest")!

    private enum UpdateError: Error { case mountFailed }

    init() {
        // Transient argument-domain flags set by the installer's `open --args`.
        let defaults = UserDefaults.standard
        if let version = defaults.string(forKey: "updateInstalledVersion") {
            postUpdateNote = .success(version)
        } else if defaults.bool(forKey: "updateInstallFailed") {
            postUpdateNote = .failure
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: return true
        default: return false
        }
    }

    func openReleasesPage() { NSWorkspace.shared.open(Self.releasesPageURL) }

    // MARK: Check

    func check() {
        guard !isBusy else { return }
        postUpdateNote = nil
        phase = .checking
        Task {
            guard let release = await Self.fetchLatestRelease() else {
                phase = .failed("Couldn't reach GitHub. Check your connection and try again.")
                return
            }
            let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            if Self.isNewer(latest, than: currentVersion), let dmgURL = release.dmgURL {
                phase = .available(version: latest, dmgURL: dmgURL)
            } else {
                phase = .upToDate
            }
        }
    }

    // MARK: Download + silent mount

    func download() {
        guard case let .available(version, dmgURL) = phase else { return }
        phase = .downloading(version: version)
        Task {
            do {
                let (tmp, response) = try await URLSession.shared.download(from: dmgURL)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let dmgDest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("24dost-\(version).dmg")
                try? FileManager.default.removeItem(at: dmgDest)
                try FileManager.default.moveItem(at: tmp, to: dmgDest)

                guard let mountPoint = await Self.attachDMG(at: dmgDest.path) else {
                    throw UpdateError.mountFailed
                }
                let appSource = (mountPoint as NSString).appendingPathComponent(Self.appBundleName)
                guard FileManager.default.fileExists(atPath: appSource) else {
                    _ = await Self.runProcessData("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
                    throw UpdateError.mountFailed
                }
                phase = .readyToInstall(version: version, appSource: appSource,
                                        mountPoint: mountPoint, dmgPath: dmgDest.path)
            } catch {
                phase = .failed("The update couldn't be downloaded from GitHub.")
            }
        }
    }

    // MARK: Install (detached helper → quit → replace → relaunch)

    func install() {
        guard case let .readyToInstall(version, appSource, mountPoint, dmgPath) = phase else { return }
        let dest = Bundle.main.bundlePath
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = """
        #!/bin/bash
        APP_PID="$1"; SRC="$2"; DEST="$3"; MOUNT="$4"; DMG="$5"; VERSION="$6"
        for i in $(seq 1 150); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.1; done
        OK=0
        STAGE="${DEST}.update-$$"; BACKUP="${DEST}.old-$$"
        rm -rf "$STAGE" "$BACKUP"
        if ditto "$SRC" "$STAGE"; then
          xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null
          if mv "$DEST" "$BACKUP" 2>/dev/null; then
            if mv "$STAGE" "$DEST" 2>/dev/null; then
              OK=1; rm -rf "$BACKUP"
            else
              mv "$BACKUP" "$DEST" 2>/dev/null
            fi
          fi
        fi
        rm -rf "$STAGE" 2>/dev/null
        hdiutil detach "$MOUNT" -quiet 2>/dev/null
        rm -f "$DMG" 2>/dev/null
        if [ "$OK" = "1" ]; then
          open -a "$DEST" --args -updateInstalledVersion "$VERSION"
        else
          open -a "$DEST" --args -updateInstallFailed 1
        fi
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("24dost-install.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            phase = .failed("Couldn't stage the installer. Try again.")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path, pid, appSource, dest, mountPoint, dmgPath, version]
        do { try task.run() } catch {
            phase = .failed("Couldn't launch the installer. Try again.")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: GitHub + process helpers

    /// 런칭 시 가벼운 조회용: 현재 번들보다 새 버전이 있으면 그 버전 문자열, 없으면 nil.
    static func availableUpdateVersion() async -> String? {
        guard let release = await fetchLatestRelease() else { return nil }
        let latest = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        return isNewer(latest, than: current) ? latest : nil
    }

    private struct LatestRelease { let tag: String; let dmgURL: URL? }

    private static func fetchLatestRelease() async -> LatestRelease? {
        var request = URLRequest(url: latestAPIURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String
        else { return nil }
        let assets = object["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
        let dmgURL = (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:))
        return LatestRelease(tag: tag, dmgURL: dmgURL)
    }

    // Mounts a dmg with no Finder window; returns its mount point parsed from
    // hdiutil's plist output (robust against the tab-delimited default format).
    private static func attachDMG(at path: String) async -> String? {
        let data = await runProcessData(
            "/usr/bin/hdiutil",
            ["attach", path, "-nobrowse", "-noverify", "-plist"]
        )
        guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first
    }

    private static func runProcessData(_ launchPath: String, _ args: [String]) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = args
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = Pipe()
                do { try process.run() } catch {
                    continuation.resume(returning: Data()); return
                }
                let out = outPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: out)
            }
        }
    }

    // Numeric component-wise compare ("1.1.10" > "1.1.9"); non-numeric suffixes
    // on a component (e.g. "8_t2") are treated as their leading number.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { comp in
                Int(comp.prefix { $0.isNumber }) ?? 0
            }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - Subtitles

/// 값 하나를 고르는 드롭다운. 시스템 Picker 대신 Menu 로 이 창의 톤에 맞춘다.
struct SettingsMenuPicker: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    @AppStorage(AppAccentColor.storageKey) private var accentColorRaw = AppAccentColor.defaultChoice.rawValue

    private var currentLabel: String {
        options.first { $0.value == selection }?.label ?? selection
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.label) { selection = option.value }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentLabel)
                    .font(SettingsFont.bold(16))
                    .foregroundStyle(AppAccentColor.choice(for: accentColorRaw).color)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(settingsInactiveText)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
    }
}

struct SubtitleSettingsView: View {
    @AppStorage(SubtitleDefaults.autoGenerate)     private var autoGenerate = false
    @AppStorage(SubtitleDefaults.sourceLanguage)   private var sourceLanguage = "auto"
    @AppStorage(SubtitleDefaults.targetLanguage)   private var targetLanguage = SubtitleDefaults.defaultTarget
    @AppStorage(SubtitleDefaults.backend)          private var backendRaw = TranslationBackend.apple.rawValue
    @AppStorage(SubtitleDefaults.claudeModel)      private var claudeModel = SubtitleDefaults.defaultClaudeModel
    @AppStorage(SubtitleDefaults.lookAheadSeconds) private var lookAhead = SubtitleDefaults.defaultLookAhead
    @AppStorage(AppAccentColor.storageKey)         private var accentColorRaw = AppAccentColor.defaultChoice.rawValue

    @State private var apiKeyDraft = ""
    @State private var apiKeySaved = ClaudeAPIKeyStore.hasKey
    @State private var supportedSourceLocales: [(value: String, label: String)] = [("auto", "Auto")]

    private var accentColor: Color { AppAccentColor.choice(for: accentColorRaw).color }
    private var backend: TranslationBackend { TranslationBackend(rawValue: backendRaw) ?? .apple }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection("Automatic Subtitles") {
                SettingsRow("Generate When No Subtitles Exist",
                            caption: "Transcribes the audio on this Mac and translates it, running ahead of the playhead so subtitles appear on time.") {
                    OnOffToggle(isOn: $autoGenerate)
                }
                SettingsRow("Spoken Language") {
                    SettingsMenuPicker(options: supportedSourceLocales, selection: $sourceLanguage)
                }
                SettingsRow("Translate Into") {
                    SettingsMenuPicker(options: Self.targetLanguages, selection: $targetLanguage)
                }
                SettingsRow("Look Ahead",
                            caption: "How far ahead of the playhead to keep subtitles ready.",
                            showDivider: false) {
                    HStack(spacing: 10) {
                        Text("\(Int(lookAhead))s")
                            .font(SettingsFont.bold(16))
                            .foregroundStyle(accentColor)
                            .monospacedDigit()
                        Stepper("", value: $lookAhead, in: 5...90, step: 5).labelsHidden()
                    }
                }
            }

            SettingsSection("Translation Engine") {
                SettingsRow("Engine",
                            caption: backend == .apple
                                ? "Apple's on-device translation. Offline and free, but each line is translated on its own."
                                : "Sends each batch of lines to the Claude API with the preceding lines as context, so pronouns and tone carry across.") {
                    SettingsMenuPicker(
                        options: TranslationBackend.allCases.map { ($0.rawValue, $0.label) },
                        selection: $backendRaw
                    )
                }

                if backend == .claude {
                    SettingsRow("Model") {
                        SettingsMenuPicker(options: Self.claudeModels, selection: $claudeModel)
                    }
                    SettingsRow("API Key",
                                caption: "Stored in your Keychain, never in preferences.",
                                showDivider: false) {
                        HStack(spacing: 8) {
                            SecureField(apiKeySaved ? "••••••••••••" : "sk-ant-…", text: $apiKeyDraft)
                                .textFieldStyle(.plain)
                                .font(SettingsFont.regular(13))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06),
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .frame(width: 180)

                            Button(apiKeyDraft.isEmpty && apiKeySaved ? "Clear" : "Save") {
                                if apiKeyDraft.isEmpty && apiKeySaved {
                                    ClaudeAPIKeyStore.delete()
                                    apiKeySaved = false
                                } else {
                                    apiKeySaved = ClaudeAPIKeyStore.save(apiKeyDraft)
                                    apiKeyDraft = ""
                                }
                            }
                            .font(SettingsFont.bold(15))
                            .foregroundStyle(accentColor)
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    SettingsRow("Model", showDivider: false) {
                        Text("System")
                            .font(SettingsFont.bold(16))
                            .foregroundStyle(settingsInactiveText)
                    }
                }
            }
        }
        .task { await loadSupportedLocales() }
    }

    /// 시스템이 실제로 인식할 수 있는 언어만 고르게 한다.
    private func loadSupportedLocales() async {
        let locales = await SpeechTranscriber.supportedLocales
        let display = Locale.current
        var options: [(value: String, label: String)] = [("auto", "Auto")]
        options += locales
            .map { locale -> (String, String) in
                let id = locale.identifier(.bcp47)
                return (id, display.localizedString(forIdentifier: locale.identifier) ?? id)
            }
            .sorted { $0.1 < $1.1 }
        await MainActor.run { supportedSourceLocales = options }
    }

    private static let targetLanguages: [(value: String, label: String)] = [
        ("ko", "한국어"), ("en", "English"), ("ja", "日本語"),
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"),
        ("it", "Italiano"), ("pt", "Português"), ("ru", "Русский"),
        ("ar", "العربية"), ("hi", "हिन्दी"), ("th", "ไทย"), ("vi", "Tiếng Việt")
    ]

    private static let claudeModels: [(value: String, label: String)] = [
        ("claude-haiku-4-5", "Haiku 4.5"),
        ("claude-sonnet-5",  "Sonnet 5"),
        ("claude-opus-5",    "Opus 5")
    ]
}
