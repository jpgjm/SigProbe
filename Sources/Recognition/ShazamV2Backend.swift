//
//  ShazamV2Backend.swift
//  SigProbe
//
//  match/v2 エンドポイント用のバックエンド。
//
//  v5 (discovery/v5) と違い Apple の API トークンが必要で、そのトークンを得るには
//  端末上で生成される x-apple-actionsignature が要る。SigProbe はそれを自前で作れない。
//
//  そこで実機の Shazam を LSPatch でフックして採取した
//    - key.json          … { apple_action_signature, x_request_timestamp }
//    - last-request.json … apiToken リクエストの URL(inid含む) と全ヘッダ
//  を **アプリの Documents ディレクトリから読み込む**。値・URL・ヘッダは一切
//  ハードコードしない。採取した last-request.json をそのまま再生し、署名2値だけ
//  key.json で上書きする（key.json だけ差し替えれば更新できるように）。
//
//  ファイルの置き方（iOS・ファイル App 経由）：
//    「ファイル」→「このiPhone内」→「SigProbe」フォルダに
//    key.json と last-request.json を入れる。
//    (project.yml で UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace を有効化済み)
//
//  ⚠️ 署名は短命。トークン(exp 約30日)を取れるのは署名が生きている短時間だけなので、
//     採取したらすぐトークン化し、以後は exp まで使い回す運用にする。
//

import Foundation

enum ShazamV2Backend {

    static let keyFileName = "key.json"
    static let lastRequestFileName = "last-request.json"
    static let authFileName = "shazam-auth.json"   // v2direct 用（採取した Authorization ベアラ）

    /// 採取ファイルを置くディレクトリ（アプリの Documents）。
    static var captureDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 採取した apiToken リクエストの再生に必要な一式。全て採取ファイル由来。
    struct CapturedRequest {
        let url: URL                      // last-request.json の url（inid 等を含む）
        let headers: [String: String]     // last-request.json の headers（署名2値は key.json で上書き済み）
        let requestTimestamp: String      // key.json の x_request_timestamp
    }

    // MARK: - 採取ファイルの読み込み（ハードコードしない）

    /// Documents から key.json と last-request.json を読み、再生用リクエストを組む。
    /// - key.json          … apple_action_signature / x_request_timestamp（署名2値の正）
    /// - last-request.json … url と headers（inid・storefront・tz・UA 等の文脈）
    static func loadCapturedRequest() throws -> CapturedRequest {
        let dir = captureDirectory
        let keyURL = dir.appendingPathComponent(keyFileName)
        let lastURL = dir.appendingPathComponent(lastRequestFileName)

        let fm = FileManager.default
        guard fm.fileExists(atPath: keyURL.path) else {
            throw ShazamAPIError.authFailure(
                "\(keyFileName) が見つかりません。ファイル App の『このiPhone内 → SigProbe』に "
                + "\(keyFileName) と \(lastRequestFileName) を置いてください。"
            )
        }
        guard fm.fileExists(atPath: lastURL.path) else {
            throw ShazamAPIError.authFailure(
                "\(lastRequestFileName) が見つかりません。SigProbe フォルダに置いてください。"
            )
        }

        // key.json（署名2値）
        let keyRoot = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: keyURL))
        guard let signature = keyRoot["apple_action_signature"]?.stringValue,
              let timestamp = keyRoot["x_request_timestamp"]?.stringValue else {
            throw ShazamAPIError.authFailure("\(keyFileName) の形式が想定と違います")
        }

        // last-request.json（url + headers）
        let lastRoot = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: lastURL))
        guard let urlString = lastRoot["url"]?.stringValue,
              let url = URL(string: urlString) else {
            throw ShazamAPIError.authFailure("\(lastRequestFileName) に有効な url がありません")
        }

        // headers を辞書化。採取された全ヘッダをそのまま再生する。
        var headers: [String: String] = [:]
        if case .object(let dict)? = lastRoot["headers"] {
            for (k, v) in dict {
                if let s = v.stringValue { headers[k] = s }
            }
        }
        // 署名2値だけ key.json の値で上書き（key.json だけ更新すれば差し替え可能に）
        headers["x-apple-actionsignature"] = signature
        headers["x-request-timestamp"] = timestamp

        return CapturedRequest(url: url, headers: headers, requestTimestamp: timestamp)
    }

    /// 設定画面表示用：採取ファイルが揃っているかと、key.json の timestamp。
    struct CaptureStatus {
        let keyExists: Bool
        let lastRequestExists: Bool
        let timestamp: String?
        var isReady: Bool { keyExists && lastRequestExists }
    }

    static func captureStatus() -> CaptureStatus {
        let dir = captureDirectory
        let fm = FileManager.default
        let keyURL = dir.appendingPathComponent(keyFileName)
        let lastURL = dir.appendingPathComponent(lastRequestFileName)
        let keyExists = fm.fileExists(atPath: keyURL.path)
        let lastExists = fm.fileExists(atPath: lastURL.path)

        var ts: String?
        if keyExists,
           let data = try? Data(contentsOf: keyURL),
           let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
            ts = root["x_request_timestamp"]?.stringValue
        }
        return CaptureStatus(keyExists: keyExists, lastRequestExists: lastExists, timestamp: ts)
    }

    // MARK: - v2direct 用：採取した Authorization ベアラ

    /// Documents の shazam-auth.json から Authorization ベアラ(JWT)を読む。
    /// ShazamSigCapture(iOS) が採取したファイルをそのまま置くだけでよい。値はハードコードしない。
    static func loadCapturedBearer() throws -> String {
        let url = captureDirectory.appendingPathComponent(authFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ShazamAPIError.authFailure(
                "\(authFileName) が見つかりません。ファイル App の『このiPhone内 → SigProbe』に "
                + "ShazamSigCapture が採取した \(authFileName) を置いてください。"
            )
        }
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard let auth = bearerHeader(from: root) else {
            throw ShazamAPIError.authFailure("\(authFileName) に headers.Authorization がありません")
        }
        return strippedBearer(auth)
    }

    /// shazam-auth.json の headers.Authorization を大文字小文字を無視して探す。
    private static func bearerHeader(from root: JSONValue) -> String? {
        guard case .object(let headers)? = root["headers"] else { return nil }
        for (k, v) in headers where k.lowercased() == "authorization" {
            if let s = v.stringValue { return s }
        }
        return nil
    }

    /// "Bearer xxx" から素のトークンを取り出す。
    private static func strippedBearer(_ auth: String) -> String {
        let trimmed = auth.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("bearer ") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    /// 設定画面表示用：shazam-auth.json の有無と JWT の exp。
    struct BearerStatus {
        let exists: Bool
        let expiry: Date?
        var isReady: Bool { exists }
    }

    static func bearerStatus() -> BearerStatus {
        let url = captureDirectory.appendingPathComponent(authFileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let auth = bearerHeader(from: root) else {
            return BearerStatus(exists: false, expiry: nil)
        }
        return BearerStatus(exists: true, expiry: jwtExpiry(strippedBearer(auth)))
    }

    /// JWT のペイロードから exp を取り出す（署名検証はせず base64url decode のみ）。
    private static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = obj["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - トークン取得

    static func fetchToken(session: URLSession) async throws -> (token: String, signatureTimestamp: String) {
        let captured = try loadCapturedRequest()

        // 採取した apiToken リクエストをそのまま再生する（URL もヘッダもファイル由来）
        var request = URLRequest(url: captured.url)
        request.httpMethod = "GET"
        for (name, value) in captured.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ShazamAPIError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 {
                throw ShazamAPIError.authFailure(
                    "Apple 署名が失効しています (401)。key.json の x_request_timestamp は "
                    + "\(captured.requestTimestamp) です。実機で採取し直してください。"
                )
            }
            throw ShazamAPIError.authFailure("トークン取得に失敗しました (HTTP \(http.statusCode))")
        }

        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let token = root["token"]?.stringValue else {
            throw ShazamAPIError.authFailure("レスポンスに token が含まれていません")
        }

        return (token, captured.requestTimestamp)
    }

    // MARK: - パース

    /// v2 のレスポンスは v5 と構造が全く違う。
    ///   results.matches[0].id / .type をキーに
    ///   resources[type][id].attributes を引く「参照型」。
    ///
    /// ⚠️ 現在 key.json が失効しており実マッチを確認できていないため、
    ///    以下のフィールド対応は Shazam-API (Node) の変換処理からの推定。
    ///    実際に通ったら「生レスポンスを見る」で確認して調整すること。
    static func parse(_ root: JSONValue) -> RecognitionResult? {
        guard let match = root["results"]?["matches"]?[0] else { return nil }

        let songId = match["id"]?.stringValue ?? ""
        let songType = match["type"]?.stringValue ?? "shazam-songs"

        let resource = root["resources"]?[songType]?[songId]
        let attrs = resource?["attributes"]

        let title = attrs?["title"]?.stringValue ?? ""
        let artist = attrs?["artist"]?.stringValue ?? attrs?["subtitle"]?.stringValue ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        // アルバムは relationships 経由でもう一段引く
        var albumName: String?
        var albumReleaseDate: String?
        if let albumRef = resource?["relationships"]?["albums"]?["data"]?[0],
           let albumType = albumRef["type"]?.stringValue,
           let albumId = albumRef["id"]?.stringValue,
           let albumAttrs = root["resources"]?[albumType]?[albumId]?["attributes"] {
            albumName = albumAttrs["name"]?.stringValue
            albumReleaseDate = albumAttrs["releaseDate"]?.stringValue
        }

        // 画像は images.coverart / artwork.url (テンプレート) のどちらかで来る
        let images = attrs?["images"]
        let coverArt = images?["coverart"]?.stringValue
        let coverArtHq = images?["coverarthq"]?.stringValue ?? artworkURL(attrs?["artwork"])

        return RecognitionResult(
            trackId: songId.isEmpty ? UUID().uuidString : songId,
            title: title,
            artist: artist,
            album: albumName,
            coverArtURL: coverArt,
            coverArtHqURL: coverArtHq,
            genre: attrs?["genres"]?["primary"]?.stringValue,
            releaseDate: albumReleaseDate,
            label: attrs?["label"]?.stringValue,
            shazamURL: attrs?["webUrl"]?.stringValue ?? match["href"]?.stringValue,
            appleMusicURL: nil,
            spotifyURL: nil,
            isrc: attrs?["isrc"]?.stringValue,
            youtubeVideoId: nil
        )
    }

    /// Apple Music 形式の artwork テンプレート ({w}x{h}) を実寸 URL に展開する。
    private static func artworkURL(_ artwork: JSONValue?) -> String? {
        guard let template = artwork?["url"]?.stringValue else { return nil }
        return template
            .replacingOccurrences(of: "{w}", with: "800")
            .replacingOccurrences(of: "{h}", with: "800")
            .replacingOccurrences(of: "{f}", with: "jpg")
    }
}
