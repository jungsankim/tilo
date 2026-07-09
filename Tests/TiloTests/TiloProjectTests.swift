import XCTest
@testable import Tilo

final class TiloProjectTests: XCTestCase {
    func testRoundTripPreservesProjectState() throws {
        let firstID = UUID()
        let secondID = UUID()
        let project = TiloProject(
            view: ProjectViewSettings(fillMode: false, playlistVisible: true, gridColumns: 3),
            playback: ProjectPlaybackSettings(
                progress: 0.42,
                loopEnabled: true,
                subtitlesEnabled: false,
                masterVolume: 0.75,
                relativeTimeline: true,
                abA: 0.2,
                abB: 0.6,
                soloItemID: firstID,
                zoomedItemID: secondID,
                subtitleScale: 1.4
            ),
            videos: [
                ProjectVideo(
                    id: firstID,
                    file: ProjectFileReference(
                        absolutePath: "/Videos/one.mp4",
                        relativePath: "Videos/one.mp4",
                        fileName: "one.mp4",
                        fileSize: 123
                    ),
                    isMuted: false,
                    volume: 0.8,
                    timeOffset: -0.1,
                    rotationQuarters: 1,
                    zoomScale: 1.5,
                    panX: 0.1,
                    panY: -0.2,
                    audioTrackIndex: 1,
                    audioTrackReference: ProjectTrackReference(
                        propertyListData: Data([0x01, 0x02]),
                        index: 1,
                        languageTag: "ko",
                        name: "한국어"
                    ),
                    subtitleTrackSelection: SubtitleTrackSelection.embedded(2).persistenceKey,
                    subtitleTrackReference: ProjectTrackReference(
                        propertyListData: Data([0x03, 0x04]),
                        index: 2,
                        languageTag: "en",
                        name: "English"
                    )
                ),
                ProjectVideo(
                    id: secondID,
                    file: ProjectFileReference(
                        absolutePath: "/Videos/two.mkv",
                        relativePath: "Videos/two.mkv",
                        fileName: "two.mkv",
                        fileSize: 456
                    ),
                    isMuted: true,
                    volume: 1,
                    timeOffset: 0.3,
                    rotationQuarters: 0,
                    zoomScale: 1,
                    panX: 0,
                    panY: 0
                ),
            ],
            playlist: [
                ProjectFileReference(
                    absolutePath: "/Videos/one.mp4",
                    relativePath: "Videos/one.mp4",
                    fileName: "one.mp4",
                    fileSize: 123
                ),
            ],
            swaps: [ProjectSwap(itemID: firstID, slotID: secondID)]
        )

        let data = try TiloProjectCodec.encode(project)
        let restored = try TiloProjectCodec.decode(data)

        XCTAssertEqual(restored, project)
    }

    func testRejectsFutureFormatVersion() throws {
        var project = emptyProject()
        project.formatVersion = TiloProject.currentFormatVersion + 1

        XCTAssertThrowsError(try project.validate()) { error in
            XCTAssertEqual(error as? TiloProjectError, .unsupportedVersion(2))
        }
    }

    func testRejectsDuplicateVideoIDs() throws {
        let id = UUID()
        var project = emptyProject()
        let reference = ProjectFileReference(
            absolutePath: "/one.mp4", relativePath: nil, fileName: "one.mp4", fileSize: nil
        )
        project.videos = [
            ProjectVideo(id: id, file: reference, isMuted: false, volume: 1, timeOffset: 0,
                         rotationQuarters: 0, zoomScale: 1, panX: 0, panY: 0),
            ProjectVideo(id: id,
                         file: ProjectFileReference(absolutePath: "/two.mp4", relativePath: nil,
                                                    fileName: "two.mp4", fileSize: nil),
                         isMuted: false, volume: 1, timeOffset: 0,
                         rotationQuarters: 0, zoomScale: 1, panX: 0, panY: 0),
        ]

        XCTAssertThrowsError(try project.validate()) { error in
            XCTAssertEqual(error as? TiloProjectError, .duplicateVideoID)
        }
    }

    func testVersionOneProjectWithoutTrackFieldsStillDecodes() throws {
        let original = emptyProject()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: TiloProjectCodec.encode(original)) as? [String: Any]
        )
        object["videos"] = [[
            "id": UUID().uuidString,
            "file": [
                "absolutePath": "/Videos/legacy.mp4",
                "fileName": "legacy.mp4",
            ],
            "isMuted": false,
            "volume": 1.0,
            "timeOffset": 0.0,
            "rotationQuarters": 0,
            "zoomScale": 1.0,
            "panX": 0.0,
            "panY": 0.0,
        ]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try TiloProjectCodec.decode(data)

        XCTAssertNil(decoded.videos.first?.audioTrackIndex)
        XCTAssertNil(decoded.videos.first?.audioTrackReference)
        XCTAssertNil(decoded.videos.first?.subtitleTrackSelection)
        XCTAssertNil(decoded.videos.first?.subtitleTrackReference)
    }

    func testSubtitleSelectionPersistenceKeys() {
        let selections: [SubtitleTrackSelection] = [.automatic, .off, .external, .embedded(3)]
        for selection in selections {
            XCTAssertEqual(
                SubtitleTrackSelection(persistenceKey: selection.persistenceKey),
                selection
            )
        }
        XCTAssertNil(SubtitleTrackSelection(persistenceKey: "embedded:-1"))
        XCTAssertNil(SubtitleTrackSelection(persistenceKey: "unknown"))
    }

    private func emptyProject() -> TiloProject {
        TiloProject(
            view: ProjectViewSettings(fillMode: true, playlistVisible: true, gridColumns: 0),
            playback: ProjectPlaybackSettings(
                progress: 0,
                loopEnabled: true,
                subtitlesEnabled: true,
                masterVolume: 1,
                relativeTimeline: false,
                abA: nil,
                abB: nil,
                soloItemID: nil,
                zoomedItemID: nil
            ),
            videos: [],
            playlist: [],
            swaps: []
        )
    }
}
