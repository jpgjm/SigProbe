//
//  DeviceIdProvider.swift
//  SigProbe
//
//  v2direct の match/v2 URL …/iphone/<deviceId>/<requestId> のうち
//  1つ目の deviceId をどう用意するかの方式と生成器。
//
//  実機ダンプで確認済みの通り、サーバは deviceId を認証検証していない
//  （Shazam の認識は匿名・端末登録なし、Bearer JWT に device クレーム無し）。
//  よってどちらの方式でも認識の成否・精度は変わらない。選択は「値の性格」の違いだけ。
//  なお 2つ目の requestId は認識ごとに新規生成で、この設定の対象外。
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// deviceId(1つ目の UUID)の生成方式。
enum DeviceIdMode: String, CaseIterable, Identifiable {
    /// 端末と無関係な UUID を初回に1個生成し、保存して使い回す。
    case persistentRandom
    /// identifierForVendor(IDFV) を使う。実質「ユーザー端末の UUID」。
    case identifierForVendor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .persistentRandom:    return "自前ランダム生成 + 保存"
        case .identifierForVendor: return "identifierForVendor (IDFV)"
        }
    }

    var note: String {
        switch self {
        case .persistentRandom:
            return "端末と無関係な UUID を初回に1個だけ生成し、保存して以後ずっと使い回す。値を自分で管理でき、識別子として端末に紐づかない。"
        case .identifierForVendor:
            return "この端末×この開発元に割り当てられる UUID(IDFV)を使う。実質「ユーザー端末の UUID」で入力不要。同じ開発元のアプリを全て削除→再インストールすると変わり得る。取得できない稀なケースは保存済みランダムに自動フォールバックする。"
        }
    }
}

/// 選択された方式で deviceId を返す。
enum DeviceIdProvider {

    /// 自前ランダム版の保存キー。
    private static let storeKey = "v2direct.deviceId.persistentRandom"

    /// 方式に応じた deviceId(大文字 UUID 文字列)を返す。
    static func deviceId(for mode: DeviceIdMode) -> String {
        switch mode {
        case .persistentRandom:
            return persistentRandom()
        case .identifierForVendor:
            #if canImport(UIKit)
            if let idfv = UIDevice.current.identifierForVendor?.uuidString {
                return idfv.uppercased()
            }
            #endif
            // IDFV が取れない稀なケースは保存済みランダムに退避（送信を止めない）。
            return persistentRandom()
        }
    }

    /// 初回に生成して UserDefaults に保存し、以後は同じ値を返す。
    private static func persistentRandom() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: storeKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.uppercased()
        defaults.set(generated, forKey: storeKey)
        return generated
    }

    /// 保存済みの自前ランダム値をクリアする（設定で「作り直す」用）。次回アクセスで再生成される。
    static func resetPersistentRandom() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}
