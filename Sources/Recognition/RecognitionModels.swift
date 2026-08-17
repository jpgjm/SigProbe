//
//  RecognitionModels.swift
//  SigProbe
//

import Foundation

// MARK: - 結果

struct RecognitionResult: Identifiable, Equatable {
    var id: String { trackId }

    let trackId: String
    let title: String
    let artist: String
    let album: String?
    let coverArtURL: String?
    let coverArtHqURL: String?
    let genre: String?
    let releaseDate: String?
    let label: String?
    let shazamURL: String?
    let appleMusicURL: String?
    let spotifyURL: String?
    let isrc: String?
    let youtubeVideoId: String?
}

// MARK: - 状態

enum RecognitionStatus: Equatable {
    case ready
    case listening(progress: Double)
    case processing
    case querying
    case success(RecognitionResult)
    case noMatch(String)
    case error(String)

    var isBusy: Bool {
        switch self {
        case .listening, .processing, .querying: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .ready:              return "待機中"
        case .listening:          return "聴き取り中…"
        case .processing:         return "指紋を生成中…"
        case .querying:           return "照合中…"
        case .success:            return "認識しました"
        case .noMatch(let m):     return m
        case .error(let m):       return m
        }
    }
}

// MARK: - 寛容な JSON

/// Shazam の非公式エンドポイントはレスポンス構造がしばしば変わる。
/// Swift の Codable は型が 1 つ食い違っただけで全体のデコードに失敗するため、
/// 動的な木として受けてから必要なフィールドだけ拾う。
indirect enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            self = .null
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let dict) = self { return dict[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let arr) = self, arr.indices.contains(index) { return arr[index] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b):   return String(b)
        default:             return nil
        }
    }

    var arrayValue: [JSONValue] {
        if case .array(let arr) = self { return arr }
        return []
    }

    /// 文字列 or 文字列配列のどちらでも受ける (歌詞セクションの text 用)
    var stringListValue: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let arr): return arr.compactMap { $0.stringValue }
        default: return []
        }
    }
}

// MARK: - パース

enum ShazamResponseParser {

    static func parse(_ root: JSONValue) -> RecognitionResult? {
        guard let track = root["track"] else { return nil }

        let sections = track["sections"]?.arrayValue ?? []

        let songSection = sections.first { $0["type"]?.stringValue == "SONG" }
        let metadata = songSection?["metadata"]?.arrayValue ?? []
        func meta(_ title: String) -> String? {
            metadata.first { $0["title"]?.stringValue == title }?["text"]?.stringValue
        }

        let hub = track["hub"]
        let options = hub?["options"]?.arrayValue ?? []
        let providers = hub?["providers"]?.arrayValue ?? []

        let appleURL = options
            .first { ($0["providername"]?.stringValue ?? "").lowercased().contains("apple") }?["actions"]?[0]?["uri"]?.stringValue

        let spotifyURL = providers
            .first { ($0["caption"]?.stringValue ?? "").lowercased().contains("spotify") }?["actions"]?[0]?["uri"]?.stringValue

        let youtubeURI = options
            .first { ($0["type"]?.stringValue ?? "").lowercased().contains("video") }?["actions"]?[0]?["uri"]?.stringValue

        let youtubeVideoId: String? = youtubeURI.flatMap { uri in
            if let range = uri.range(of: "v=", options: .backwards) {
                let candidate = String(uri[range.upperBound...])
                if !candidate.isEmpty { return candidate }
            }
            if let range = uri.range(of: "/", options: .backwards) {
                let candidate = String(uri[range.upperBound...])
                if candidate.count == 11 { return candidate }
            }
            return nil
        }

        let title = track["title"]?.stringValue ?? ""
        let artist = track["subtitle"]?.stringValue ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        return RecognitionResult(
            trackId: track["key"]?.stringValue ?? root["tagid"]?.stringValue ?? UUID().uuidString,
            title: title,
            artist: artist,
            album: meta("Album"),
            coverArtURL: track["images"]?["coverart"]?.stringValue,
            coverArtHqURL: track["images"]?["coverarthq"]?.stringValue,
            genre: track["genres"]?["primary"]?.stringValue,
            releaseDate: meta("Released"),
            label: meta("Label"),
            shazamURL: track["url"]?.stringValue,
            appleMusicURL: appleURL,
            spotifyURL: spotifyURL,
            isrc: track["isrc"]?.stringValue,
            youtubeVideoId: youtubeVideoId
        )
    }
}
