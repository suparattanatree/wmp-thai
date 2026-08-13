import Foundation

/// Asks GitHub Releases whether a newer build exists, and points at the release
/// page. Installing updates in place is Sparkle's job, not this one's.
@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Set in Info.plist so the repository can move without touching code.
    private var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "WMPUpdateRepository") as? String ?? ""
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func check() {
        guard !repository.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else {
            state = .failed("ยังไม่ได้ตั้งค่าที่เก็บโค้ด")
            return
        }
        state = .checking

        Task {
            do {
                var request = URLRequest(url: url)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    state = .upToDate     // no releases published yet
                    return
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let page = json["html_url"] as? String, let pageURL = URL(string: page)
                else {
                    state = .failed("อ่านข้อมูลรุ่นล่าสุดไม่ได้")
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                state = isNewer(latest, than: currentVersion)
                    ? .available(version: latest, url: pageURL)
                    : .upToDate
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Plain numeric comparison: 1.10 is newer than 1.9.
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
