//
//  FFTProcessor.swift
//  SigProbe
//
//  2048 点実数 FFT のパワースペクトル計算。
//
//  出力は Kotlin 版 computeRfft と同じ定義:
//      magnitude[k] = max((re[k]^2 + im[k]^2) / 2^17, 1e-10)
//  ここで re/im は「標準的な DFT」の値 (FFTW3 の r2c 出力と同じスケール)。
//
//  実装が 2 つあるのは検証のため。
//   - .naive     : Kotlin 版の逐語移植。演算順序まで同じなので結果がビット一致しうる。
//                  Android 版と署名を突き合わせる際はこちらを使う。
//   - .accelerate: vDSP。実運用向け。20 倍前後速い。
//

import Foundation
import Accelerate

protocol FFTProcessor: AnyObject {
    /// windowed: 2048 要素。into: 1025 要素。
    func magnitudeSpectrum(windowed: [Double], into output: inout [Double])
    var displayName: String { get }
}

enum FFTKind: String, CaseIterable, Identifiable {
    case accelerate
    case naive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accelerate: return "vDSP (高速)"
        case .naive:      return "純Swift (Android照合用)"
        }
    }

    func make() -> FFTProcessor {
        switch self {
        case .accelerate: return AccelerateFFT()
        case .naive:      return NaiveFFT()
        }
    }
}

// MARK: - vDSP

final class AccelerateFFT: FFTProcessor {

    let displayName = "vDSP"

    private let n = 2048
    private let log2n: vDSP_Length = 11
    private let outputSize = 1025

    private let setup: FFTSetupD
    private var realp: [Double]
    private var imagp: [Double]

    init() {
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
        realp = [Double](repeating: 0, count: 1024)
        imagp = [Double](repeating: 0, count: 1024)
    }

    deinit {
        vDSP_destroy_fftsetupD(setup)
    }

    func magnitudeSpectrum(windowed: [Double], into output: inout [Double]) {
        precondition(windowed.count == n)
        precondition(output.count == outputSize)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)

                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPDoubleComplex.self, capacity: n / 2) { cp in
                        vDSP_ctozD(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }

                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // vDSP の実数 FFT 出力は標準 DFT の 2 倍にスケールされている。
                //   true_re = realp/2, true_im = imagp/2
                //   → (true_re^2 + true_im^2) / 2^17 = (realp^2 + imagp^2) / 2^19
                // さらに packed 形式のため realp[0] = 2*DC, imagp[0] = 2*Nyquist(bin 1024)。
                let scale = 1.0 / Double(1 << 19)
                let minVal = 1e-10

                let dc = rp[0]
                var m = dc * dc * scale
                output[0] = m < minVal ? minVal : m

                for k in 1..<1024 {
                    let re = rp[k]
                    let im = ip[k]
                    m = (re * re + im * im) * scale
                    output[k] = m < minVal ? minVal : m
                }

                let nyq = ip[0]
                m = nyq * nyq * scale
                output[1024] = m < minVal ? minVal : m
            }
        }
    }
}

// MARK: - Naive (Kotlin 逐語移植)

final class NaiveFFT: FFTProcessor {

    let displayName = "NaiveSwift"

    private let n = 2048
    private let outputSize = 1025

    private var re = [Double](repeating: 0, count: 2048)
    private var im = [Double](repeating: 0, count: 2048)

    func magnitudeSpectrum(windowed: [Double], into output: inout [Double]) {
        precondition(windowed.count == n)
        precondition(output.count == outputSize)

        for i in 0..<n {
            re[i] = windowed[i]
            im[i] = 0
        }

        // ビット反転並び替え
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }

        // Cooley-Tukey バタフライ (n = 2048 で 11 段)
        var len = 2
        while len <= n {
            let halfLen = len >> 1
            let ang = -Double.pi / Double(halfLen)      // = -2π / len
            let wBaseRe = cos(ang)
            let wBaseIm = sin(ang)
            var i = 0
            while i < n {
                var wRe = 1.0
                var wIm = 0.0
                for k in 0..<halfLen {
                    let u = i + k
                    let v = u + halfLen
                    let evenRe = re[u]
                    let evenIm = im[u]
                    let oddRe = re[v] * wRe - im[v] * wIm
                    let oddIm = re[v] * wIm + im[v] * wRe
                    re[u] = evenRe + oddRe
                    im[u] = evenIm + oddIm
                    re[v] = evenRe - oddRe
                    im[v] = evenIm - oddIm
                    let newWRe = wRe * wBaseRe - wIm * wBaseIm
                    wIm = wRe * wBaseIm + wIm * wBaseRe
                    wRe = newWRe
                }
                i += len
            }
            len <<= 1
        }

        let scaleFactor = 1.0 / Double(1 << 17)
        let minVal = 1e-10
        for idx in 0..<outputSize {
            let r = re[idx]
            let g = im[idx]
            let mag = (r * r + g * g) * scaleFactor
            output[idx] = mag < minVal ? minVal : mag
        }
    }
}
