import Foundation
import Security
import SwiftUI
import Translation

// MARK: - Protocol

enum TranslatorError: LocalizedError {
    case missingAPIKey
    case httpError(Int, String)
    case badResponse
    case unavailablePair(String, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Claude API 키가 설정되지 않았습니다. 설정 → Subtitles 에서 입력하세요."
        case .httpError(let code, let body):
            return "번역 API 오류 (\(code)): \(body)"
        case .badResponse:
            return "번역 응답을 해석하지 못했습니다."
        case .unavailablePair(let from, let to):
            return "\(from) → \(to) 번역을 지원하지 않습니다."
        }
    }
}

/// 자막 줄 번역. 앞뒤 문맥을 함께 넘길 수 있어야 대명사·존댓말·화자 톤이 이어진다.
protocol SubtitleTranslating: Sendable {
    /// - Parameters:
    ///   - lines: 이번에 번역할 줄들 (순서 유지, 같은 개수로 반환)
    ///   - context: 바로 앞에 나온 원문 줄들 (오래된 것부터). 문맥용이며 번역 대상 아님.
    func translate(lines: [String],
                   context: [String],
                   from source: Locale.Language,
                   to target: Locale.Language) async throws -> [String]
}

enum TranslationBackend: String, CaseIterable, Identifiable {
    case apple
    case claude

    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple:  return "Apple"
        case .claude: return "Claude"
        }
    }
}

// MARK: - Apple Translation

/// `TranslationSession` 은 SwiftUI 의 `.translationTask` 수정자를 통해서만 만들 수 있다.
/// 백그라운드 파이프라인에서 쓰려면 뷰가 만들어 준 세션을 여기 담아 두고 기다리는 다리가 필요하다.
/// ContentView 가 `AppleTranslationHost` 를 숨겨 놓고 세션을 여기로 넘겨준다.
@MainActor
final class AppleTranslationBridge: ObservableObject {
    static let shared = AppleTranslationBridge()

    @Published fileprivate(set) var configuration: TranslationSession.Configuration?

    private var session: TranslationSession?
    private var sessionKey: String?
    /// 세션을 기다리는 쪽들. 전부 MainActor 위에서만 만져지므로 경쟁 조건은 없다.
    private var waiters: [UUID: CheckedContinuation<TranslationSession?, Never>] = [:]

    /// 뷰가 세션을 못 만들어 주는 경우(지원하지 않는 언어쌍, 모델 미설치 등)
    /// 영원히 기다리면 자막 파이프라인 전체가 멈춘다. 그래서 반드시 만료시킨다.
    private let sessionTimeout: Duration = .seconds(10)

    private func key(_ from: Locale.Language, _ to: Locale.Language) -> String {
        "\(from.maximalIdentifier)->\(to.maximalIdentifier)"
    }

    /// 요청한 언어쌍의 세션을 얻는다. 없으면 configuration 을 바꿔 뷰가 새로 만들도록 유도하고 기다린다.
    /// 제한 시간 안에 못 받으면 nil — 호출자는 번역을 포기하고 원문을 쓴다.
    func session(from: Locale.Language, to: Locale.Language) async -> TranslationSession? {
        let wanted = key(from, to)
        if let session, sessionKey == wanted { return session }

        // 언어쌍이 바뀌면 기존 세션을 버리고 새 configuration 을 게시한다.
        session = nil
        sessionKey = wanted
        configuration = TranslationSession.Configuration(source: from, target: to)

        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.sessionTimeout ?? .seconds(10))
                // 이미 adopt 로 깨어났다면 removeValue 가 nil 이라 이중 resume 이 나지 않는다.
                self?.waiters.removeValue(forKey: id)?.resume(returning: nil)
            }
        }
    }

    /// 뷰에서 세션이 준비되면 호출.
    func adopt(_ newSession: TranslationSession) {
        session = newSession
        let pending = waiters
        waiters.removeAll()
        for (_, w) in pending { w.resume(returning: newSession) }
    }

    /// 언어쌍을 바꿀 때 뷰가 세션을 다시 만들도록 강제.
    func invalidate() {
        session = nil
        sessionKey = nil
        configuration?.invalidate()
    }
}

/// ContentView 어딘가에 크기 0으로 심어 두는 뷰. 실제 UI는 없다.
struct AppleTranslationHost: View {
    @ObservedObject var bridge: AppleTranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .translationTask(bridge.configuration) { session in
                bridge.adopt(session)
            }
    }
}

struct AppleTranslator: SubtitleTranslating {
    func translate(lines: [String],
                   context: [String],
                   from source: Locale.Language,
                   to target: Locale.Language) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        // Apple 번역은 줄 단위 독립 번역이라 context 는 쓰지 않는다.
        guard let session = await AppleTranslationBridge.shared.session(from: source, to: target) else {
            throw TranslatorError.unavailablePair(
                source.languageCode?.identifier ?? "?",
                target.languageCode?.identifier ?? "?"
            )
        }
        let requests = lines.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)
        // 응답 순서가 보장되지 않을 수 있으므로 clientIdentifier 로 되돌린다.
        var byIndex: [Int: String] = [:]
        for r in responses {
            if let idStr = r.clientIdentifier, let idx = Int(idStr) {
                byIndex[idx] = r.targetText
            }
        }
        return lines.indices.map { byIndex[$0] ?? lines[$0] }
    }
}

// MARK: - Claude

/// Anthropic Messages API 직접 호출. 앞 대사 몇 줄을 문맥으로 함께 넘겨
/// 대명사·존댓말·화자 톤이 이어지도록 한다.
struct ClaudeTranslator: SubtitleTranslating {
    let model: String
    let apiKey: String

    /// 프롬프트 캐시를 살리려면 이 문자열이 요청마다 바이트 단위로 동일해야 한다.
    private static let systemPrompt = """
    You translate subtitles for a video player. You will be given numbered lines of \
    transcribed speech and must return the same numbered lines, translated.

    Rules:
    - Return exactly the same number of lines, with the same numbering, and nothing else. \
    No preamble, no notes, no explanation, no XML or internal tags.
    - Translate line by line, but read all the lines together first: they are consecutive \
    speech from the same scene. Keep pronouns, politeness level, and speaker voice consistent \
    across lines and consistent with the preceding context you are given.
    - Keep each line short enough to read as a subtitle. Prefer natural spoken phrasing over \
    literal wording.
    - The input is automatic speech recognition output, so it may contain small errors. Translate \
    the intended meaning; do not transcribe the error.
    - If a line is only filler, noise, or untranslatable, return it unchanged.
    - Never merge or split lines. Line N of the output must correspond to line N of the input.
    """

    func translate(lines: [String],
                   context: [String],
                   from source: Locale.Language,
                   to target: Locale.Language) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        guard !apiKey.isEmpty else { throw TranslatorError.missingAPIKey }

        let sourceName = Self.languageName(source)
        let targetName = Self.languageName(target)

        var userText = "Translate from \(sourceName) to \(targetName).\n\n"
        if !context.isEmpty {
            userText += "Preceding lines, for context only — do NOT translate these:\n"
            userText += context.map { "- \($0)" }.joined(separator: "\n")
            userText += "\n\n"
        }
        userText += "Lines to translate:\n"
        userText += lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "system": [[
                "type": "text",
                "text": Self.systemPrompt,
                "cache_control": ["type": "ephemeral"]
            ]],
            "messages": [["role": "user", "content": userText]]
        ]
        // Claude 5 계열은 확장 사고가 기본으로 켜져 있어 자막 번역에는 과하다.
        // (Haiku 4.5 는 파라미터를 생략하면 사고 없이 동작한다.)
        if model.hasPrefix("claude-sonnet-5") || model.hasPrefix("claude-opus-5") {
            body["thinking"] = ["type": "disabled"]
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslatorError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TranslatorError.httpError(http.statusCode, String(text.prefix(300)))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw TranslatorError.badResponse
        }
        // refusal 등으로 본문이 비어 있을 수 있다 — 그때는 원문을 그대로 쓴다.
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { return lines }

        return Self.parseNumbered(text, expecting: lines)
    }

    /// "1. …" 형태를 파싱. 개수가 안 맞으면 단순 줄분할로, 그래도 안 맞으면 원문을 돌려준다.
    /// (자막이 통째로 밀려 보이는 것보다 원문이 보이는 편이 낫다.)
    static func parseNumbered(_ text: String, expecting lines: [String]) -> [String] {
        var byIndex: [Int: String] = [:]
        var lastIndex: Int? = nil
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let match = line.range(of: #"^(\d+)[.)]\s*"#, options: .regularExpression) {
                let numStr = line[line.startIndex..<match.upperBound]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .)"))
                if let n = Int(numStr), n >= 1, n <= lines.count {
                    byIndex[n - 1] = String(line[match.upperBound...])
                    lastIndex = n - 1
                    continue
                }
            }
            // 번호 없는 이어지는 줄은 직전 항목에 붙인다 (줄바꿈된 자막).
            if let last = lastIndex, let existing = byIndex[last] {
                byIndex[last] = existing + " " + line
            }
        }
        if byIndex.count == lines.count {
            return lines.indices.map { byIndex[$0] ?? lines[$0] }
        }

        let plain = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if plain.count == lines.count { return plain }

        // 부분적으로라도 얻은 건 쓰고 나머지는 원문 유지.
        return lines.indices.map { byIndex[$0] ?? lines[$0] }
    }

    static func languageName(_ language: Locale.Language) -> String {
        let id = language.maximalIdentifier
        return Locale(identifier: "en").localizedString(forIdentifier: id)
            ?? language.languageCode?.identifier
            ?? id
    }
}

// MARK: - API key storage (Keychain)

enum ClaudeAPIKeyStore {
    private static let service = "com.dost.app"
    private static let account = "anthropic-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return delete() }
        guard let data = trimmed.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static var hasKey: Bool { load() != nil }
}
