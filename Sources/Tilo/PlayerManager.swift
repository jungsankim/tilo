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
    let id = UUID()
    /// 실제 재생 URL (MKV 변환본일 수 있음)
    let url: URL
    /// 원본 파일 — 표시 이름, 자막 탐색, 중복 판정에 쓴다
    let sourceURL: URL
    let player: AVPlayer

    /// 사용자가 설정한 음소거 (솔로가 켜져 있으면 솔로가 우선한다)
    @Published var isMuted: Bool = false {
        didSet { muteChanged?() }
    }
    var muteChanged: (() -> Void)?

    /// 영상의 실제 화면비(가로/세로). 로드 전에는 16:9로 가정한다.
    @Published var aspect: CGFloat = 16.0 / 9.0

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
    /// 코덱 미지원 등으로 재생에 실패하면 셀에 안내를 띄운다
    @Published var loadFailed = false
    /// 현재 시각에 표시할 자막 (외부 .srt/.smi)
    @Published var currentSubtitle: String?
    var isScrubbing = false
    var loopEnabled = true

    var subtitlesEnabled = true {
        didSet {
            applyEmbeddedSubtitles()
            if !subtitlesEnabled { currentSubtitle = nil }
        }
    }

    /// 시크바가 보이는 동안만 진행률을 발행해서 불필요한 뷰 갱신을 줄인다
    var progressActive = false {
        didSet { if progressActive { publishProgressNow() } }
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusCancellable: AnyCancellable?
    private var appliedResolutionCap: CGSize = .zero
    private var subtitleCues: [SubtitleCue] = []
    private var legibleGroup: AVMediaSelectionGroup?

    init(url: URL, sourceURL: URL? = nil) {
        self.url = url
        self.sourceURL = sourceURL ?? url
        self.player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        // 충분히 버퍼링될 때까지 기다려 스톨(끊김)을 줄인다
        player.automaticallyWaitsToMinimizeStalling = true
        // 네트워크(NAS/SMB) 파일은 대역폭을 여러 스트림이 나눠 쓰므로,
        // 순간적인 정체를 흡수하도록 미리 더 많이 버퍼링한다.
        // 로컬 파일은 기본값(0=자동)으로 둬서 메모리를 아낀다.
        if Self.isNetworkURL(url) {
            player.currentItem?.preferredForwardBufferDuration = 10
        }
        loadAspect()

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.updateSubtitle(at: time.seconds)
            guard self.progressActive, !self.isScrubbing else { return }
            guard let duration = self.player.currentItem?.duration.seconds,
                  duration.isFinite, duration > 0 else { return }
            self.progress = min(time.seconds / duration, 1)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.loopEnabled else { return }
            self.player.seek(to: .zero)
            self.player.play()
        }
        statusCancellable = player.currentItem?.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .failed { self?.loadFailed = true }
            }
        loadSubtitles()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    var durationSeconds: Double {
        guard let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    func seek(to fraction: Double) {
        let duration = durationSeconds
        guard duration > 0 else { return }
        let time = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        // 스크럽 중에는 키프레임 단위로 빠르게, 끝나면 정밀하게 이동한다
        let tolerance: CMTime = isScrubbing ? .positiveInfinity : .zero
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        progress = fraction
    }

    private func publishProgressNow() {
        guard let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        progress = min(player.currentTime().seconds / duration, 1)
    }

    // MARK: - 자막

    private func loadSubtitles() {
        // 자막은 원본 파일 옆에서 찾는다 (movie.mkv → movie.smi)
        let videoURL = sourceURL
        Task { [weak self] in
            let cues = SubtitleLoader.load(for: videoURL)
            let group = try? await self?.player.currentItem?.asset
                .loadMediaSelectionGroup(for: .legible)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.subtitleCues = cues
                self.legibleGroup = group ?? nil
                self.applyEmbeddedSubtitles()
            }
        }
    }

    /// 외부 자막 파일이 없을 때만 영상에 내장된 자막 트랙을 켠다
    private func applyEmbeddedSubtitles() {
        guard let group = legibleGroup, let currentItem = player.currentItem else { return }
        if subtitlesEnabled, subtitleCues.isEmpty {
            currentItem.select(group.options.first ?? group.defaultOption, in: group)
        } else if group.allowsEmptySelection {
            currentItem.select(nil, in: group)
        }
    }

    private func updateSubtitle(at seconds: Double) {
        guard subtitlesEnabled, !subtitleCues.isEmpty else { return }
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
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return }
            let rotated = size.applying(transform)
            let width = abs(rotated.width)
            let height = abs(rotated.height)
            if width > 0, height > 0 { aspect = width / height }
        }
    }
}

struct PlaylistEntry: Identifiable, Equatable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

final class PlayerManager: ObservableObject {
    /// Finder "다음으로 열기" 등 AppDelegate 경로에서도 같은 인스턴스를 쓴다
    static let shared = PlayerManager()

    @Published var items: [VideoItem] = []
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
        didSet { items.forEach { $0.loopEnabled = loopEnabled } }
    }

    /// 오디오 솔로: 설정되면 이 영상만 소리가 나고 나머지는 음소거
    @Published var soloItemID: UUID? {
        didSet { applyAudio() }
    }

    /// 자막 표시 (외부 .srt/.smi + 내장 자막 트랙)
    @Published var subtitlesEnabled = true {
        didSet { items.forEach { $0.subtitlesEnabled = subtitlesEnabled } }
    }

    /// 전역 볼륨 (0...1). 각 영상의 개별 볼륨과 곱해진다.
    @Published var masterVolume: Double = UserDefaults.standard.object(forKey: "masterVolume") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
            applyAudio()
        }
    }

    /// A-B 구간반복 지점 (전역 진행률 분수). 둘 다 설정되면 활성.
    @Published var abA: Double?
    @Published var abB: Double?

    /// MP4로 변환 중인 파일들 (이름 → 진행률 %)
    @Published var remuxing: [String: Int] = [:]
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
    }

    /// 더블클릭 확대로 단독 표시 중인 영상
    @Published var zoomedItemID: UUID?

    private var timeObserver: Any?
    private var observedPlayer: AVPlayer?
    private var cancellables: Set<AnyCancellable> = []
    private var pendingCaps: [UUID: CGSize] = [:]
    private var capsTask: Task<Void, Never>?

    var maxDuration: Double {
        items
            .compactMap { $0.player.currentItem?.duration.seconds }
            .filter { $0.isFinite }
            .max() ?? 0
    }

    func openVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        types += Self.remuxExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func add(urls: [URL]) {
        for url in urls {
            if url.hasDirectoryPath {
                // 폴더를 통째로 넣으면 재생목록에만 등록한다
                // (수십 개를 한꺼번에 화면에 띄우지 않도록)
                appendToPlaylist(videosInFolder(url))
            } else if Self.isVideoFile(url) {
                stageAny(url)
                appendToPlaylist(videosInFolder(url.deletingLastPathComponent()))
                appendToPlaylist([url])
            }
        }
        rememberRecent(urls)
        applyAudio()
        updateTimeObserver()
        saveSession()
    }

    /// 네이티브 형식은 바로, MKV/WebM은 변환을 거쳐 화면에 올린다
    private func stageAny(_ url: URL) {
        if Self.needsRemux(url) {
            convertAndStage(url)
        } else {
            stage(url)
        }
    }

    private func convertAndStage(_ source: URL) {
        guard !isStaged(source) else { return }
        guard Remuxer.ffmpegURL != nil else {
            showNotice(String(localized: "MKV/WebM 재생에는 ffmpeg가 필요합니다 — 터미널에서 brew install ffmpeg"))
            stage(source)
            return
        }
        let name = source.lastPathComponent
        remuxing[name] = 0
        Task { @MainActor in
            let result = await Remuxer.remux(source) { fraction in
                Task { @MainActor [weak self] in
                    if self?.remuxing[name] != nil {
                        self?.remuxing[name] = Int(fraction * 100)
                    }
                }
            }
            remuxing.removeValue(forKey: name)
            switch result {
            case .success(let output):
                stage(output, sourceURL: source)
            case .failure(let failure):
                if let codec = failure.videoCodec, ["vp8", "vp9"].contains(codec) {
                    showNotice(String(localized: "\(name): \(codec.uppercased()) 코덱은 macOS에서 재생할 수 없습니다 (재인코딩 필요)"))
                } else {
                    let codecText = failure.videoCodec.map { String(localized: " (영상 코덱: \($0))") } ?? ""
                    showNotice(String(localized: "\(name) 변환 실패\(codecText) — 로그: ~/Library/Logs/Tilo/remux.log"))
                }
                stage(source)
            }
            applyAudio()
            updateTimeObserver()
        }
    }

    private func isStaged(_ url: URL) -> Bool {
        items.contains { $0.sourceURL.standardizedFileURL == url.standardizedFileURL }
    }

    /// 영상 하나를 화면(스테이지)에 올린다. 이미 올라간 영상은 무시.
    private func stage(_ url: URL, sourceURL: URL? = nil) {
        guard !isStaged(sourceURL ?? url) else { return }
        let item = VideoItem(url: url, sourceURL: sourceURL)
        item.loopEnabled = loopEnabled
        item.subtitlesEnabled = subtitlesEnabled
        item.muteChanged = { [weak self] in self?.applyAudio() }
        items.append(item)
        if isPlaying { item.player.play() }
        // 화면비가 늦게 로드되므로, 갱신되면 레이아웃을 다시 그리게 한다
        item.$aspect
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
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
    }

    func removeFromPlaylist(_ entry: PlaylistEntry) {
        playlist.removeAll { $0.id == entry.id }
        if let item = items.first(where: { $0.sourceURL.standardizedFileURL == entry.url }) {
            remove(item)
        }
        saveSession()
    }

    func clearPlaylist() {
        playlist.removeAll()
        saveSession()
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

    /// macOS가 컨테이너를 지원하지 않아 변환이 필요한 확장자
    static let remuxExtensions: Set<String> = ["mkv", "webm"]

    static func needsRemux(_ url: URL) -> Bool {
        remuxExtensions.contains(url.pathExtension.lowercased())
    }

    static func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if remuxExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// 화면의 모든 영상을 닫는다 (재생목록은 유지)
    func closeAll() {
        items.forEach { $0.player.pause() }
        items.removeAll()
        soloItemID = nil
        zoomedItemID = nil
        rectSwaps.removeAll()
        isPlaying = false
        progressModel.fraction = 0
        abA = nil
        abB = nil
        updateTimeObserver()
        saveSession()
    }

    func remove(_ item: VideoItem) {
        item.player.pause()
        items.removeAll { $0.id == item.id }
        if soloItemID == item.id { soloItemID = nil }
        if zoomedItemID == item.id { zoomedItemID = nil }
        // 제거된 영상이 끼어 있는 자리 교환은 풀어준다
        rectSwaps = rectSwaps.filter { $0.key != item.id && $0.value != item.id }
        if items.isEmpty {
            isPlaying = false
            progressModel.fraction = 0
        }
        updateTimeObserver()
        saveSession()
    }

    /// 디코딩 해상도 제한을 디바운스해서 적용한다. 창 크기를 드래그하는
    /// 동안 매 프레임 디코더가 재설정되는 것을 막는다.
    func scheduleResolutionCaps(_ sizes: [UUID: CGSize]) {
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
        items.forEach { $0.isMuted = shouldMute }
    }

    func toggleSolo(_ item: VideoItem) {
        soloItemID = soloItemID == item.id ? nil : item.id
    }

    func toggleZoom(_ item: VideoItem) {
        if zoomedItemID == item.id {
            zoomedItemID = nil
            soloItemID = nil
        } else {
            zoomedItemID = item.id
            soloItemID = item.id
        }
    }

    private func applyAudio() {
        for item in items {
            item.player.isMuted = soloItemID.map { $0 != item.id } ?? item.isMuted
            item.player.volume = Float(masterVolume * item.volume)
        }
    }

    func togglePlayAll() {
        isPlaying ? pauseAll() : playAll()
    }

    func playAll() {
        items.forEach { $0.player.play() }
        isPlaying = true
    }

    func pauseAll() {
        items.forEach { $0.player.pause() }
        isPlaying = false
    }

    func seekAll(to fraction: Double) {
        let base = fraction * maxDuration
        // 스크럽 중에는 영상 N개를 매 틱마다 정밀 시크하면 무거우므로
        // 키프레임 단위로 따라가고, 손을 떼는 순간 정밀 시크로 보정한다
        let tolerance: CMTime = isScrubbing ? .positiveInfinity : .zero
        for item in items {
            // 개별 시간 오프셋을 더해 정렬 위치로 이동 (영상 길이 안으로 클램프)
            var t = base + item.timeOffset
            let dur = item.durationSeconds
            if dur > 0 { t = min(max(t, 0), dur) } else { t = max(t, 0) }
            item.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                             toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
        progressModel.fraction = fraction
    }

    /// 일시정지 상태에서 모든 영상을 프레임 단위로 이동 (비교·분석용)
    func stepFrames(_ count: Int) {
        if isPlaying { pauseAll() }
        for item in items {
            item.player.currentItem?.step(byCount: count)
        }
        // 진행률을 가장 긴 영상 기준으로 갱신
        if let master = observedPlayer ?? items.first?.player, maxDuration > 0 {
            progressModel.fraction = min(master.currentTime().seconds / maxDuration, 1)
        }
    }

    /// 개별 영상의 시간 오프셋을 delta초만큼 조정하고 그 영상만 다시 맞춘다
    func adjustOffset(_ item: VideoItem, by delta: Double) {
        item.timeOffset += delta
        let base = progress * maxDuration
        var t = base + item.timeOffset
        let dur = item.durationSeconds
        if dur > 0 { t = min(max(t, 0), dur) } else { t = max(t, 0) }
        item.player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func resetOffset(_ item: VideoItem) {
        guard item.timeOffset != 0 else { return }
        adjustOffset(item, by: -item.timeOffset)
    }

    func rotate(_ item: VideoItem) {
        item.rotationQuarters = (item.rotationQuarters + 1) % 4
        objectWillChange.send() // 회전이 화면비를 바꿔 레이아웃 재계산
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
        item.zoomScale = new
        item.panOffset = CGSize(
            width: focus.x - ratio * (focus.x - item.panOffset.width),
            height: focus.y - ratio * (focus.y - item.panOffset.height)
        )
        clampPan(item)
    }

    /// Option+드래그로 보이는 영역을 이동한다. 오프셋은 타일 크기 대비 비율.
    func setPan(_ item: VideoItem, to offset: CGSize) {
        item.panOffset = offset
        clampPan(item)
    }

    /// 확대 배율 안에서 영상이 화면 밖으로 완전히 벗어나지 않도록 이동을 제한
    private func clampPan(_ item: VideoItem) {
        let limit = max(0, (item.zoomScale - 1) / (2 * item.zoomScale))
        item.panOffset = CGSize(
            width: min(max(item.panOffset.width, -limit), limit),
            height: min(max(item.panOffset.height, -limit), limit)
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
            snapshotRects[item.id].map { Snapshotter.Tile(item: item, rect: $0) }
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

    /// 진행률 추적 기준 플레이어를 다시 고른다. 길이가 가장 긴 영상이
    /// 끝까지 시간을 보고하므로 그 플레이어를 기준으로 삼는다.
    private func updateTimeObserver() {
        if let observer = timeObserver, let player = observedPlayer {
            player.removeTimeObserver(observer)
            timeObserver = nil
            observedPlayer = nil
        }

        let master = items.max {
            ($0.player.currentItem?.duration.seconds ?? 0) < ($1.player.currentItem?.duration.seconds ?? 0)
        }?.player ?? items.first?.player
        guard let master else { return }

        observedPlayer = master
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = master.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            let duration = self.maxDuration
            guard duration > 0 else { return }
            self.progressModel.fraction = min(time.seconds / duration, 1)
            // A-B 구간반복: B를 지나면 모든 영상을 A로 되돌린다
            if let a = self.abA, let b = self.abB,
               self.progressModel.fraction >= b, self.isPlaying {
                self.seekAll(to: a)
            }
        }
    }
}
