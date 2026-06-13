import Foundation

struct SubtitleCue {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleLoader {
    /// 영상과 같은 이름의 .srt/.smi 파일을 찾는다.
    /// movie.mp4 → movie.srt 우선, movie.ko.srt처럼 언어 코드가 붙어도 인식.
    static func load(for videoURL: URL) -> [SubtitleCue] {
        let folder = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = contents
            .filter { ["srt", "smi"].contains($0.pathExtension.lowercased()) }
            .filter { $0.lastPathComponent.hasPrefix(baseName) }
            .sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }

        for url in candidates {
            guard let text = readText(url) else { continue }
            let cues = url.pathExtension.lowercased() == "smi" ? parseSMI(text) : parseSRT(text)
            if !cues.isEmpty { return cues }
        }
        return []
    }

    /// 한국어 자막은 CP949 인코딩이 흔해서 UTF-8 → UTF-16 → CP949 순으로 시도
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let cp949 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
            )
        )
        for encoding in [String.Encoding.utf8, .utf16, cp949] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }

    // MARK: - SRT

    static func parseSRT(_ raw: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timeIndex].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = parseTimestamp(parts[0]),
                  let end = parseTimestamp(parts[1]) else { continue }
            let body = stripTags(lines[(timeIndex + 1)...].joined(separator: "\n"))
            if !body.isEmpty {
                cues.append(SubtitleCue(start: start, end: end, text: body))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:23,456" 또는 "00:01:23.456"
    static func parseTimestamp(_ string: String) -> Double? {
        let cleaned = string.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    // MARK: - SMI (SAMI)

    static func parseSMI(_ raw: String) -> [SubtitleCue] {
        guard let regex = try? NSRegularExpression(
            pattern: "<SYNC\\s+Start\\s*=\\s*\"?(\\d+)[^>]*>",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))

        var cues: [SubtitleCue] = []
        for (index, match) in matches.enumerated() {
            guard let ms = Double(ns.substring(with: match.range(at: 1))) else { continue }
            let bodyStart = match.range.location + match.range.length
            let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
            let body = stripTags(ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart)))
            let start = ms / 1000
            // 다음 SYNC가 이 자막의 끝. (빈 SYNC는 자막을 지우는 용도)
            let end = index + 1 < matches.count
                ? (Double(ns.substring(with: matches[index + 1].range(at: 1))) ?? ms) / 1000
                : start + 5
            if !body.isEmpty, end > start {
                cues.append(SubtitleCue(start: start, end: end, text: body))
            }
        }
        return cues
    }

    /// HTML 태그 제거: <br>은 줄바꿈으로, 엔티티는 복원
    static func stripTags(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: "<br\\s*/?>", with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\""]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
