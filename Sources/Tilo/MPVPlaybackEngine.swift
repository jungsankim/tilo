import AppKit
import CMpv
import Foundation
import MpvBridge

enum PlaybackBackendKind: String, Codable, Equatable {
    case avFoundation
    case libmpv

    var displayName: String {
        switch self {
        case .avFoundation: return String(localized: "기본 재생")
        case .libmpv: return String(localized: "원본 직접 재생")
        }
    }
}

struct MPVMediaTrack: Equatable, Sendable {
    enum Kind: String, Sendable {
        case audio
        case subtitle = "sub"
        case video
    }

    let order: Int
    let id: Int64
    let kind: Kind
    let title: String?
    let language: String?
    let ffmpegStreamIndex: Int?
    let selected: Bool
}

/// libmpv 코어 하나를 영상 하나에 대응시킨다. 모든 제어 호출은 전용 큐로
/// 보내 UI를 막지 않고, 이벤트 값은 즉시 복사한 뒤 메인 스레드에 전달한다.
final class MPVPlaybackEngine {
    static var isAvailable: Bool { mpv_client_api_version() > 0 }

    /// 실제 렌더러를 교체하기 전에 libmpv가 파일 헤더와 비디오 트랙을 열 수
    /// 있는지 별도 core에서 확인한다. 특히 재생목록 교체 실패 시 원본 타일을
    /// 그대로 유지하기 위한 준비 단계다.
    static func canOpen(_ url: URL, timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let handle = mpv_create() else {
                    continuation.resume(returning: false)
                    return
                }
                defer { mpv_terminate_destroy(handle) }

                for (name, value) in [
                    ("config", "no"),
                    ("terminal", "no"),
                    ("vo", "null"),
                    ("ao", "null"),
                    ("pause", "yes"),
                ] {
                    name.withCString { namePointer in
                        value.withCString { valuePointer in
                            _ = mpv_set_option_string(handle, namePointer, valuePointer)
                        }
                    }
                }
                guard mpv_initialize(handle) >= 0 else {
                    continuation.resume(returning: false)
                    return
                }

                let arguments = ["loadfile", url.standardizedFileURL.path, "replace"]
                guard runCommand(arguments, on: handle) >= 0 else {
                    continuation.resume(returning: false)
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    guard let event = mpv_wait_event(handle, 0.1) else { continue }
                    switch event.pointee.event_id {
                    case MPV_EVENT_FILE_LOADED:
                        continuation.resume(returning: hasVideoTrack(handle))
                        return
                    case MPV_EVENT_END_FILE:
                        guard let data = event.pointee.data else { continue }
                        let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        if end.reason == MPV_END_FILE_REASON_ERROR {
                            continuation.resume(returning: false)
                            return
                        }
                    default:
                        break
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }

    private static func runCommand(_ arguments: [String], on handle: OpaquePointer) -> Int32 {
        let storage = arguments.map { argument in argument.withCString { strdup($0) } }
        defer {
            storage.forEach { pointer in if let pointer { free(pointer) } }
        }
        var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            mpv_command(handle, buffer.baseAddress)
        }
    }

    private static func hasVideoTrack(_ handle: OpaquePointer) -> Bool {
        var count: Int64 = 0
        guard "track-list/count".withCString({
            mpv_get_property(handle, $0, MPV_FORMAT_INT64, &count)
        }) >= 0 else { return false }
        for index in 0..<Int(count) {
            let name = "track-list/\(index)/type"
            let raw = name.withCString { mpv_get_property_string(handle, $0) }
            guard let raw else { continue }
            let type = String(cString: raw)
            mpv_free(raw)
            if type == "video" { return true }
        }
        return false
    }

    let url: URL
    private(set) var handle: OpaquePointer?
    private(set) var durationSeconds: Double = 0
    private(set) var pixelSize: CGSize = .zero
    private(set) var nominalFrameRate: Float = 0
    private(set) var hasAudio = false
    private(set) var tracks: [MPVMediaTrack] = []
    private(set) var isReady = false
    private(set) var loadFailed = false
    private(set) var failureDescription: String?

    var onReady: (() -> Void)?
    var onFailure: ((String?) -> Void)?
    var onDurationChanged: (() -> Void)?
    var onTimeChanged: ((Double) -> Void)?
    var onMetadataChanged: (() -> Void)?
    var onSubtitleChanged: ((String?) -> Void)?
    var onTracksChanged: (([MPVMediaTrack]) -> Void)?

    private let commandQueue = DispatchQueue(label: "com.jungsankim.tilo.mpv.command")
    private var eventPump: MPVEventPump?
    private var started = false
    private var rendererReady = false
    private var isShuttingDown = false
    private var storedSurfaceView: MPVOpenGLView?
    private let timeLock = NSLock()
    private var currentTimeValue: Double = 0
    private var timeDeliveryScheduled = false

    /// 이벤트 스레드가 최신 값을 즉시 기록하고 UI는 잠금으로 읽는다. 따라서
    /// UI 알림을 합치더라도 동기화 계산에는 오래된 시간이 쓰이지 않는다.
    var currentTimeSeconds: Double {
        timeLock.lock()
        defer { timeLock.unlock() }
        return currentTimeValue
    }

    var surfaceView: MPVOpenGLView {
        precondition(Thread.isMainThread)
        if let storedSurfaceView { return storedSurfaceView }
        let view = MPVOpenGLView(engine: self)
        storedSurfaceView = view
        return view
    }

    init?(url: URL) {
        self.url = url.standardizedFileURL
        guard let handle = mpv_create() else { return nil }
        self.handle = handle

        setOption("config", "no")
        setOption("terminal", "no")
        setOption("osc", "no")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("input-media-keys", "no")
        setOption("media-controls", "no")
        setOption("vo", "libmpv")
        setOption("hwdec", "auto-safe")
        setOption("pause", "yes")
        setOption("keep-open", "yes")
        setOption("audio-display", "no")
        setOption("sub-auto", "fuzzy")

        guard mpv_initialize(handle) >= 0 else {
            mpv_destroy(handle)
            self.handle = nil
            return nil
        }

        observe(1, "time-pos", MPV_FORMAT_DOUBLE)
        observe(2, "duration", MPV_FORMAT_DOUBLE)
        observe(3, "video-params/w", MPV_FORMAT_INT64)
        observe(4, "video-params/h", MPV_FORMAT_INT64)
        observe(5, "container-fps", MPV_FORMAT_DOUBLE)
        observe(6, "track-list/count", MPV_FORMAT_INT64)
        observe(7, "sub-text", MPV_FORMAT_STRING)

        let pump = MPVEventPump(handle: handle)
        pump.owner = self
        eventPump = pump
        pump.start()
    }

    deinit {
        shutdown()
    }

    /// VideoItem이 콜백을 연결한 다음 호출한다. render context를 먼저 만든 뒤
    /// loadfile을 보내야 macOS에서 별도 창 fallback이나 VO 실패가 생기지 않는다.
    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard !started, !isShuttingDown else { return }
        started = true
        surfaceView.prepareRenderer()
    }

    func rendererDidPrepare() {
        guard !rendererReady, let _ = handle, !isShuttingDown else { return }
        rendererReady = true
        command(["loadfile", url.path, "replace"])
    }

    func rendererDidFail(_ code: Int32) {
        publishFailure("libmpv renderer error \(code)")
    }

    func play(rate: Float) {
        setProperty("speed", Double(max(rate, 0.01)))
        setProperty("pause", false)
    }

    func pause() {
        setProperty("pause", true)
    }

    func seek(to seconds: Double, exact: Bool) {
        command([
            "seek",
            String(format: "%.6f", max(seconds, 0)),
            exact ? "absolute+exact" : "absolute+keyframes",
        ])
    }

    func stepFrames(_ count: Int) {
        let commandName = count >= 0 ? "frame-step" : "frame-back-step"
        for _ in 0..<abs(count) { command([commandName]) }
    }

    func setMuted(_ muted: Bool) {
        setProperty("mute", muted)
    }

    func setVolume(_ volume: Double) {
        setProperty("volume", min(max(volume, 0), 1) * 100)
    }

    /// mpv 네이티브 A-B 구간반복. nil이면 해제("no").
    /// 주기적 감시보다 정확해서 B 지점을 지나치지 않고 프레임 단위로 되돌아간다.
    func setABLoop(a: Double?, b: Double?) {
        if let a, let b {
            setProperty("ab-loop-a", a)
            setProperty("ab-loop-b", b)
        } else {
            setProperty("ab-loop-a", "no")
            setProperty("ab-loop-b", "no")
        }
    }

    func setLooping(_ enabled: Bool) {
        setProperty("loop-file", enabled ? "inf" : "no")
    }

    func setSubtitlesEnabled(_ enabled: Bool) {
        setProperty("sub-visibility", enabled)
    }

    func setSubtitleScale(_ scale: Double) {
        setProperty("sub-scale", min(max(scale, 0.5), 2))
    }

    func setAudioTrack(order: Int?) {
        guard let order,
              let track = tracks.first(where: { $0.kind == .audio && $0.order == order })
        else {
            setProperty("aid", "auto")
            return
        }
        setProperty("aid", track.id)
    }

    func setSubtitleTrack(order: Int?) {
        guard let order,
              let track = tracks.first(where: { $0.kind == .subtitle && $0.order == order })
        else {
            setProperty("sid", "auto")
            return
        }
        setProperty("sid", track.id)
    }

    func setPresentation(
        fill: Bool,
        rotationQuarters: Int,
        zoomScale: CGFloat,
        panOffset: CGSize
    ) {
        setProperty("panscan", fill ? 1.0 : 0.0)
        let rotation = Int64((((rotationQuarters % 4) + 4) % 4) * 90)
        setProperty("video-rotate", rotation)
        setProperty("video-zoom", log2(max(Double(zoomScale), 1)))
        setProperty("video-pan-x", Double(panOffset.width) * 2)
        setProperty("video-pan-y", Double(panOffset.height) * 2)
    }

    /// 메인 스레드를 막지 않는 종료. 렌더 스레드(=메인)가 libmpv API의 반환을
    /// 기다리면 데드락이 될 수 있다고 render.h가 경고하므로, 코어를 기다리는
    /// 단계(이벤트 스레드 합류, 명령 큐 배수, core 파괴)는 전부 백그라운드에서
    /// 수행한다. deinit에서 불려도 안전하도록 자원을 지역 변수로 옮겨 잡는다.
    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        // quit을 비동기로 먼저 보내 디먹서/디코더가 블로킹 I/O(NAS·외장하드)에서
        // 즉시 빠져나오게 한다. 이후 단계들의 대기 시간이 크게 줄어든다.
        if let handle { Self.sendAsyncCommand(["quit"], to: handle) }

        let pump = eventPump
        eventPump = nil
        pump?.owner = nil
        let queue = commandQueue
        let handle = self.handle
        self.handle = nil
        let surface = storedSurfaceView
        storedSurfaceView = nil

        // render context는 draw()와 같은 메인 스레드에서 해제해야 동시 호출이
        // 없다. 해제가 끝난 뒤에만 core를 파괴하도록 백그라운드 단계를 그 뒤에
        // 이어 붙인다. surface가 한 번도 필요하지 않았던 core는 view를 새로
        // 만들지 않는다.
        let finish = {
            surface?.shutdownRenderer()
            DispatchQueue.global(qos: .userInitiated).async {
                pump?.stopAndWait()
                // 종료 플래그가 설정되기 전에 큐에 들어간 제어 작업도 모두
                // 빠져나온 뒤에만 core를 파괴한다.
                queue.sync {}
                if let handle { mpv_terminate_destroy(handle) }
            }
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    private static func sendAsyncCommand(_ arguments: [String], to handle: OpaquePointer) {
        let storage = arguments.map { argument in argument.withCString { strdup($0) } }
        defer {
            storage.forEach { pointer in if let pointer { free(pointer) } }
        }
        var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        pointers.append(nil)
        pointers.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command_async(handle, 0, buffer.baseAddress)
        }
    }

    fileprivate func consume(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_FILE_LOADED:
            refreshMetadata()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isShuttingDown else { return }
                self.isReady = true
                self.loadFailed = false
                self.onReady?()
            }
        case MPV_EVENT_VIDEO_RECONFIG, MPV_EVENT_AUDIO_RECONFIG:
            refreshMetadata()
        case MPV_EVENT_PROPERTY_CHANGE:
            consumeProperty(event)
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if end.reason == MPV_END_FILE_REASON_ERROR {
                let message = mpv_error_string(end.error).map(String.init(cString:))
                publishFailure(message)
            }
        default:
            break
        }
    }

    private func consumeProperty(_ event: mpv_event) {
        guard let data = event.data else { return }
        let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard let namePointer = property.name else { return }
        let name = String(cString: namePointer)

        switch (name, property.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE):
            guard let value = property.data?.assumingMemoryBound(to: Double.self).pointee,
                  value.isFinite else { return }
            recordTime(max(value, 0))
        case ("duration", MPV_FORMAT_DOUBLE):
            guard let value = property.data?.assumingMemoryBound(to: Double.self).pointee,
                  value.isFinite, value > 0 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.durationSeconds = value
                self.onDurationChanged?()
            }
        case ("video-params/w", MPV_FORMAT_INT64),
             ("video-params/h", MPV_FORMAT_INT64),
             ("container-fps", MPV_FORMAT_DOUBLE),
             ("track-list/count", MPV_FORMAT_INT64):
            refreshMetadata()
        case ("sub-text", MPV_FORMAT_STRING):
            var text: String?
            if let raw = property.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                text = value.isEmpty ? nil : value
            }
            DispatchQueue.main.async { [weak self] in self?.onSubtitleChanged?(text) }
        default:
            break
        }
    }

    /// time-pos는 프레임마다 올 수 있으므로 엔진마다 메인 큐 알림을 초당 10회로
    /// 합친다. 마지막 값은 지연 블록이 반드시 전달해 일시정지/프레임 이동도 빠뜨리지 않는다.
    private func recordTime(_ value: Double) {
        timeLock.lock()
        currentTimeValue = value
        guard !timeDeliveryScheduled else {
            timeLock.unlock()
            return
        }
        timeDeliveryScheduled = true
        timeLock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.timeLock.lock()
            let latest = self.currentTimeValue
            self.timeDeliveryScheduled = false
            self.timeLock.unlock()
            guard !self.isShuttingDown else { return }
            self.onTimeChanged?(latest)
        }
    }

    private func refreshMetadata() {
        guard let handle else { return }
        let duration = getDouble("duration", handle: handle)
        let width = getInt("video-params/w", handle: handle)
        let height = getInt("video-params/h", handle: handle)
        let fps = getDouble("container-fps", handle: handle)
        let tracks = readTracks(handle: handle)
        let hasAudio = tracks.contains { $0.kind == .audio }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            if let duration, duration > 0 { self.durationSeconds = duration }
            if let width, let height, width > 0, height > 0 {
                self.pixelSize = CGSize(width: Int(width), height: Int(height))
            }
            if let fps, fps > 0 { self.nominalFrameRate = Float(fps) }
            self.hasAudio = hasAudio
            self.tracks = tracks
            self.onTracksChanged?(tracks)
            self.onMetadataChanged?()
            self.onDurationChanged?()
        }
    }

    private func publishFailure(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShuttingDown, !self.loadFailed else { return }
            self.loadFailed = true
            self.failureDescription = message
            self.onFailure?(message)
        }
    }

    private func readTracks(handle: OpaquePointer) -> [MPVMediaTrack] {
        guard let count = getInt("track-list/count", handle: handle), count > 0 else { return [] }
        var audioOrder = 0
        var subtitleOrder = 0
        var videoOrder = 0
        var result: [MPVMediaTrack] = []

        for index in 0..<Int(count) {
            let prefix = "track-list/\(index)"
            guard let typeName = getString("\(prefix)/type", handle: handle),
                  let kind = MPVMediaTrack.Kind(rawValue: typeName),
                  let id = getInt("\(prefix)/id", handle: handle)
            else { continue }
            let order: Int
            switch kind {
            case .audio: order = audioOrder; audioOrder += 1
            case .subtitle: order = subtitleOrder; subtitleOrder += 1
            case .video: order = videoOrder; videoOrder += 1
            }
            let ffIndex = getInt("\(prefix)/ff-index", handle: handle).map(Int.init)
            result.append(MPVMediaTrack(
                order: order,
                id: id,
                kind: kind,
                title: getString("\(prefix)/title", handle: handle),
                language: getString("\(prefix)/lang", handle: handle),
                ffmpegStreamIndex: ffIndex,
                selected: getFlag("\(prefix)/selected", handle: handle) ?? false
            ))
        }
        return result
    }

    private func setOption(_ name: String, _ value: String) {
        guard let handle else { return }
        name.withCString { namePointer in
            value.withCString { valuePointer in
                _ = mpv_set_option_string(handle, namePointer, valuePointer)
            }
        }
    }

    private func observe(_ id: UInt64, _ name: String, _ format: mpv_format) {
        guard let handle else { return }
        name.withCString { pointer in
            _ = mpv_observe_property(handle, id, pointer, format)
        }
    }

    private func command(_ arguments: [String]) {
        guard !isShuttingDown else { return }
        commandQueue.async { [weak self] in
            guard let self, !self.isShuttingDown, let handle = self.handle else { return }
            let storage = arguments.map { argument in
                argument.withCString { strdup($0) }
            }
            defer {
                storage.forEach { pointer in
                    if let pointer { free(pointer) }
                }
            }
            var pointers: [UnsafePointer<CChar>?] = storage.map { pointer in
                pointer.map { UnsafePointer<CChar>($0) }
            }
            pointers.append(nil)
            pointers.withUnsafeMutableBufferPointer { buffer in
                _ = mpv_command(handle, buffer.baseAddress)
            }
        }
    }

    private func setProperty(_ name: String, _ value: Bool) {
        enqueueProperty(name, format: MPV_FORMAT_FLAG, value: Int32(value ? 1 : 0))
    }

    private func setProperty(_ name: String, _ value: Int64) {
        enqueueProperty(name, format: MPV_FORMAT_INT64, value: value)
    }

    private func setProperty(_ name: String, _ value: Double) {
        enqueueProperty(name, format: MPV_FORMAT_DOUBLE, value: value)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard !isShuttingDown else { return }
        commandQueue.async { [weak self] in
            guard let self, !self.isShuttingDown, let handle = self.handle else { return }
            name.withCString { namePointer in
                value.withCString { valuePointer in
                    _ = mpv_set_property_string(handle, namePointer, valuePointer)
                }
            }
        }
    }

    private func enqueueProperty<T>(_ name: String, format: mpv_format, value: T) {
        guard !isShuttingDown else { return }
        commandQueue.async { [weak self] in
            guard let self, !self.isShuttingDown, let handle = self.handle else { return }
            var mutableValue = value
            name.withCString { namePointer in
                withUnsafeMutablePointer(to: &mutableValue) { valuePointer in
                    _ = mpv_set_property(handle, namePointer, format, valuePointer)
                }
            }
        }
    }

    private func getDouble(_ name: String, handle: OpaquePointer) -> Double? {
        var value = 0.0
        let status = name.withCString {
            mpv_get_property(handle, $0, MPV_FORMAT_DOUBLE, &value)
        }
        return status >= 0 && value.isFinite ? value : nil
    }

    private func getInt(_ name: String, handle: OpaquePointer) -> Int64? {
        var value: Int64 = 0
        let status = name.withCString {
            mpv_get_property(handle, $0, MPV_FORMAT_INT64, &value)
        }
        return status >= 0 ? value : nil
    }

    private func getFlag(_ name: String, handle: OpaquePointer) -> Bool? {
        var value: Int32 = 0
        let status = name.withCString {
            mpv_get_property(handle, $0, MPV_FORMAT_FLAG, &value)
        }
        return status >= 0 ? value != 0 : nil
    }

    private func getString(_ name: String, handle: OpaquePointer) -> String? {
        let raw = name.withCString { mpv_get_property_string(handle, $0) }
        guard let raw else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }
}

/// 한 mpv_handle의 이벤트를 읽는 스레드는 반드시 하나여야 한다. pump는
/// owner를 약하게 참조해 엔진 수명을 붙잡지 않으며 종료 시 wakeup 후 합류한다.
private final class MPVEventPump {
    weak var owner: MPVPlaybackEngine?
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.jungsankim.tilo.mpv.events")
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var stopped = false
    private var running = false

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()

        queue.async { [self] in
            defer { finished.signal() }
            while !isStopped {
                guard let pointer = mpv_wait_event(handle, 0.25) else { continue }
                let event = pointer.pointee
                if event.event_id != MPV_EVENT_NONE {
                    owner?.consume(event)
                }
            }
        }
    }

    func stopAndWait() {
        lock.lock()
        let shouldWait = running && !stopped
        stopped = true
        lock.unlock()
        guard shouldWait else { return }
        mpv_wakeup(handle)
        // mpv_wakeup()은 대기 중인 mpv_wait_event()를 반드시 깨운다. 제한 시간
        // 뒤 core를 먼저 파괴하면 event thread가 해제된 handle을 만질 수 있다.
        finished.wait()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
