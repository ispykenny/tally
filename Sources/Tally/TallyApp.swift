import Sparkle
import SwiftUI

/// Sparkle over-the-air updates. The feed and EdDSA public key live in
/// Info.plist (SUFeedURL / SUPublicEDKey); releases publish a signed
/// appcast.xml alongside the artifacts.
enum Updater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: !PreviewMode.isActive,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}

@main
struct TallyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            Image(nsImage: MenuBarIcon.image)
            if state.isSignedIn {
                Text(menuBarText)
            }
        }
        .menuBarExtraStyle(.window)
    }

    /// Badge text: the open-PR count, plus a twinkling star for a few
    /// seconds whenever the count changes.
    private var menuBarText: String {
        var text = state.totalPRCount > 0 ? "\(state.totalPRCount)" : ""
        if state.showSparkle {
            text += text.isEmpty ? "" : " "
            text += state.sparklePhase ? "✨" : "🌟"
        }
        return text
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if PreviewMode.isNetTest {
            PreviewMode.runNetTest()
            return
        }
        if PreviewMode.isSearchTest {
            PreviewMode.runSearchTest()
            return
        }
        if PreviewMode.isPRTest {
            PreviewMode.runPRTest()
            return
        }
        if PreviewMode.isReposTest {
            PreviewMode.runReposTest()
            return
        }
        if PreviewMode.isActive {
            Task { @MainActor in
                PreviewMode.activate()
            }
            return
        }
        NotificationManager.shared.setup()
        Task { @MainActor in
            await AppState.shared.bootstrap()
            // `open Tally.app --args --sparkle-demo` — demo the badge
            // animation once, right after launch.
            if CommandLine.arguments.contains("--sparkle-demo") {
                AppState.shared.triggerSparkle()
            }
        }
    }
}
