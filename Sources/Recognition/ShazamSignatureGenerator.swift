//
//  ShazamSignatureGenerator.swift
//  SigProbe
//
//  Metrolist (Kotlin) 版 ShazamSignatureGenerator.kt の忠実な Swift 移植。
//  元をたどると vibra / SongRec の C++ 実装。
//
//  定数・ループ順序・打ち切り条件・truncation の挙動を Kotlin 版と一致させてある。
//  数値を 1 つでも変えると Shazam 側は「No match」しか返さなくなるため、
//  このファイルは検証が済むまで安易に整理しないこと。
//

import Foundation

// MARK: - Peak

struct FrequencyPeak {
    let fftPassNumber: Int
    let peakMagnitude: Int
    let correctedPeakFrequencyBin: Int
}

// MARK: - Generator

enum ShazamSignatureGenerator {

    static let sampleRate = 16_000
    static let fftSize = 2048
    static let fftOutputSize = fftSize / 2 + 1        // 1025
    static let maxPeaks = 255
    static let maxTimeSeconds = 12.0
    static let ringBufSize = 256
    static let hopSize = 128

    // FrequencyBand: 0 = 250-520Hz, 1 = 520-1450Hz, 2 = 1450-3500Hz, 3 = 3500-5500Hz
    static let band250_520 = 0
    static let band520_1450 = 1
    static let band1450_3500 = 2
    static let band3500_5500 = 3

    /// Hanning 窓: w[i] = 0.5 * (1 - cos(2π*(i+1)/2049)), i = 0..2047
    /// C++ 版 hanning.h の HANNIG_MATRIX と同値。
    static let hanning: [Double] = (0..<fftSize).map { i in
        0.5 * (1.0 - cos(2.0 * Double.pi * Double(i + 1) / 2049.0))
    }

    /// 生成結果。署名 URI に加えて、検証に使う中間情報も返す。
    struct Output {
        let signatureURI: String
        let rawBytes: Data
        let numSamples: Int
        let totalPeaks: Int
        let peaksPerBand: [Int]
        /// 署名が表す音声長 (ms)。API へ渡す samplems。
        var sampleDurationMs: Int { numSamples * 1000 / ShazamSignatureGenerator.sampleRate }
    }

    /// 16bit PCM (モノラル / 16kHz / リトルエンディアン) から署名を生成する。
    static func generate(pcm: [Int16], fft: FFTProcessor) -> Output {
        let state = State(fft: fft)
        return state.process(pcm)
    }

    // MARK: - State

    private final class State {

        private let fft: FFTProcessor

        /// 直近 2048 サンプルのリングバッファ
        private var samplesRing = [Double](repeating: 0,
                                           count: ShazamSignatureGenerator.fftSize)
        private var samplesPos = 0

        /// FFT 出力のリングバッファ (ringBufSize x fftOutputSize) をフラット配列で保持
        private var fftOutputs = [Double](
            repeating: 0,
            count: ShazamSignatureGenerator.ringBufSize * ShazamSignatureGenerator.fftOutputSize)
        private var fftPos = 0
        private var fftNumWritten = 0

        /// spread 済み FFT のリングバッファ
        private var spreadFfts = [Double](
            repeating: 0,
            count: ShazamSignatureGenerator.ringBufSize * ShazamSignatureGenerator.fftOutputSize)
        private var spreadPos = 0
        private var spreadNumWritten = 0

        private var numSamples = 0

        private var bandPeaks: [[FrequencyPeak]] = [[], [], [], []]
        private var totalPeaks = 0

        /// 作業用バッファ (毎フレーム確保しないよう使い回す)
        private var windowed = [Double](repeating: 0,
                                        count: ShazamSignatureGenerator.fftSize)
        private var spectrum = [Double](repeating: 0,
                                        count: ShazamSignatureGenerator.fftOutputSize)
        private var spread = [Double](repeating: 0,
                                      count: ShazamSignatureGenerator.fftOutputSize)

        init(fft: FFTProcessor) {
            self.fft = fft
        }

        @inline(__always)
        private func idx(_ ring: Int, _ bin: Int) -> Int {
            ring * ShazamSignatureGenerator.fftOutputSize + bin
        }

        @inline(__always)
        private func wrap(_ value: Int) -> Int {
            let r = value % ShazamSignatureGenerator.ringBufSize
            return r < 0 ? r + ShazamSignatureGenerator.ringBufSize : r
        }

        func process(_ pcm: [Int16]) -> Output {
            let hop = ShazamSignatureGenerator.hopSize
            var offset = 0

            while offset + hop <= pcm.count {
                // C++ 版と同じ打ち切り条件: 時間と本数の「両方」を満たしたら停止
                let elapsedSec = Double(numSamples) / Double(ShazamSignatureGenerator.sampleRate)
                if elapsedSec >= ShazamSignatureGenerator.maxTimeSeconds
                    && totalPeaks >= ShazamSignatureGenerator.maxPeaks {
                    break
                }

                numSamples += hop
                feedSamples(pcm, start: offset, count: hop)
                doFFT()
                doPeakSpreading()
                if spreadNumWritten >= 47 {
                    doPeakRecognition()
                }
                offset += hop
            }

            let raw = encodeSignature()
            let base64 = raw.base64EncodedString()

            return Output(
                signatureURI: "data:audio/vnd.shazam.sig;base64,\(base64)",
                rawBytes: raw,
                numSamples: numSamples,
                totalPeaks: totalPeaks,
                peaksPerBand: bandPeaks.map { $0.count }
            )
        }

        private func feedSamples(_ pcm: [Int16], start: Int, count: Int) {
            for k in start..<(start + count) {
                samplesRing[samplesPos] = Double(pcm[k])
                samplesPos = (samplesPos + 1) % ShazamSignatureGenerator.fftSize
            }
        }

        private func doFFT() {
            let n = ShazamSignatureGenerator.fftSize
            for i in 0..<n {
                windowed[i] = samplesRing[(samplesPos + i) % n] * ShazamSignatureGenerator.hanning[i]
            }

            fft.magnitudeSpectrum(windowed: windowed, into: &spectrum)

            let base = idx(fftPos, 0)
            for bin in 0..<ShazamSignatureGenerator.fftOutputSize {
                fftOutputs[base + bin] = spectrum[bin]
            }
            fftPos = (fftPos + 1) % ShazamSignatureGenerator.ringBufSize
            fftNumWritten += 1
        }

        private func doPeakSpreading() {
            let outSize = ShazamSignatureGenerator.fftOutputSize
            let lastFftIdx = wrap(fftPos - 1)
            let base = idx(lastFftIdx, 0)
            for bin in 0..<outSize {
                spread[bin] = fftOutputs[base + bin]
            }

            // 周波数方向: 3 点 running max (前方への in-place パス)
            if outSize >= 3 {
                for pos in 0..<(outSize - 2) {
                    spread[pos] = max(spread[pos], max(spread[pos + 1], spread[pos + 2]))
                }
            }

            // 時間方向: -1, -3, -6 フレーム前へ max を伝播させる。
            // 更新されるのは「過去のエントリ」だけで、今回のエントリには
            // 周波数方向の spreading しか適用されない (C++ 版と同じ)。
            for pos in 0..<outSize {
                var maxVal = spread[pos]
                for offset in [-1, -3, -6] {
                    let target = idx(wrap(spreadPos + offset), pos)
                    let oldVal = spreadFfts[target]
                    if oldVal > maxVal { maxVal = oldVal }
                    spreadFfts[target] = maxVal
                }
            }

            let writeBase = idx(spreadPos, 0)
            for bin in 0..<outSize {
                spreadFfts[writeBase + bin] = spread[bin]
            }
            spreadPos = (spreadPos + 1) % ShazamSignatureGenerator.ringBufSize
            spreadNumWritten += 1
        }

        private func doPeakRecognition() {
            let outSize = ShazamSignatureGenerator.fftOutputSize
            let fftMinus46 = idx(wrap(fftPos - 46), 0)
            let spreadMinus49 = idx(wrap(spreadPos - 49), 0)

            let otherOffsets = [-53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249]
            let neighborOffsets = [-10, -7, -4, -3, 1, 2, 5, 8]

            let floorValue = 1.0 / 64.0

            for binPos in 10..<(outSize - 8) {
                let fftVal = fftOutputs[fftMinus46 + binPos]
                if fftVal < floorValue { continue }
                if fftVal < spreadFfts[spreadMinus49 + binPos] { continue }

                // spreadMinus49 の 8 近傍
                var maxNeighborSpread49 = 0.0
                for neighborOffset in neighborOffsets {
                    let v = spreadFfts[spreadMinus49 + binPos + neighborOffset]
                    if v > maxNeighborSpread49 { maxNeighborSpread49 = v }
                }
                if fftVal <= maxNeighborSpread49 { continue }

                // 他 14 個の時間オフセット
                var maxNeighborOther = maxNeighborSpread49
                for otherOffset in otherOffsets {
                    let v = spreadFfts[idx(wrap(spreadPos + otherOffset), binPos - 1)]
                    if v > maxNeighborOther { maxNeighborOther = v }
                }
                if fftVal <= maxNeighborOther { continue }

                let fftNumber = spreadNumWritten - 46

                let peakMag = log(max(floorValue, fftVal)) * 1477.3 + 6144
                let peakMagBefore = log(max(floorValue, fftOutputs[fftMinus46 + binPos - 1])) * 1477.3 + 6144
                let peakMagAfter = log(max(floorValue, fftOutputs[fftMinus46 + binPos + 1])) * 1477.3 + 6144

                let peakVariation1 = peakMag * 2 - peakMagBefore - peakMagAfter
                let peakVariation2 = (peakMagAfter - peakMagBefore) * 32 / peakVariation1

                let correctedBin = Double(binPos) * 64.0 + peakVariation2
                // peakVariation1 == 0 の場合 correctedBin は NaN/Inf になりうる。
                // Kotlin では下の帯域判定が全て false になって continue するが、
                // Swift の Int(_:) は NaN で trap するためここで明示的に弾く。
                guard correctedBin.isFinite, peakMag.isFinite else { continue }

                let frequencyHz = correctedBin * (16000.0 / 2.0 / 1024.0 / 64.0)

                let band: Int
                if frequencyHz < 250.0 {
                    continue
                } else if frequencyHz < 520.0 {
                    band = ShazamSignatureGenerator.band250_520
                } else if frequencyHz < 1450.0 {
                    band = ShazamSignatureGenerator.band520_1450
                } else if frequencyHz < 3500.0 {
                    band = ShazamSignatureGenerator.band1450_3500
                } else if frequencyHz <= 5500.0 {
                    band = ShazamSignatureGenerator.band3500_5500
                } else {
                    continue
                }

                bandPeaks[band].append(
                    FrequencyPeak(
                        fftPassNumber: fftNumber,
                        peakMagnitude: Int(peakMag),                 // Kotlin toInt() と同じ 0 方向切り捨て
                        correctedPeakFrequencyBin: Int(correctedBin)
                    )
                )
                totalPeaks += 1
            }
        }

        // MARK: - Encoding

        private func encodeSignature() -> Data {
            var contents = Data()

            // バンド昇順 (Kotlin の std::map 相当の反復順)
            for bandId in 0...3 {
                let peaks = bandPeaks[bandId]
                if peaks.isEmpty { continue }

                var peakBuf = Data()
                var prevFftPassNumber = 0

                for peak in peaks {
                    let diff = peak.fftPassNumber - prevFftPassNumber
                    if diff >= 255 {
                        // 0xFF マーカー + 絶対位置
                        peakBuf.append(0xFF)
                        peakBuf.appendLE32(peak.fftPassNumber)
                        prevFftPassNumber = peak.fftPassNumber
                    }
                    peakBuf.append(UInt8((peak.fftPassNumber - prevFftPassNumber) & 0xFF))
                    peakBuf.appendLE16(peak.peakMagnitude)
                    peakBuf.appendLE16(peak.correctedPeakFrequencyBin)
                    prevFftPassNumber = peak.fftPassNumber
                }

                // バンドタグ: 0x60030040 + bandId
                contents.appendLE32(0x6003_0040 + bandId)
                contents.appendLE32(peakBuf.count)
                contents.append(peakBuf)

                // 4 バイト境界へパディング
                let padBytes = (4 - peakBuf.count % 4) % 4
                for _ in 0..<padBytes { contents.append(0) }
            }

            let sizeMinusHeader = contents.count + 8
            let samplesAndOffset = Int(Double(numSamples)
                                       + Double(ShazamSignatureGenerator.sampleRate) * 0.24)

            // 48 バイトヘッダ (全てリトルエンディアン)
            var header = Data()
            header.appendLE32(Int(Int32(bitPattern: 0xcafe_2580)))   // magic1
            header.appendLE32(0)                                     // crc32 (後で埋める)
            header.appendLE32(sizeMinusHeader)                       // size_minus_header
            header.appendLE32(Int(Int32(bitPattern: 0x9411_9c00)))   // magic2
            header.appendLE32(0)
            header.appendLE32(0)
            header.appendLE32(0)                                     // void1[3]
            header.appendLE32(3 << 27)                               // shifted_sample_rate_id
            header.appendLE32(0)
            header.appendLE32(0)                                     // void2[2]
            header.appendLE32(samplesAndOffset)                      // number_samples_plus_divided_sample_rate
            header.appendLE32((15 << 19) + 0x40000)                  // fixed_value

            var full = Data()
            full.append(header)
            full.appendLE32(0x4000_0000)
            full.appendLE32(contents.count + 8)
            full.append(contents)

            // CRC32 はオフセット 8 以降 (magic1 と crc32 フィールド自身を除く)
            let crc = CRC32.checksum(full.suffix(from: 8))
            full[4] = UInt8(crc & 0xFF)
            full[5] = UInt8((crc >> 8) & 0xFF)
            full[6] = UInt8((crc >> 16) & 0xFF)
            full[7] = UInt8((crc >> 24) & 0xFF)

            return full
        }
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendLE32(_ value: Int) {
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }

    mutating func appendLE16(_ value: Int) {
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
}
