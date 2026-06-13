import AppKit
import Foundation

/// GitHub 릴리스 API로 새 버전을 확인한다. 별도 서버 없이 동작.
enum UpdateChecker {
    static let repoPage = URL(string: "https://github.com/jungsankim/tilo")!
    static let releasesPage = URL(string: "https://github.com/jungsankim/tilo/releases/latest")!
    static let issuesPage = URL(string: "https://github.com/jungsankim/tilo/issues/new")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/jungsankim/tilo/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 결과를 NSAlert로 보여준다 (메뉴 "업데이트 확인…")
    @MainActor
    static func checkAndPresent() {
        Task { @MainActor in
            let alert = NSAlert()
            do {
                let latest = try await fetchLatestVersion()
                if isVersion(latest, newerThan: currentVersion) {
                    alert.messageText = String(localized: "새 버전 v\(latest)이 있습니다 (현재 v\(currentVersion))")
                    alert.addButton(withTitle: String(localized: "다운로드 페이지 열기"))
                    alert.addButton(withTitle: String(localized: "나중에"))
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(releasesPage)
                    }
                    return
                }
                alert.messageText = String(localized: "최신 버전을 사용 중입니다 (v\(currentVersion))")
            } catch {
                alert.messageText = String(localized: "업데이트 정보를 가져올 수 없습니다")
                alert.informativeText = error.localizedDescription
            }
            alert.runModal()
        }
    }

    private static func fetchLatestVersion() async throws -> String {
        var request = URLRequest(url: latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Release: Decodable { let tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 단순 semver 비교 (1.2.3 형식)
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
