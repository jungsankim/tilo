import Foundation

/// AVFoundation 미디어 선택 그룹을 비전문가용 UI에 표시하기 위한 가벼운 모델.
struct MediaTrackOption: Identifiable, Equatable {
    let index: Int
    let name: String
    let languageTag: String?
    let propertyListData: Data?

    var id: Int { index }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "트랙 \(index + 1)")
            : trimmed
    }

    var projectReference: ProjectTrackReference {
        ProjectTrackReference(
            propertyListData: propertyListData,
            index: index,
            languageTag: languageTag,
            name: name
        )
    }
}

/// 외부 자막과 내장 자막을 한 선택 메뉴에서 다루기 위한 상태.
enum SubtitleTrackSelection: Hashable {
    case automatic
    case off
    case external
    case embedded(Int)

    var persistenceKey: String {
        switch self {
        case .automatic: return "automatic"
        case .off: return "off"
        case .external: return "external"
        case .embedded(let index): return "embedded:\(index)"
        }
    }

    init?(persistenceKey: String) {
        switch persistenceKey {
        case "automatic": self = .automatic
        case "off": self = .off
        case "external": self = .external
        default:
            guard persistenceKey.hasPrefix("embedded:"),
                  let index = Int(persistenceKey.dropFirst("embedded:".count)),
                  index >= 0
            else { return nil }
            self = .embedded(index)
        }
    }
}
