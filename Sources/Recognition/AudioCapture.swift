//
//  AudioCapture.swift
//  SigProbe
//
//  マイクから録音し、16kHz / モノラル / 16bit PCM へ変換する。
//
//  Android 版は 44.1kHz で録って線形補間で 16kHz に落としていたが、
//  それだとアンチエイリアスが無く 8kHz 超の成分が折り返して
//  3500-5500Hz バンドの指紋を汚す。
//  AVAudioConverter は内部でローパスを掛けるため、この問題は起きない。
//
//  AVAudioSession は .measurement モードを使う。
//  これが Android の AudioSource.UNPROCESSED に相当し、
//  AGC / ノイズ抑制 / エコーキャンセルを無効化する。音楽認識では必須。
//

import Foundation
import AVFoundation

enum AudioCaptureError: LocalizedError {
    case permissionDenied
    case formatUnavailable
    case converterUnavailable
    case engineFailed(String)
    case noSamples

    var errorDescription: String? {
        switch self {
        case .permissionDenied:      return "マイクの使用が許可されていません"
        case .formatUnavailable:     return "オーディオフォーマットを構成できません"
        case .converterUnavailable:  return "サンプルレート変換器を作成できません"
        case .engineFailed(let m):   return "オーディオエンジンの起動に失敗: \(m)"
        case .noSamples:             return "録音データが空です"
        }
    }
}

final class AudioCapture {

    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var collected: [Int16] = []

    // MARK: - 権限

    static func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    static var hasPermission: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            return AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    // MARK: - 録音

    /// duration 秒ぶんの 16kHz / モノラル / Int16 PCM を返す。
    /// - Parameter onProgress: 0.0 - 1.0 の進捗 (メインスレッドでは呼ばれない)
    func record(duration: TimeInterval,
                onProgress: @escaping (Double) -> Void) async throws -> [Int16] {

        guard Self.hasPermission else { throw AudioCaptureError.permissionDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true, options: [])
        defer { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.formatUnavailable
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: true) else {
            throw AudioCaptureError.formatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.downmix = true

        let targetSampleCount = Int(Self.targetSampleRate * duration)

        lock.lock()
        collected.removeAll(keepingCapacity: true)
        collected.reserveCapacity(targetSampleCount + 4096)
        lock.unlock()

        return try await withCheckedThrowingContinuation { continuation in
            var finished = false
            let finish: (Result<[Int16], Error>) -> Void = { [weak self] result in
                guard let self else { return }
                self.lock.lock()
                if finished { self.lock.unlock(); return }
                finished = true
                self.lock.unlock()

                inputNode.removeTap(onBus: 0)
                self.engine.stop()
                continuation.resume(with: result)
            }

            inputNode.installTap(onBus: 0,
                                 bufferSize: 4096,
                                 format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }

                let converted = self.convert(buffer: buffer,
                                             using: converter,
                                             outputFormat: outputFormat)
                guard !converted.isEmpty else { return }

                self.lock.lock()
                self.collected.append(contentsOf: converted)
                let count = self.collected.count
                self.lock.unlock()

                onProgress(min(1.0, Double(count) / Double(targetSampleCount)))

                if count >= targetSampleCount {
                    self.lock.lock()
                    let samples = Array(self.collected.prefix(targetSampleCount))
                    self.lock.unlock()
                    finish(.success(samples))
                }
            }

            engine.prepare()
            do {
                try engine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                continuation.resume(throwing: AudioCaptureError.engineFailed(error.localizedDescription))
                return
            }

            // 保険。マイクが無音でもタップは回るはずだが、
            // 何らかの理由で目標サンプル数に届かない場合に備える。
            DispatchQueue.global().asyncAfter(deadline: .now() + duration + 3.0) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let samples = self.collected
                self.lock.unlock()
                if samples.isEmpty {
                    finish(.failure(AudioCaptureError.noSamples))
                } else {
                    finish(.success(samples))
                }
            }
        }
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - 変換

    private func convert(buffer: AVAudioPCMBuffer,
                         using converter: AVAudioConverter,
                         outputFormat: AVAudioFormat) -> [Int16] {

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                               frameCapacity: capacity) else { return [] }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)

        guard status != .error, error == nil, outBuffer.frameLength > 0,
              let channel = outBuffer.int16ChannelData else { return [] }

        let count = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
