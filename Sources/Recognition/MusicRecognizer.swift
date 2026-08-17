//
//  MusicRecognizer.swift
//  SigProbe
//
//  録音 → 指紋生成 → API 照合 の一連を束ねる。
//  ViviMusic へ統合する際は、このクラスと Recognition/ 配下をそのまま持っていける。
//

import Foundation
import SwiftUI

@MainActor
final class MusicRecognizer: ObservableObject {

    @Published private(set) var status: RecognitionStatus = .ready
    @Published private(set) var lastSignature: String?
    @Published private(set) var lastSignatureInfo: String?
    @Published private(set) var lastRawResponse: String?
    @Published private(set) var lastEndpoint: ShazamEndpoint?
    @Published private(set) var lastPCM: [Int16] = []

    @Published var fftKind: FFTKind {
        didSet { UserDefaults.standard.set(fftKind.rawValue, forKey: Keys.fftKind) }
    }
    @Published var recordSeconds: Double {
        didSet { UserDefaults.standard.set(recordSeconds, forKey: Keys.recordSeconds) }
    }
    @Published var endpoint: ShazamEndpoint {
        didSet { UserDefaults.standard.set(endpoint.rawValue, forKey: Keys.endpoint) }
    }
    /// v2direct の deviceId 生成方式。
    @Published var deviceIdMode: DeviceIdMode {
        didSet { UserDefaults.standard.set(deviceIdMode.rawValue, forKey: Keys.deviceIdMode) }
    }

    private enum Keys {
        static let fftKind = "fftKind"
        static let recordSeconds = "recordSeconds"
        static let endpoint = "shazamEndpoint"
        static let deviceIdMode = "v2direct.deviceIdMode"
    }

    let log = LogStore()

    private var capture: AudioCapture?
    private var task: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let storedKind = defaults.string(forKey: Keys.fftKind)
        fftKind = storedKind.flatMap(FFTKind.init(rawValue:)) ?? .accelerate

        let storedSeconds = defaults.double(forKey: Keys.recordSeconds)
        recordSeconds = storedSeconds > 0 ? storedSeconds : 12.0

        let storedEndpoint = defaults.string(forKey: Keys.endpoint)
        endpoint = storedEndpoint.flatMap(ShazamEndpoint.init(rawValue:)) ?? .v5

        let storedDeviceIdMode = defaults.string(forKey: Keys.deviceIdMode)
        deviceIdMode = storedDeviceIdMode.flatMap(DeviceIdMode.init(rawValue:)) ?? .persistentRandom
    }

    // MARK: - 実行

    func start() {
        guard !status.isBusy else { return }

        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    func cancel() {
        task?.cancel()
        capture?.cancel()
        capture = nil
        status = .ready
        log.append("ユーザーによりキャンセル")
    }

    func reset() {
        guard !status.isBusy else { return }
        status = .ready
    }

    private func run() async {
        log.append("―― 認識開始 ――")

        // 1. 権限
        if !AudioCapture.hasPermission {
            log.append("マイク権限を要求")
            let granted = await AudioCapture.requestPermission()
            if !granted {
                status = .error("マイクの使用が許可されていません")
                log.append("マイク権限が拒否された")
                return
            }
        }

        // 2. 録音
        let duration = recordSeconds
        status = .listening(progress: 0)
        log.append("録音開始: \(String(format: "%.1f", duration)) 秒 / 16000Hz mono Int16")

        let capture = AudioCapture()
        self.capture = capture

        let pcm: [Int16]
        do {
            pcm = try await capture.record(duration: duration) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .listening = self.status else { return }
                    self.status = .listening(progress: progress)
                }
            }
        } catch {
            status = .error(error.localizedDescription)
            log.append("録音失敗: \(error.localizedDescription)")
            self.capture = nil
            return
        }
        self.capture = nil

        guard !Task.isCancelled else { return }

        lastPCM = pcm
        let peak = pcm.map { abs(Int($0)) }.max() ?? 0
        log.append("録音完了: \(pcm.count) サンプル (\(pcm.count * 1000 / 16000) ms), ピーク振幅 \(peak)")
        if peak < 200 {
            log.append("⚠️ 入力レベルが極めて低い。マイクが塞がれているか無音の可能性")
        }

        // 3. 指紋生成
        status = .processing
        let kind = fftKind
        log.append("指紋生成開始 (FFT: \(kind.label))")

        let started = Date()
        let output: ShazamSignatureGenerator.Output = await Task.detached(priority: .userInitiated) {
            ShazamSignatureGenerator.generate(pcm: pcm, fft: kind.make())
        }.value
        let elapsed = Date().timeIntervalSince(started)

        guard !Task.isCancelled else { return }

        lastSignature = output.signatureURI
        lastSignatureInfo = """
        FFT実装        : \(kind.label)
        処理時間       : \(String(format: "%.2f", elapsed)) 秒
        サンプル数     : \(output.numSamples) (\(output.sampleDurationMs) ms)
        ピーク総数     : \(output.totalPeaks)
        バンド別ピーク : 250-520Hz=\(output.peaksPerBand[0]) / \
        520-1450Hz=\(output.peaksPerBand[1]) / \
        1450-3500Hz=\(output.peaksPerBand[2]) / \
        3500-5500Hz=\(output.peaksPerBand[3])
        署名バイト数   : \(output.rawBytes.count)
        Base64長       : \(output.signatureURI.count)
        """
        log.append("指紋生成完了: ピーク \(output.totalPeaks) 本 / \(output.rawBytes.count) バイト / \(String(format: "%.2f", elapsed))秒")

        if output.totalPeaks == 0 {
            status = .error("ピークが 1 本も検出されませんでした。音量が低すぎる可能性があります")
            log.append("⚠️ ピーク 0 本。照合は行わない")
            return
        }

        // 4. 照合
        status = .querying
        let endpoint = self.endpoint
        lastEndpoint = endpoint
        log.append("Shazam へ送信 (endpoint=\(endpoint.shortLabel), samplems=\(output.sampleDurationMs))")

        // ShazamAPIClient の段階ログ（①トークン/②match）を画面ログへ流す。
        // どのリクエストで詰まったか（タイムアウト箇所）を可視化する。
        ShazamAPIClient.stageLog = { [weak self] msg in
            Task { @MainActor in self?.log.append(msg) }
        }

        do {
            // v2direct の deviceId は選択方式で解決してから渡す（IDFV 取得は MainActor 上で）。
            let deviceId = DeviceIdProvider.deviceId(for: deviceIdMode)
            if endpoint == .v2direct {
                log.append("deviceId 方式=\(deviceIdMode.label) → \(deviceId)")
            }
            let (result, raw) = try await ShazamAPIClient.shared.recognize(
                signatureURI: output.signatureURI,
                sampleDurationMs: output.sampleDurationMs,
                endpoint: endpoint,
                deviceId: deviceId
            )
            lastRawResponse = raw
            log.append("レスポンス受信: \(raw.count) 文字")

            if let result {
                status = .success(result)
                log.append("✅ 一致: \(result.title) / \(result.artist)")
            } else {
                status = .noMatch("一致する曲が見つかりませんでした")
                log.append(endpoint == .v5
                           ? "一致なし (track フィールドが空)"
                           : "一致なし (results.matches が空)")
            }
        } catch {
            if let apiError = error as? ShazamAPIError, case .noMatch = apiError {
                status = .noMatch("一致する曲が見つかりませんでした")
                log.append("一致なし (HTTP 404)")
            } else if let apiError = error as? ShazamAPIError, case .authFailure(let detail) = apiError {
                status = .error(endpoint == .v2direct
                    ? "採取した Bearer が使えませんでした。shazam-auth.json を採り直してください"
                    : "v2 の認証に失敗しました。設定で v5 に切り替えてください")
                log.append("❌ 認証失敗: \(detail)")
                log.append(endpoint == .v2direct
                    ? "→ JWT が失効した可能性。ShazamSigCapture で shazam-auth.json を採り直すこと"
                    : "→ key.json の署名が失効している。設定 → API エンドポイント で v5 を選ぶこと")
            } else {
                status = .error(error.localizedDescription)
                log.append("❌ 照合失敗: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 検証用エクスポート

    /// 録音した 16kHz PCM を WAV として書き出す。
    /// Android 版 (Metrolist / ArchiveTune) に同じ WAV を食わせて
    /// 署名を突き合わせるための検証用。
    func exportWAV() -> URL? {
        guard !lastPCM.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sigprobe-\(Int(Date().timeIntervalSince1970)).wav")
        do {
            try WAVWriter.write(pcm: lastPCM, sampleRate: 16000, to: url)
            log.append("WAV を書き出し: \(url.lastPathComponent)")
            return url
        } catch {
            log.append("WAV 書き出し失敗: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - WAV

enum WAVWriter {
    static func write(pcm: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let dataBytes = pcm.count * 2
        let byteRate = sampleRate * 2
        let riffSize = 36 + dataBytes

        func le32(_ v: Int) { data.appendLE32(v) }
        func le16(_ v: Int) { data.appendLE16(v) }

        data.append(contentsOf: Array("RIFF".utf8))
        le32(riffSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        le32(16)            // fmt チャンクサイズ
        le16(1)             // PCM
        le16(1)             // モノラル
        le32(sampleRate)
        le32(byteRate)
        le16(2)             // ブロックアライン
        le16(16)            // ビット深度
        data.append(contentsOf: Array("data".utf8))
        le32(dataBytes)

        for sample in pcm {
            let u = UInt16(bitPattern: sample)
            data.append(UInt8(u & 0xFF))
            data.append(UInt8((u >> 8) & 0xFF))
        }

        try data.write(to: url, options: .atomic)
    }
}
