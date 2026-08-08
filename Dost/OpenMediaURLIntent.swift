import AppIntents
import Foundation

struct OpenMediaURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Media URL"
    static var description = IntentDescription("Opens a directly playable media URL in 24dost.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    var url: String

    @Parameter(title: "Display Title")
    var displayTitle: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$url) with title \(\.$displayTitle)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .result() }
        let normalizedTitle = displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle: String?
        if let normalizedTitle, !normalizedTitle.isEmpty {
            fallbackTitle = normalizedTitle
        } else {
            fallbackTitle = AppDelegate.pendingExternalDisplayTitle()
        }
        guard let request = AppDelegate.mediaOpenRequest(from: value, displayTitle: fallbackTitle) else {
            return .result()
        }
        AppDelegate.queueExternalMediaOpenRequest(request)
        if !AppDelegate.deliverPendingExternalMediaOpenRequestIfPossible() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                _ = AppDelegate.deliverPendingExternalMediaOpenRequestIfPossible()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                _ = AppDelegate.deliverPendingExternalMediaOpenRequestIfPossible()
            }
        }

        return .result()
    }
}

struct DostShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMediaURLIntent(),
            phrases: [
                "Open media URL in \(.applicationName)",
                "Play media URL in \(.applicationName)"
            ],
            shortTitle: "Open Media URL",
            systemImageName: "link"
        )
    }
}
