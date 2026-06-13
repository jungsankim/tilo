import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 빨간 닫기 버튼으로 창을 닫으면 앱도 확실하게 종료한다
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder에서 더블클릭하거나 "다음으로 열기 → Tilo"로 연 파일
    func application(_ application: NSApplication, open urls: [URL]) {
        PlayerManager.shared.add(urls: urls)
    }
}

@main
struct TiloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = PlayerManager.shared
    @AppStorage("fillMode") private var fillMode = true
    @AppStorage("playlistVisible") private var playlistVisible = true
    @AppStorage("seekStep") private var seekStep = 5
    @AppStorage("gridColumns") private var gridColumns = 0

    var body: some Scene {
        WindowGroup("Tilo") {
            ContentView()
                .environmentObject(manager)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Tilo에 관하여") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(
                            string: String(localized: "여러 영상을 한 화면에서 동시에 재생하는 멀티 비디오 플레이어")
                                + "\n\ngithub.com/jungsankim/tilo",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11),
                                .foregroundColor: NSColor.secondaryLabelColor,
                            ]
                        ),
                    ])
                }
                Button("업데이트 확인…") { UpdateChecker.checkAndPresent() }
            }

            CommandGroup(replacing: .help) {
                Button("Tilo 도움말 (GitHub)") { NSWorkspace.shared.open(UpdateChecker.repoPage) }
                Button("문제 신고…") { NSWorkspace.shared.open(UpdateChecker.issuesPage) }
            }

            CommandGroup(replacing: .newItem) {
                Button("동영상 열기…") { manager.openVideos() }
                    .keyboardShortcut("o")

                Menu("최근 항목") {
                    let recents = manager.recentItems
                    if recents.isEmpty {
                        Button("없음") {}.disabled(true)
                    } else {
                        ForEach(recents, id: \.self) { url in
                            Button(url.lastPathComponent) { manager.openRecent(url) }
                        }
                        Divider()
                        Button("메뉴 지우기") { manager.clearRecent() }
                    }
                }

                Divider()

                Button("스냅샷 저장") { manager.saveSnapshot() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(manager.items.isEmpty)

                Button("모두 닫기") { manager.closeAll() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(manager.items.isEmpty)
            }

            CommandMenu("재생 메뉴") {
                if manager.isPlaying {
                    Button("일시정지") { manager.togglePlayAll() }
                        .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button("재생") { manager.togglePlayAll() }
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(manager.items.isEmpty)
                }

                Divider()

                Button("\(seekStep)초 뒤로") { manager.seekRelative(Double(-seekStep)) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("\(seekStep)초 앞으로") { manager.seekRelative(Double(seekStep)) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("30초 뒤로") { manager.seekRelative(-30) }
                    .keyboardShortcut(.leftArrow, modifiers: .shift)
                Button("30초 앞으로") { manager.seekRelative(30) }
                    .keyboardShortcut(.rightArrow, modifiers: .shift)

                Button("이전 프레임") { manager.stepFrames(-1) }
                    .keyboardShortcut(",", modifiers: [])
                    .disabled(manager.items.isEmpty)
                Button("다음 프레임") { manager.stepFrames(1) }
                    .keyboardShortcut(".", modifiers: [])
                    .disabled(manager.items.isEmpty)

                Divider()

                Button("모든 영상 동기화") { manager.seekAll(to: manager.progress) }
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(manager.items.isEmpty)
                Toggle("반복재생", isOn: Binding(
                    get: { manager.loopEnabled },
                    set: { manager.loopEnabled = $0 }
                ))
                .keyboardShortcut("l", modifiers: [])
                Button("구간반복 설정/해제") { manager.cycleABLoop() }
                    .keyboardShortcut("r", modifiers: [])
                    .disabled(manager.items.isEmpty)

                Divider()

                Button("전체 음소거 전환") { manager.toggleMuteAll() }
                    .keyboardShortcut("m", modifiers: [])
                    .disabled(manager.items.isEmpty)
            }

            CommandGroup(before: .toolbar) {
                Toggle("화면 꽉 채우기", isOn: $fillMode)
                    .keyboardShortcut("a", modifiers: [])
                Toggle("자막 표시", isOn: Binding(
                    get: { manager.subtitlesEnabled },
                    set: { manager.subtitlesEnabled = $0 }
                ))
                .keyboardShortcut("c", modifiers: [])
                Toggle("재생목록", isOn: $playlistVisible)
                    .keyboardShortcut("p", modifiers: [])

                Picker("화면 배치", selection: $gridColumns) {
                    Text("자동 모자이크").tag(0)
                    Text("2 × 2").tag(2)
                    Text("3 × 3").tag(3)
                    Text("4 × 4").tag(4)
                }

                Button("전체화면 전환") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [])
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}
