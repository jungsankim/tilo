import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let tiloProject = UTType(exportedAs: "com.jungsankim.tilo.project", conformingTo: .json)
}

/// 사용자가 저장하고 다시 열 수 있는 Tilo 작업 파일(.tilo)의 버전 1 모델.
/// 경로는 이동 가능한 상대 경로와 원래 절대 경로를 함께 보관한다.
struct TiloProject: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int = currentFormatVersion
    var view: ProjectViewSettings
    var playback: ProjectPlaybackSettings
    var videos: [ProjectVideo]
    var playlist: [ProjectFileReference]
    var swaps: [ProjectSwap]

    func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw TiloProjectError.unsupportedVersion(formatVersion)
        }
        let ids = videos.map(\.id)
        guard Set(ids).count == ids.count else {
            throw TiloProjectError.duplicateVideoID
        }
        let paths = videos.map { $0.file.absolutePath }
        guard Set(paths).count == paths.count else {
            throw TiloProjectError.duplicateVideoPath
        }
        guard [0, 2, 3, 4].contains(view.gridColumns) else {
            throw TiloProjectError.invalidLayout
        }
        guard playback.progress.isFinite, (0...1).contains(playback.progress),
              playback.masterVolume.isFinite, (0...1).contains(playback.masterVolume),
              (playback.subtitleScale.map { $0.isFinite && (0.5...2).contains($0) } ?? true),
              [playback.abA, playback.abB].compactMap({ $0 }).allSatisfy({
                  $0.isFinite && (0...1).contains($0)
              }),
              playback.abA == nil || playback.abB == nil || playback.abA! < playback.abB!,
              videos.allSatisfy({ video in
                  video.volume.isFinite && (0...1).contains(video.volume)
                      && video.timeOffset.isFinite
                      && (0..<4).contains(video.rotationQuarters)
                      && video.zoomScale.isFinite && (1...6).contains(video.zoomScale)
                      && video.panX.isFinite && video.panY.isFinite
                      && (video.audioTrackIndex.map { $0 >= 0 } ?? true)
                      && (video.audioTrackReference.map { $0.index >= 0 } ?? true)
                      && (video.subtitleTrackReference.map { $0.index >= 0 } ?? true)
                      && (video.subtitleTrackSelection.flatMap(
                          SubtitleTrackSelection.init(persistenceKey:)
                      ) != nil || video.subtitleTrackSelection == nil)
                      && [video.abA, video.abB].compactMap({ $0 }).allSatisfy({
                          $0.isFinite && (0...1).contains($0)
                      })
                      && (video.abA == nil || video.abB == nil || video.abA! < video.abB!)
              })
        else {
            throw TiloProjectError.invalidPlaybackState
        }
    }
}

struct ProjectViewSettings: Codable, Equatable {
    var fillMode: Bool
    var playlistVisible: Bool
    /// 0 = 자동 모자이크, 2/3/4 = 고정 그리드
    var gridColumns: Int
}

struct ProjectPlaybackSettings: Codable, Equatable {
    var progress: Double
    var loopEnabled: Bool
    var subtitlesEnabled: Bool
    var masterVolume: Double
    var relativeTimeline: Bool
    var abA: Double?
    var abB: Double?
    var soloItemID: UUID?
    var zoomedItemID: UUID?
    /// nil이면 이전 프로젝트이므로 현재 앱의 기본값을 사용한다.
    var subtitleScale: Double? = nil
}

struct ProjectVideo: Codable, Equatable {
    var id: UUID
    var file: ProjectFileReference
    var isMuted: Bool
    var volume: Double
    var timeOffset: Double
    var rotationQuarters: Int
    var zoomScale: Double
    var panX: Double
    var panY: Double
    /// nil은 파일 기본 오디오. 선택값은 같은 파일 안에서의 트랙 순서다.
    var audioTrackIndex: Int? = nil
    /// Apple 미디어 선택 식별자와 사람이 읽을 수 있는 fallback을 함께 저장한다.
    var audioTrackReference: ProjectTrackReference? = nil
    /// 이전 프로젝트와 호환되도록 선택 키를 optional 문자열로 보관한다.
    var subtitleTrackSelection: String? = nil
    var subtitleTrackReference: ProjectTrackReference? = nil
    /// 개별 영상 A-B 구간반복 지점 (자기 길이의 비율). 이전 프로젝트에는 없다.
    var abA: Double? = nil
    var abB: Double? = nil
}

struct ProjectTrackReference: Codable, Equatable {
    /// AVMediaSelectionOption.propertyList()를 binary plist로 직렬화한 값.
    var propertyListData: Data?
    /// 변환으로 식별자가 바뀔 때 사용할 형식 내 상대 순서.
    var index: Int
    var languageTag: String?
    var name: String?
}

struct ProjectFileReference: Codable, Equatable, Hashable {
    var absolutePath: String
    var relativePath: String?
    var fileName: String
    var fileSize: Int64?
}

struct ProjectSwap: Codable, Equatable {
    var itemID: UUID
    var slotID: UUID
}

enum TiloProjectError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case duplicateVideoID
    case duplicateVideoPath
    case invalidLayout
    case invalidPlaybackState

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return String(localized: "지원하지 않는 프로젝트 버전입니다 (버전 \(version))")
        case .duplicateVideoID, .duplicateVideoPath:
            return String(localized: "프로젝트에 중복된 영상 정보가 있습니다")
        case .invalidLayout, .invalidPlaybackState:
            return String(localized: "프로젝트 설정이 올바르지 않습니다")
        }
    }
}

enum TiloProjectCodec {
    static func encode(_ project: TiloProject) throws -> Data {
        try project.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(project)
    }

    static func decode(_ data: Data) throws -> TiloProject {
        let project = try JSONDecoder().decode(TiloProject.self, from: data)
        try project.validate()
        return project
    }
}
