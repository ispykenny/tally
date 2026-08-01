import AppKit
import SwiftUI

/// `Tally --preview` opens the menu UI in a floating window with sample
/// data — used for screenshots and design review without clicking the
/// status item. Nothing is persisted; the demo state lives in memory only.
enum PreviewMode {
    static var isActive: Bool { CommandLine.arguments.contains("--preview") }

    static var isNetTest: Bool { CommandLine.arguments.contains("--nettest") }

    static var isSearchTest: Bool { CommandLine.arguments.contains("--searchtest") }

    static var isPRTest: Bool { CommandLine.arguments.contains("--prtest") }

    static var isReposTest: Bool { CommandLine.arguments.contains("--repostest") }

    /// Diagnostic: fetch the user's repositories and run the fuzzy
    /// matcher against an optional query (last argument).
    static func runReposTest() {
        Task {
            guard let token = Keychain.token else {
                print("REPOSTEST no token in keychain")
                fflush(stdout)
                exit(1)
            }
            do {
                let repos = try await GitHubService.userRepositories(token: token)
                print("REPOSTEST OK count=\(repos.count)")
                for repo in repos.prefix(10) {
                    print("  \(repo.fullName)\(repo.isPrivate == true ? " (private)" : "")")
                }
                let last = CommandLine.arguments.last ?? ""
                if last != "--repostest" {
                    let matches = repos.filter { RepoMatcher.matches($0.fullName, query: last) }
                    print("REPOSTEST matches for \"\(last)\": \(matches.map(\.fullName))")
                }
            } catch {
                print("REPOSTEST FAIL error=\(error.localizedDescription)")
            }
            fflush(stdout)
            exit(0)
        }
    }

    /// Diagnostic: run the real GraphQL PR fetch with the stored token.
    static func runPRTest() {
        Task {
            let last = CommandLine.arguments.last ?? ""
            let repo = last.contains("/") ? last : "vercel/next.js"
            guard let token = Keychain.token else {
                print("PRTEST no token in keychain")
                fflush(stdout)
                exit(1)
            }
            do {
                let result = try await GitHubService.openPullRequests(repoFullName: repo, token: token)
                print("PRTEST OK repo=\(repo) count=\(result.prs.count) totalOpen=\(result.totalOpen)")
                for pr in result.prs.prefix(10) {
                    print("  #\(pr.number) approvals=\(pr.approvals) comments=\(pr.commentsCount) draft=\(pr.isDraft) by=\(pr.user?.login ?? "?") viewer=\(pr.viewerReviewState ?? "-") requested=\(pr.viewerReviewRequested) mine=\(pr.viewerDidAuthor) \(pr.title.prefix(40))")
                }
            } catch {
                print("PRTEST FAIL error=\(error.localizedDescription)")
            }
            fflush(stdout)
            exit(0)
        }
    }

    /// Diagnostic: run the real repo-search code path with the stored token.
    static func runSearchTest() {
        Task {
            let query = CommandLine.arguments.last == "--searchtest" ? "react" : (CommandLine.arguments.last ?? "react")
            guard let token = Keychain.token else {
                print("SEARCHTEST no token in keychain")
                fflush(stdout)
                exit(1)
            }
            print("SEARCHTEST token prefix=\(String(token.prefix(11)))… query=\(query)")
            do {
                let results = try await GitHubService.searchRepositories(matching: query, token: token)
                print("SEARCHTEST OK count=\(results.count) first=\(results.first?.fullName ?? "none")")
            } catch {
                print("SEARCHTEST FAIL error=\(error.localizedDescription)")
            }
            fflush(stdout)
            exit(0)
        }
    }

    /// Diagnostic: verify URLSession works from inside this app process.
    static func runNetTest() {
        Task {
            do {
                let url = URL(string: "https://api.github.com/zen")!
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("NETTEST OK status=\(status) body=\(String(data: data, encoding: .utf8) ?? "?")")
            } catch {
                print("NETTEST FAIL error=\(error)")
            }
            fflush(stdout)
            exit(0)
        }
    }

    private static var window: NSWindow?

    @MainActor
    static func activate() {
        seedDemoData()

        let root = MenuView()
            .environmentObject(AppState.shared)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 16))

        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Self.window = window

        print("PREVIEW_WINDOW \(window.windowNumber)")
        fflush(stdout)
    }

    /// Avatars come from TALLY_AVATAR_DIR (local files) when set, so
    /// screenshots don't depend on the network.
    private static func demoAvatarURL(for login: String) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["TALLY_AVATAR_DIR"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("\(login).png")
        }
        return URL(string: "https://avatars.githubusercontent.com/\(login)?size=64")
    }

    @MainActor
    private static func seedDemoData() {
        let state = AppState.shared
        let now = Date()

        func pr(
            _ id: Int, _ number: Int, _ title: String, _ repo: String,
            _ author: String, hoursAgo: Double, draft: Bool = false,
            approvals: Int = 0, comments: Int = 0,
            viewerState: String? = nil, requested: Bool = false
        ) -> PullRequest {
            PullRequest(
                id: id,
                number: number,
                title: title,
                htmlURL: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
                user: .init(login: author, avatarURL: demoAvatarURL(for: author)),
                createdAt: now.addingTimeInterval(-3600 * hoursAgo),
                draft: draft,
                repoFullName: repo,
                approvals: approvals,
                commentsCount: comments,
                viewerReviewState: viewerState,
                viewerReviewRequested: requested
            )
        }

        state.user = GitHubUser(login: "kenny", avatarURL: nil, name: "Kenny")
        state.repos = ["vercel/next.js", "facebook/react"]
        state.pullRequests = [
            "vercel/next.js": [
                pr(1, 84120, "Fix hydration mismatch when streaming Server Components", "vercel/next.js", "leerob", hoursAgo: 1.4, approvals: 2, comments: 7, viewerState: "APPROVED"),
                pr(2, 84117, "Turbopack: cache resolved module graphs across rebuilds", "vercel/next.js", "sokra", hoursAgo: 5, comments: 3, requested: true),
                pr(3, 84102, "docs: clarify `revalidateTag` behavior with route handlers", "vercel/next.js", "delbaoliveira", hoursAgo: 26, draft: true, comments: 1),
            ],
            "facebook/react": [
                pr(4, 31544, "[compiler] Bail out on mutated captured refs in loops", "facebook/react", "josephsavona", hoursAgo: 3, approvals: 1, comments: 12),
                pr(5, 31538, "Warn when a suspended lane is entangled with a transition", "facebook/react", "acdlite", hoursAgo: 12, approvals: 3),
            ],
        ]
        state.lastRefreshed = now.addingTimeInterval(-40)
        // Show one section collapsed in screenshots (in-memory only).
        state.collapsedRepos = ["facebook/react"]
        if ProcessInfo.processInfo.environment["TALLY_PREVIEW_SPARKLE"] != nil {
            state.triggerSparkle()
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
