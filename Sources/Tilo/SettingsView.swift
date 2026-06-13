import SwiftUI

/// 환경설정 창 (⌘,)
struct SettingsView: View {
    @EnvironmentObject var manager: PlayerManager
    @AppStorage("loopDefault") private var loopDefault = true
    @AppStorage("seekStep") private var seekStep = 5
    @AppStorage("restoreSessionEnabled") private var restoreSessionEnabled = true
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section {
                Toggle("다시 시작할 때 마지막 세션 복원", isOn: $restoreSessionEnabled)
                Toggle("반복재생 기본 켜기", isOn: $loopDefault)
                    .onChange(of: loopDefault) { manager.loopEnabled = $0 }
                Picker("방향키 이동 간격", selection: $seekStep) {
                    ForEach([5, 10, 15], id: \.self) { step in
                        Text("\(step)초").tag(step)
                    }
                }
            }

            Section {
                LabeledContent("변환 캐시") {
                    HStack(spacing: 10) {
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("비우기") {
                            Remuxer.clearCache()
                            cacheSize = Remuxer.cacheSize()
                        }
                        .disabled(cacheSize == 0)
                    }
                }
            }

            Section {
                LabeledContent("버전") {
                    HStack(spacing: 10) {
                        Text("v\(UpdateChecker.currentVersion)")
                            .foregroundStyle(.secondary)
                        Button("업데이트 확인…") { UpdateChecker.checkAndPresent() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize()
        .onAppear { cacheSize = Remuxer.cacheSize() }
    }
}
