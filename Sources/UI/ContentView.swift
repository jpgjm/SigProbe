//
//  ContentView.swift
//  SigProbe
//

import SwiftUI
import UIKit

/// 同一ビューに .sheet を複数積むと iOS のバージョンによって不安定になるため、
/// 一本の .sheet(item:) に集約する。
/// (@MainActor 付きの型の内側に置くと Identifiable 準拠が隔離違反になるため外に出す)
enum SheetRoute: Identifiable {
    case settings
    case signature
    case rawResponse
    case log
    case shareWAV(URL)

    var id: String {
        switch self {
        case .settings:            return "settings"
        case .signature:           return "signature"
        case .rawResponse:         return "rawResponse"
        case .log:                 return "log"
        case .shareWAV(let url):   return "share:\(url.path)"
        }
    }
}

@MainActor
struct ContentView: View {

    @StateObject private var recognizer = MusicRecognizer()
    @State private var route: SheetRoute?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    statusSection
                    actionButton

                    if case .success(let result) = recognizer.status {
                        resultCard(result)
                    }

                    diagnosticsSection
                }
                .padding()
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("SigProbe")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        route = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(item: $route) { destination in
                switch destination {
                case .settings:
                    SettingsView(recognizer: recognizer)
                case .signature:
                    TextDumpView(title: "署名",
                                 header: recognizer.lastSignatureInfo,
                                 body: recognizer.lastSignature ?? "")
                case .rawResponse:
                    TextDumpView(title: "生レスポンス",
                                 header: recognizer.lastEndpoint.map {
                                     "エンドポイント : \($0.label)"
                                 },
                                 body: recognizer.lastRawResponse ?? "")
                case .log:
                    LogView(log: recognizer.log)
                case .shareWAV(let url):
                    ActivityView(items: [url])
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - ステータス

    private var statusSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                    .frame(width: 180, height: 180)

                if case .listening(let progress) = recognizer.status {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 180, height: 180)
                        .animation(.linear(duration: 0.2), value: progress)
                }

                Image(systemName: iconName)
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(recognizer.status.isBusy ? .accentColor : .secondary)
            }

            Text(recognizer.status.label)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }

    private var iconName: String {
        switch recognizer.status {
        case .ready:      return "waveform"
        case .listening:  return "mic.fill"
        case .processing: return "waveform.path.ecg"
        case .querying:   return "antenna.radiowaves.left.and.right"
        case .success:    return "checkmark.circle"
        case .noMatch:    return "questionmark.circle"
        case .error:      return "exclamationmark.triangle"
        }
    }

    // MARK: - ボタン

    private var actionButton: some View {
        Group {
            if recognizer.status.isBusy {
                Button(role: .destructive) {
                    recognizer.cancel()
                } label: {
                    Text("中止")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    recognizer.start()
                } label: {
                    Label("認識する", systemImage: "mic")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 結果

    private func resultCard(_ result: RecognitionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let urlString = result.coverArtHqURL ?? result.coverArtURL,
                   let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.secondary.opacity(0.15)
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.title3).bold()
                    Text(result.artist)
                        .font(.body)
                        .foregroundColor(.secondary)
                    if let album = result.album {
                        Text(album).font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Divider()

            infoRow("ジャンル", result.genre)
            infoRow("リリース", result.releaseDate)
            infoRow("レーベル", result.label)
            infoRow("ISRC", result.isrc)
            infoRow("YouTube ID", result.youtubeVideoId)
            infoRow("Shazam ID", result.trackId)

            if let urlString = result.shazamURL, let url = URL(string: urlString) {
                Link("Shazam で開く", destination: url).font(.callout)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 92, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 診断

    private var diagnosticsSection: some View {
        VStack(spacing: 0) {
            diagnosticRow("署名を見る", "waveform.badge.magnifyingglass",
                          enabled: recognizer.lastSignature != nil) {
                route = .signature
            }
            Divider()
            diagnosticRow("生レスポンスを見る", "curlybraces",
                          enabled: recognizer.lastRawResponse != nil) {
                route = .rawResponse
            }
            Divider()
            diagnosticRow("録音を WAV で書き出す", "square.and.arrow.up",
                          enabled: !recognizer.lastPCM.isEmpty) {
                if let url = recognizer.exportWAV() {
                    route = .shareWAV(url)
                }
            }
            Divider()
            diagnosticRow("ログ", "doc.plaintext", enabled: true) {
                route = .log
            }
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func diagnosticRow(_ title: String,
                               _ icon: String,
                               enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 24)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

// MARK: - 設定

@MainActor
struct SettingsView: View {
    @ObservedObject var recognizer: MusicRecognizer
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("API エンドポイント"),
                        footer: Text(endpointFooter)) {
                    Picker("エンドポイント", selection: Binding(
                        get: { recognizer.endpoint },
                        set: { recognizer.endpoint = $0 }
                    )) {
                        ForEach(ShazamEndpoint.allCases) { ep in
                            Text(ep.label).tag(ep)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if recognizer.endpoint == .v2 {
                    Section(header: Text("v2 採取ファイル"),
                            footer: Text(captureFooter)) {
                        let status = ShazamV2Backend.captureStatus()
                        captureRow("key.json", status.keyExists)
                        captureRow("last-request.json", status.lastRequestExists)
                        if let ts = status.timestamp {
                            HStack {
                                Text("timestamp").font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Text(ts).font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if recognizer.endpoint == .v2direct {
                    Section(header: Text("v2direct 採取ファイル"),
                            footer: Text(bearerFooter)) {
                        let status = ShazamV2Backend.bearerStatus()
                        captureRow("shazam-auth.json", status.exists)
                        if let exp = status.expiry {
                            HStack {
                                Text("JWT exp").font(.caption).foregroundColor(.secondary)
                                Spacer()
                                Text(bearerExpiryText(exp))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(exp < Date() ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    Section(header: Text("deviceId 方式"),
                            footer: Text(recognizer.deviceIdMode.note
                                         + "\n\nURL …/iphone/<deviceId>/<requestId> の1つ目。サーバは検証しないため認識の成否・精度には影響しない。requestId は毎回自動で新規生成。")) {
                        Picker("deviceId 方式", selection: Binding(
                            get: { recognizer.deviceIdMode },
                            set: { recognizer.deviceIdMode = $0 }
                        )) {
                            ForEach(DeviceIdMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()

                        HStack {
                            Text("現在値").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(DeviceIdProvider.deviceId(for: recognizer.deviceIdMode))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }

                        if recognizer.deviceIdMode == .persistentRandom {
                            Button("保存した deviceId を作り直す") {
                                DeviceIdProvider.resetPersistentRandom()
                                // 再生成を促すため画面を更新
                                recognizer.deviceIdMode = .persistentRandom
                            }
                            .font(.caption)
                        }
                    }
                }

                Section(header: Text("FFT 実装"),
                        footer: Text("Android 版と署名を突き合わせて検証するときは「純Swift」を選ぶ。演算順序まで Kotlin 版と同じため、同じ PCM から同じ結果が出るはず。通常の利用では vDSP が速い。")) {
                    Picker("実装", selection: Binding(
                        get: { recognizer.fftKind },
                        set: { recognizer.fftKind = $0 }
                    )) {
                        ForEach(FFTKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(header: Text("録音時間"),
                        footer: Text("Shazam のアルゴリズムは 12 秒を上限として設計されている。短くすると認識率が落ちる。")) {
                    HStack {
                        Text("\(String(format: "%.0f", recognizer.recordSeconds)) 秒")
                            .frame(width: 60, alignment: .leading)
                        Slider(value: $recognizer.recordSeconds, in: 4...12, step: 1)
                    }
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func captureRow(_ name: String, _ exists: Bool) -> some View {
        HStack {
            Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(exists ? .green : .secondary)
            Text(name).font(.system(.callout, design: .monospaced))
            Spacer()
            Text(exists ? "あり" : "なし").font(.caption).foregroundColor(.secondary)
        }
    }

    private var captureFooter: String {
        """
        実機の Shazam を LSPatch でフックして採取した key.json と last-request.json を、\
        ファイル App の「このiPhone内 → SigProbe」に置く。値・URL・ヘッダはハードコードせず、\
        このファイルから読む。署名は短命なので、401 が出たら採り直す。
        """
    }

    private var bearerFooter: String {
        """
        実機 iOS Shazam の match/v2 が使う Authorization(約30日の JWT)を ShazamSigCapture で採取し、\
        その shazam-auth.json をファイル App の「このiPhone内 → SigProbe」に置く。\
        Apple 署名も apiToken 交換も不要。exp を過ぎたら採り直す。
        """
    }

    private func bearerExpiryText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        if date < Date() { return "\(f.string(from: date)) (失効)" }
        let days = Int(date.timeIntervalSinceNow / 86400)
        return "\(f.string(from: date)) (あと\(days)日)"
    }

    private var endpointFooter: String {
        """
        \(recognizer.endpoint.note)

        指紋の生成処理は両者で完全に同じ。違うのは送信先とレスポンス構造だけなので、\
        「指紋は正しいのに一致しない」のか「エンドポイント側の問題」なのかを切り分けられる。
        """
    }
}

// MARK: - テキストダンプ

struct TextDumpView: View {
    let title: String
    let header: String?
    let body_: String
    @Environment(\.presentationMode) private var presentationMode
    @State private var showingShare = false

    init(title: String, header: String?, body: String) {
        self.title = title
        self.header = header
        self.body_ = body
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let header {
                        Text(header)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(body_)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showingShare) {
                ActivityView(items: [fullText])
            }
        }
        .navigationViewStyle(.stack)
    }

    private var fullText: String {
        if let header { return header + "\n\n" + body_ }
        return body_
    }
}

// MARK: - ログ

@MainActor
struct LogView: View {
    @ObservedObject var log: LogStore
    @Environment(\.presentationMode) private var presentationMode
    @State private var showingShare = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(log.entries) { entry in
                        Text(log.formatted(entry))
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("ログ")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("閉じる") { presentationMode.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button {
                            showingShare = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            log.clear()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingShare) {
                ActivityView(items: [log.plainText])
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 共有シート

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
