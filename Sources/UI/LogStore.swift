//
//  LogStore.swift
//  SigProbe
//

import Foundation
import SwiftUI

/// 全ての append は MusicRecognizer (@MainActor) 側から呼ばれる前提。
/// ネストした Entry の Identifiable 準拠が隔離違反にならないよう、
/// このクラス自体にはグローバルアクター注釈を付けない。
final class LogStore: ObservableObject {

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    @Published private(set) var entries: [Entry] = []

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return f
    }()

    func append(_ text: String) {
        entries.append(Entry(date: Date(), text: text))
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var plainText: String {
        entries
            .map { "[\(Self.formatter.string(from: $0.date))] \($0.text)" }
            .joined(separator: "\n")
    }

    func formatted(_ entry: Entry) -> String {
        "[\(Self.formatter.string(from: entry.date))] \(entry.text)"
    }
}
