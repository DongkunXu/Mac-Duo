import AppKit
import SwiftUI

@main
struct MacDuoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `MacDuo --self-test` runs the offscreen rendering checks and exits before any UI appears.
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: appDelegate.model)
        } label: {
            MenuBarIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)

        Window(Text(verbatim: "Mac Duo"), id: SettingsView.windowID) {
            SettingsView(model: appDelegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 720, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

struct MenuBarIcon: View {
    let model: AppModel

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(Text(verbatim: "Mac Duo"))
    }

    private var symbol: String {
        if model.visibleProblem != nil { return "exclamationmark.triangle" }
        if !model.isEnabled { return "laptopcomputer.slash" }
        if model.isPaused { return "pause.circle" }
        return "laptopcomputer"
    }
}
