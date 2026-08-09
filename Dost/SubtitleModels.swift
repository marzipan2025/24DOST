import Foundation

// MARK: - Cue

/// 자막 한 줄. 외부 파일(.srt/.smi)에서 파싱된 것과 엔진이 생성한 것 모두 같은 타입을 쓴다.
/// 자막을 만든 창 길이의 등급. 높을수록 긴 창 — 경계(콜드 스타트)가 적다.
enum SubtitleTier {
    static let urgent  = 0   // 60초  — 재생 위치에 준비된 게 없어 급히 만든 것
    static let relaxed = 1   // 180초 — 앞서 달리며 여유롭게 만든 것
    static let fine    = 2   // 600초 — 할 일이 없을 때 다시 만든 것
    static let max     = fine
}

struct SubtitleCue: Equatable, Sendable, Codable {
    let start: TimeInterval
    let end: TimeInterval
    /// 화면에 표시할 텍스트. 번역이 끝났으면 번역문, 아직이면 원문.
    var text: String
    /// 인식된 원문. 번역 전이거나 번역이 필요 없으면 text 와 동일.
    var sourceText: String
    /// 어느 길이의 창으로 만들어졌는지. 다시 만들면 올라간다.
    /// 0 = 60초(급했을 때), 1 = 180초, 2 = 600초. 진단용 색 표시에 쓴다.
    var tier: Int

    init(start: TimeInterval, end: TimeInterval, text: String,
         sourceText: String? = nil, tier: Int = SubtitleTier.relaxed) {
        self.start = start
        self.end = end
        self.text = text
        self.sourceText = sourceText ?? text
        self.tier = tier
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(TimeInterval.self, forKey: .start)
        end = try c.decode(TimeInterval.self, forKey: .end)
        text = try c.decode(String.self, forKey: .text)
        sourceText = try c.decodeIfPresent(String.self, forKey: .sourceText) ?? text
        if let t = try c.decodeIfPresent(Int.self, forKey: .tier) {
            tier = t
        } else {
            // 옛 캐시: isCoarse 불리언만 있었다.
            let coarse = try c.decodeIfPresent(Bool.self, forKey: .isCoarse) ?? false
            tier = coarse ? SubtitleTier.urgent : SubtitleTier.relaxed
        }
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, text, sourceText, tier, isCoarse
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(text, forKey: .text)
        try c.encode(sourceText, forKey: .sourceText)
        try c.encode(tier, forKey: .tier)
    }
}

// MARK: - Cue lookup

extension Array where Element == SubtitleCue {
    /// 시작시간 오름차순으로 정렬돼 있다고 가정하고 주어진 시각의 큐를 이진 탐색.
    /// 겹치는 큐가 있으면 가장 먼저 시작한 것을 돌려준다.
    func cue(at seconds: TimeInterval) -> SubtitleCue? {
        guard !isEmpty else { return nil }
        var lo = 0
        var hi = count - 1
        var candidate: Int? = nil
        // start <= seconds 인 마지막 인덱스를 찾는다.
        while lo <= hi {
            let mid = (lo + hi) / 2
            if self[mid].start <= seconds {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard let idx = candidate else { return nil }
        // 앞쪽으로 몇 개만 훑어 종료시간이 살아있는 큐를 찾는다(겹침 대비).
        var i = idx
        while i >= 0, i > idx - 4 {
            if seconds < self[i].end { return self[i] }
            i -= 1
        }
        return nil
    }

    /// 정렬 상태를 유지하며 삽입. 같은 start 가 이미 있으면 교체한다.
    mutating func insertSorted(_ cue: SubtitleCue) {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].start < cue.start { lo = mid + 1 } else { hi = mid }
        }
        if lo < count, abs(self[lo].start - cue.start) < 0.001 {
            self[lo] = cue
        } else {
            insert(cue, at: lo)
        }
    }
}

// MARK: - Parsing (.srt / .smi)

enum SubtitleFile {

    static let supportedExtensions: Set<String> = ["srt", "smi", "vtt"]

    /// 파일에서 큐를 읽는다. 확장자에 따라 파서를 고르고, 인코딩은 자동 판별.
    static func parse(url: URL) -> [SubtitleCue]? {
        guard let raw = readText(url: url) else { return nil }
        let cues: [SubtitleCue]
        switch url.pathExtension.lowercased() {
        case "srt", "vtt": cues = parseSRT(raw)
        case "smi":        cues = parseSMI(raw)
        default:           return nil
        }
        return cues.isEmpty ? nil : cues
    }

    /// UTF-8 → CP949 → EUC-KR → Latin-1 순으로 시도. SMI 는 주로 CP949/EUC-KR.
    static func readText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        let cp949 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
        if cp949 != kCFStringEncodingInvalidId,
           let s = String(data: data, encoding: String.Encoding(rawValue: cp949)) {
            return s
        }
        let eucKr = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))
        if eucKr != kCFStringEncodingInvalidId,
           let s = String(data: data, encoding: String.Encoding(rawValue: eucKr)) {
            return s
        }
        return String(data: data, encoding: .isoLatin1)
    }

    static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let raw = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // 타임스탬프 라인 위치: 보통 0 또는 1 (인덱스 번호가 있는 경우)
            var tsIdx = -1
            for (i, line) in lines.enumerated() where line.contains("-->") { tsIdx = i; break }
            guard tsIdx >= 0 else { continue }
            let tsLine = lines[tsIdx]
            guard let arrow = tsLine.range(of: "-->") else { continue }
            let startStr = String(tsLine[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let endTail  = String(tsLine[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            // 종료 측엔 WebVTT 스타일 정보가 붙을 수 있어 첫 토큰만 사용
            let endStr = endTail.split(separator: " ", maxSplits: 1).first.map(String.init) ?? endTail
            guard let start = parseTimestamp(startStr),
                  let end   = parseTimestamp(endStr),
                  end > start else { continue }
            var body = lines.dropFirst(tsIdx + 1).joined(separator: "\n")
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// `HH:MM:SS,mmm` / `HH:MM:SS.mmm` / `MM:SS.mmm` 를 초로.
    static func parseTimestamp(_ s: String) -> TimeInterval? {
        let unified = s.replacingOccurrences(of: ",", with: ".")
        let parts = unified.split(separator: ":")
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        default:
            return nil
        }
    }

    /// SAMI(.smi) 파서. `<SYNC Start=NNN>` 블록을 시간 순으로 추출.
    /// `&nbsp;` 단일/`<P>` 빈 블록은 "자막 지우기" 마커로 이전 큐를 종료시킨다.
    /// 복수 언어가 있으면 첫 `<P>` 언어를 사용 (KRCC/ENCC 등).
    static func parseSMI(_ text: String) -> [SubtitleCue] {
        let pattern = #"<SYNC\s+Start\s*=\s*(\d+)[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        struct Event { let time: TimeInterval; let bodyRange: NSRange }
        var events: [Event] = []
        events.reserveCapacity(matches.count)
        for (i, m) in matches.enumerated() {
            guard m.numberOfRanges >= 2 else { continue }
            guard let ms = Int(ns.substring(with: m.range(at: 1))) else { continue }
            let bodyStart = m.range.location + m.range.length
            let bodyEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            events.append(Event(time: TimeInterval(ms) / 1000.0,
                                bodyRange: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))))
        }

        var cues: [SubtitleCue] = []
        for i in 0..<events.count {
            let e = events[i]
            let cleaned = cleanSMIChunk(ns.substring(with: e.bodyRange))
            let nextTime = (i + 1 < events.count) ? events[i + 1].time : (e.time + 10.0)
            if cleaned.isEmpty {
                // 클리어 마커: 이전 cue 가 이 시점을 넘어 지속되도록 기록됐다면 잘라준다.
                if let last = cues.last, last.end > e.time {
                    cues[cues.count - 1] = SubtitleCue(start: last.start, end: e.time, text: last.text)
                }
                continue
            }
            cues.append(SubtitleCue(start: e.time, end: nextTime, text: cleaned))
        }
        return cues
    }

    private static func cleanSMIChunk(_ chunk: String) -> String {
        var s = chunk
        // 첫 <P ...> 이후만 사용 (SYNC 블록 선두의 공백/주석 제거)
        if let r = s.range(of: "<P[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...])
        }
        // 블록 닫는 태그에서 잘라냄
        if let r = s.range(of: "</(SYNC|BODY|SAMI)>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        }
        // 다른 언어용 <P> 블록이 이어지면 첫 언어만 사용
        if let r = s.range(of: "<P[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeHTMLEntities(s)
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var s = input
        let pairs: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
            ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'")
        ]
        for (k, v) in pairs {
            s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
        }
        // 수치 엔티티 &#NNN;
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: (s as NSString).length))
            var result = s
            // 뒤에서부터 치환해 range shift 를 피한다.
            for m in matches.reversed() {
                guard m.numberOfRanges >= 2 else { continue }
                let numStr = (result as NSString).substring(with: m.range(at: 1))
                guard let code = UInt32(numStr), let scalar = Unicode.Scalar(code) else { continue }
                result = (result as NSString).replacingCharacters(in: m.range, with: String(scalar))
            }
            s = result
        }
        return s
    }

    // MARK: Writing

    /// 큐 배열을 SRT 문자열로. 생성된 자막을 사이드카로 캐시할 때 사용.
    static func srtString(from cues: [SubtitleCue]) -> String {
        var out = ""
        for (i, cue) in cues.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))\n"
            out += cue.text + "\n\n"
        }
        return out
    }

    private static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let ms = Int(((clamped - Double(total)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, min(999, ms))
    }
}
