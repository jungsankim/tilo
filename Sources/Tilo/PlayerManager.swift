import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// 전역 진행률을 별도 모델로 분리해서, 0.25초마다 그리드 전체가 아니라
/// 이 모델을 구독하는 슬라이더만 다시 그려지게 한다
final class PlaybackProgress: ObservableObject {
    @Published var fraction: Double = 0
}

final class VideoItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let player: AVPlayer

    /// 사용자가 설정한 음소거 (솔로가 켜져 있으면 솔로가 우선한다)
    @Published var isMuted: Bool = false {
        didSet { muteChanged?() }
    }
    var muteChanged: (() -> Void)?

    /// 영상의 실제 화면비(가로/세로). 로드 전에는 16:9로 가정한다.
    @Published var aspect: CGFloat = 16.0 / 9.0

    /// 이 영상의 개별 재생 진행률 (0...1)
    @Published var progress: Double = 0
    var isScrubbing = false
    var loopEnabled = true

    /// 시크바가 보이는 동안만 진행률을 발행해서 불필요한 뷰 갱신을 줄인다
    var progressActive = false {
        didSet { if progressActive { publishProgressNow() } }
    }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var appliedResolutionCap: CGSize = .zero

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        loadAspect()

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, self.progressActive, !self.isScrubbing else { return }
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
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func seek(to fraction: Double) {
        guard let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        let time = CMTime(seconds: fraction * duration, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        progress = fraction
    }

    private func publishProgressNow() {
        guard let duration = player.currentItem?.duration.seconds,
              duration.isFinite, duration > 0 else { return }
        progress = min(player.currentTime().seconds / duration, 1)
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

    private func loadAspect() {
        Task { @MainActor in
            let asset = AVURLAsset(url: url)
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

final class PlayerManager: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var isPlaying = false
    /// 최장 영상 길이를 기준으로 한 전체 진행률 (0...1)
    let progressModel = PlaybackProgress()
    var progress: Double { progressModel.fraction }
    var isScrubbing = false

    /// 영상이 끝나면 처음부터 다시 재생 (영상별로 각자 루프)
    @Published var loopEnabled = true {
        didSet { items.forEach { $0.loopEnabled = loopEnabled } }
    }

    /// 오디오 솔로: 설정되면 이 영상만 소리가 나고 나머지는 음소거
    @Published var soloItemID: UUID? {
        didSet { applyAudio() }
    }

    /// 더블클릭 확대로 단독 표시 중인 영상
    @Published var zoomedItemID: UUID?

    private var timeObserver: Any?
    private var observedPlayer: AVPlayer?
    private var cancellables: Set<AnyCancellable> = []

    var maxDuration: Double {
        items
            .compactMap { $0.player.currentItem?.duration.seconds }
            .filter { $0.isFinite }
            .max() ?? 0
    }

    func openVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        guard panel.runModal() == .OK else { return }
        add(urls: panel.urls)
    }

    func add(urls: [URL]) {
        for url in urls {
            let item = VideoItem(url: url)
            item.loopEnabled = loopEnabled
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
        applyAudio()
        updateTimeObserver()
    }

    func remove(_ item: VideoItem) {
        item.player.pause()
        items.removeAll { $0.id == item.id }
        if soloItemID == item.id { soloItemID = nil }
        if zoomedItemID == item.id { zoomedItemID = nil }
        if items.isEmpty {
            isPlaying = false
            progressModel.fraction = 0
        }
        updateTimeObserver()
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
        let time = CMTime(seconds: fraction * maxDuration, preferredTimescale: 600)
        for item in items {
            item.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        progressModel.fraction = fraction
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
        }
    }
}
