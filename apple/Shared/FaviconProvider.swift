import Foundation
import ImageIO

/// 앱과 위젯이 공유하는 App Group UserDefaults(파비콘 on/off 등).
public extension UserDefaults {
    static let appGroup = UserDefaults(suiteName: VaultAccess.appGroupId)
}

// 계정 → 도메인 매핑, 그리고 파비콘/로고 이미지의 공유 캐시 + 고화질 다운로드.
// 캐시는 App Group 컨테이너에 두어 앱과 위젯 확장이 같은 이미지를 공유한다.
// 이미지 → 뷰 변환(UIImage/NSImage)은 각 뷰에서 처리하고 여기서는 Data 만 다룬다.

// MARK: - 도메인 해석 + 캐시 경로

public enum FaviconProvider {

    /// 파비콘 캐시 폴더. App Group 을 우선 사용(위젯 공유), 없으면 앱 캐시로 폴백.
    public static let cacheDirectory: URL = {
        let fm = FileManager.default
        let base: URL
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: VaultAccess.appGroupId) {
            base = group.appendingPathComponent("Favicons", isDirectory: true)
        } else {
            base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Favicons", isDirectory: true)
        }
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func fileURL(for domain: String) -> URL {
        cacheDirectory.appendingPathComponent(domain.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// 디스크에 이미 캐시된 이미지(동기). 위젯 타임라인에서 사용.
    public static func cachedData(for domain: String) -> Data? {
        guard let data = try? Data(contentsOf: fileURL(for: domain)), !data.isEmpty else { return nil }
        return data
    }

    /// 파비콘 표시 on/off. 앱·위젯이 공유하도록 App Group 저장소에 둔다(미설정 시 기본 on).
    public static var faviconsEnabled: Bool {
        (UserDefaults.appGroup?.object(forKey: "showFavicons") as? Bool) ?? true
    }

    /// 계정에 대해 캐시된 파비콘(설정 on + 도메인 해석 + 디스크 캐시가 있을 때).
    public static func cachedData(for account: OtpAccount) -> Data? {
        guard faviconsEnabled, let domain = domain(for: account) else { return nil }
        return cachedData(for: domain)
    }

    /// 계정을 가장 그럴듯한 웹사이트 도메인으로 매핑(로고/파비콘 조회용).
    public static func domain(for account: OtpAccount) -> String? {
        resolve(for: account)?.domain
    }

    /// 도메인과 "확신 여부"를 함께 반환한다.
    /// - confident=true: Known 매핑 / 도메인처럼 생긴 문자열 / 이메일 호스트 → 신뢰. Google·icon.horse
    ///   같은 '항상 무언가 반환하는' 폴백을 써도 대체로 맞다.
    /// - confident=false: 단순 추측(`{issuer}.com`) → 브랜드 로고(Clearbit)만 조회. Clearbit 이
    ///   404 면 아이콘 없이 이니셜로 남긴다(엉뚱한 글로브/글자 로고를 확신처럼 보여주지 않기 위함).
    public static func resolve(for account: OtpAccount) -> (domain: String, confident: Bool)? {
        let issuer = (account.issuer ?? "").trimmingCharacters(in: .whitespaces)
        let name = account.accountName
        for source in [issuer, name] {
            let lower = source.lowercased()
            guard !lower.isEmpty else { continue }
            for (key, dom) in known where lower.contains(key) { return (dom, true) }
            // 이미 도메인처럼 보이는 경우("pixiv.net").
            if !lower.contains(" "), lower.contains("."), !lower.contains("@") { return (lower, true) }
            // 이메일 계정명 → 일반 메일 호스트가 아니면 그 도메인 사용.
            if let at = lower.firstIndex(of: "@") {
                let host = String(lower[lower.index(after: at)...])
                if !genericMailHosts.contains(host) { return (host, true) }
            }
        }
        // 마지막 폴백은 issuer 가 '한 단어'일 때만 추측한다(다단어는 사내 툴 등 오매칭이 잦다).
        let words = issuer.lowercased().split(separator: " ")
        if words.count == 1, let first = words.first, !first.isEmpty {
            return ("\(first).com", false)
        }
        return nil
    }

    /// 표시 이름이 도메인으로 깔끔히 매핑되지 않는 알려진 서비스.
    /// 부분일치(contains)이므로 **더 구체적인 키를 먼저** 두어야 한다(순서 있는 배열).
    /// 예: "Amazon Web Services" 는 "amazon" 도 포함하므로 "amazon web services"/"aws" 를
    /// 먼저 검사해야 AWS 로고가 결정적으로 선택된다(Dictionary 는 순서가 불명확해 부적합).
    private static let known: [(String, String)] = [
        ("amazon web services", "aws.amazon.com"),
        ("aws", "aws.amazon.com"),
        ("visit japan web", "vjw-lp.digital.go.jp"),
        ("electronic arts", "ea.com"),
        ("google", "google.com"), ("github", "github.com"), ("gitlab", "gitlab.com"),
        ("amazon", "amazon.com"),
        ("cloudflare", "cloudflare.com"), ("discord", "discord.com"),
        ("facebook", "facebook.com"), ("twitter", "x.com"), ("linkedin", "linkedin.com"),
        ("notion", "notion.so"), ("bitwarden", "bitwarden.com"), ("tumblr", "tumblr.com"),
        ("pixiv", "pixiv.net"), ("nvidia", "nvidia.com"), ("mathworks", "mathworks.com"),
        ("mailgun", "mailgun.com"), ("proxmox", "proxmox.com"),
        ("plaync", "plaync.com"), ("bithumb", "bithumb.com"), ("coinrail", "coinrail.co.kr"),
        ("coinnest", "coinnest.co.kr"), ("coinlink", "coinlink.co.kr"),
        ("miningpoolhub", "miningpoolhub.com"), ("pypi", "pypi.org"),
        ("microsoft", "microsoft.com"), ("apple", "apple.com"),
        ("dropbox", "dropbox.com"), ("slack", "slack.com"),
        ("steam", "steampowered.com"), ("reddit", "reddit.com"),
        ("paypal", "paypal.com"), ("instagram", "instagram.com"), ("binance", "binance.com"),
        ("coinbase", "coinbase.com"), ("upbit", "upbit.com"),
    ]

    private static let genericMailHosts: Set<String> = [
        "gmail.com", "googlemail.com", "naver.com", "outlook.com", "hotmail.com",
        "yahoo.com", "icloud.com", "me.com", "proton.me", "protonmail.com",
    ]
}

// MARK: - 다운로드 + 캐시 (in-flight 중복 제거)

/// 고화질 로고/파비콘을 받아 App Group 에 캐시한다.
/// 우선순위: (1) Clearbit 실제 로고(고해상도) → (2) Google 파비콘 128px.
/// 두 소스 모두 도메인만 있으면 되고, 실패 시 nil.
public actor FaviconStore {
    public static let shared = FaviconStore()

    private var memory: [String: Data] = [:]
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init() {}

    /// 계정의 파비콘이 캐시에 없으면 받아 둔다(설정 on 일 때만). 위젯 프리페치용.
    public func prefetch(_ account: OtpAccount) async {
        guard FaviconProvider.faviconsEnabled,
              let r = FaviconProvider.resolve(for: account),
              FaviconProvider.cachedData(for: r.domain) == nil else { return }
        _ = await iconData(for: r.domain, brandOnly: !r.confident)
    }

    /// 메모리 → 디스크 → 네트워크 순으로 이미지를 얻는다.
    /// brandOnly=true 면 실제 브랜드 로고(Clearbit)만 시도한다(추측 도메인용).
    public func iconData(for domain: String, brandOnly: Bool = false) async -> Data? {
        if let cached = memory[domain] { return cached }
        if let disk = FaviconProvider.cachedData(for: domain) {
            memory[domain] = disk
            return disk
        }
        if let task = inFlight[domain] { return await task.value }

        let task = Task<Data?, Never> { await Self.download(domain: domain, brandOnly: brandOnly) }
        inFlight[domain] = task
        let data = await task.value
        inFlight[domain] = nil
        if let data {
            memory[domain] = data
            try? data.write(to: FaviconProvider.fileURL(for: domain), options: .atomic)
        }
        return data
    }

    /// 소스들을 화질 우선순위로 시도한다.
    /// (1) Clearbit — 유명 브랜드의 실제 로고를 256px 로 제공(구글/디스코드 등 고화질).
    /// (2) icon.horse — 대개 512px PNG.
    /// (3) Google s2 256/128 — 항상 무언가 반환하는 안정적 폴백.
    /// 받은 이미지가 이미 충분히 크면(≥128px) 즉시 사용하고, 모두 작을 때만
    /// 그중 가장 큰 것을 쓴다(16px 짜리 저화질 파비콘을 피한다).
    /// SVG/HTML 등 래스터가 아닌 응답(UIImage/NSImage 로 못 읽음)은 건너뛴다.
    private static func download(domain: String, brandOnly: Bool = false) async -> Data? {
        // 추측 도메인(brandOnly)은 Clearbit 만: 없으면 404 → 아이콘 없이 이니셜(엉뚱한 로고 방지).
        // 확신 도메인은 전체 체인(icon.horse/Google 폴백 포함).
        let sources = brandOnly
            ? ["https://logo.clearbit.com/\(domain)?size=256&format=png"]
            : [
                "https://logo.clearbit.com/\(domain)?size=256&format=png",
                "https://icon.horse/icon/\(domain)",
                "https://www.google.com/s2/favicons?domain=\(domain)&sz=256",
                "https://www.google.com/s2/favicons?domain=\(domain)&sz=128",
            ]
        var best: Data?
        var bestDim = 0
        for urlString in sources {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count > 200, isRasterImage(data) else { continue }
            let dim = pixelDimension(data)
            if dim >= 128 { return data }            // 이미 선명 → 채택
            if dim > bestDim { best = data; bestDim = dim }  // 더 큰 후보 기억
        }
        return best
    }

    /// 인코딩된 이미지의 최대 픽셀 변(멀티 해상도 .ico 포함)을 ImageIO 로 확인한다.
    /// 전체 디코드 없이 헤더만 읽으므로 가볍다.
    private static func pixelDimension(_ data: Data) -> Int {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        var maxDim = 0
        for i in 0..<max(CGImageSourceGetCount(src), 1) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            else { continue }
            let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
            maxDim = max(maxDim, w, h)
        }
        return maxDim
    }

    /// OS 가 디코딩할 수 있는 래스터 이미지인지 매직 바이트로 확인(SVG/HTML 배제).
    private static func isRasterImage(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let b = [UInt8](data.prefix(12))
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true }          // PNG
        if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return true }                        // JPEG
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }                        // GIF
        if b[0] == 0x42, b[1] == 0x4D { return true }                                      // BMP
        if b[0] == 0x00, b[1] == 0x00, b[2] == 0x01, b[3] == 0x00 { return true }          // ICO
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return true }        // WEBP
        return false
    }
}
