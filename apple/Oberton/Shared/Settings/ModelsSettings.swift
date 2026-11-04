import ObertonCore
import SwiftUI

// MARK: - B // Models & AI

/// Settings › Models (ModelsPage.xaml): every model Oberton can use, as rows with what each is for, whether it is
/// downloaded, active and loaded, and a Download or Use button. Speech recognition, local AI cleanup (Apple
/// Intelligence, then Windows' curated Ollama models), Extended Notes' model, cloud AI and the Read aloud voice.
struct ModelsSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigator
    @Environment(\.ob) private var ob
    /// The direct download's own runtime, downloading in the background or from the runtime row.
    @ObservedObject private var localAI = LocalAISetup.shared
    /// The Ollama models installed and loaded now (nil while checking), and whether the runtime answers.
    @State private var installed: [String]?
    @State private var loaded: [String] = []
    @State private var runtimeUp = false
    /// Extended Notes' "best on this Mac", for the explanation under its menu.
    @State private var notesInstalled: [NotesModels.Installed] = []
    /// The download running now (an Ollama model, or `runtimeID` for the runtime itself) and how far it got.
    @State private var download: (id: String, fraction: Double?)?
    @State private var downloadTask: Task<Void, Never>?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Caption("Download the models you want and choose which one is active. Local models run on this \(Device.noun); downloading is the only time they use the internet.")
            heading("Speech recognition", top: 18)
            // Each Windows row card has 8 below it, the last one too.
            SpeechModelList().padding(.bottom, 8)
            HStack {
                Readout("AI cleanup · on this \(Device.noun)")
                Spacer()
                #if os(macOS)
                Button("Refresh") { Task { await rebuild() } }.buttonStyle(CapsuleButtonStyle(kind: .quiet, padding: 10))
                #endif
            }
            .padding(.top, 22).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 8) {
                // The Mac's own on-device model, beside Windows' list.
                ModelRow(name: "Apple Intelligence", badges: appleBadges,
                         detail: AppleIntelligenceBackend.unavailableReason ?? "Apple's on-device model. Nothing to install; nothing leaves this \(Device.noun).",
                         action: isDefault(.appleOnDevice) ? nil : ("Use this", { use(.appleOnDevice) }), primary: true)
                #if os(macOS)
                localRows
                #endif
            }
            .padding(.bottom, 8)
            // Windows' second sentence is about a PC's graphics card ("With 6 GB of GPU memory, 3–4B models run fully on the
            // GPU…"); a Mac's GPU shares its memory, so only the first one holds here.
            Caption("The active model is the default for profiles that don't pick their own.", bottom: 0).padding(.top, 2)
            heading("Extended notes · AI", top: 22)
            NotesModelMenu(width: 528)
            Caption(notesExplanation, bottom: 0).padding(.top, 6)
            heading("AI cleanup · cloud", top: 22)
            Caption(model.settings.cloud.keepOffline
                        ? "\"Keep everything offline\" is on, so cloud models are blocked. Change that and add keys under Settings › Cloud AI."
                        : "Text you dictate with a profile set to one of these is sent to that service. Keys are set under Settings › Cloud AI.",
                    bottom: 8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CloudCatalog.anthropic) { m in cloudRow(m.id, name: m.title, detail: "Anthropic · " + m.blurb) }
                let openai = ModelID(provider: .openai, name: model.settings.cloud.openAIModel)
                cloudRow(openai, name: openai.name, detail: "OpenAI-compatible · From \(model.settings.cloud.openAIBaseURL)")
            }
            .padding(.bottom, 8)
            heading("Read aloud voice", top: 22)
            // As on Windows, the other rows' buttons stay usable while a download runs (a second download waits its turn).
            ReadAloudVoiceRows(busy: false).padding(.bottom, 8)
            #if os(macOS)
            advanced.padding(.top, 24)
            #endif
        }
        #if os(macOS)
        .task { await rebuild() }
        // Windows cancels the page's download when the page goes (Unloaded); the runtime's own setup carries on.
        .onDisappear { downloadTask?.cancel() }
        #else
        .task { await loadNotesModels() }
        #endif
        .alert("Oberton", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") {}
        } message: { Text(failure ?? "") }
        .dialogLook(.warning, shown: failure != nil)
    }

    private func heading(_ text: String, top: CGFloat) -> some View {
        Readout(text).padding(.top, top).padding(.bottom, 8)
    }

    /// One download at a time on the page: another Download waits (Windows' `if (Busy) return;`). Windows leaves the
    /// other rows' buttons as they were when the download began, so they look and stay usable; Use this still works.
    private var busy: Bool { download != nil || model.whisperDownload != nil || localAI.isRunning }

    /// The active model, matched as Windows does (`string.Equals(…, OrdinalIgnoreCase)`).
    private func isDefault(_ id: ModelID) -> Bool {
        let d = model.settings.defaultModel
        return d.provider == id.provider && d.name.caseInsensitiveCompare(id.name) == .orderedSame
    }

    /// NotesModelChoices.Explain, with the Mac's GPU (the share of memory Metal may use) for the PC's graphics card.
    private var notesExplanation: String {
        let gpu = NotesRecorder.gpuBytes, ram = LocalModel.systemRam
        let best = NotesModels.pickBest(notesInstalled, gpuBytes: gpu, ramBytes: ram)?.name
        return "Extended Notes formats and sums up long sessions in the background, so it can use a bigger model than " +
            "dictation needs. Best on this \(Device.noun) is the largest installed model that " +
            (gpu.map { "fits in the GPU's memory (\(NotesModels.gb($0)) here)" }
                ?? "runs well without a GPU (up to \(String(format: "%g", NotesModels.maxBillionsWithoutGpu))B)") +
            (best.map { ": \($0)." } ?? ".") +
            " A mixture-of-experts model such as Qwen3 30B-A3B counts too when it fits in this \(Device.noun)'s memory (\(NotesModels.gb(ram))): " +
            "only about 3B of its 30B parameters work on each word, so it runs from memory, with as much of it on the GPU as there is room for. " +
            "It is much better at formatting and summing up, at the cost of speed: a step takes it tens of seconds, which notes have time for. " +
            "A cloud model would send the whole transcript to that service."
    }

    private func loadNotesModels() async {
        guard let url = try? OllamaBackend.validated(model.settings.ollamaEndpoint) else { notesInstalled = []; return }
        notesInstalled = await OllamaBackend.installedDetails(endpoint: url)
    }

    private var appleBadges: [(String, Badge.Kind)] {
        (isDefault(.appleOnDevice) ? [("Active", .active)] : []) + [AppleIntelligenceBackend.unavailableReason == nil ? ("Ready", .ok) : ("Unavailable", .outline)]
    }

    // MARK: Local models (Ollama)

    #if os(macOS)
    @ViewBuilder private var localRows: some View {
        if let installed {
            // Windows puts this first whenever nothing is listed, with the AI status line after it.
            if OllamaRuntime.canManage && !OllamaRuntime.isInstalled && !runtimeUp {
                runtimeRow
            } else if installed.isEmpty {
                Caption("The local AI runtime isn't answering, so downloaded models can't be listed. " +
                        (OllamaRuntime.canManage ? model.aiStatus
                            : "Install Ollama from ollama.com and start it; the models here then download through it."))
            }
            ForEach(catalogue(installed), id: \.id) { m in localRow(m, installed: installed) }
        } else {
            Caption("Checking…")
        }
    }

    private func localRow(_ m: LocalCatalogModel, installed: [String]) -> ModelRow {
        let downloaded = installed.contains { LocalCatalog.same($0, m.id) }
        let id = ModelID(provider: .ollama, name: m.id)
        let active = model.settings.defaultModel.provider == .ollama && LocalCatalog.same(model.settings.defaultModel.name, m.id)
        let fetching = download?.id == m.id
        var badges: [(String, Badge.Kind)] = active ? [("Active", .active)] : []
        if loaded.contains(where: { LocalCatalog.same($0, m.id) }) { badges.append(("Loaded", .ok)) }
        badges.append(downloaded ? ("Downloaded", .plain) : ("Not downloaded", .outline))
        let detail = (m.size.isEmpty ? m.description : "\(m.description) · \(m.size)") + LocalCatalog.ramWarning(m, downloaded: downloaded)
        let action: (String, () -> Void)?
        if fetching { action = ("Cancel", { downloadTask?.cancel() }) }
        else if !downloaded { action = ("Download", { pull(m.id) }) }
        else if active { action = nil }
        else { action = ("Use this", { use(id) }) }
        let fraction: Double?? = fetching ? .some(download?.fraction) : nil
        return ModelRow(name: m.name, badges: badges, detail: detail, action: action, progress: fraction,
                        primary: downloaded && !fetching)
    }

    /// Windows' list, then what else Ollama has ("Installed on this Mac.").
    private func catalogue(_ installed: [String]) -> [LocalCatalogModel] {
        LocalCatalog.all + installed.filter { name in !LocalCatalog.all.contains { LocalCatalog.same(name, $0.id) } }
            .map { LocalCatalogModel(id: $0, name: $0, description: "Installed on this \(Device.noun).", size: "") }
    }

    /// The direct download without its runtime yet (Windows bundles one; here setup's background download or this row
    /// fetches it). The App Store version can't run a downloaded program; there the user installs Ollama.
    private var runtimeRow: some View {
        let fetching = localAI.isRunning
        return ModelRow(name: "Ollama (local AI runtime)", badges: [("Not downloaded", .outline)],
                        detail: "Runs the local models on this \(Device.noun), only for Oberton. Downloads Ollama \(OllamaRuntime.version) (about 190 MB), then \(LocalCatalog.all[0].name), the default model (\(LocalCatalog.all[0].size)).",
                        action: fetching ? ("Cancel", { localAI.cancel() }) : ("Download", { installRuntime() }),
                        progress: fetching ? .some(localAI.progress ?? nil) : nil)
    }

    private func rebuild() async {
        guard let endpoint = try? OllamaBackend.validated(model.settings.ollamaEndpoint) else { installed = []; return }
        // Starts Oberton's own runtime if it is installed and nothing answers (Windows lists through EnsureRunning).
        runtimeUp = (try? await OllamaRuntime.ensureRunning(settings: model.settings)) != nil
        installed = runtimeUp ? await OllamaBackend.installedModels(endpoint: endpoint) : []
        loaded = runtimeUp ? await OllamaBackend.loadedModels(endpoint: endpoint) : []
        await model.refreshOllama()
        await loadNotesModels()
    }

    /// Download a model through Ollama, with its progress on the row and Cancel (Windows' DownloadLocalAsync).
    private func pull(_ name: String) {
        run(name) {
            try await OllamaRuntime.ensureRunning(settings: model.settings)
            let endpoint = try OllamaBackend.validated(model.settings.ollamaEndpoint)
            try await OllamaBackend.pull(endpoint: endpoint, model: name) { f in Task { @MainActor in progress(name, f) } }
        }
    }

    /// Install Oberton's own runtime, start it, and download the default model, as Windows' setup does.
    private func installRuntime() {
        guard !busy else { return }
        localAI.start(model) { error in
            failure = (error as? UserFacingError)?.message ?? "The download failed. See the log for details."
            if !(error is UserFacingError) { Log.error("Model download failed: \(error)") }
            Task { await rebuild() }
        }
    }

    private func progress(_ id: String, _ f: Double?) { if download?.id == id { download = (id, f) } }

    private func run(_ id: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        download = (id, nil)
        downloadTask = Task {
            do { try await work() } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch let e as UserFacingError {
                failure = e.message
            } catch {
                Log.error("Model download failed: \(error)")
                failure = "The download failed. See the log for details."
            }
            download = nil
            downloadTask = nil
            await rebuild()
        }
    }
    #endif

    /// Make a model the active one and load it now (Windows' UseAiAsync: save, rebuild, warm up, rebuild). The warm-up's
    /// lines go to the status line only (`settings.didSet` → `warmUpAI`), as on Windows.
    private func use(_ id: ModelID) {
        model.settings.defaultModel = id
        let settings = model.settings
        Task {
            #if os(macOS)
            await rebuild()
            #endif
            await AIStatus.warmUp(id, settings: settings) { _, _ in }
            #if os(macOS)
            await rebuild()
            #endif
        }
    }

    // MARK: Cloud

    private func cloudRow(_ id: ModelID, name: String, detail: String) -> some View {
        let hasKey = KeyStore.get(id.provider) != nil
        var badges: [(String, Badge.Kind)] = [("Cloud", .cloud)]
        if isDefault(id) { badges.append(("Active", .active)) }
        badges.append(hasKey ? ("Key set", .plain) : ("No key", .outline))
        if model.settings.cloud.keepOffline { badges.append(("Blocked · offline", .outline)) }
        let action: (String, () -> Void)? = !hasKey ? ("Add key", { nav.goSettings(.cloud) }) : isDefault(id) ? nil : ("Use this", { use(id) })
        return ModelRow(name: name, badges: badges, detail: detail, action: action, primary: hasKey)
    }

    private static var system: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    // MARK: Advanced

    #if os(macOS)
    @State private var showAdvanced = false

    private var advanced: some View {
        DisclosureGroup("Advanced: local AI runtime", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 0) {
                FieldLabel("Runtime endpoint")
                CommitField(value: Binding(get: { model.settings.ollamaEndpoint }, set: { new in
                    // Checked when the address is done, not on every keystroke (a half-typed address isn't local yet).
                    model.settings.ollamaEndpoint = new
                    model.settings.enforceLocalEndpoint()
                }), width: 300)
                Caption("Must be a local address (127.0.0.1 / localhost); other addresses are rejected.", bottom: 0).padding(.top, 4)
                if OllamaRuntime.canManage {
                    Toggle("Start the bundled Ollama automatically", isOn: $model.settings.startOllama)
                        .toggleStyle(.checkbox).font(Ob.sans(Ob.body)).padding(.top, 10)
                }
                FieldLabel("Give up after (seconds)")
                // Windows binds an int: any whole number is taken (0 and below too, which then means the 10 s floor);
                // anything else is refused with a red border and the setting stays.
                CommitField(value: Binding(get: { String(Int(model.settings.aiTimeoutSeconds)) },
                                           set: { if let v = Int($0.trimmingCharacters(in: .whitespaces)) { model.settings.aiTimeoutSeconds = Double(v) } }),
                            width: 100, isValid: { Int($0.trimmingCharacters(in: .whitespaces)) != nil })
            }
            .padding(.top, 8)
        }
        .font(Ob.sans(Ob.body))
        .tint(ob.ink)
    }
    #endif
}

/// A model as a row in a hairline box: its name in mono with badges (wrapping), a line about it, and one button at the
/// right: Use this filled, Download, Cancel and Add key quiet (ModelsPage.Row).
struct ModelRow: View {
    var name: String
    var badges: [(String, Badge.Kind)]
    var detail: String
    var action: (String, () -> Void)? = nil
    /// Downloading: the fraction done (nil inside while unknown), as a thin bar under the line.
    var progress: Double?? = nil
    /// The button is "Use this" (filled); otherwise a quiet one.
    var primary = false
    var enabled = true
    @Environment(\.ob) private var ob

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                BadgeFlow(spacing: 6) {
                    Text(name).font(Ob.mono(13.5, .bold)).padding(.trailing, 4)
                    ForEach(Array(badges.enumerated()), id: \.offset) { _, b in Badge(text: b.0, kind: b.1) }
                }
                Text(detail).font(Ob.sans(12)).foregroundStyle(ob.muted).fixedSize(horizontal: false, vertical: true)
                if let progress { ProgressBar(fraction: progress).frame(height: 4).padding(.top, 8) }
            }
            Spacer(minLength: 0)
            if let action {
                if primary && action.0 == "Use this" {
                    Button(action.0, action: action.1).buttonStyle(.primary).disabled(!enabled)
                } else {
                    Button(action.0, action: action.1).buttonStyle(.quiet).disabled(!enabled)
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 14))
        .overlay(Rectangle().strokeBorder(ob.divider, lineWidth: 1))
    }
}

/// Lays its children out left to right and wraps them onto new lines (a WPF WrapPanel).
private struct BadgeFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * 2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + 2
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + size.width
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}
