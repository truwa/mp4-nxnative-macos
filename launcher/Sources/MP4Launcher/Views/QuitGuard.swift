import SwiftUI
import AppKit

/// Closing the last launcher window quits the launcher. While the game or a build runs, that asks first, and on
/// confirm stops it properly before quitting. Used by the windows' close buttons and by Quit (⌘Q).
@MainActor
enum QuitGuard {
    private static var confirmed = false
    /// True once the launcher is quitting: a window closing then must not open another one.
    static var quitting = false
    /// The Build window's title, and its way back to the Play window (set by BuildWindow): opens Play when a build is playable, true when it did.
    /// Closing the Build window then returns to Play instead of quitting (user's bug, 2026-11-09: hammer → Build → close quit the app).
    static let buildTitle = "MP4 nxnative – Build the game"
    static var backToPlay: (() -> Bool)?

    /// The question to ask, or nil when nothing would be lost by quitting.
    static func question(_ model: AppModel) -> (title: String, text: String, ok: String)? {
        if model.play.isRunning {
            return ("The game is running", "Closing the launcher will also close the game.", "Close game and launcher")
        }
        if model.build.isRunning {
            return ("A build is running", "Closing stops it; Start building continues it later.", "Stop build and close")
        }
        return nil
    }

    /// Asks (as a sheet on `window` when there is one); true when the player confirmed.
    static func confirm(_ model: AppModel, window: NSWindow?, then done: @escaping (Bool) -> Void) {
        guard let q = question(model) else { done(true); return }
        let a = NSAlert()
        a.messageText = q.title; a.informativeText = q.text
        a.addButton(withTitle: q.ok); a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        if let window {
            a.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
        } else {
            done(a.runModal() == .alertFirstButtonReturn)
        }
    }

    /// Stops the game or the build, then calls `done` once they have ended (at most ~6 s).
    static func stopAll(_ model: AppModel, then done: @escaping () -> Void) {
        if model.play.isRunning { model.play.stop() }
        if model.build.isRunning { model.build.cancel() }
        func wait(_ tries: Int) {
            if (!model.play.isRunning && !model.build.isRunning) || tries == 0 { done(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { wait(tries - 1) }
        }
        wait(30)
    }

    /// Quit after confirming; returns the reply for applicationShouldTerminate.
    static func shouldTerminate(_ model: AppModel) -> NSApplication.TerminateReply {
        if confirmed || question(model) == nil { quitting = true; return .terminateNow }
        confirm(model, window: NSApp.keyWindow) { ok in
            guard ok else { NSApp.reply(toApplicationShouldTerminate: false); return }
            confirmed = true
            stopAll(model) { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    /// The red close button of a launcher window: closing the last window asks first, then quits.
    static func closeTapped(_ window: NSWindow, model: AppModel) {
        let others = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        if !others, window.title == buildTitle, let back = backToPlay, back() { window.close(); return }   // a playable build: back to Play (a running build goes on)
        if others || question(model) == nil { window.close(); return }
        confirm(model, window: window) { ok in
            guard ok else { return }
            confirmed = true
            quitting = true; stopAll(model) { NSApp.terminate(nil) }
        }
    }
}

/// Hooks a SwiftUI window's close button to QuitGuard.
struct CloseGuard: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor final class Coordinator: NSObject {
        let model: AppModel
        weak var window: NSWindow?
        init(model: AppModel) { self.model = model }

        func attach(to w: NSWindow?) {
            guard let w, w !== window, let button = w.standardWindowButton(.closeButton) else { return }
            window = w
            button.target = self
            button.action = #selector(close(_:))
        }
        @objc func close(_ sender: Any?) {
            guard let window else { return }
            QuitGuard.closeTapped(window, model: model)
        }
    }
}
