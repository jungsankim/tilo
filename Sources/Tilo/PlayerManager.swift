import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

/// 전역 진행률을 별도 모델로 분리해서, 0.25초마다 그리드 전체가 아니라
/// 이 모델을 구독하는 슬라이더만 다시 그려지게 한다
final class PlaybackProgress: ObservableObject {
    @Published var fraction: Double = 0
}

final class VideoItem: Identifiable, ObservableObject {
    private final class SubtitleBridge: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
        weak var owner: VideoItem?

        func legibleOutput(
            _ output: AVPlayerItemLegibleOutput,
            didOutputAttributedStrings strings: [NSAttributedString],
            nativeSampleBuffers: [Any],
            forItemTime itemTime: CMTime
        ) {
            let text = strings.map(\.string).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            owner?.receiveEmbeddedSubtitle(text.isEmpty ? nil : text)
        }

        func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
            owner?.receiveEmbeddedSubtitle(nil)
        }
    }

    let id: UUID
    /// 실제 재생 URL (MKV 변환본일 수 있음)
    let url: URL
    /// 원본 파일 — 표시 이름, 자막 탐색, 중복 판정에 쓴다
    let sourceURL: URL
    let backendKind: PlaybackBackendKind
    let player: AVPlayer
    let mpvEngine: MPVPlaybackEngine?

    var usesMPV: Bool { backendKind == .libmpv && mpvEngine != nil }

    /// 사용자가 설정한 음소거 (솔로가 켜져 있으면 솔로가 우선한다)
    @Published var isMuted: Bool = false {
        didSet { muteChanged?() }
    }
    var muteChanged: (() -> Void)?

    /// 영상의 실제 화면비(가로/세로). 로드 전에는 16:9로 가정한다.
    @Published var aspect: CGFloat = 16.0 / 9.0
    /// 회전 메타데이터를 반영한 원본 픽셀 크기와 명목 프레임률.
    @Published var pixelSize: CGSize = .zero
    @Published var nominalFrameRate: Float = 0
    @Published var hasAudio = false
    @Published private(set) var mediaOptionsLoaded = false
    @Published private(set) var audioTrackOptions: [MediaTrackOption] = []
    @Published private(set) var subtitleTrackOptions: [MediaTrackOption] = []
    @Published private(set) var externalSubtitleName: String?

    /// nil은 파일의 기본 오디오를 사용한다.
    @Published var selectedAudioTrackIndex: Int? = nil {
        didSet {
            guard selectedAudioTrackIndex != oldValue else { return }
            if mediaOptionsLoaded { restoredAudioTrackReference = nil }
            applyAudioTrackSelection()
            trackSelectionChanged?()
        }
    }

    /// 자동은 외부 자막을 우선하고, 없으면 영상의 기본 내장 자막을 사용한다.
    @Published var subtitleTrackSelection: SubtitleTrackSelection = .automatic {
        didSet {
            guard subtitleTrackSelection != oldValue else { return }
            if mediaOptionsLoaded { restoredSubtitleTrackReference = nil }
            currentSubtitle = nil
            applyEmbeddedSubtitles()
            refreshTimeObserver()
            if usesExternalSubtitles {
                updateSubtitle(at: player.currentTime().seconds)
            }
            trackSelectionChanged?()
        }
    }

    /// 동기화 재생 시 이 영상만 앞뒤로 미세 정렬하는 오프셋(초). 비교용.
    @Published var timeOffset: Double = 0

    /// 개별 볼륨 (0...1). 전역 볼륨과 곱해져 실제 볼륨이 된다.
    @Published var volume: Double = 1 {
        didSet { muteChanged?() }
    }

    /// 90° 단위 회전 (0, 1, 2, 3 = 0°, 90°, 180°, 270°)
    @Published var rotationQuarters: Int = 0

    /// 타일 내부 리프레임: 확대 배율(1 = 원본)과 중심 이동(타일 크기 대비 비율)
    @Published var zoomScale: CGFloat = 1
    @Published var panOffset: CGSize = .zero

    var isReframed: Bool { zoomScale > 1.001 || panOffset != .zero }

    func resetReframe() {
        zoomScale = 1
        panOffset = .zero
    }

    /// 회전을 반영한 표시 화면비
    var displayAspect: CGFloat {
        rotationQuarters % 2 == 0 ? aspect : 1 / aspect
    }

    /// 이 영상의 개별 재생 진행률 (0...1)
    @Published var progress: Double = 0
    /// 개별 A-B 구간반복 지점 (이 영상 길이의 비율). 둘 다 설정되면 활성.
    @Published var abA: Double? { didSet { applyEngineABLoop() } }
    @Published var abB: Double? { didSet { applyEngineABLoop() } }

    /// mpv는 네이티브 ab-loop가 프레임 단위로 반복을 처리하므로
    /// 매니저의 주기 감시(0.25초 간격)가 손댈 필요가 없다.
    var usesNativeABLoop: Bool { mpvEngine != nil && durationSeconds > 0 }

    /// mpv 엔진에 A-B 구간을 초 단위로 반영한다. 복원 직후처럼 길이를 아직
    /// 모르면 아무것도 하지 않고, 길이가 확정될 때 다시 불린다.
    func applyEngineABLoop() {
        guard let mpvEngine else { return }
        let dur = durationSeconds
        if let a = abA, let b = abB, dur > 0 {
            mpvEngine.setABLoop(a: a * dur, b: b * dur)
        } else {
            mpvEngine.setABLoop(a: nil, b: nil)
        }
    }
    /// 코덱 미지원 등으로 재생에 실패하면 셀에 안내를 띄운다
    @Published var loadFailed = false
    @Published var mediaReady = false
    /// 현재 시각에 표시할 자막 (외부 파일과 내장 트랙 모두 같은 오버레이 사용)
    @Published var currentSubtitle: String?
    var isScrubbing = false
    /// 시크 직후에는 이전 재생 시각 콜백이 늦게 도착해 진행률을 되돌릴 수 있어,
    /// 이 시각까지는 시간 콜백의 진행률 갱신을 무시한다.
    private var progressHoldUntil: TimeInterval = 0
    private var lastSeekTarget: Double?
    private var lastSeekAt: TimeInterval = 0

    /// 최근에 요청한 시크가 아직 목표 지점에 도달하지 못한 상태.
    /// 정밀 시크는 파일에 따라 1초 넘게 걸릴 수 있어, 그 사이 드리프트 보정이
    /// 새 시크를 겹쳐 걸면 재생이 계속 끊기며 기어가는 것처럼 보인다.
    var seekSettling: Bool {
        guard let lastSeekTarget else { return false }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSeekAt < 2.0 else { return false }
        return abs(currentTimeSeconds - lastSeekTarget) > 0.3
    }
    var loopEnabled = true {
        didSet { mpvEngine?.setLooping(loopEnabled) }
    }
    /// 루프 복귀 시 적용할 재생 속도 (상대 타임라인 모드에서 영상별로 다름)
    var rateProvider: (() -> Float)?
    /// 프로젝트 복원처럼 재생 준비 완료 시 후속 동작이 필요할 때 사용한다.
    var readyChanged: (() -> Void)? {
        didSet {
            // 작은 로컬 파일은 stage()가 콜백을 연결하기 전에 준비가 끝날 수 있다.
            // 다음 run loop로 넘겨 item이 manager.items에 들어간 뒤 길이를 계산한다.
            if mediaReady {
                DispatchQueue.main.async { [weak self] in self?.readyChanged?() }
            }
        }
    }
    var durationChanged: (() -> Void)? {
        didSet {
            if durationSeconds > 0 {
                DispatchQueue.main.async { [weak self] in self?.durationChanged?() }
            }
        }
    }
    var playbackFailed: (() -> Void)? {
        didSet {
            if loadFailed {
                DispatchQueue.main.async { [weak self] in self?.playbackFailed?() }
            }
        }
    }
    var trackSelectionChanged: (() -> Void)?

    var subtitlesEnabled = true {
        didSet {
            if usesMPV {
                applyEmbeddedSubtitles()
                if !subtitlesEnabled { currentSubtitle = nil }
                return
            }
            applyEmbeddedSubtitles()
            if !subtitlesEnabled { currentSubtitle = nil }
            refreshTimeObserver()
        }
    }

    /// 시크바가 보이는 동안만 진행률을 발행해서 불필요한 뷰 갱신을 줄인다
    var progressActive = false {
        didSet {
            guard progressActive != oldValue else { return }
            if progressActive { publishProgressNow() }
            refreshTimeObserver()
        }
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusCancellable: AnyCancellable?
    private var durationCancellable: AnyCancellable?
    private var appliedResolutionCap: CGSize = .zero
    private var assetDurationSeconds: Double = 0
    private var subtitleCues: [SubtitleCue] = []
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?
    private var restoredAudioTrackReference: ProjectTrackReference?
    private var restoredSubtitleTrackReference: ProjectTrackReference?
    private let legibleOutput = AVPlayerItemLegibleOutput()
    private let subtitleBridge = SubtitleBridge()

    init(
        id: UUID = UUID(),
        url: URL,
        sourceURL: URL? = nil,
        audioTrackIndex: Int? = nil,
        audioTrackReference: ProjectTrackReference? = nil,
        subtitleSelection: SubtitleTrackSelection = .automatic,
        subtitleTrackReference: ProjectTrackReference? = nil,
        backendKind requestedBackend: PlaybackBackendKind = .avFoundation
    ) {
        self.id = id
        self.url = url
        self.sourceURL = sourceURL ?? url
        if requestedBackend == .libmpv, let engine = MPVPlaybackEngine(url: url) {
            self.backendKind = .libmpv
            self.mpvEngine = engine
            self.player = AVPlayer()
        } else {
            self.backendKind = .avFoundation
            self.mpvEngine = nil
            self.player = AVPlayer(url: url)
        }
        self.restoredAudioTrackReference = audioTrackReference
        self.restoredSubtitleTrackReference = subtitleTrackReference
        self.selectedAudioTrackIndex = audioTrackIndex
        self.subtitleTrackSelection = subtitleSelection
        if usesMPV {
            configureMPVCallbacks()
            mpvEngine?.start()
            return
        }

        player.actionAtItemEnd = .pause
        // 내장 자막도 SwiftUI 오버레이로 받아 외부 자막과 같은 크기 설정을 적용한다.
        subtitleBridge.owner = self
        legibleOutput.suppressesPlayerRendering = true
        legibleOutput.setDelegate(subtitleBridge, queue: .main)
        player.currentItem?.add(legibleOutput)
        // 충분히 버퍼링될 때까지 기다려 스톨(끊김)을 줄인다
        player.automaticallyWaitsToMinimizeStalling = true
        // 네트워크(NAS/SMB) 파일은 대역폭을 여러 스트림이 나눠 쓰므로,
        // 순간적인 정체를 흡수하도록 미리 더 많이 버퍼링한다.
        // 로컬 파일은 기본값(0=자동)으로 둬서 메모리를 아낀다.
        if Self.isNetworkURL(url) {
            player.currentItem?.preferredForwardBufferDuration = 10
        }
        loadAspect()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.loopEnabled else { return }
            self.player.seek(to: .zero)
            self.player.playImmediately(atRate: self.rateProvider?() ?? 1)
        }
        statusCancellable = player.currentItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .failed {
                    self?.loadFailed = true
                    self?.playbackFailed?()
                }
                if status == .readyToPlay {
                    self?.mediaReady = true
                    self?.readyChanged?()
                }
            }
        durationCancellable = player.currentItem?.publisher(for: \.duration)
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in self?.durationChanged?() }
        loadMediaOptions()
    }

    private func configureMPVCallbacks() {
        guard let engine = mpvEngine else { return }
        engine.onReady = { [weak self] in
            guard let self else { return }
            self.syncMPVMetadata()
            self.mediaReady = true
            self.loadFailed = false
            self.readyChanged?()
        }
        engine.onFailure = { [weak self] _ in
            guard let self else { return }
            self.loadFailed = true
            self.playbackFailed?()
        }
        engine.onDurationChanged = { [weak self] in
            guard let self else { return }
            self.syncMPVMetadata()
            // 프로젝트 복원처럼 길이를 모른 채 A-B가 설정된 경우 지금 반영한다
            self.applyEngineABLoop()
            self.durationChanged?()
        }
        engine.onMetadataChanged = { [weak self] in
            self?.syncMPVMetadata()
        }
        engine.onTimeChanged = { [weak self] seconds in
            guard let self, self.progressActive, self.acceptsTimeUpdates,
                  self.durationSeconds > 0 else { return }
            let fraction = min(max(seconds / self.durationSeconds, 0), 1)
            if abs(fraction - self.progress) > 0.0001 { self.progress = fraction }
        }
        engine.onTracksChanged = { [weak self] tracks in
            guard let self else { return }
            let audio = tracks.filter { $0.kind == .audio }.map {
                MediaTrackOption(
                    index: $0.order,
                    name: $0.title ?? $0.language ?? "",
                    languageTag: $0.language,
                    propertyListData: nil
                )
            }
            let subtitles = tracks.filter { $0.kind == .subtitle }.map {
                MediaTrackOption(
                    index: $0.order,
                    name: $0.title ?? $0.language ?? "",
                    languageTag: $0.language,
                    propertyListData: nil
                )
            }
            self.audioTrackOptions = audio
            self.subtitleTrackOptions = subtitles
            self.hasAudio = !audio.isEmpty
            if let reference = self.restoredAudioTrackReference,
               let resolved = Self.resolve(reference, in: audio) {
                self.selectedAudioTrackIndex = resolved
            }
            if case .embedded = self.subtitleTrackSelection,
               let reference = self.restoredSubtitleTrackReference,
               let resolved = Self.resolve(reference, in: subtitles) {
                self.subtitleTrackSelection = .embedded(resolved)
            }
            self.mediaOptionsLoaded = true
            self.applyAudioTrackSelection()
            self.applyEmbeddedSubtitles()
        }
        engine.setLooping(loopEnabled)
        engine.setSubtitlesEnabled(subtitlesEnabled)
    }

    private func syncMPVMetadata() {
        guard let engine = mpvEngine else { return }
        assetDurationSeconds = engine.durationSeconds
        pixelSize = engine.pixelSize
        nominalFrameRate = engine.nominalFrameRate
        hasAudio = engine.hasAudio
        if engine.pixelSize.width > 0, engine.pixelSize.height > 0 {
            aspect = engine.pixelSize.width / engine.pixelSize.height
        }
    }

    deinit {
        if !usesMPV, let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var durationSeconds: Double {
        if let mpvEngine { return mpvEngine.durationSeconds }
        if let duration = player.currentItem?.duration.seconds,
           duration.isFinite, duration > 0 {
            return duration
        }
        return assetDurationSeconds
    }

    var currentTimeSeconds: Double {
        mpvEngine?.currentTimeSeconds ?? player.currentTime().seconds
    }

    func play(rate: Float) {
        if let mpvEngine {
            mpvEngine.play(rate: rate)
        } else {
            player.playImmediately(atRate: rate)
        }
    }

    func pause() {
        if let mpvEngine {
            mpvEngine.pause()
        } else {
            player.pause()
        }
    }

    func seek(toSeconds seconds: Double, exact: Bool = true) {
        progressHoldUntil = Date().timeIntervalSinceReferenceDate + 0.35
        lastSeekTarget = max(seconds, 0)
        lastSeekAt = Date().timeIntervalSinceReferenceDate
        if let mpvEngine {
            mpvEngine.seek(to: seconds, exact: exact)
        } else {
            let tolerance: CMTime = exact ? .zero : .positiveInfinity
            player.seek(
                to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600),
                toleranceBefore: tolerance,
                toleranceAfter: tolerance
            )
        }
    }

    func stepFrames(_ count: Int) {
        if let mpvEngine {
            mpvEngine.stepFrames(count)
        } else {
            player.currentItem?.step(byCount: count)
        }
    }

    func applyOutputAudio(muted: Bool, volume: Double) {
        if let mpvEngine {
            mpvEngine.setMuted(muted)
            mpvEngine.setVolume(volume)
        } else {
            if player.isMuted != muted { player.isMuted = muted }
            let floatVolume = Float(volume)
            if abs(player.volume - floatVolume) > 0.0001 { player.volume = floatVolume }
        }
    }

    func setSubtitleScale(_ scale: Double) {
        mpvEngine?.setSubtitleScale(scale)
    }

    func seek(to fraction: Double) {
        let duration = durationSeconds
        guard duration > 0 else { return }
        seek(toSeconds: fraction * duration, exact: !isScrubbing)
        progress = fraction
    }

    /// 스크럽 중이거나 방금 시크한 직후에는 시간 콜백이 진행률을 덮어쓰지 않게 한다
    private var acceptsTimeUpdates: Bool {
        !isScrubbing && Date().timeIntervalSinceReferenceDate >= progressHoldUntil
    }

    private func publishProgressNow() {
        let duration = durationSeconds
        guard duration > 0 else { return }
        progress = min(max(currentTimeSeconds / duration, 0), 1)
    }

    // MARK: - 자막

    private func loadMediaOptions() {
        // 외부 자막은 원본 파일 옆에서 찾는다 (movie.mkv → movie.smi).
        // 재생 URL은 호환 변환본일 수 있으므로 선택 그룹은 player asset에서 읽는다.
        let videoURL = sourceURL
        Task { [weak self] in
            let external = SubtitleLoader.loadWithSource(for: videoURL)
            let audible = try? await self?.player.currentItem?.asset
                .loadMediaSelectionGroup(for: .audible)
            let legible = try? await self?.player.currentItem?.asset
                .loadMediaSelectionGroup(for: .legible)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.subtitleCues = external?.cues ?? []
                self.externalSubtitleName = external?.url.lastPathComponent
                self.audibleGroup = audible ?? nil
                self.legibleGroup = legible ?? nil
                self.audioTrackOptions = Self.trackOptions(from: self.audibleGroup)
                self.subtitleTrackOptions = Self.trackOptions(from: self.legibleGroup)
                if let reference = self.restoredAudioTrackReference,
                   let index = Self.resolve(reference, in: self.audibleGroup) {
                    self.selectedAudioTrackIndex = index
                }
                if case .embedded = self.subtitleTrackSelection,
                   let reference = self.restoredSubtitleTrackReference,
                   let index = Self.resolve(reference, in: self.legibleGroup) {
                    self.subtitleTrackSelection = .embedded(index)
                }
                self.mediaOptionsLoaded = true
                if !self.audioTrackOptions.isEmpty { self.hasAudio = true }
                self.applyAudioTrackSelection()
                self.applyEmbeddedSubtitles()
                self.refreshTimeObserver()
                // 초기 로딩의 마지막 selection/seek 이벤트가 자막을 비우는 경우를 막는다.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.usesExternalSubtitles else { return }
                    self.updateSubtitle(at: self.player.currentTime().seconds)
                }
            }
        }
    }

    private static func trackOptions(from group: AVMediaSelectionGroup?) -> [MediaTrackOption] {
        guard let group else { return [] }
        return group.options.enumerated().map { index, option in
            MediaTrackOption(
                index: index,
                name: option.displayName,
                languageTag: option.extendedLanguageTag ?? option.locale?.identifier,
                propertyListData: try? PropertyListSerialization.data(
                    fromPropertyList: option.propertyList(),
                    format: .binary,
                    options: 0
                )
            )
        }
    }

    private static func resolve(
        _ reference: ProjectTrackReference,
        in group: AVMediaSelectionGroup?
    ) -> Int? {
        guard let group else { return nil }
        if let data = reference.propertyListData,
           let propertyList = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ),
           let option = group.mediaSelectionOption(withPropertyList: propertyList),
           let index = group.options.firstIndex(of: option) {
            return index
        }
        if let exact = group.options.firstIndex(where: { option in
            let language = option.extendedLanguageTag ?? option.locale?.identifier
            return language == reference.languageTag && option.displayName == reference.name
        }) {
            return exact
        }
        if let languageTag = reference.languageTag,
           let language = group.options.firstIndex(where: {
               ($0.extendedLanguageTag ?? $0.locale?.identifier) == languageTag
           }) {
            return language
        }
        return group.options.indices.contains(reference.index) ? reference.index : nil
    }

    private static func resolve(
        _ reference: ProjectTrackReference,
        in options: [MediaTrackOption]
    ) -> Int? {
        if let exact = options.first(where: {
            $0.languageTag == reference.languageTag && $0.name == reference.name
        }) {
            return exact.index
        }
        if let languageTag = reference.languageTag,
           let language = options.first(where: { $0.languageTag == languageTag }) {
            return language.index
        }
        return options.first(where: { $0.index == reference.index })?.index
    }

    var selectedAudioTrackReference: ProjectTrackReference? {
        guard let index = selectedAudioTrackIndex else { return nil }
        return audioTrackOptions.first { $0.index == index }?.projectReference
            ?? restoredAudioTrackReference
    }

    var selectedSubtitleTrackReference: ProjectTrackReference? {
        guard case .embedded(let index) = subtitleTrackSelection else { return nil }
        return subtitleTrackOptions.first { $0.index == index }?.projectReference
            ?? restoredSubtitleTrackReference
    }

    private func applyAudioTrackSelection() {
        if let mpvEngine {
            mpvEngine.setAudioTrack(order: selectedAudioTrackIndex)
            return
        }
        guard let group = audibleGroup, let currentItem = player.currentItem else { return }
        guard let index = selectedAudioTrackIndex else {
            currentItem.selectMediaOptionAutomatically(in: group)
            return
        }
        let selected = group.options.indices.contains(index)
            ? group.options[index]
            : (group.defaultOption ?? group.options.first)
        currentItem.select(selected, in: group)
    }

    /// ffmpeg 내보내기에서 AVPlayer와 같은 오디오를 고르기 위한 상대 스트림 순서.
    var effectiveAudioTrackIndex: Int {
        if let selectedAudioTrackIndex { return max(0, selectedAudioTrackIndex) }
        if let mpvEngine,
           let selected = mpvEngine.tracks.first(where: { $0.kind == .audio && $0.selected }) {
            return selected.order
        }
        guard let group = audibleGroup,
              let selected = player.currentItem?.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(of: selected)
        else { return 0 }
        return index
    }

    private var usesExternalSubtitles: Bool {
        guard !usesMPV else { return false }
        guard subtitlesEnabled, !subtitleCues.isEmpty else { return false }
        switch subtitleTrackSelection {
        case .automatic, .external: return true
        case .off, .embedded: return false
        }
    }

    private var usesEmbeddedSubtitles: Bool {
        guard !usesMPV else { return false }
        guard subtitlesEnabled else { return false }
        switch subtitleTrackSelection {
        case .automatic: return subtitleCues.isEmpty
        case .external: return subtitleCues.isEmpty
        case .embedded: return true
        case .off: return false
        }
    }

    private func receiveEmbeddedSubtitle(_ text: String?) {
        guard usesEmbeddedSubtitles else { return }
        if currentSubtitle != text { currentSubtitle = text }
    }

    /// 외부 자막이나 개별 시크바가 실제로 필요할 때만 시간 콜백을 유지한다.
    /// 여러 영상을 재생할 때 영상 수 × 초당 4회의 메인 스레드 작업을 피한다.
    private func refreshTimeObserver() {
        if usesMPV { return }
        let needsObserver = progressActive || usesExternalSubtitles
        if !needsObserver {
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            return
        }
        guard timeObserver == nil else { return }

        if usesExternalSubtitles {
            updateSubtitle(at: player.currentTime().seconds)
        }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            if self.usesExternalSubtitles {
                self.updateSubtitle(at: time.seconds)
            }
            guard self.progressActive, self.acceptsTimeUpdates else { return }
            let duration = self.durationSeconds
            guard duration > 0 else { return }
            let fraction = min(max(time.seconds / duration, 0), 1)
            if abs(fraction - self.progress) > 0.0001 {
                self.progress = fraction
            }
        }
    }

    /// 외부 자막 파일이 없을 때만 영상에 내장된 자막 트랙을 켠다
    private func applyEmbeddedSubtitles() {
        if let mpvEngine {
            let visible = subtitlesEnabled && subtitleTrackSelection != .off
            mpvEngine.setSubtitlesEnabled(visible)
            switch subtitleTrackSelection {
            case .embedded(let index):
                mpvEngine.setSubtitleTrack(order: index)
            case .automatic, .external:
                mpvEngine.setSubtitleTrack(order: nil)
            case .off:
                break
            }
            return
        }
        guard let group = legibleGroup, let currentItem = player.currentItem else { return }
        let selected: AVMediaSelectionOption?
        if !subtitlesEnabled {
            selected = nil
        } else {
            switch subtitleTrackSelection {
            case .automatic:
                if subtitleCues.isEmpty {
                    currentItem.selectMediaOptionAutomatically(in: group)
                    return
                }
                selected = nil
            case .off:
                selected = nil
            case .external:
                // 프로젝트 복원 뒤 외부 파일이 없어졌다면 내장 기본 자막으로 대체한다.
                if subtitleCues.isEmpty {
                    currentItem.selectMediaOptionAutomatically(in: group)
                    return
                }
                selected = nil
            case .embedded(let index):
                selected = group.options.indices.contains(index)
                    ? group.options[index]
                    : (group.defaultOption ?? group.options.first)
            }
        }
        if let selected {
            currentItem.select(selected, in: group)
        } else if group.allowsEmptySelection {
            currentItem.select(nil, in: group)
        }
        // 일시정지 상태에서도 새로 선택한 내장 자막을 즉시 다시 출력한다.
        if usesEmbeddedSubtitles {
            let time = player.currentTime()
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    private func updateSubtitle(at seconds: Double) {
        guard usesExternalSubtitles else { return }
        let text = cueText(at: seconds)
        if text != currentSubtitle { currentSubtitle = text }
    }

    private func cueText(at time: Double) -> String? {
        // start <= time 인 마지막 큐를 이진 탐색으로 찾고,
        // 겹치는 큐를 대비해 근처 몇 개만 거슬러 확인한다
        var low = 0
        var high = subtitleCues.count
        while low < high {
            let mid = (low + high) / 2
            if subtitleCues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        for index in stride(from: low - 1, through: max(0, low - 4), by: -1) {
            let cue = subtitleCues[index]
            if cue.start <= time, time < cue.end { return cue.text }
        }
        return nil
    }

    /// 타일 크기에 맞춰 디코딩 해상도를 제한한다. 작은 타일에 4K를 통째로
    /// 디코딩하는 낭비를 막는 것이 여러 영상 동시 재생 성능의 핵심이다.
    /// 잦은 재설정을 피하려고 64pt 이상 달라질 때만 적용한다.
    func applyResolutionCap(_ size: CGSize) {
        guard !usesMPV else { return }
        guard let currentItem = player.currentItem else { return }
        guard abs(appliedResolutionCap.width - size.width) > 64
            || abs(appliedResolutionCap.height - size.height) > 64 else { return }
        appliedResolutionCap = size
        currentItem.preferredMaximumResolution = size
    }

    /// SMB/AFP/NFS로 마운트된 공유는 file:// URL이지만 볼륨이 로컬이 아니다.
    /// 비-파일 URL(http 등)도 네트워크로 본다.
    static func isNetworkURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return true }
        let isLocal = (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal
        return isLocal == false
    }

    private func loadAspect() {
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            // 컨테이너 미지원(MKV 등)을 재생 시도 전에 미리 감지한다
            if let playable = try? await asset.load(.isPlayable), !playable {
                loadFailed = true
            }
            if let audioTracks = try? await asset.loadTracks(withMediaType: .audio) {
                hasAudio = !audioTracks.isEmpty
            }
            if let duration = try? await asset.load(.duration),
               duration.seconds.isFinite, duration.seconds > 0 {
                assetDurationSeconds = duration.seconds
                durationChanged?()
            }
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return }
            let rotated = size.applying(transform)
            let width = abs(rotated.width)
            let height = abs(rotated.height)
            if width > 0, height > 0 {
                pixelSize = CGSize(width: width, height: height)
                aspect = width / height
            }
            if let frameRate = try? await track.load(.nominalFrameRate), frameRate > 0 {
                nominalFrameRate = frameRate
            }
        }
    }
}

struct PlaylistEntry: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

final class PlayerManager: ObservableObject {
    private struct InitialPlaybackPosition {
        let seconds: Double
        let fraction: Double
        let relative: Bool
        /// 준비 중에도 다른 영상이 계속 재생되면 완료 시점의 타임라인을 따라간다.
        let followsLiveTimeline: Bool
    }

    private struct ReplacementRequest {
        let itemID: UUID
        let previousSource: URL
        let targetSource: URL
        let projectState: ProjectVideo
        let generation: UUID
    }

    /// Finder "다음으로 열기" 등 AppDelegate 경로에서도 같은 인스턴스를 쓴다
    static let shared = PlayerManager()

    // MARK: - 프로젝트 상태

    @Published private(set) var currentProjectURL: URL?
    @Published private(set) var isProjectEdited = false
    /// 프로젝트를 연 뒤 ContentView의 AppStorage 값에 적용할 설정.
    @Published var pendingProjectViewSettings: ProjectViewSettings?

    private(set) var projectViewSettings = ProjectViewSettings(
        fillMode: UserDefaults.standard.object(forKey: "fillMode") as? Bool ?? true,
        playlistVisible: UserDefaults.standard.object(forKey: "playlistVisible") as? Bool ?? true,
        gridColumns: UserDefaults.standard.integer(forKey: "gridColumns")
    )
    private var suppressProjectDirty = false
    private var pendingRestoreFraction: Double?
    private var expectedRestoreIDs: Set<UUID> = []
    private var restoreSeekTask: Task<Void, Never>?
    /// 파일 선택 직후 네이티브/원본 직접 재생 가능 여부를 검사하는 동안
    /// 빈 화면이 멈춘 것처럼 보이지 않도록 UI에 파일명을 공개한다.
    @Published private(set) var preparingFileNames: [String] = []
    private var pendingSources: Set<URL> = [] {
        didSet {
            preparingFileNames = pendingSources
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }
    /// 기존 타일을 유지한 채 새 파일을 준비 중인 교체 작업.
    @Published private var pendingReplacementIDs: Set<UUID> = []
    /// 새 프로젝트를 열면 이전 작업의 비동기 변환 결과를 무시하기 위한 토큰.
    private var workspaceGeneration = UUID()

    private var directPlaybackEnabled: Bool {
        UserDefaults.standard.object(forKey: "experimentalDirectPlayback") as? Bool ?? true
    }

    var projectDisplayName: String {
        currentProjectURL?.deletingPathExtension().lastPathComponent
            ?? String(localized: "현재 작업")
    }

    var projectWindowTitle: String {
        guard currentProjectURL != nil else { return isProjectEdited ? "Tilo •" : "Tilo" }
        let suffix = isProjectEdited ? " •" : ""
        return "\(projectDisplayName)\(suffix) — Tilo"
    }

    func markProjectEdited() {
        guard !suppressProjectDirty else { return }
        guard currentProjectURL != nil || !items.isEmpty || !playlist.isEmpty else { return }
        guard !isProjectEdited else { return }
        isProjectEdited = true
    }

    func updateProjectViewSettings(
        fillMode: Bool,
        playlistVisible: Bool,
        gridColumns: Int,
        markEdited: Bool = true
    ) {
        let settings = ProjectViewSettings(
            fillMode: fillMode,
            playlistVisible: playlistVisible,
            gridColumns: gridColumns
        )
        guard settings != projectViewSettings else { return }
        projectViewSettings = settings
        if markEdited { markProjectEdited() }
    }

    func consumePendingProjectViewSettings() {
        pendingProjectViewSettings = nil
    }

    @Published var items: [VideoItem] = []
    @Published var selectedItemID: UUID?
    var selectedItem: VideoItem? { items.first { $0.id == selectedItemID } }
    /// 재생목록. 영상을 추가하면 같은 폴더의 영상들이 자동으로 들어온다.
    @Published var playlist: [PlaylistEntry] = []
    @Published var isPlaying = false
    /// 최장 영상 길이를 기준으로 한 전체 진행률 (0...1)
    let progressModel = PlaybackProgress()
    var progress: Double { progressModel.fraction }
    var isScrubbing = false

    /// 영상이 끝나면 처음부터 다시 재생 (영상별로 각자 루프).
    /// 기본값은 환경설정의 "반복재생 기본 켜기"를 따른다.
    @Published var loopEnabled = UserDefaults.standard.object(forKey: "loopDefault") as? Bool ?? true {
        didSet {
            items.forEach { $0.loopEnabled = loopEnabled }
            markProjectEdited()
        }
    }

    /// 오디오 솔로: 설정되면 이 영상만 소리가 나고 나머지는 음소거
    @Published var soloItemID: UUID? {
        didSet {
            applyAudio()
            markProjectEdited()
        }
    }

    /// 자막 표시 (외부 .srt/.smi + 내장 자막 트랙)
    @Published var subtitlesEnabled = true {
        didSet {
            items.forEach { $0.subtitlesEnabled = subtitlesEnabled }
            markProjectEdited()
        }
    }

    /// 외부·내장 자막에 공통 적용하는 글자 크기(50%...200%).
    @Published var subtitleScale: Double = {
        let saved = UserDefaults.standard.double(forKey: "subtitleScale")
        return saved > 0 ? min(max(saved, 0.5), 2) : 1
    }() {
        didSet {
            UserDefaults.standard.set(subtitleScale, forKey: "subtitleScale")
            items.forEach { $0.setSubtitleScale(subtitleScale) }
            markProjectEdited()
        }
    }

    /// 전역 볼륨 (0...1). 각 영상의 개별 볼륨과 곱해진다.
    @Published var masterVolume: Double = UserDefaults.standard.object(forKey: "masterVolume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
            applyAudio()
            markProjectEdited()
        }
    }

    /// 스피커 아이콘 클릭으로 전체 음소거. 끄면 직전 볼륨으로 복귀.
    private var preMuteVolume: Double = 1
    var isMasterMuted: Bool { masterVolume <= 0.001 }
    func toggleMasterMute() {
        if isMasterMuted {
            masterVolume = preMuteVolume > 0.01 ? preMuteVolume : 1
        } else {
            preMuteVolume = masterVolume
            masterVolume = 0
        }
    }

    /// 전체 재생바 기준: false = 절대 시간(가장 긴 영상), true = 상대 비율
    /// (각 영상이 자기 길이의 같은 비율 지점으로 이동, 100%에서 모두 함께 끝남)
    @Published var relativeTimeline = UserDefaults.standard.bool(forKey: "relativeTimeline") {
        didSet {
            UserDefaults.standard.set(relativeTimeline, forKey: "relativeTimeline")
            // 모드가 바뀌면 현재 위치를 새 매핑으로 다시 맞추고 속도를 재적용
            seekAll(to: progress)
            if isPlaying { playAll() }
            markProjectEdited()
        }
    }

    /// 상대 타임라인 모드에서 영상이 가장 긴 영상과 함께 끝나도록 하는 재생 속도.
    /// 절대 모드(또는 길이 미상)에서는 1배.
    private func desiredRate(for item: VideoItem) -> Float {
        guard relativeTimeline, maxDuration > 0 else { return 1 }
        let dur = item.durationSeconds
        return dur > 0 ? Float(dur / maxDuration) : 1
    }

    /// A-B 구간반복 지점 (전역 진행률 분수). 둘 다 설정되면 활성.
    @Published var abA: Double?
    @Published var abB: Double?

    /// MP4로 변환 중인 파일들 (이름 → 진행률 %)
    @Published var remuxing: [String: Int] = [:]
    /// 모자이크 영상 내보내기 진행률. nil이면 작업이 없다.
    @Published var mosaicExportProgress: Int?
    private var mosaicExportSession: MosaicExporter.Session?
    private var mosaicExportTask: Task<Void, Never>?
    var isExportingMosaic: Bool { mosaicExportProgress != nil }
    /// 일시적으로 띄우는 안내 메시지 (몇 초 후 자동 소멸)
    @Published var notice: String?
    private var noticeTask: Task<Void, Never>?

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// 드래그로 맞바꾼 자리 (자동 배치 위에 적용되는 순열: 내 id → 내가 차지할 자리의 id)
    @Published var rectSwaps: [UUID: UUID] = [:]
    /// 현재 드래그 중인 영상 (드롭 대상 셀이 읽는다)
    var draggingItemID: UUID?

    /// 두 영상의 표시 위치를 맞바꾼다
    func swapPositions(_ first: UUID, _ second: UUID) {
        guard first != second else { return }
        let sourceFirst = rectSwaps[first] ?? first
        let sourceSecond = rectSwaps[second] ?? second
        rectSwaps[first] = sourceSecond == first ? nil : sourceSecond
        rectSwaps[second] = sourceFirst == second ? nil : sourceFirst
        markProjectEdited()
    }

    /// R 키 한 번 = A 지점, 두 번 = B 지점 + 반복 시작, 세 번 = 해제
    func cycleABLoop() {
        if abA == nil {
            abA = progress
        } else if abB == nil {
            if progress > (abA ?? 0) + 0.005 {
                abB = progress
            } else {
                abA = nil
            }
        } else {
            abA = nil
            abB = nil
        }
        markProjectEdited()
    }

    /// 더블클릭 확대로 단독 표시 중인 영상
    @Published var zoomedItemID: UUID?

    private var progressObservationTask: Task<Void, Never>?
    private weak var observedItem: VideoItem?
    /// 서로 다른 디코더(AVFoundation/libmpv)는 시작 지연과 시계가 다르므로,
    /// 눈에 띄는 차이만 드물게 보정한다. 작은 차이까지 계속 seek하면 오히려
    /// 재생이 끊겨 보이므로 0.2초를 허용 범위로 둔다.
    private let playbackDriftTolerance: Double = 0.2
    /// 영상 제거 시 화면비 구독도 함께 해제해 플레이어가 남지 않도록 한다.
    private var aspectCancellables: [UUID: AnyCancellable] = [:]
    private var pendingCaps: [UUID: CGSize] = [:]
    private var capsTask: Task<Void, Never>?
    private var cachedMaxDuration: Double = 0
    private var batchingAudioChanges = false

    var maxDuration: Double {
        cachedMaxDuration
    }

    // MARK: - 프로젝트 파일

    func newProject() {
        guard confirmReplacingCurrentProject() else { return }
        suppressProjectDirty = true
        resetWorkspaceForProject()
        currentProjectURL = nil
        isProjectEdited = false
        suppressProjectDirty = false
        saveSession()
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.tiloProject]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        guard confirmReplacingCurrentProject() else { return }
        do {
            let data = try Data(contentsOf: url)
            let project = try TiloProjectCodec.decode(data)
            guard let relinked = resolveProjectFiles(project, projectURL: url) else { return }
            apply(project: project, projectURL: url, relinked: relinked)
        } catch {
            presentProjectError(
                title: String(localized: "프로젝트를 열 수 없습니다"),
                error: error
            )
        }
    }

    @discardableResult
    func saveProject() -> Bool {
        guard let currentProjectURL else { return saveProjectAs() }
        return writeProject(to: currentProjectURL)
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tiloProject]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = currentProjectURL?.lastPathComponent ?? "Tilo Project.tilo"
        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        let url = selected.pathExtension.lowercased() == "tilo"
            ? selected
            : selected.appendingPathExtension("tilo")
        return writeProject(to: url)
    }

    /// 앱 종료 시 저장되지 않은 프로젝트를 실수로 버리지 않도록 확인한다.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard isProjectEdited else {
            cancelMosaicExport(showsNotice: false)
            return .terminateNow
        }
        let response = unsavedChangesAlert()
        switch response {
        case .alertFirstButtonReturn:
            if saveProject() {
                cancelMosaicExport(showsNotice: false)
                return .terminateNow
            }
            return .terminateCancel
        case .alertSecondButtonReturn:
            cancelMosaicExport(showsNotice: false)
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func confirmReplacingCurrentProject() -> Bool {
        guard isProjectEdited else { return true }
        let response = unsavedChangesAlert()
        switch response {
        case .alertFirstButtonReturn: return saveProject()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    private func unsavedChangesAlert() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = String(localized: "변경 사항을 저장하시겠습니까?")
        alert.informativeText = String(
            localized: "\(projectDisplayName)의 저장되지 않은 변경 사항이 있습니다."
        )
        alert.addButton(withTitle: String(localized: "저장"))
        alert.addButton(withTitle: String(localized: "저장하지 않음"))
        alert.addButton(withTitle: String(localized: "취소"))
        alert.buttons[1].hasDestructiveAction = true
        alert.buttons[2].keyEquivalent = "\u{1b}"
        return alert.runModal()
    }

    private func writeProject(to url: URL) -> Bool {
        do {
            let project = makeProject(relativeTo: url)
            let data = try TiloProjectCodec.encode(project)
            try data.write(to: url, options: .atomic)
            currentProjectURL = url.standardizedFileURL
            isProjectEdited = false
            showNotice(String(localized: "프로젝트 저장됨: \(url.lastPathComponent)"))
            return true
        } catch {
            presentProjectError(
                title: String(localized: "프로젝트를 저장할 수 없습니다"),
                error: error
            )
            return false
        }
    }

    private func makeProject(relativeTo projectURL: URL) -> TiloProject {
        TiloProject(
            view: projectViewSettings,
            playback: ProjectPlaybackSettings(
                progress: min(max(progress, 0), 1),
                loopEnabled: loopEnabled,
                subtitlesEnabled: subtitlesEnabled,
                masterVolume: min(max(masterVolume, 0), 1),
                relativeTimeline: relativeTimeline,
                abA: abA,
                abB: abB,
                soloItemID: soloItemID,
                zoomedItemID: zoomedItemID,
                subtitleScale: subtitleScale
            ),
            videos: items.map { item in
                ProjectVideo(
                    id: item.id,
                    file: projectReference(for: item.sourceURL, relativeTo: projectURL),
                    isMuted: item.isMuted,
                    volume: item.volume,
                    timeOffset: item.timeOffset,
                    rotationQuarters: item.rotationQuarters,
                    zoomScale: Double(item.zoomScale),
                    panX: Double(item.panOffset.width),
                    panY: Double(item.panOffset.height),
                    audioTrackIndex: item.selectedAudioTrackIndex,
                    audioTrackReference: item.selectedAudioTrackReference,
                    subtitleTrackSelection: item.subtitleTrackSelection.persistenceKey,
                    subtitleTrackReference: item.selectedSubtitleTrackReference,
                    abA: item.abA,
                    abB: item.abB
                )
            },
            playlist: playlist.map { projectReference(for: $0.url, relativeTo: projectURL) },
            swaps: rectSwaps
                .map { ProjectSwap(itemID: $0.key, slotID: $0.value) }
                .sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        )
    }

    private func projectReference(for url: URL, relativeTo projectURL: URL) -> ProjectFileReference {
        let standardized = url.standardizedFileURL
        let folderPath = projectURL.deletingLastPathComponent().standardizedFileURL.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let relative = standardized.path.hasPrefix(prefix)
            ? String(standardized.path.dropFirst(prefix.count))
            : nil
        let attributes = try? FileManager.default.attributesOfItem(atPath: standardized.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        return ProjectFileReference(
            absolutePath: standardized.path,
            relativePath: relative,
            fileName: standardized.lastPathComponent,
            fileSize: size
        )
    }

    /// 반환값 nil은 사용자가 누락 파일 처리 자체를 취소했다는 뜻이다.
    private func resolveProjectFiles(
        _ project: TiloProject,
        projectURL: URL
    ) -> [String: URL]? {
        let references = project.videos.map(\.file) + project.playlist
        let unique = Dictionary(references.map { ($0.absolutePath, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = unique.values.filter { resolve($0, projectURL: projectURL, relinked: [:]) == nil }
        guard !missing.isEmpty else { return [:] }

        let alert = NSAlert()
        alert.messageText = String(localized: "프로젝트 파일 \(missing.count)개를 찾을 수 없습니다")
        alert.informativeText = String(localized: "파일이 들어 있는 폴더를 선택하면 이름과 크기를 기준으로 다시 연결합니다.")
        alert.addButton(withTitle: String(localized: "폴더 선택…"))
        alert.addButton(withTitle: String(localized: "찾은 파일만 열기"))
        alert.addButton(withTitle: String(localized: "취소"))
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { return [:] }
        guard response == .alertFirstButtonReturn else { return nil }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "다시 연결")
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        return findMissingFiles(missing, in: folder)
    }

    private func findMissingFiles(
        _ references: [ProjectFileReference],
        in folder: URL
    ) -> [String: URL] {
        let names = Set(references.map(\.fileName))
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        var candidates: [String: [URL]] = [:]
        while let candidate = enumerator?.nextObject() as? URL {
            guard names.contains(candidate.lastPathComponent) else { continue }
            let values = try? candidate.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            candidates[candidate.lastPathComponent, default: []].append(candidate)
        }

        var result: [String: URL] = [:]
        for reference in references {
            guard let matches = candidates[reference.fileName], !matches.isEmpty else { continue }
            let sized = reference.fileSize.flatMap { size in
                matches.first {
                    Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == size
                }
            }
            result[reference.absolutePath] = (sized ?? matches[0]).standardizedFileURL
        }
        return result
    }

    private func resolve(
        _ reference: ProjectFileReference,
        projectURL: URL,
        relinked: [String: URL]
    ) -> URL? {
        let fm = FileManager.default
        if let relative = reference.relativePath {
            let candidate = projectURL.deletingLastPathComponent()
                .appendingPathComponent(relative)
                .standardizedFileURL
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let absolute = URL(fileURLWithPath: reference.absolutePath).standardizedFileURL
        if fm.fileExists(atPath: absolute.path) { return absolute }
        return relinked[reference.absolutePath]
    }

    private func apply(
        project: TiloProject,
        projectURL: URL,
        relinked: [String: URL]
    ) {
        suppressProjectDirty = true
        resetWorkspaceForProject()
        currentProjectURL = projectURL.standardizedFileURL
        projectViewSettings = project.view
        pendingProjectViewSettings = project.view

        loopEnabled = project.playback.loopEnabled
        subtitlesEnabled = project.playback.subtitlesEnabled
        if let scale = project.playback.subtitleScale { subtitleScale = scale }
        masterVolume = project.playback.masterVolume
        relativeTimeline = project.playback.relativeTimeline
        abA = project.playback.abA
        abB = project.playback.abB

        let resolvedVideos = project.videos.compactMap { video -> (ProjectVideo, URL)? in
            resolve(video.file, projectURL: projectURL, relinked: relinked).map { (video, $0) }
        }
        expectedRestoreIDs = Set(resolvedVideos.map { $0.0.id })
        pendingRestoreFraction = project.playback.progress
        progressModel.fraction = project.playback.progress

        let validIDs = expectedRestoreIDs
        rectSwaps = Dictionary(
            uniqueKeysWithValues: project.swaps.compactMap { swap in
                guard validIDs.contains(swap.itemID), validIDs.contains(swap.slotID) else { return nil }
                return (swap.itemID, swap.slotID)
            }
        )
        soloItemID = project.playback.soloItemID.flatMap { validIDs.contains($0) ? $0 : nil }
        zoomedItemID = project.playback.zoomedItemID.flatMap { validIDs.contains($0) ? $0 : nil }

        let resolvedPlaylist = project.playlist.compactMap {
            resolve($0, projectURL: projectURL, relinked: relinked)
        }
        appendToPlaylist(resolvedPlaylist)
        for (video, source) in resolvedVideos {
            stageAny(source, projectState: video)
        }

        applyAudio()
        updateTimeObserver()
        scheduleProjectRestoreSeek()
        isProjectEdited = false
        suppressProjectDirty = false
        saveSession()

        let allReferences = project.videos.map(\.file) + project.playlist
        let missingCount = Set(allReferences.compactMap { reference in
            resolve(reference, projectURL: projectURL, relinked: relinked) == nil
                ? reference.absolutePath
                : nil
        }).count
        if missingCount > 0 {
            showNotice(String(localized: "찾지 못한 파일 \(missingCount)개를 제외하고 열었습니다"))
        }
    }

    private func resetWorkspaceForProject() {
        workspaceGeneration = UUID()
        restoreSeekTask?.cancel()
        capsTask?.cancel()
        items.forEach { $0.pause() }
        items.removeAll()
        playlist.removeAll()
        selectedPlaylist.removeAll()
        selectedItemID = nil
        aspectCancellables.removeAll()
        rectSwaps.removeAll()
        remuxing.removeAll()
        pendingSources.removeAll()
        pendingReplacementIDs.removeAll()
        soloItemID = nil
        zoomedItemID = nil
        isPlaying = false
        progressModel.fraction = 0
        abA = nil
        abB = nil
        pendingRestoreFraction = nil
        expectedRestoreIDs.removeAll()
        updateTimeObserver()
    }

    private func scheduleProjectRestoreSeek() {
        guard let fraction = pendingRestoreFraction else { return }
        restoreSeekTask?.cancel()
        restoreSeekTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.seekAll(to: fraction)
            let readyIDs = Set(self.items.filter { $0.durationSeconds > 0 }.map(\.id))
            if self.expectedRestoreIDs.isSubset(of: readyIDs) {
                self.pendingRestoreFraction = nil
                self.expectedRestoreIDs.removeAll()
            }
        }
    }

    private func presentProjectError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func openVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        types += Self.supportedVideoExtensions.compactMap { UTType(filenameExtension: $0) }
        types = Array(Set(types))
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func add(urls: [URL]) {
        if let projectURL = urls.first(where: { $0.pathExtension.lowercased() == "tilo" }) {
            openProject(at: projectURL)
        }
        var changed = false
        for url in urls {
            guard url.pathExtension.lowercased() != "tilo" else { continue }
            if url.hasDirectoryPath {
                // 폴더를 통째로 넣으면 재생목록에만 등록한다
                // (수십 개를 한꺼번에 화면에 띄우지 않도록)
                appendToPlaylist(videosInFolder(url))
                changed = true
            } else if Self.isVideoFile(url) {
                stageAny(url)
                appendToPlaylist(videosInFolder(url.deletingLastPathComponent()))
                appendToPlaylist([url])
                changed = true
            }
        }
        rememberRecent(urls.filter { $0.pathExtension.lowercased() != "tilo" })
        applyAudio()
        updateTimeObserver()
        saveSession()
        if changed { markProjectEdited() }
    }

    /// 확장자가 아니라 실제 재생 가능 여부를 먼저 확인한다. 직접 재생할 수
    /// 없으면 리먹스/호환 변환을 거친 뒤 화면에 올린다.
    private func stageAny(
        _ url: URL,
        projectState: ProjectVideo? = nil,
        insertionIndex: Int? = nil,
        initialPosition: InitialPlaybackPosition? = nil
    ) {
        let source = url.standardizedFileURL
        guard !isStaged(source), pendingSources.insert(source).inserted else { return }

        let generation = workspaceGeneration
        Task { @MainActor [weak self] in
            let playable = await Remuxer.isNativelyPlayable(source)
            guard let self else { return }
            guard self.workspaceGeneration == generation else {
                self.pendingSources.remove(source)
                return
            }
            switch Self.importStrategy(
                nativePlayable: playable,
                directPlaybackEnabled: self.directPlaybackEnabled,
                libmpvAvailable: MPVPlaybackEngine.isAvailable,
                compatibilityToolAvailable: Remuxer.ffmpegURL != nil
            ) {
            case .direct:
                self.pendingSources.remove(source)
                self.stage(
                    source,
                    projectState: projectState,
                    insertionIndex: insertionIndex,
                    initialPosition: initialPosition
                )
            case .libmpv:
                let mpvPlayable = await MPVPlaybackEngine.canOpen(source)
                guard self.workspaceGeneration == generation else {
                    self.pendingSources.remove(source)
                    return
                }
                if mpvPlayable {
                    self.pendingSources.remove(source)
                    self.showNotice(String(localized: "원본 파일을 변환 없이 직접 재생합니다: \(source.lastPathComponent)"))
                    self.stage(
                        source,
                        projectState: projectState,
                        insertionIndex: insertionIndex,
                        initialPosition: initialPosition,
                        backendKind: .libmpv
                    )
                } else if Remuxer.ffmpegURL != nil {
                    self.showNotice(String(localized: "\(source.lastPathComponent): 직접 재생에 실패해 호환 변환을 시도합니다"))
                    self.convertAndStage(
                        source,
                        projectState: projectState,
                        insertionIndex: insertionIndex,
                        initialPosition: initialPosition
                    )
                } else {
                    self.pendingSources.remove(source)
                    self.stage(
                        source,
                        projectState: projectState,
                        insertionIndex: insertionIndex,
                        initialPosition: initialPosition,
                        allowRecovery: false
                    )
                }
            case .compatibilityProcessing:
                self.showNotice(String(localized: "\(source.lastPathComponent): 기본 재생으로 열 수 없어 호환 재생용 파일을 준비합니다"))
                self.convertAndStage(
                    source,
                    projectState: projectState,
                    insertionIndex: insertionIndex,
                    initialPosition: initialPosition
                )
            case .unsupported:
                self.pendingSources.remove(source)
                self.stage(
                    source,
                    projectState: projectState,
                    insertionIndex: insertionIndex,
                    initialPosition: initialPosition
                )
            }
        }
    }

    private func convertAndStage(
        _ source: URL,
        projectState: ProjectVideo? = nil,
        insertionIndex: Int? = nil,
        initialPosition: InitialPlaybackPosition? = nil,
        forceTranscode: Bool = false
    ) {
        guard !isStaged(source) else {
            pendingSources.remove(source.standardizedFileURL)
            return
        }
        guard Remuxer.ffmpegURL != nil else {
            showNotice(String(localized: "호환 변환에는 ffmpeg가 필요합니다 — 터미널에서 brew install ffmpeg"))
            pendingSources.remove(source.standardizedFileURL)
            stage(
                source,
                projectState: projectState,
                insertionIndex: insertionIndex,
                initialPosition: initialPosition,
                allowRecovery: false
            )
            return
        }
        let generation = workspaceGeneration
        let name = source.lastPathComponent
        let jobKey = source.standardizedFileURL.path
        remuxing[jobKey] = 0
        Task { @MainActor in
            let result = await Remuxer.makePlayableCopy(source, forceTranscode: forceTranscode) { fraction in
                Task { @MainActor [weak self] in
                    if self?.workspaceGeneration == generation, self?.remuxing[jobKey] != nil {
                        self?.remuxing[jobKey] = Int(fraction * 100)
                    }
                }
            }
            guard workspaceGeneration == generation else { return }
            remuxing.removeValue(forKey: jobKey)
            pendingSources.remove(source.standardizedFileURL)
            switch result {
            case .success(let output):
                stage(
                    output,
                    sourceURL: source,
                    projectState: projectState,
                    insertionIndex: insertionIndex,
                    initialPosition: initialPosition
                )
            case .failure(let failure):
                let codecText = failure.videoCodec.map { String(localized: " (영상 코덱: \($0))") } ?? ""
                showNotice(String(localized: "\(name) 변환 실패\(codecText) — 로그: ~/Library/Logs/Tilo/remux.log"))
                stage(
                    source,
                    projectState: projectState,
                    insertionIndex: insertionIndex,
                    initialPosition: initialPosition,
                    allowRecovery: false
                )
            }
        }
    }

    private func isStaged(_ url: URL) -> Bool {
        items.contains { $0.sourceURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// 영상 하나를 화면(스테이지)에 올린다. 이미 올라간 영상은 무시.
    private func stage(
        _ url: URL,
        sourceURL: URL? = nil,
        projectState: ProjectVideo? = nil,
        insertionIndex: Int? = nil,
        initialPosition: InitialPlaybackPosition? = nil,
        allowRecovery: Bool = true,
        backendKind: PlaybackBackendKind = .avFoundation
    ) {
        guard !isStaged(sourceURL ?? url) else { return }
        let restoredSubtitle = projectState?.subtitleTrackSelection
            .flatMap(SubtitleTrackSelection.init(persistenceKey:)) ?? .automatic
        let item = VideoItem(
            id: projectState?.id ?? UUID(),
            url: url,
            sourceURL: sourceURL,
            audioTrackIndex: projectState?.audioTrackIndex,
            audioTrackReference: projectState?.audioTrackReference,
            subtitleSelection: restoredSubtitle,
            subtitleTrackReference: projectState?.subtitleTrackReference,
            backendKind: backendKind
        )
        if let state = projectState {
            item.isMuted = state.isMuted
            item.volume = min(max(state.volume, 0), 1)
            item.timeOffset = state.timeOffset
            item.rotationQuarters = ((state.rotationQuarters % 4) + 4) % 4
            item.zoomScale = CGFloat(min(max(state.zoomScale, 1), 6))
            item.panOffset = CGSize(width: state.panX, height: state.panY)
            item.abA = state.abA
            item.abB = state.abB
        }
        item.loopEnabled = loopEnabled
        item.subtitlesEnabled = subtitlesEnabled
        item.muteChanged = { [weak self, weak item] in
            guard let self, let item, !self.batchingAudioChanges else { return }
            self.applyAudio(to: item)
            self.markProjectEdited()
        }
        var pendingInitialPosition = initialPosition
        item.readyChanged = { [weak self, weak item] in
            guard let self else { return }
            if let item, let position = pendingInitialPosition {
                let resolved = position.followsLiveTimeline
                    ? self.livePlaybackPosition(excluding: item.id, fallback: position)
                    : position
                self.restore(resolved, for: item)
                pendingInitialPosition = nil
            }
            self.updateTimeObserver()
            self.scheduleProjectRestoreSeek()
            self.objectWillChange.send()
        }
        item.durationChanged = { [weak self] in
            self?.updateTimeObserver()
            self?.objectWillChange.send()
        }
        item.trackSelectionChanged = { [weak self] in
            self?.markProjectEdited()
        }
        if allowRecovery, sourceURL == nil {
            item.playbackFailed = { [weak self, weak item] in
                guard let item else { return }
                self?.recoverFailedPlayback(item)
            }
        }
        item.rateProvider = { [weak self, weak item] in
            guard let self, let item else { return 1 }
            return self.desiredRate(for: item)
        }
        if let insertionIndex {
            items.insert(item, at: min(max(insertionIndex, 0), items.count))
        } else {
            items.append(item)
        }
        scheduleProjectRestoreSeek()
        applyAudio()
        updateTimeObserver()
        saveSession()
        item.setSubtitleScale(subtitleScale)
        if isPlaying { item.play(rate: desiredRate(for: item)) }
        // 화면비가 늦게 로드되므로, 갱신되면 레이아웃을 다시 그리게 한다
        aspectCancellables[item.id] = item.$aspect
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// 사전 검사에서는 가능하다고 나왔지만 실제 디코더 준비가 실패한 경우,
    /// 같은 자리와 설정을 유지한 채 강제 호환 변환으로 한 번 더 시도한다.
    private func recoverFailedPlayback(_ item: VideoItem) {
        guard items.contains(where: { $0 === item }),
              !pendingReplacementIDs.contains(item.id)
        else { return }
        let source = item.sourceURL.standardizedFileURL
        let state = ProjectVideo(
            id: item.id,
            file: ProjectFileReference(
                absolutePath: source.path,
                relativePath: nil,
                fileName: source.lastPathComponent,
                fileSize: nil
            ),
            isMuted: item.isMuted,
            volume: item.volume,
            timeOffset: item.timeOffset,
            rotationQuarters: item.rotationQuarters,
            zoomScale: Double(item.zoomScale),
            panX: Double(item.panOffset.width),
            panY: Double(item.panOffset.height),
            audioTrackIndex: item.selectedAudioTrackIndex,
            audioTrackReference: item.selectedAudioTrackReference,
            subtitleTrackSelection: item.subtitleTrackSelection.persistenceKey,
            subtitleTrackReference: item.selectedSubtitleTrackReference,
            abA: item.abA,
            abB: item.abB
        )
        showNotice(String(localized: "\(source.lastPathComponent): 직접 재생에 실패해 호환 변환을 시도합니다"))
        beginReplacement(
            target: source,
            replacing: item,
            projectState: state,
            forceTranscode: true
        )
    }

    // MARK: - 재생목록

    func isOnStage(_ entry: PlaylistEntry) -> Bool {
        items.contains { $0.sourceURL.standardizedFileURL == entry.url }
    }

    /// 재생목록 항목을 화면에 추가하거나 화면에서 내린다
    func toggleOnStage(_ entry: PlaylistEntry) {
        if let item = items.first(where: { $0.sourceURL.standardizedFileURL == entry.url }) {
            remove(item)
        } else {
            stageAny(entry.url)
            applyAudio()
            updateTimeObserver()
            saveSession()
        }
        markProjectEdited()
    }

    func canReplaceSelectedItem(with entry: PlaylistEntry) -> Bool {
        guard let selectedItem else { return false }
        let target = entry.url.standardizedFileURL
        return selectedItem.sourceURL.standardizedFileURL != target
            && !pendingReplacementIDs.contains(selectedItem.id)
            && !isStaged(target)
            && !pendingSources.contains(target)
    }

    /// 현재 선택한 타일의 자리와 화면/오디오 설정은 유지하면서 미디어만 바꾼다.
    func replaceSelectedItem(with entry: PlaylistEntry) {
        guard let oldItem = selectedItem else {
            showNotice(String(localized: "먼저 모자이크에서 교체할 영상을 선택하세요"))
            return
        }
        let target = entry.url.standardizedFileURL
        guard oldItem.sourceURL.standardizedFileURL != target else { return }
        guard !pendingReplacementIDs.contains(oldItem.id) else {
            showNotice(String(localized: "선택한 영상은 이미 교체 중입니다"))
            return
        }
        guard !isStaged(target), !pendingSources.contains(target) else {
            showNotice(String(localized: "이 영상은 이미 모자이크에서 재생 중입니다"))
            return
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value
        let state = ProjectVideo(
            id: oldItem.id,
            file: ProjectFileReference(
                absolutePath: target.path,
                relativePath: nil,
                fileName: target.lastPathComponent,
                fileSize: fileSize
            ),
            isMuted: oldItem.isMuted,
            volume: oldItem.volume,
            timeOffset: oldItem.timeOffset,
            rotationQuarters: oldItem.rotationQuarters,
            zoomScale: Double(oldItem.zoomScale),
            panX: Double(oldItem.panOffset.width),
            panY: Double(oldItem.panOffset.height)
        )

        showNotice(String(localized: "선택 영상을 교체하는 중: \(target.lastPathComponent)"))
        beginReplacement(
            target: target,
            replacing: oldItem,
            projectState: state
        )
    }

    /// 기존 타일은 화면과 저장 상태에 그대로 둔 채 대상 파일만 준비한다.
    /// 준비에 성공한 순간에만 같은 배열 위치를 원자적으로 교체한다.
    private func beginReplacement(
        target: URL,
        replacing oldItem: VideoItem,
        projectState: ProjectVideo,
        forceTranscode: Bool = false
    ) {
        let source = target.standardizedFileURL
        guard items.contains(where: { $0 === oldItem }) else { return }
        guard pendingReplacementIDs.insert(oldItem.id).inserted else { return }
        guard pendingSources.insert(source).inserted else {
            pendingReplacementIDs.remove(oldItem.id)
            return
        }

        let request = ReplacementRequest(
            itemID: oldItem.id,
            previousSource: oldItem.sourceURL.standardizedFileURL,
            targetSource: source,
            projectState: projectState,
            generation: workspaceGeneration
        )

        if forceTranscode {
            convertReplacement(request, forceTranscode: true)
            return
        }

        Task { @MainActor [weak self] in
            let playable = await Remuxer.isNativelyPlayable(source)
            guard let self else { return }
            guard self.replacementIsCurrent(request) else {
                self.finishReplacement(request)
                return
            }
            switch Self.importStrategy(
                nativePlayable: playable,
                directPlaybackEnabled: self.directPlaybackEnabled,
                libmpvAvailable: MPVPlaybackEngine.isAvailable,
                compatibilityToolAvailable: Remuxer.ffmpegURL != nil
            ) {
            case .direct:
                self.commitReplacement(request, playbackURL: source)
            case .libmpv:
                let mpvPlayable = await MPVPlaybackEngine.canOpen(source)
                guard self.replacementIsCurrent(request) else {
                    self.finishReplacement(request)
                    return
                }
                if mpvPlayable {
                    self.commitReplacement(
                        request,
                        playbackURL: source,
                        backendKind: .libmpv
                    )
                } else if Remuxer.ffmpegURL != nil {
                    self.convertReplacement(request)
                } else {
                    self.finishReplacement(request)
                    self.showNotice(String(localized: "교체할 파일을 재생할 수 없어 기존 영상을 유지합니다"))
                }
            case .compatibilityProcessing:
                self.showNotice(String(localized: "\(source.lastPathComponent): 기본 재생으로 열 수 없어 호환 재생용 파일을 준비합니다"))
                self.convertReplacement(request)
            case .unsupported:
                self.finishReplacement(request)
                self.showNotice(String(localized: "교체할 파일을 재생할 수 없어 기존 영상을 유지합니다"))
            }
        }
    }

    private func convertReplacement(
        _ request: ReplacementRequest,
        forceTranscode: Bool = false
    ) {
        guard Remuxer.ffmpegURL != nil else {
            finishReplacement(request)
            showNotice(String(localized: "교체할 파일을 재생할 수 없어 기존 영상을 유지합니다"))
            return
        }
        let source = request.targetSource
        let jobKey = source.path
        remuxing[jobKey] = 0
        Task { @MainActor [weak self] in
            let result = await Remuxer.makePlayableCopy(source, forceTranscode: forceTranscode) { fraction in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.replacementIsCurrent(request),
                          self.remuxing[jobKey] != nil
                    else { return }
                    self.remuxing[jobKey] = Int(fraction * 100)
                }
            }
            guard let self else { return }
            self.remuxing.removeValue(forKey: jobKey)
            guard self.replacementIsCurrent(request) else {
                self.finishReplacement(request)
                return
            }
            switch result {
            case .success(let output):
                self.commitReplacement(request, playbackURL: output, sourceURL: source)
            case .failure(let failure):
                self.finishReplacement(request)
                let codecText = failure.videoCodec.map { String(localized: " (영상 코덱: \($0))") } ?? ""
                self.showNotice(String(localized: "\(source.lastPathComponent) 변환 실패\(codecText) — 기존 영상을 유지합니다"))
            }
        }
    }

    private func replacementIsCurrent(_ request: ReplacementRequest) -> Bool {
        workspaceGeneration == request.generation
            && pendingReplacementIDs.contains(request.itemID)
            && items.contains {
                $0.id == request.itemID
                    && $0.sourceURL.standardizedFileURL == request.previousSource
            }
    }

    private func finishReplacement(_ request: ReplacementRequest) {
        pendingReplacementIDs.remove(request.itemID)
        pendingSources.remove(request.targetSource)
    }

    private func commitReplacement(
        _ request: ReplacementRequest,
        playbackURL: URL,
        sourceURL: URL? = nil,
        backendKind: PlaybackBackendKind = .avFoundation
    ) {
        guard replacementIsCurrent(request),
              let index = items.firstIndex(where: { $0.id == request.itemID })
        else {
            finishReplacement(request)
            return
        }

        let oldItem = items[index]
        let position = currentPlaybackPosition(preferred: oldItem, followsLiveTimeline: isPlaying)
        oldItem.pause()
        items.remove(at: index)
        aspectCancellables.removeValue(forKey: oldItem.id)
        finishReplacement(request)
        stage(
            playbackURL,
            sourceURL: sourceURL,
            projectState: request.projectState,
            insertionIndex: index,
            initialPosition: position,
            backendKind: backendKind
        )
        markProjectEdited()
        showNotice(String(localized: "선택 영상 교체됨: \(request.targetSource.lastPathComponent)"))
    }

    func removeFromPlaylist(_ entry: PlaylistEntry) {
        playlist.removeAll { $0.id == entry.id }
        selectedPlaylist.remove(entry.url)
        if let item = items.first(where: { $0.sourceURL.standardizedFileURL == entry.url }) {
            remove(item)
        }
        saveSession()
        markProjectEdited()
    }

    func clearPlaylist() {
        playlist.removeAll()
        selectedPlaylist.removeAll()
        saveSession()
        markProjectEdited()
    }

    // MARK: - 재생목록 선택/삭제

    /// 다중 선택 (⌘/⇧ 클릭). 빈 곳 클릭이나 단순 클릭은 단일 선택.
    @Published var selectedPlaylist: Set<URL> = []
    private var lastClickedPlaylistIndex: Int?

    func clickPlaylist(_ entry: PlaylistEntry, index: Int, command: Bool, shift: Bool) {
        if shift, let anchor = lastClickedPlaylistIndex, anchor < playlist.count {
            let lo = min(anchor, index), hi = max(anchor, index)
            selectedPlaylist = Set(playlist[lo...hi].map { $0.url })
        } else if command {
            if selectedPlaylist.contains(entry.url) {
                selectedPlaylist.remove(entry.url)
            } else {
                selectedPlaylist.insert(entry.url)
            }
            lastClickedPlaylistIndex = index
        } else {
            selectedPlaylist = [entry.url]
            lastClickedPlaylistIndex = index
        }
    }

    func clearPlaylistSelection() {
        selectedPlaylist.removeAll()
    }

    /// 선택된 항목들을 목록에서 삭제하고, 화면에 올라가 있으면 같이 내린다
    func deleteSelectedFromPlaylist() {
        guard !selectedPlaylist.isEmpty else { return }
        let targets = selectedPlaylist
        for item in items where targets.contains(item.sourceURL.standardizedFileURL) {
            item.pause()
        }
        items.removeAll { targets.contains($0.sourceURL.standardizedFileURL) }
        aspectCancellables = aspectCancellables.filter { id, _ in items.contains { $0.id == id } }
        playlist.removeAll { targets.contains($0.url) }
        selectedPlaylist.removeAll()
        if items.isEmpty { isPlaying = false; progressModel.fraction = 0 }
        soloItemID = items.contains { $0.id == soloItemID } ? soloItemID : nil
        zoomedItemID = items.contains { $0.id == zoomedItemID } ? zoomedItemID : nil
        selectedItemID = items.contains { $0.id == selectedItemID } ? selectedItemID : nil
        updateTimeObserver()
        saveSession()
        markProjectEdited()
    }

    // MARK: - 세션 복원 / 최근 항목

    private let stagedKey = "session.staged"
    private let playlistKey = "session.playlist"
    private let recentKey = "recentItems"

    /// 현재 화면에 올라간 영상과 재생목록을 저장한다 (다음 실행 때 복원)
    func saveSession() {
        let staged = items.map { $0.sourceURL.path }
        UserDefaults.standard.set(staged, forKey: stagedKey)
        UserDefaults.standard.set(playlist.map { $0.url.path }, forKey: playlistKey)
    }

    /// 마지막 세션을 복원한다. 실행 시 파일 인자가 없을 때만 호출.
    func restoreSession() {
        guard items.isEmpty, playlist.isEmpty else { return }
        let fm = FileManager.default
        let playlistPaths = UserDefaults.standard.stringArray(forKey: playlistKey) ?? []
        appendToPlaylist(playlistPaths.map { URL(fileURLWithPath: $0) }.filter { fm.fileExists(atPath: $0.path) })
        let stagedPaths = UserDefaults.standard.stringArray(forKey: stagedKey) ?? []
        for path in stagedPaths where fm.fileExists(atPath: path) {
            stageAny(URL(fileURLWithPath: path))
        }
        applyAudio()
        updateTimeObserver()
    }

    var recentItems: [URL] {
        (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func openRecent(_ url: URL) {
        add(urls: [url])
    }

    func clearRecent() {
        UserDefaults.standard.removeObject(forKey: recentKey)
        objectWillChange.send()
    }

    private func rememberRecent(_ urls: [URL]) {
        var paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        for url in urls.reversed() {
            let path = url.path
            paths.removeAll { $0 == path }
            paths.insert(path, at: 0)
        }
        UserDefaults.standard.set(Array(paths.prefix(12)), forKey: recentKey)
    }

    private func appendToPlaylist(_ urls: [URL]) {
        var known = Set(playlist.map(\.url))
        for url in urls {
            let standardized = url.standardizedFileURL
            guard known.insert(standardized).inserted else { continue }
            playlist.append(PlaylistEntry(url: standardized))
        }
    }

    private func videosInFolder(_ folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { Self.isVideoFile($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// macOS가 컨테이너를 지원하지 않아 사전 검사 없이 변환하는 확장자
    static let remuxExtensions: Set<String> = ["mkv", "webm"]

    enum ImportStrategy: Equatable {
        case direct
        case libmpv
        case compatibilityProcessing
        case unsupported
    }

    /// 확장자와 무관하게 macOS가 실제로 재생할 수 있으면 원본을 그대로 사용한다.
    static func importStrategy(
        nativePlayable: Bool,
        directPlaybackEnabled: Bool = false,
        libmpvAvailable: Bool = false,
        compatibilityToolAvailable: Bool
    ) -> ImportStrategy {
        if nativePlayable { return .direct }
        if directPlaybackEnabled, libmpvAvailable { return .libmpv }
        return compatibilityToolAvailable ? .compatibilityProcessing : .unsupported
    }

    /// Finder·열기 패널·폴더 검색에서 영상으로 취급하는 확장자. 실제 지원
    /// 가능 여부는 AVFoundation/ffmpeg 검사로 최종 결정한다.
    static let supportedVideoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "avi",
        "mkv", "webm", "wmv", "asf", "flv",
        "mpg", "mpeg", "mpe", "vob", "ts", "mts", "m2ts",
        "ogv", "3gp", "3g2", "mxf", "divx", "f4v",
        "rm", "rmvb", "m1v", "m2v", "dv", "y4m",
        "h264", "264", "hevc", "h265",
    ]

    static func needsRemux(_ url: URL) -> Bool {
        remuxExtensions.contains(url.pathExtension.lowercased())
    }

    static func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// 화면의 모든 영상을 닫는다 (재생목록은 유지)
    func closeAll() {
        // 진행 중인 사전 검사·호환 변환 결과가 닫은 뒤 다시 나타나지 않게 한다.
        workspaceGeneration = UUID()
        pendingSources.removeAll()
        pendingReplacementIDs.removeAll()
        remuxing.removeAll()
        items.forEach { $0.pause() }
        items.removeAll()
        aspectCancellables.removeAll()
        soloItemID = nil
        zoomedItemID = nil
        selectedItemID = nil
        rectSwaps.removeAll()
        isPlaying = false
        progressModel.fraction = 0
        abA = nil
        abB = nil
        updateTimeObserver()
        saveSession()
        markProjectEdited()
    }

    func remove(_ item: VideoItem) {
        item.pause()
        items.removeAll { $0.id == item.id }
        aspectCancellables.removeValue(forKey: item.id)
        if soloItemID == item.id { soloItemID = nil }
        if zoomedItemID == item.id { zoomedItemID = nil }
        if selectedItemID == item.id { selectedItemID = items.first?.id }
        // 제거된 영상이 끼어 있는 자리 교환은 풀어준다
        rectSwaps = rectSwaps.filter { $0.key != item.id && $0.value != item.id }
        if items.isEmpty {
            isPlaying = false
            progressModel.fraction = 0
        }
        updateTimeObserver()
        saveSession()
        markProjectEdited()
    }

    /// 디코딩 해상도 제한을 디바운스해서 적용한다. 창 크기를 드래그하는
    /// 동안 매 프레임 디코더가 재설정되는 것을 막는다.
    func scheduleResolutionCaps(_ sizes: [UUID: CGSize]) {
        let unchanged = sizes.count == pendingCaps.count && sizes.allSatisfy { id, size in
            guard let previous = pendingCaps[id] else { return false }
            return abs(previous.width - size.width) < 1 && abs(previous.height - size.height) < 1
        }
        guard !unchanged else { return }
        pendingCaps = sizes
        capsTask?.cancel()
        capsTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            for item in self.items {
                if let size = self.pendingCaps[item.id] {
                    item.applyResolutionCap(size)
                }
            }
        }
    }

    /// 전체 타임라인 기준으로 모든 영상을 몇 초 앞뒤로 이동
    func seekRelative(_ seconds: Double) {
        let duration = maxDuration
        guard duration > 0 else { return }
        let target = min(max(progress * duration + seconds, 0), duration)
        seekAll(to: target / duration)
    }

    /// 하나라도 소리가 나는 영상이 있으면 전부 음소거, 아니면 전부 해제
    func toggleMuteAll() {
        let shouldMute = !items.allSatisfy(\.isMuted)
        batchingAudioChanges = true
        for item in items where item.isMuted != shouldMute {
            item.isMuted = shouldMute
        }
        batchingAudioChanges = false
        applyAudio()
        markProjectEdited()
    }

    func toggleSolo(_ item: VideoItem) {
        soloItemID = soloItemID == item.id ? nil : item.id
    }

    func select(_ item: VideoItem) {
        guard selectedItemID != item.id else { return }
        selectedItemID = item.id
    }

    func toggleZoom(_ item: VideoItem) {
        selectedItemID = item.id
        if zoomedItemID == item.id {
            zoomedItemID = nil
            soloItemID = nil
        } else {
            zoomedItemID = item.id
            soloItemID = item.id
        }
    }

    private func applyAudio(to item: VideoItem) {
        let muted = soloItemID.map { $0 != item.id } ?? item.isMuted
        item.applyOutputAudio(muted: muted, volume: masterVolume * item.volume)
    }

    private func applyAudio() {
        items.forEach(applyAudio(to:))
    }

    func togglePlayAll() {
        isPlaying ? pauseAll() : playAll()
    }

    func playAll() {
        // 상대 모드에서는 영상별로 다른 속도로 재생해 같은 비율을 유지한다
        items.forEach { $0.play(rate: desiredRate(for: $0)) }
        isPlaying = true
    }

    func pauseAll() {
        items.forEach { $0.pause() }
        isPlaying = false
    }

    private func seek(
        _ item: VideoItem,
        to seconds: Double,
        exact: Bool = true
    ) {
        let duration = item.durationSeconds
        let target = duration > 0
            ? min(max(seconds, 0), duration)
            : max(seconds, 0)
        item.seek(toSeconds: target, exact: exact)
    }

    private func currentPlaybackPosition(
        preferred: VideoItem? = nil,
        excluding excludedID: UUID? = nil,
        followsLiveTimeline: Bool
    ) -> InitialPlaybackPosition {
        let candidates = items.filter { item in
            item.id != excludedID
                && item.durationSeconds > 0
                && item.currentTimeSeconds.isFinite
        }
        let reference = candidates.first { $0 === observedItem }
            ?? preferred.flatMap { preferred in
                candidates.first { $0 === preferred }
            }
            ?? candidates.max { $0.durationSeconds < $1.durationSeconds }

        if relativeTimeline {
            let fraction: Double
            if let reference {
                fraction = (reference.currentTimeSeconds - reference.timeOffset)
                    / reference.durationSeconds
            } else {
                fraction = progress
            }
            let clamped = min(max(fraction, 0), 1)
            return InitialPlaybackPosition(
                seconds: clamped * maxDuration,
                fraction: clamped,
                relative: true,
                followsLiveTimeline: followsLiveTimeline
            )
        }

        let seconds = max(
            reference.map { $0.currentTimeSeconds - $0.timeOffset }
                ?? progress * maxDuration,
            0
        )
        let fraction = maxDuration > 0 ? min(max(seconds / maxDuration, 0), 1) : progress
        return InitialPlaybackPosition(
            seconds: seconds,
            fraction: fraction,
            relative: false,
            followsLiveTimeline: followsLiveTimeline
        )
    }

    private func livePlaybackPosition(
        excluding itemID: UUID,
        fallback: InitialPlaybackPosition
    ) -> InitialPlaybackPosition {
        let hasReference = items.contains {
            $0.id != itemID
                && $0.durationSeconds > 0
                && $0.currentTimeSeconds.isFinite
        }
        guard hasReference else {
            return InitialPlaybackPosition(
                seconds: fallback.seconds,
                fraction: fallback.fraction,
                relative: fallback.relative,
                followsLiveTimeline: false
            )
        }
        return currentPlaybackPosition(
            excluding: itemID,
            followsLiveTimeline: false
        )
    }

    private func restore(_ position: InitialPlaybackPosition, for item: VideoItem) {
        if position.relative {
            seek(item, to: position.fraction * item.durationSeconds + item.timeOffset)
            progressModel.fraction = min(max(position.fraction, 0), 1)
        } else {
            seek(item, to: position.seconds + item.timeOffset)
            if maxDuration > 0 {
                progressModel.fraction = min(max(position.seconds / maxDuration, 0), 1)
            }
        }
    }

    func seekAll(to fraction: Double) {
        let base = fraction * maxDuration
        // 스크럽 중에는 영상 N개를 매 틱마다 정밀 시크하면 무거우므로
        // 키프레임 단위로 따라가고, 손을 떼는 순간 정밀 시크로 보정한다
        let exact = !isScrubbing
        for item in items {
            let dur = item.durationSeconds
            // 상대 모드: 각 영상의 자기 길이 비율 지점. 절대 모드: 같은 시각.
            let time = relativeTimeline ? fraction * dur + item.timeOffset
                                        : base + item.timeOffset
            seek(item, to: time, exact: exact)
        }
        progressModel.fraction = fraction
    }

    /// 일시정지 상태에서 모든 영상을 프레임 단위로 이동 (비교·분석용)
    func stepFrames(_ count: Int) {
        if isPlaying { pauseAll() }
        for item in items {
            item.stepFrames(count)
        }
        // 진행률을 가장 긴 영상 기준으로 갱신
        if let master = observedItem ?? items.first, maxDuration > 0 {
            progressModel.fraction = min(master.currentTimeSeconds / maxDuration, 1)
        }
    }

    /// 개별 영상의 시간 오프셋을 delta초만큼 조정하고 그 영상만 다시 맞춘다
    /// 개별 영상 구간반복: 한 번 = A 지점, 두 번 = B 지점 + 반복 시작, 세 번 = 해제.
    /// 지점은 그 영상 자체 길이의 비율로 잡는다.
    func cycleABLoop(_ item: VideoItem) {
        let dur = item.durationSeconds
        let fraction = dur > 0 ? min(max(item.currentTimeSeconds / dur, 0), 1) : 0
        if item.abA == nil {
            item.abA = fraction
        } else if item.abB == nil {
            if fraction > (item.abA ?? 0) + 0.005 {
                item.abB = fraction
            } else {
                item.abA = nil
            }
        } else {
            item.abA = nil
            item.abB = nil
        }
        // 기준 영상이 구간반복을 시작·해제하면 타임라인 기준을 다시 고른다
        updateTimeObserver()
        markProjectEdited()
    }

    /// 개별 시크바: 그 영상만 지정 지점으로 옮긴다. 재생 중 드리프트 보정이
    /// 1초 안에 원래 위치로 되돌리지 않도록, 시간 정렬(timeOffset)을 새 지점
    /// 기준으로 함께 갱신해 이후에도 그 간격을 유지한 채 동기화한다.
    func seekIndividually(_ item: VideoItem, to fraction: Double) {
        item.seek(to: fraction)
        let dur = item.durationSeconds
        guard dur > 0 else { return }
        let base = relativeTimeline ? progress * dur : progress * maxDuration
        item.timeOffset = fraction * dur - base
        markProjectEdited()
    }

    func adjustOffset(_ item: VideoItem, by delta: Double) {
        item.timeOffset += delta
        let base = relativeTimeline ? progress * item.durationSeconds : progress * maxDuration
        var t = base + item.timeOffset
        let dur = item.durationSeconds
        if dur > 0 { t = min(max(t, 0), dur) } else { t = max(t, 0) }
        item.seek(toSeconds: t)
        markProjectEdited()
    }

    func resetOffset(_ item: VideoItem) {
        guard item.timeOffset != 0 else { return }
        adjustOffset(item, by: -item.timeOffset)
    }

    func rotate(_ item: VideoItem) {
        item.rotationQuarters = (item.rotationQuarters + 1) % 4
        objectWillChange.send() // 회전이 화면비를 바꿔 레이아웃 재계산
        markProjectEdited()
    }

    // MARK: - 리프레임 (타일 내부 확대·이동)

    /// 스크롤로 확대 배율을 조정한다 (1~6배). focus는 커서의 타일 내 위치
    /// (중심 0, 범위 -0.5…0.5, x는 오른쪽·y는 아래). 그 지점이 제자리에 남도록
    /// 이동량을 함께 보정해서 "커서 기준 확대"가 되게 한다.
    func adjustZoom(_ item: VideoItem, by delta: CGFloat, focus: CGPoint = .zero) {
        let old = item.zoomScale
        let new = min(max(old + delta, 1), 6)
        guard new != old else { return }
        let ratio = new / old
        let proposedPan = CGSize(
            width: focus.x - ratio * (focus.x - item.panOffset.width),
            height: focus.y - ratio * (focus.y - item.panOffset.height)
        )
        item.zoomScale = new
        item.panOffset = clampedPan(proposedPan, scale: new)
        markProjectEdited()
    }

    /// Option+드래그로 보이는 영역을 이동한다. 오프셋은 타일 크기 대비 비율.
    func setPan(_ item: VideoItem, to offset: CGSize) {
        let clamped = clampedPan(offset, scale: item.zoomScale)
        guard clamped != item.panOffset else { return }
        item.panOffset = clamped
        markProjectEdited()
    }

    func setZoom(_ item: VideoItem, to scale: CGFloat) {
        adjustZoom(item, by: scale - item.zoomScale)
    }

    /// 확대 배율 안에서 영상이 화면 밖으로 완전히 벗어나지 않도록 이동을 제한
    private func clampedPan(_ offset: CGSize, scale: CGFloat) -> CGSize {
        let limit = max(0, (scale - 1) / (2 * scale))
        return CGSize(
            width: min(max(offset.width, -limit), limit),
            height: min(max(offset.height, -limit), limit)
        )
    }

    // MARK: - 스냅샷

    /// ContentView가 매 레이아웃마다 현재 배치를 기록한다 (메뉴에서 스냅샷 호출 가능).
    /// @Published가 아니라서 기록 자체는 뷰를 다시 그리지 않는다.
    private(set) var snapshotRects: [UUID: CGRect] = [:]
    private(set) var snapshotCanvas: CGSize = .zero
    private(set) var snapshotFill = true

    func recordLayout(rects: [UUID: CGRect], canvas: CGSize, fill: Bool) {
        snapshotRects = rects
        snapshotCanvas = canvas
        snapshotFill = fill
    }

    func saveSnapshot() {
        guard !items.isEmpty, snapshotCanvas.width > 0 else { return }
        let tiles = items.compactMap { item in
            snapshotRects[item.id].map {
                Snapshotter.Tile(
                    url: item.url,
                    timeSeconds: item.currentTimeSeconds,
                    rect: $0,
                    rotationQuarters: item.rotationQuarters,
                    prefersFFmpeg: item.usesMPV
                )
            }
        }
        let canvas = snapshotCanvas
        let fill = snapshotFill
        Task { @MainActor in
            if let url = await Snapshotter.capture(tiles: tiles, canvas: canvas, fill: fill) {
                showNotice(String(localized: "스냅샷 저장됨: \(url.lastPathComponent)"))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                showNotice(String(localized: "스냅샷 저장에 실패했습니다"))
            }
        }
    }

    // MARK: - 모자이크 영상 내보내기

    func exportMosaicVideo() {
        guard !isExportingMosaic else { return }
        guard Remuxer.ffmpegURL != nil else {
            showNotice(String(localized: "영상 내보내기에는 ffmpeg가 필요합니다"))
            return
        }
        guard snapshotCanvas.width > 0, snapshotCanvas.height > 0 else {
            showNotice(String(localized: "내보낼 레이아웃 정보가 없습니다"))
            return
        }

        let visible = items.compactMap { item -> (VideoItem, CGRect)? in
            guard let rect = snapshotRects[item.id], item.durationSeconds > 0 else { return nil }
            return (item, rect)
        }
        guard !visible.isEmpty else {
            showNotice(String(localized: "재생 준비가 끝난 영상이 없습니다"))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        panel.nameFieldStringValue = "Tilo_Mosaic_\(formatter.string(from: Date())).mp4"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let outputURL = selected.pathExtension.lowercased() == "mp4"
            ? selected
            : selected.appendingPathExtension("mp4")

        let duration = visible.map { $0.0.durationSeconds }.max() ?? 0
        let outputSize = mosaicOutputSize(for: snapshotCanvas)
        let maxFrameRate = visible.map { Double($0.0.nominalFrameRate) }.max() ?? 0
        let framesPerSecond = maxFrameRate >= 50 ? 60 : maxFrameRate >= 28 ? 30 : 24
        let solo = soloItemID
        let tiles = visible.map { item, rect in
            let audible = masterVolume > 0.001
                && item.hasAudio
                && (solo.map { $0 == item.id } ?? !item.isMuted)
            return MosaicExporter.Tile(
                url: item.url,
                rect: rect,
                duration: item.durationSeconds,
                timeOffset: item.timeOffset,
                rotationQuarters: item.rotationQuarters,
                zoomScale: item.zoomScale,
                panOffset: item.panOffset,
                includeAudio: audible,
                audioVolume: masterVolume * item.volume,
                audioStreamIndex: item.effectiveAudioTrackIndex
            )
        }
        let request = MosaicExporter.Request(
            tiles: tiles,
            canvasSize: snapshotCanvas,
            outputSize: outputSize,
            duration: duration,
            framesPerSecond: framesPerSecond,
            fill: snapshotFill,
            relativeTimeline: relativeTimeline,
            loopEnabled: loopEnabled,
            outputURL: outputURL
        )
        let session = MosaicExporter.Session()
        mosaicExportSession = session
        mosaicExportProgress = 0
        mosaicExportTask = Task { @MainActor [weak self] in
            let result = await MosaicExporter.export(request, session: session) { fraction in
                Task { @MainActor [weak self, weak session] in
                    guard let self, let session, self.mosaicExportSession === session else { return }
                    self.mosaicExportProgress = Int((fraction * 100).rounded())
                }
            }
            guard let self, self.mosaicExportSession === session else { return }
            self.mosaicExportTask = nil
            self.mosaicExportSession = nil
            self.mosaicExportProgress = nil
            switch result {
            case .success(let url):
                self.showNotice(String(localized: "모자이크 영상 저장됨: \(url.lastPathComponent)"))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(.cancelled):
                self.showNotice(String(localized: "영상 내보내기가 취소되었습니다"))
            case .failure(let error):
                if case .encodingFailed(let logURL) = error, let logURL {
                    self.showNotice(String(localized: "영상 내보내기 실패 — 로그: \(logURL.path)"))
                } else {
                    self.showNotice(error.localizedDescription)
                }
            }
        }
    }

    func cancelMosaicExport(showsNotice: Bool = true) {
        guard isExportingMosaic else { return }
        mosaicExportSession?.cancel()
        mosaicExportTask?.cancel()
        mosaicExportTask = nil
        mosaicExportSession = nil
        mosaicExportProgress = nil
        if showsNotice { showNotice(String(localized: "영상 내보내기가 취소되었습니다")) }
    }

    private func mosaicOutputSize(for canvas: CGSize) -> CGSize {
        let aspect = canvas.width / canvas.height
        var height = 1080
        var width = Int((CGFloat(height) * aspect).rounded())
        if width > 3840 {
            width = 3840
            height = Int((CGFloat(width) / aspect).rounded())
        }
        width = max(2, width - width % 2)
        height = max(2, height - height % 2)
        return CGSize(width: width, height: height)
    }

    /// 진행률 추적 기준 플레이어를 다시 고른다. 길이가 가장 긴 영상이
    /// 끝까지 시간을 보고하므로 그 플레이어를 기준으로 삼는다.
    private func updateTimeObserver() {
        let readyItems = items.filter(\.mediaReady)
        let candidates = readyItems.isEmpty ? items : readyItems
        // 개별 구간반복 중인 영상은 시간이 계속 되돌아가므로 타임라인 기준에서 제외
        let steady = candidates.filter { $0.abA == nil || $0.abB == nil }
        let masterCandidates = steady.isEmpty ? candidates : steady
        let master = masterCandidates.max { $0.durationSeconds < $1.durationSeconds }
        cachedMaxDuration = items.lazy.map(\.durationSeconds).max() ?? 0

        // 같은 기준 영상이면 기존 관찰 작업을 유지한다.
        if let master, observedItem === master, progressObservationTask != nil { return }

        progressObservationTask?.cancel()
        progressObservationTask = nil
        observedItem = nil

        guard let master else { return }

        observedItem = master
        progressObservationTask = Task { @MainActor [weak self, weak master] in
            var synchronizationTick = 0
            while !Task.isCancelled {
                guard let self, let master, self.observedItem === master else { return }
                if !self.isScrubbing, self.isPlaying {
                    self.enforceItemABLoops()
                }
                if !self.isScrubbing {
                    let timelineTime = master.currentTimeSeconds - master.timeOffset
                    let timelineDuration = self.relativeTimeline
                        ? master.durationSeconds
                        : self.cachedMaxDuration
                    if timelineDuration > 0 {
                        let fraction = min(max(timelineTime / timelineDuration, 0), 1)
                        if abs(fraction - self.progressModel.fraction) > 0.0001 {
                            self.progressModel.fraction = fraction
                        }
                        if let a = self.abA, let b = self.abB,
                           fraction >= b, self.isPlaying {
                            self.seekAll(to: a)
                        } else if self.isPlaying, synchronizationTick % 4 == 0 {
                            // 250ms 관찰 주기의 네 번째마다만 비교해 디코더 부하를
                            // 늘리지 않으면서 장시간 clock drift를 억제한다.
                            self.correctPlaybackDrift(
                                relativeTo: master,
                                timelineTime: timelineTime,
                                timelineFraction: fraction
                            )
                        }
                    }
                }
                synchronizationTick = (synchronizationTick + 1) % 4
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// 개별 영상 A-B 구간반복: B 지점을 지나면 A 지점으로 되돌린다.
    /// mpv 영상은 네이티브 ab-loop가 처리하므로 AVFoundation 영상만 감시한다.
    private func enforceItemABLoops() {
        for item in items where item.mediaReady {
            guard let a = item.abA, let b = item.abB, !item.usesNativeABLoop else { continue }
            let dur = item.durationSeconds
            guard dur > 0, !item.seekSettling else { continue }
            if item.currentTimeSeconds / dur >= b {
                item.seek(to: a)
            }
        }
    }

    private func correctPlaybackDrift(
        relativeTo master: VideoItem,
        timelineTime: Double,
        timelineFraction: Double
    ) {
        guard items.count > 1 else { return }

        for item in items where item !== master && item.mediaReady {
            let duration = item.durationSeconds
            guard duration > 0 else { continue }
            // 직전 시크가 아직 자리 잡는 중이면 보정 시크를 겹쳐 걸지 않는다.
            // 매 틱마다 정밀 시크를 다시 걸면 영상이 재생되지 못하고 기어간다.
            guard !item.seekSettling else { continue }
            // 개별 구간반복 중인 영상은 의도적으로 타임라인과 어긋난 상태다
            guard item.abA == nil || item.abB == nil else { continue }

            let target: Double
            if relativeTimeline {
                target = timelineFraction * duration + item.timeOffset
                // 개별 시크로 오프셋이 커져 범위를 벗어난 구간에서는 강제 이동하지 않는다
                guard target >= 0, target < duration else { continue }
            } else {
                target = timelineTime + item.timeOffset
                // 더 짧은 영상이 먼저 끝나 독립적으로 반복되는 구간에서는
                // 가장 긴 영상의 시각으로 강제 이동하지 않는다.
                guard target >= 0, target < duration else { continue }
            }

            let current = item.currentTimeSeconds
            guard target.isFinite, current.isFinite,
                  abs(current - target) > playbackDriftTolerance
            else { continue }

            seek(item, to: target)
        }
    }
}
