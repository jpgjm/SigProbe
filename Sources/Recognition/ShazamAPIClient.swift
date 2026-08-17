//
//  ShazamAPIClient.swift
//  SigProbe
//
//  amp.shazam.com の非公式エンドポイントへ署名を投げる。
//
//  2 系統のエンドポイントを切り替えられる。
//    .v5 : discovery/v5 — 認証不要。Kotlin 版 (shazamkit/Shazam.kt) と同じ構成。既定。
//    .v2 : match/v2     — Apple トークン必須 (ShazamV2Backend)。比較検証用。
//

import Foundation

// MARK: - エンドポイント種別

enum ShazamEndpoint: String, CaseIterable, Identifiable {
    case v5
    case v2
    case v2direct

    var id: String { rawValue }

    var label: String {
        switch self {
        case .v5:       return "discovery/v5 (認証不要)"
        case .v2:       return "match/v2 (要 Apple トークン)"
        case .v2direct: return "match/v2 (採取Bearer直接)"
        }
    }

    var shortLabel: String {
        switch self {
        case .v5:       return "v5"
        case .v2:       return "v2"
        case .v2direct: return "v2d"
        }
    }

    var note: String {
        switch self {
        case .v5:
            return "外部依存が無く単体で完結する。通常はこちら。"
        case .v2:
            return "第三者が公開する key.json の Apple 署名に依存する。署名が古いと 401 で失敗する。"
        case .v2direct:
            return "実機 iOS Shazam の match/v2 が使う Authorization ベアラ(約30日の JWT)をそのまま流用する。Apple 署名も apiToken 交換も不要。ShazamSigCapture が採取した shazam-auth.json を Documents に置く。"
        }
    }
}

enum ShazamAPIError: LocalizedError {
    case tooManyRequests
    case noMatch
    case serviceUnavailable
    case httpStatus(Int)
    case invalidResponse
    case authFailure(String)

    var errorDescription: String? {
        switch self {
        case .tooManyRequests:     return "リクエストが多すぎます (429)"
        case .noMatch:             return "一致する曲が見つかりませんでした"
        case .serviceUnavailable:  return "Shazam のサービスが一時的に利用できません"
        case .httpStatus(let c):   return "認識に失敗しました (HTTP \(c))"
        case .invalidResponse:     return "レスポンスを解釈できませんでした"
        case .authFailure(let m):  return "認証に失敗しました: \(m)"
        }
    }
}

actor ShazamAPIClient {

    static let shared = ShazamAPIClient()

    private let maxRetries = 3
    private let initialRetryDelay: UInt64 = 2_000_000_000   // 2s
    private let minRequestInterval: TimeInterval = 1.0
    private var lastRequestTime: Date = .distantPast

    // v2 用トークンキャッシュ
    private var tokenCache: String?
    private var tokenCacheDate: Date = .distantPast
    private let tokenLifetime: TimeInterval = 30 * 60

    private let userAgents = [
        "Dalvik/2.1.0 (Linux; U; Android 5.0.2; VS980 4G Build/LRX22G)",
        "Dalvik/1.6.0 (Linux; U; Android 4.4.2; SM-T210 Build/KOT49H)",
        "Dalvik/2.1.0 (Linux; U; Android 5.1.1; SM-P905V Build/LMY47X)",
        "Dalvik/2.1.0 (Linux; U; Android 6.0.1; SM-G920F Build/MMB29K)",
        "Dalvik/2.1.0 (Linux; U; Android 5.0; SM-G900F Build/LRX21T)"
    ]

    private let timezones = [
        "Europe/Paris", "Europe/London", "America/New_York",
        "America/Los_Angeles", "Asia/Tokyo", "Asia/Dubai"
    ]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// 段階ログの受け口（MusicRecognizer 側が設定する）。どのリクエストで詰まったか可視化する。
    nonisolated(unsafe) static var stageLog: (@Sendable (String) -> Void)?
    private func stage(_ msg: String) { ShazamAPIClient.stageLog?(msg) }

    /// 認識を実行し、(結果, 生レスポンス文字列) を返す。
    func recognize(signatureURI: String,
                   sampleDurationMs: Int,
                   endpoint: ShazamEndpoint = .v5,
                   deviceId: String? = nil) async throws -> (RecognitionResult?, String) {

        var lastError: Error = ShazamAPIError.invalidResponse

        for attempt in 0..<maxRetries {
            try await enforceRateLimit()
            do {
                switch endpoint {
                case .v5:
                    return try await performV5(signatureURI: signatureURI,
                                               sampleDurationMs: sampleDurationMs)
                case .v2:
                    return try await performV2(signatureURI: signatureURI,
                                               sampleDurationMs: sampleDurationMs)
                case .v2direct:
                    return try await performV2Direct(signatureURI: signatureURI,
                                                     sampleDurationMs: sampleDurationMs,
                                                     deviceId: deviceId)
                }
            } catch ShazamAPIError.tooManyRequests {
                lastError = ShazamAPIError.tooManyRequests
                if attempt < maxRetries - 1 {
                    try await Task.sleep(nanoseconds: initialRetryDelay << UInt64(attempt))
                    continue
                }
            } catch {
                throw error
            }
        }

        throw lastError
    }

    // MARK: - v5 (discovery/v5)

    private func performV5(signatureURI: String,
                           sampleDurationMs: Int) async throws -> (RecognitionResult?, String) {

        let timestamp = Int(Date().timeIntervalSince1970)
        let uuid1 = UUID().uuidString.uppercased()
        let uuid2 = UUID().uuidString.lowercased()

        var components = URLComponents(
            string: "https://amp.shazam.com/discovery/v5/en/US/android/-/tag/\(uuid1)/\(uuid2)"
        )!
        components.queryItems = [
            URLQueryItem(name: "sync", value: "true"),
            URLQueryItem(name: "webv3", value: "true"),
            URLQueryItem(name: "sampling", value: "true"),
            URLQueryItem(name: "connected", value: ""),
            URLQueryItem(name: "shazamapiversion", value: "v3"),
            URLQueryItem(name: "sharehub", value: "true"),
            URLQueryItem(name: "video", value: "v3")
        ]

        // 位置情報は実際の座標を送らず、毎回ランダムな値を捏造する。
        let body: [String: Any] = [
            "geolocation": [
                "altitude": Double.random(in: 100...500),
                "latitude": Double.random(in: -90...90),
                "longitude": Double.random(in: -180...180)
            ],
            "signature": [
                "samplems": sampleDurationMs,
                "timestamp": timestamp,
                "uri": signatureURI
            ],
            "timestamp": timestamp,
            "timezone": timezones.randomElement()!
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgents.randomElement()!, forHTTPHeaderField: "User-Agent")
        request.setValue("en_US", forHTTPHeaderField: "Content-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ShazamAPIError.invalidResponse
        }

        let rawText = String(data: data, encoding: .utf8) ?? "<非UTF-8 \(data.count) bytes>"

        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 429:        throw ShazamAPIError.tooManyRequests
            case 404:        throw ShazamAPIError.noMatch
            case 500..<600:  throw ShazamAPIError.serviceUnavailable
            default:         throw ShazamAPIError.httpStatus(http.statusCode)
            }
        }

        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let result = ShazamResponseParser.parse(root)
        return (result, rawText)
    }

    // MARK: - v2 (match/v2)

    /// トークンは毎回取り直すと無駄なので、短時間だけ actor 内にキャッシュする。
    private func cachedOrFreshToken() async throws -> String {
        if let token = tokenCache,
           Date().timeIntervalSince(tokenCacheDate) < tokenLifetime {
            return token
        }
        let (token, _) = try await ShazamV2Backend.fetchToken(session: session)
        tokenCache = token
        tokenCacheDate = Date()
        return token
    }

    private func performV2(signatureURI: String,
                           sampleDurationMs: Int) async throws -> (RecognitionResult?, String) {

        let usingCache = (tokenCache != nil && Date().timeIntervalSince(tokenCacheDate) < tokenLifetime)
        stage(usingCache ? "①トークン: キャッシュ利用" : "①トークン取得中… (apiToken)")
        let token = try await cachedOrFreshToken()
        stage("①トークン OK (\(token.count)文字)")

        let deviceId = UUID().uuidString.uppercased()
        let sessionId = UUID().uuidString.uppercased()

        var components = URLComponents(
            string: "https://amp.shazam.com/match/v2/en-US/US/iphone/\(deviceId)/\(sessionId)"
        )!
        components.queryItems = [
            URLQueryItem(name: "recognitionType", value: "progressive-with-rolling"),
            URLQueryItem(name: "sampling", value: "true"),
            URLQueryItem(name: "matchv2t", value: "false"),
            URLQueryItem(name: "hidelb", value: "true"),
            URLQueryItem(name: "video", value: "v3")
        ]

        let body: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "timezone": TimeZone.current.identifier,
            "signatures": [[
                "uri": signatureURI,
                "audioSource": "MIC",
                "samplems": sampleDurationMs
            ]]
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("IPHONE", forHTTPHeaderField: "X-Shazam-Platform")
        request.setValue("26.0.0", forHTTPHeaderField: "X-Shazam-Appversion")
        request.setValue("0", forHTTPHeaderField: "X-Shazam-Auth-Retry")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Shazam/5817 CFNetwork/3860.200.71 Darwin/25.1.0",
                         forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        stage("②match/v2 送信中… (amp.shazam.com)")
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ShazamAPIError.invalidResponse
        }
        stage("②match/v2 応答 HTTP \(http.statusCode)")

        let rawText = String(data: data, encoding: .utf8) ?? "<非UTF-8 \(data.count) bytes>"

        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                // トークンが腐っている可能性があるので捨てる
                tokenCache = nil
                throw ShazamAPIError.authFailure(
                    "トークンが拒否されました (HTTP \(http.statusCode))"
                )
            case 429:        throw ShazamAPIError.tooManyRequests
            case 404:        throw ShazamAPIError.noMatch
            case 500..<600:  throw ShazamAPIError.serviceUnavailable
            default:         throw ShazamAPIError.httpStatus(http.statusCode)
            }
        }

        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let result = ShazamV2Backend.parse(root)
        return (result, rawText)
    }

    // MARK: - v2direct (match/v2 · 採取した Bearer を直接使用)

    /// 実機 iOS Shazam が match/v2 に付ける Authorization(約30日の JWT)を Documents の
    /// shazam-auth.json から読み、そのまま流用して match/v2 を叩く。
    /// Apple 署名も apiToken 交換も行わない。ボディ・ヘッダは実機 iOS の実測形に合わせる。
    private func performV2Direct(signatureURI: String,
                                 sampleDurationMs: Int,
                                 deviceId: String? = nil) async throws -> (RecognitionResult?, String) {

        stage("①Bearer 読込中… (shazam-auth.json)")
        let bearer = try ShazamV2Backend.loadCapturedBearer()
        stage("①Bearer OK (\(bearer.count)文字)")

        // path のロケールは実機に合わせて端末設定から組む（応答言語に影響。認証には無関係）。
        let lang = Locale.current.language.languageCode?.identifier ?? "ja"
        let region = Locale.current.region?.identifier ?? "JP"
        // deviceId: 呼び出し側(設定の方式)で解決済みの値を使う。未指定時のみ使い捨てを生成。
        // 認証には無関係(サーバは検証しない)なので任意値で通る。
        let installId = deviceId ?? UUID().uuidString.uppercased()
        let requestId = UUID().uuidString.uppercased()

        var components = URLComponents(
            string: "https://amp.shazam.com/match/v2/\(lang)/\(region)/iphone/\(installId)/\(requestId)"
        )!
        // 実機 iOS の match/v2 と同じクエリ（matchv2t は付かない）。
        components.queryItems = [
            URLQueryItem(name: "recognitionType", value: "progressive-with-rolling"),
            URLQueryItem(name: "sampling", value: "true"),
            URLQueryItem(name: "hidelb", value: "true"),
            URLQueryItem(name: "video", value: "v3")
        ]

        // 実機 iOS が送るボディ形式そのまま（signatures 配列 + timestamp + timezone + context:{}）。
        let body: [String: Any] = [
            "signatures": [[
                "uri": signatureURI,
                "audioSource": "MIC",
                "samplems": sampleDurationMs
            ]],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "timezone": TimeZone.current.identifier,
            "context": [String: Any]()
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        // 実機 iOS の match/v2 が実際に付けていたヘッダのみ（User-Agent 等は付けない）。
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("IPHONE", forHTTPHeaderField: "X-Shazam-Platform")
        request.setValue("17.18.0", forHTTPHeaderField: "X-Shazam-AppVersion")
        request.setValue("0", forHTTPHeaderField: "X-Shazam-Auth-Retry")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        stage("②match/v2 送信中… (採取Bearer / amp.shazam.com)")
        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ShazamAPIError.invalidResponse
        }
        stage("②match/v2 応答 HTTP \(http.statusCode)")

        let rawText = String(data: data, encoding: .utf8) ?? "<非UTF-8 \(data.count) bytes>"

        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                throw ShazamAPIError.authFailure(
                    "採取した Bearer が拒否されました (HTTP \(http.statusCode))。"
                    + "shazam-auth.json を採り直してください（JWT は約30日で失効）。"
                )
            case 429:        throw ShazamAPIError.tooManyRequests
            case 404:        throw ShazamAPIError.noMatch
            case 500..<600:  throw ShazamAPIError.serviceUnavailable
            default:         throw ShazamAPIError.httpStatus(http.statusCode)
            }
        }

        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let result = ShazamV2Backend.parse(root)
        return (result, rawText)
    }

    // MARK: - レート制限

    private func enforceRateLimit() async throws {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minRequestInterval {
            let wait = minRequestInterval - elapsed
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        lastRequestTime = Date()
    }
}
