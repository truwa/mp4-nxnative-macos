import SwiftUI
import AppKit

/// The settings window behind the gear: picture, build folder, saves, keys, game data, diagnostics, version.
struct SettingsWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var folderSize: Int64?
    @State private var backupNote: String?

    var body: some View {
        TabView {
            gameTab.tabItem { Label("Game", systemImage: "display") }
            controlsTab.tabItem { Label("Controls", systemImage: "gamecontroller") }
            advancedTab.tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
            dataTab.tabItem { Label("Data", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 640)
    }

    private var s: AppSettings { model.settings }
    private var applies: some View {
        Text(model.play.isRunning ? "The game is running: changes take effect the next time it starts." : "Changes take effect the next time the game starts.")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.bottom, 8)
    }

    // MARK: Game

    private var gameTab: some View {
        @Bindable var s = model.settings
        return VStack(spacing: 0) {
            Form {
                Section("Picture") {
                    Row("Resolution", "900p is the game's own size; the other sizes are made from the game's own code, the scan visor included.") {
                        Picker("", selection: $s.resolution) {
                            ForEach(s.resolutionOptions, id: \.size) { o in Text(o.label).tag(o.size) }
                        }.labelsHidden().fixedSize()
                    }
                    Row("Steady resolution", s.resolution == "native" ? "At 900p the game manages its own size." : "Keeps the chosen size instead of lowering it in busy scenes.") {
                        Toggle("", isOn: $s.opts.steadyRes).labelsHidden().toggleStyle(.switch)
                    }.disabled(s.resolution == "native")
                    // Frame rate (60 / 120 / 240 with the frame-rate packs): held back for a later release (user, 2026-11-09); the game runs at its own 60
                    // More detail at a distance (the Level of Detail pack): mod support is held back for a later release (user, 2026-11-09)
                    Row("Start in", "Fullscreen or a window; switch any time with the green button.") {
                        Picker("", selection: $s.opts.fullscreen) { Text("Window").tag(false); Text("Fullscreen").tag(true) }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    Row("Show overlay", "The render size and the frame rate in the top left corner of the picture.") {
                        Toggle("", isOn: $s.opts.showOverlay).labelsHidden().toggleStyle(.switch)
                    }
                }
                Section("Language") {
                    Row("Game language", "Text and voices, where the game has them.") {
                        Picker("", selection: $s.opts.language) { ForEach(GameOptions.languages, id: \.code) { Text($0.name).tag($0.code) } }
                            .labelsHidden().fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
            applies
        }
    }


    // MARK: Controls

    private var controlsTab: some View {
        @Bindable var s = model.settings
        return VStack(spacing: 0) {
            Form {
                Section {
                    Row("A and B", "By label: the button printed A acts as A. By position: as on a Switch (A on the right).") {
                        Picker("", selection: $s.opts.padAB) { Text("By label").tag("label"); Text("By position").tag("position") }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    Row("X and Y", "By label: the button printed X acts as X. By position: as on a Switch (X on top).") {
                        Picker("", selection: $s.opts.padXY) { Text("By label").tag("label"); Text("By position").tag("position") }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                } header: { Text("Button layout (Xbox and PlayStation controllers)") } footer: {
                    Text("Nintendo controllers always use their printed letters.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Feedback and motion") {
                    Row("Rumble", "Vibration on controllers that have it.") { Toggle("", isOn: $s.opts.rumble).labelsHidden().toggleStyle(.switch) }
                    Row("Gyro aiming", "Aim by moving the controller (DualSense, Switch Pro Controller).") { Toggle("", isOn: $s.opts.gyro).labelsHidden().toggleStyle(.switch) }
                }
                Section {
                    Label(model.controllerLine, systemImage: "gamecontroller").font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            applies
        }
    }

    // MARK: Advanced

    private var advancedTab: some View {
        @Bindable var s = model.settings
        return VStack(spacing: 0) {
            Form {
                Section {
                    Text("Most players never need these. Each is explained below it.").font(.callout).foregroundStyle(.secondary)
                }
                Section("Picture") {
                    Row("Fit", "Fit keeps the game's shape with black bars; Fill covers the window and crops the edges.") {
                        Picker("", selection: $s.opts.pictureFit) { Text("Fit").tag("fit"); Text("Fill").tag("fill") }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    Row("Brightness", String(format: "%.0f%%: 100%% is the picture as the game makes it.", s.opts.brightness * 100)) {
                        Slider(value: $s.opts.brightness, in: 0.5...1.5, step: 0.05).frame(width: 180)
                    }
                    Row("Console mode", "Handheld renders lighter, like a Switch out of its dock: can help a slower Mac.") {
                        Picker("", selection: $s.opts.console) { Text("Docked").tag("docked"); Text("Handheld").tag("handheld") }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    Row("Frame pacing", "Game: frames shown as the game times them (recommended). Display: one per display refresh.") {
                        Picker("", selection: $s.opts.pacing) { Text("Game").tag("game"); Text("Display").tag("display") }.labelsHidden().pickerStyle(.segmented).fixedSize()
                    }
                    Row("Apple's Metal HUD", "Apple's own overlay: frame rate, frame time and GPU memory, top right.") {
                        Toggle("", isOn: $s.metalHUD).labelsHidden().toggleStyle(.switch)
                    }
                }
                Section("Build") {
                    Row("Priority", "Normal uses the whole Mac. Low keeps the Mac responsive for other work; the shaders take about a third longer. While the game runs the build is always low. A running build switches within seconds (its shader step restarts under the new setting; finished shaders are kept).") {
                        Picker("", selection: $s.buildPriority) { Text("Normal").tag("normal"); Text("Low").tag("low") }.labelsHidden().pickerStyle(.segmented).fixedSize()
                            .onChange(of: s.buildPriority) { _, _ in model.updateBuildPriority() }
                    }
#if DEVELOPER
                    Row("Threads only", "Compiles the shaders in one process with threads instead of one worker process per core. About a third slower on an M4; for comparing build times (the next build or Continue).") {
                        Toggle("", isOn: $s.threadsOnly).labelsHidden().toggleStyle(.switch)
                    }.disabled(model.build.isRunning)
#endif
                }
                Section("Controls") {
                    Row("Rumble strength", String(format: "%.0f%%", s.opts.rumbleStrength * 100)) {
                        Slider(value: $s.opts.rumbleStrength, in: 0.2...2.0, step: 0.1).frame(width: 180)
                    }.disabled(!s.opts.rumble)
                    Row("Gyro sensitivity", String(format: "%.0f%%", s.opts.gyroGain * 100)) {
                        Slider(value: $s.opts.gyroGain, in: 0.25...3.0, step: 0.05).frame(width: 180)
                    }.disabled(!s.opts.gyro)
                    Row("Stick dead zone", s.opts.deadZone == 0 ? "Off: the sticks as macOS reports them." : "\(s.opts.deadZone)%: small movements are ignored (for a stick that drifts).") {
                        Slider(value: Binding(get: { Double(s.opts.deadZone) }, set: { s.opts.deadZone = Int($0) }), in: 0...30, step: 1).frame(width: 180)
                    }
                    Row("Several controllers as one", "Any connected controller (and the keyboard) controls the player.") {
                        Toggle("", isOn: $s.opts.mergeControllers).labelsHidden().toggleStyle(.switch)
                    }
                }
                Section("Sound and saves") {
                    Row("Mute", "No game sound (the Mac's volume does the same).") { Toggle("", isOn: $s.opts.mute).labelsHidden().toggleStyle(.switch) }
                    Row("Back up saves before each play", "Keeps the last 10 copies in the build folder (user-data/save-backups).") {
                        Toggle("", isOn: $s.opts.backupSaves).labelsHidden().toggleStyle(.switch)
                    }
                    Row("Record the shaders you meet", "Helps a later build put them first (quick start). Only shader names are recorded.") {
                        Toggle("", isOn: $s.opts.recordShaders).labelsHidden().toggleStyle(.switch)
                    }
                }
                Section {
                    Button("Reset these settings") { s.opts = GameOptions() }
                }
            }
            .formStyle(.grouped)
            applies
        }
    }

    // MARK: Data

    private var dataTab: some View {
        @Bindable var s = model.settings
        return Form {
            Section("Build folder") {
                LabeledContent("Location") {
                    Text(displayPath(s.rootURL.path) + (folderSize.map { " (\($0.bytesText))" } ?? "")).textSelection(.enabled)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([s.rootURL]) }
            }
            Section("Saves") {
                HStack {
                    Button("Open saves folder") { NSWorkspace.shared.open(s.savesURL) }
                        .disabled(!FileManager.default.fileExists(atPath: s.savesURL.path))
                    Button("Back up saves…") { backUp() }
                        .disabled(!FileManager.default.fileExists(atPath: s.savesURL.path))
                }
                if let backupNote { Text(backupNote).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Keys") {
                LabeledContent("prod.keys", value: s.keysPresent ? "Stored in the build folder" : "Not stored")
                Button("Forget the keys") {
                    if Panels.confirm("Forget the stored prod.keys?", "A later build that merges the game data again will ask for the file.", ok: "Forget") { s.forgetKeys() }
                }
                // An unfinished build needs them to continue (the extraction script asks for prod.keys even when it reuses its work): kept until the build finishes
                .disabled(!s.keysPresent || s.buildUnfinished || model.build.isRunning)
                .help(s.buildUnfinished ? "Kept until the build is finished: continuing it needs them." : "")
            }
            Section("Game data") {
                Button("Remove game data (keeps saves)…", role: .destructive) { removeGameData() }
                    .disabled(model.play.isRunning || model.build.isRunning || !FileManager.default.fileExists(atPath: s.cacheURL.path))
            }
            Section("Diagnostics") {
                HStack {
                    Button("Copy diagnostics") { model.copyDiagnostics() }
                        .help("Versions, this Mac, the build state and the end of the logs. No keys or game files; your home folder shows as ~.")
                    Button("Open logs folder") { NSWorkspace.shared.open(s.logsURL) }
                        .disabled(!FileManager.default.fileExists(atPath: s.logsURL.path))
                }
            }
            Section {
                Text("Version \(AppSettings.appVersion) (build \(AppSettings.appBuild)) · runtime \(s.runtimeVersion ?? "?") · shader chain \(s.runtimeChain ?? "?")").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func measure() async {
        let url = model.settings.rootURL
        folderSize = await Task.detached(priority: .utility) { () -> Int64 in
            var total: Int64 = 0
            let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey], options: [])
            while let f = e?.nextObject() as? URL {
                let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { e?.skipDescendants() }
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
            return total
        }.value
    }

    private func backUp() {
        guard let dir = Panels.choose("Choose where to put the backup", folders: true) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"
        let dst = dir.appendingPathComponent("MP4 saves \(f.string(from: Date()))", isDirectory: true)
        do { try FileManager.default.copyItem(at: model.settings.savesURL, to: dst); backupNote = "Saved to \(displayPath(dst.path))" }
        catch { backupNote = "The backup failed: \(error.localizedDescription)" }
    }

    /// Deletes everything in the game folder except the saves (user-data); the stored keys go too.
    private func removeGameData() {
        let s = model.settings
        guard Panels.confirm("Remove the game data?", "This deletes the built game data, shaders, logs, and the stored prod.keys from the build folder. Your saves are kept. You can build again later.", ok: "Remove", destructive: true) else { return }
        let fm = FileManager.default   // moved aside at once and deleted in the background (removeSafely): a big build never freezes the app
        s.removeSafely(((try? fm.contentsOfDirectory(at: s.cacheURL, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent != "user-data" })
        model.shaders.refreshReport(settings: s)
        s.packsChanged()
        openWindow(id: "build")
    }
}


/// One setting: its name with a one-line explanation under it, the control on the right.
private struct Row<Control: View>: View {
    let title: String, caption: String
    @ViewBuilder let control: Control
    init(_ title: String, _ caption: String, @ViewBuilder control: () -> Control) { self.title = title; self.caption = caption; self.control = control() }
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control
        }
    }
}
