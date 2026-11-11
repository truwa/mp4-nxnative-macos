import SwiftUI
import AppKit

/// Two windows that open each other: Build (used once) and Play (every time), plus Settings behind the gear.
/// The Build window opens first when there is no finished build, the Play window otherwise.
@main
struct MP4LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        Self.quitIfAnotherCopyRuns()
        let m = AppModel()
        _model = State(initialValue: m)
        AppDelegate.model = m
    }

    /// One copy of the app at a time (2026-11-11: a developer build left open beside the release showed another build folder, and both share
    /// Application Support/mp4nxnative): another copy running is brought forward, this one says where it is and quits before any window opens.
    private static func quitIfAnotherCopyRuns() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let other = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != me && !$0.isTerminated }) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let place = (other.bundleURL?.path ?? "another place").replacingOccurrences(of: home, with: "~")
        NSApplication.shared.activate()
        let a = NSAlert()
        a.messageText = "MP4 nxnative is already open"
        a.informativeText = "Another copy of the app is running (\(place)). Two copies share the same settings and build folder, so this one closes and the open one comes forward. To use this copy, quit the other one first."
        a.addButton(withTitle: "OK")
        a.runModal()
        other.activate()
        exit(0)
    }

    var body: some Scene {
        Window("MP4 nxnative", id: "play") {
            PlayWindow().environment(model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(model.settings.gameReady && !model.settings.buildUnfinished ? .presented : .suppressed)

        Window("MP4 nxnative – Build the game", id: "build") {
            BuildWindow().environment(model)
        }
        .defaultSize(width: 760, height: 820)   // the whole checklist without scrolling (2026-11-09: 600 cut it off)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(model.settings.gameReady && !model.settings.buildUnfinished ? .suppressed : .presented)   // an unfinished build opens here, with Continue

        Window("MP4 nxnative – Build speed test", id: "speedtest") {
            SpeedTestWindow().environment(model)
        }
        .windowResizability(.contentSize)   // one column of equal panels, sized by its content (2026-11-09: a free size pulled them apart)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsWindow().environment(model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                // About shows "Version 0.3 beta (<build>)": Info.plist's CFBundleShortVersionString stays numbers only (0.3.0), MP4Version holds the beta
                Button("About MP4 nxnative") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: AppVersion.display,
                                                                 .version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""])
                    NSApp.activate(ignoringOtherApps: true)
                }
                // MP4 nxnative > Check for Updates… (Services/AppUpdate.swift), as in the user's other launchers
                Button("Check for Updates…") { AppDelegate.updates.check() }
            }
            CommandMenu("Game") { GameMenu(model: model) }
            CommandMenu("Appearance") {
                ForEach([("system", "System"), ("light", "Light"), ("dark", "Dark")], id: \.0) { value, name in
                    Button { model.settings.appearance = value } label: {
                        if model.settings.appearance == value { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        }
    }
}

/// The Game menu: the tools a player does not need on the main windows.
struct GameMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var s = model.settings
#if DEVELOPER   // developer builds only (make app); a release build (make release) has no Test Build (user, 2026-11-09)
        Toggle("Test Build", isOn: $s.testBuild)
            .disabled(model.build.isRunning || model.play.isRunning)
            .help("Only the recorded shaders, in a separate folder beside the real build: minutes, for trying new versions. Keys and saves are shared with the real build.")
        Divider()
#endif
        Button("Speed Test…") { openWindow(id: "speedtest") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    /// The update check (app menu); it refuses to install while the game or a build runs
    @MainActor static let updates: AppUpdateModel = {
        let u = AppUpdateModel()
        u.blockReason = {
            MainActor.assumeIsolated {
                guard let m = AppDelegate.model else { return nil }
                if m.play.isRunning { return "The game is running. Quit the game, then check for updates again." }
                if m.build.isRunning { return "A build is running. Stop it (it continues later where it stopped), then check for updates again." }
                return nil
            }
        }
        return u
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.settings.applyAppearance() }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the last window quits the launcher (the close button asks first while the game or a build runs).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quit (⌘Q): asks first while the game or a build runs, and stops it properly before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { Self.model.map(QuitGuard.shouldTerminate) ?? .terminateNow }
    }
}
