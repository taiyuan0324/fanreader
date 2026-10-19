import SwiftUI
import UIKit

struct AppSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: ReadingSettings
    @EnvironmentObject private var tts: TTSSettings
    @Environment(\.dismiss) private var dismiss

    @State private var backupURL: URL?
    @State private var isRestoring = false
    @State private var showShare = false
    @State private var isScanning = false
    @State private var showLog = false
    @State private var logText = ""
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读外观") {
                    Picker("主题", selection: $settings.theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.name).tag(theme)
                        }
                    }
                    Toggle("显示页眉页脚", isOn: $settings.showHeaderFooter)
                }

                Section("排版") {
                    row(title: "字号", value: String(format: "%.0f", settings.fontSize))
                    Slider(value: $settings.fontSize, in: 12...32, step: 1)
                    row(title: "行高", value: String(format: "%.2f×", settings.lineHeightMultiple))
                    Slider(value: $settings.lineHeightMultiple, in: 1.1...2.4, step: 0.05)
                    row(title: "段间距", value: String(format: "%.0f", settings.paragraphSpacing))
                    Slider(value: $settings.paragraphSpacing, in: 0...24, step: 1)
                    row(title: "首行缩进", value: String(format: "%.1f 字", settings.firstLineIndent))
                    Slider(value: $settings.firstLineIndent, in: 0...3, step: 0.5)
                    row(title: "页边距", value: String(format: "%.0f", settings.margin))
                    Slider(value: $settings.margin, in: 8...44, step: 2)
                }

                Section {
                    Picker("引擎", selection: $tts.kind) {
                        ForEach(TTSProviderKind.allCases) { kind in
                            Text(kind.name).tag(kind)
                        }
                    }

                    Text(tts.kind.hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    engineFields

                    if tts.kind != .system {
                        Button {
                            Task { await tts.test() }
                        } label: {
                            Label("试听一句", systemImage: "waveform")
                        }
                        if let error = tts.lastError {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    row(title: "语速", value: String(format: "%.2f", settings.speechRate))
                    Slider(value: $settings.speechRate, in: 0.35...0.7, step: 0.05)
                    Toggle("读完自动翻页", isOn: $settings.autoTurnPageOnSpeech)
                } header: {
                    Text("语音合成")
                } footer: {
                    Text("密钥保存在系统钥匙串,只有本机可读。")
                }

                Section("数据") {
                    row(title: "书籍", value: "\(library.books.count)")

                    Button {
                        exportBackup()
                    } label: {
                        Label("导出备份", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isRestoring = true
                    } label: {
                        Label("从备份恢复", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        isScanning = true
                        Task {
                            let result = await library.scanLocalDocuments()
                            isScanning = false
                            isError = result.imported == 0 && result.failed > 0
                            message = "扫描完成:导入 \(result.imported) 本,失败 \(result.failed) 个"
                        }
                    } label: {
                        HStack {
                            Label("扫描「翻页」文件夹", systemImage: "folder.badge.plus")
                            if isScanning {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isScanning)

                    Button {
                        logText = ImportLog.read()
                        showLog = true
                    } label: {
                        Label("查看导入日志", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("关于") {
                    row(title: "版本", value: "0.3.0")
                    Text("全部代码为本项目原创实现。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showLog) {
                NavigationStack {
                    ScrollView {
                        Text(logText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("导入日志")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("清空") {
                                ImportLog.clear()
                                logText = "(已清空)"
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showLog = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let backupURL {
                    ShareSheet(items: [backupURL])
                }
            }
            .sheet(isPresented: $isRestoring) {
                DocumentPicker(onPick: { urls in
                    isRestoring = false
                    handleRestore(.success(urls))
                }, onCancel: {
                    isRestoring = false
                })
                .ignoresSafeArea()
            }
            .alert(isError ? "操作失败" : "完成", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("好", role: .cancel) { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }


    @ViewBuilder
    private var engineFields: some View {
            switch tts.kind {
            case .doubao:
                TextField("服务地址,如 http://主机IP:3456", text: $tts.doubaoBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                HStack {
                    Button {
                        Task { await tts.probeDoubao() }
                    } label: {
                        Label("检测连接", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Spacer()
                    Text(tts.doubaoStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if tts.doubaoSpeakers.isEmpty {
                    TextField("音色(如 温柔桃子)", text: $tts.doubaoSpeaker)
                        .textInputAutocapitalization(.never)
                } else {
                    Picker("音色", selection: $tts.doubaoSpeaker) {
                        ForEach(tts.doubaoSpeakers, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                }
                Text("填你自己的豆包 TTS 地址(局域网或公网均可)。该服务靠浏览器端合成,单句约 2–4 秒。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .system:
                Picker("音色", selection: $tts.systemVoice) {
                    Text("自动(优先高级/增强)").tag("")
                    ForEach(SystemVoiceCatalog.chineseVoices()) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
                Text("想更好听:系统设置 → 辅助功能 → 朗读内容 → 声音 → 中文,下载「高级/增强」音色后回到这里选择。完全离线、免费。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .edgeServer:
                TextField("服务地址,如 http://主机IP:3000", text: $tts.edgeServerBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("服务端 TOKEN(没设就留空)", text: $tts.edgeServerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button {
                        Task { await tts.probeEdgeServer() }
                    } label: {
                        Label("检测并拉取音色", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Spacer()
                    Text(tts.edgeServerStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if tts.edgeServerVoices.isEmpty {
                    TextField("音色(如 zh-CN-XiaoxiaoNeural)", text: $tts.edgeServerVoice)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Picker("音色", selection: $tts.edgeServerVoice) {
                        ForEach(tts.edgeServerVoices, id: \.self) { name in
                            Text(EdgeVoiceNames.friendly(name)).tag(name)
                        }
                    }
                }
                Text("服务端跑 edge-tts 库,微软的 v2 校验由 Python 侧处理,App 不再受 403 影响。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .azure:
                TextField("区域(如 eastasia)", text: $tts.azureRegion)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("语音(如 zh-CN-XiaoxiaoNeural)", text: $tts.azureVoice)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("订阅密钥", text: $tts.azureKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .openAICompatible:
                TextField("Base URL", text: $tts.openAIBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("模型(tts-1)", text: $tts.openAIModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("音色(alloy)", text: $tts.openAIVoice)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $tts.openAIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func exportBackup() {
        do {
            let url = try BackupService.shared.export()
            backupURL = url
            showShare = true
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func handleRestore(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try BackupService.shared.restore(from: url)
                library.reload()
                isError = false
                message = "已恢复 \(library.books.count) 本书"
            } catch {
                isError = true
                message = error.localizedDescription
            }
        case .failure(let error):
            isError = true
            message = error.localizedDescription
        }
    }
}

/// UIActivityViewController 包装,用于分享备份文件
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
