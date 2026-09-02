import Foundation

/// 更新检查服务：仅由用户点菜单「检查更新…」时联网查询，
/// 平时不做任何网络访问。通过 GitHub Releases API 拉取最新版并比较版本号。
enum UpdateService {
    static let owner = "shanhai-meng"
    static let repo = "AcrylicBoard"

    static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    struct ReleaseInfo: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
        }

        /// 去掉 tag 前导的 v，例如 "v1.0.2" -> "1.0.2"
        var version: String {
            tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        }

        /// 对应安装包的直链：releases/download/<tag>/AcrylicBoard-<tag>.dmg
        var dmgDownloadURL: URL? {
            URL(string: "https://github.com/\(UpdateService.owner)/\(UpdateService.repo)/releases/download/\(tagName)/AcrylicBoard-\(tagName).dmg")
        }
    }

    enum CheckError: LocalizedError {
        case network(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .network(let message):
                return "网络请求失败：\(message)"
            case .badResponse:
                return "服务器返回了无法识别的内容"
            }
        }
    }

    /// 逐段按数字比较版本号，例如 "1.0.10" > "1.0.2"
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = current.split(separator: ".").map { Int($0) ?? 0 }
        let b = candidate.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return y > x }
        }
        return false
    }

    /// 拉取 GitHub 上最新一条 Release（异步）
    static func fetchLatest(completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 12
        // GitHub API 强制要求 User-Agent
        request.setValue("AcrylicBoard/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(CheckError.network(error.localizedDescription)))
                return
            }
            guard let data,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let info = try? JSONDecoder().decode(ReleaseInfo.self, from: data) else {
                completion(.failure(CheckError.badResponse))
                return
            }
            completion(.success(info))
        }.resume()
    }
}
