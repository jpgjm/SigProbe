# SigProbe

Shazam 互換の音響フィンガープリント (音楽認識) を iOS 上で検証するための単独アプリ。

Metrolist (Android / Kotlin) の `ShazamSignatureGenerator.kt` + `shazamkit/Shazam.kt` を
Swift へ移植したもの。検証が済んだら `Sources/Recognition/` をそのまま ViviMusic へ移す。

---

## なぜ純正 ShazamKit を使わないのか

iOS 15+ には Apple 純正の `ShazamKit` (`SHSession` / `SHSignatureGenerator`) があるが、
Shazam カタログとの照合には Developer Portal 側で **ShazamKit App Service** を
App ID に対して有効化する必要があり、**無料の Personal Team ではこれができない**。

有効化されていない状態で照合すると署名生成だけは通って結果が空になるため、
原因の切り分けが極めて困難になる。

> `com.apple.developer.shazamkit` のような entitlement を捏造して埋め込んではならない。
> AlarmKit で `com.apple.developer.alarmkit` を捏造したときと同様、
> エラーコードすら出ない沈黙失敗か、SideStore でのインストール自体が弾かれる。

したがって本アプリは **vibra 方式** (自前で指紋を生成し `amp.shazam.com` へ投げる) を採る。
必要な権限は `NSMicrophoneUsageDescription` のみで、entitlement は一切不要。
App ID スロットの追加消費もない。

---

## 構成

```
SigProbe/
├── .github/workflows/build.yml   GitHub Actions (unsigned IPA)
├── project.yml                   XcodeGen
├── Resources/                    Info.plist は xcodegen が生成する
└── Sources/
    ├── SigProbeApp.swift
    ├── UI/
    │   ├── ContentView.swift     認識画面・設定・ログ・ダンプ
    │   └── LogStore.swift
    └── Recognition/              ← ViviMusic へ移すのはこのフォルダ
        ├── AudioCapture.swift            AVAudioEngine → 16kHz mono Int16
        ├── FFTProcessor.swift            vDSP 版 / 純Swift 版
        ├── ShazamSignatureGenerator.swift 指紋生成 (移植の主戦場)
        ├── CRC32.swift
        ├── ShazamAPIClient.swift         amp.shazam.com (v5/v2 切替)
        ├── ShazamV2Backend.swift         match/v2 用トークン取得とパーサ
        ├── RecognitionModels.swift       結果モデル + 寛容な JSON デコーダ
        └── MusicRecognizer.swift         全体制御
```

## 処理の流れ

1. **録音** — `AVAudioEngine` + `AVAudioConverter` で 16kHz / モノラル / Int16 を 12 秒
2. **指紋生成** — 128 サンプルずつスライドしながら 2048 点 FFT → peak spreading → ピーク抽出
3. **エンコード** — 4 バンド別に差分エンコード、48 バイトヘッダ + CRC32、Base64
4. **照合** — `amp.shazam.com/discovery/v5/...` へ POST (API キー不要)
   - 設定でエンドポイントを `match/v2` に切り替えられる (下記)
5. **表示** — タイトル / アーティスト / ISRC / YouTube videoId など

## Android 版との差分

| 項目 | Android (Metrolist) | SigProbe |
|---|---|---|
| 録音レート | 44.1kHz → 線形補間で 16kHz | **最初から 16kHz へ AVAudioConverter で変換** |
| アンチエイリアス | **無し (折り返し歪みあり)** | AVAudioConverter が内蔵 |
| 入力処理 | `AudioSource.MIC` (AGC 等が掛かる) | `AVAudioSession` の **`.measurement` モード** |
| FFT | 自前 Cooley-Tukey | vDSP / 自前を切替可能 |
| バックグラウンド | Foreground Service で継続 | 画面表示中のみ (iOS に相当機能なし) |

前 2 つの改善により、3500-5500Hz バンドの指紋品質は Android 版より良くなるはず。

---

## 検証手順

指紋生成は **数値が 1 つズレるだけで「No match」しか返さず、原因の切り分けが極めて困難**。
以下の順で切り分ける。

### 1. 録音が取れているか

ログの「録音完了: … ピーク振幅 N」を見る。N が 200 未満なら入力が来ていない。

### 2. ピークが出ているか

「指紋生成完了: ピーク N 本」。実際の音楽なら **数百〜2000 本**程度が出る。
0 本ならスペクトル計算 (特に FFT のスケーリング) が疑わしい。

### 3. FFT 実装の突き合わせ

設定 → FFT 実装 で **「純Swift」** に切り替える。
これは Kotlin 版の逐語移植で演算順序まで同じなので、同じ PCM から同じ結果が出るはず。

- 純Swift でだけ認識が通る → **vDSP のスケーリングが誤り**
- どちらも通らない → 指紋生成そのもの、または API 側の問題

### 4. Android 版との突き合わせ

「録音を WAV で書き出す」で 16kHz モノラルの WAV を取り出し、
同じ WAV を Android 版 (Metrolist / ArchiveTune) の指紋生成に食わせて比較する。

> 注意: **Base64 が完全一致することは期待しない。**
> 浮動小数点の演算順序がわずかに違うだけで末尾のピークが 1〜2 本ずれる。
> 比較するのは「ピーク総数」「バンド別の本数」「上位ピークの周波数」の水準。
> 純Swift 版どうしなら一致する可能性は高いが、一致しなくても異常ではない。

### 5. エンドポイントの切り分け

設定 → API エンドポイント で送信先を切り替えられる。**指紋の生成処理は3方式とも完全に同じ**で、
違うのは送信先・認証方法・レスポンス構造だけ。

| | discovery/v5 (既定) | match/v2 | match/v2 (採取Bearer直接) |
|---|---|---|---|
| 認証 | 不要 | Apple トークン必須 | 採取した Authorization ベアラ |
| 外部依存 | 無し | 第三者の `key.json` | 実機採取の `shazam-auth.json` |
| トークン取得 | — | 署名→apiToken 交換 | **不要（Bearer を直用）** |
| 曲情報の位置 | トップレベルの `track` | `resources[type][id].attributes` | 同左（v2 と同じパーサ） |

v2 のトークンは `key.json` が公開する Apple 署名に依存する。署名は短命で、
**古くなると Apple が 401 `verificationFailure` を返す**。その場合はログに

```
❌ 認証失敗: Apple 署名が失効しています (401)。...
→ key.json の署名が失効している。設定 → API エンドポイント で v5 を選ぶこと
```

と出るので、v5 に戻せばよい。v2 は常用せず、v5 で結果が怪しいときの比較用と考える。

**v2direct（採取Bearer直接）** は、実機 iOS Shazam が `match/v2` に実際に付けている
`Authorization: Bearer <約30日の JWT>` を [ShazamSigCapture](https://github.com/) で採取し、
その `shazam-auth.json` を Documents に置くだけで使える。Apple 署名も apiToken 交換も不要で、
iOS 実機の送信形（`signatures` 配列 + `context:{}` ＋ `X-Shazam-*` ヘッダ）をそのまま再現する。
JWT はユーザー紐付けの無いアプリレベルのトークンなので約30日そのまま使い回せる（exp を過ぎたら採り直す）。

### 6. API 側の確認

「生レスポンスを見る」で JSON をそのまま確認する。冒頭にどちらのエンドポイントで
取得したかが表示される。
`track` が空なら本当に一致しなかっただけ。HTTP 429 ならレート制限。

---

## ビルド

GitHub Actions (`macos-15`) で unsigned IPA を生成する。
成果物は 3 つ、すべて共通の JST タイムスタンプ接頭辞つき。

- `<stamp>_SigProbe-ipa`
- `<stamp>_xcodebuild-log` (always)
- `<stamp>_Repository` (always)

SideStore でそのままインストールできる。entitlement が無いため署名の付け替えは不要。

### 変更が必要な箇所

`project.yml` の `PRODUCT_BUNDLE_IDENTIFIER` は `com.example.SigProbe` のままなので、
自分の命名規則に合わせて書き換えること。

---

## v2 の署名ファイル（key.json / last-request.json）

`match/v2` は Apple のトークンを要し、そのトークン取得には端末生成の
`x-apple-actionsignature` が要る。SigProbe はこれを自前で作れないため、
**実機の Shazam を LSPatch モジュール (ShazamSigCapture) でフックして採取した
2 ファイルをアプリの Documents から読み込む**。値・URL・ヘッダはハードコードしない。

### 置き方

1. ShazamSigCapture でパッチした Shazam を起動し、データ消去 → コールドスタートで
   `sf-api-token-service.itunes.apple.com/apiToken` を踏ませて採取
   （`key.json` と `last-request.json` が Android 側に書き出される）。
2. その 2 ファイルを iPhone に移し、**ファイル App →「このiPhone内」→「SigProbe」**に置く。
   （`project.yml` で `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` を有効化済み）
3. 設定 → API エンドポイント で `match/v2` を選ぶと、設定画面に
   「v2 採取ファイル」セクションが出て、2 ファイルの有無と timestamp を確認できる。

### 動作

- `key.json`          … `apple_action_signature` / `x_request_timestamp`（署名2値の正）
- `last-request.json` … apiToken の `url`(inid含む) と全 `headers`

`ShazamV2Backend.fetchToken` は last-request.json の url + headers を**そのまま再生**し、
署名2値だけ key.json で上書きしてトークンを取得する。**key.json だけ差し替えれば更新できる。**

> 署名は短命。401 `verificationFailure` が出たら実機で採り直す。
> 取得済みトークンは JWT の `exp`（約30日）まで有効なので、実運用ではトークンを
> キャッシュして使い回す。

## ViviMusic への統合時のメモ

- `Sources/Recognition/` をそのままコピーすればよい。UI 層への依存は無い。
- ただし `MusicRecognizer` は `LogStore` に依存しているので、
  統合時は ViviMusic 側のロガーへ差し替えるか `LogStore.swift` も一緒に持っていく。
- **認識開始時に ViviMusic 自身の再生を必ず一時停止すること。**
  そうしないと自分の出力を認識してしまう。
  `AVAudioSession` を `.record` に切り替える時点で再生は止まるが、
  プレイヤー側の状態も明示的に止めないと復帰時に不整合が出る。
- 認識後の遷移は Android 版と同じく `"\(title) \(artist)"` での検索が無難。
  Shazam が返す `youtubeVideoId` は音楽用の動画とは限らない。

---

## 出典

- vibra / SongRec — Shazam 署名アルゴリズムのリバースエンジニアリング
- MusicRecognizer (Aleksey Saenko) — Metrolist の音楽認識機能の原典
- Metrolist — 本移植元の Kotlin 実装
