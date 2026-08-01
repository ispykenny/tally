import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var user: GitHubUser?
    @Published var repos: [String] = []
    @Published var pullRequests: [String: [PullRequest]] = [:]
    /// True open-PR totals per repo — the list itself is capped at the
    /// newest 50, so badges read from here.
    @Published var openPRCounts: [String: Int] = [:]
    @Published var repoErrors: [String: String] = [:]
    @Published var isRefreshing = false
    @Published var lastError: String?
    @Published var lastRefreshed: Date?

    @Published var collapsedRepos: Set<String> = []

    /// Repos excluded from the menu bar badge count (still listed,
    /// still refreshed, still notify).
    @Published var mutedRepos: Set<String> = []

    /// Briefly true after the total PR count changes — drives the
    /// twinkling star next to the menu bar badge. The label can only
    /// render one image + text, so the star lives in the text and
    /// "animates" by re-rendering alternating frames.
    @Published var showSparkle = false
    @Published var sparklePhase = false
    private var sparkleTimer: Timer?
    private var sparkleTicksRemaining = 0
    private var sparkleActivity: NSObjectProtocol?
    private var pollActivity: NSObjectProtocol?

    private var pollTimer: Timer?
    private static let pollInterval: TimeInterval = 60
    private static let reposKey = "subscribedRepos"
    private static let seenKeyPrefix = "seenPRIDs."
    private static let collapsedKey = "collapsedRepos"
    private static let mutedKey = "mutedRepos"

    var isSignedIn: Bool { user != nil }

    /// Whether any subscribed repo has open PRs at all — muting is a
    /// badge concern and must not make the list claim "All clear".
    var hasAnyOpenPRs: Bool {
        repos.contains { !(pullRequests[$0] ?? []).isEmpty }
    }

    /// Badge count for the menu bar — muted repos excluded.
    var totalPRCount: Int {
        repos.reduce(0) { total, repo in
            guard !mutedRepos.contains(repo) else { return total }
            return total + (openPRCounts[repo] ?? pullRequests[repo]?.count ?? 0)
        }
    }

    private init() {
        repos = UserDefaults.standard.stringArray(forKey: Self.reposKey) ?? []
        collapsedRepos = Set(UserDefaults.standard.stringArray(forKey: Self.collapsedKey) ?? [])
        mutedRepos = Set(UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [])
    }

    /// Restore a previous session from the Keychain on launch.
    func bootstrap() async {
        guard let token = Keychain.token else { return }
        do {
            user = try await GitHubService.currentUser(token: token)
            startPolling()
            await refresh()
        } catch GitHubError.badToken {
            Keychain.delete()
            lastError = "Saved token is no longer valid — please sign in again."
        } catch {
            // Probably offline; keep the token and retry on the next poll.
            user = GitHubUser(login: "…", avatarURL: nil, name: nil)
            lastError = error.localizedDescription
            startPolling()
        }
    }

    // MARK: - Auth

    func signIn(token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = try await GitHubService.currentUser(token: trimmed)
        Keychain.save(token: trimmed)
        self.user = user
        lastError = nil
        startPolling()
        await refresh()
    }

    func signOut() {
        Keychain.delete()
        user = nil
        pullRequests = [:]
        openPRCounts = [:]
        repoErrors = [:]
        lastError = nil
        myRepos = []
        myReposLoaded = false
        stopPolling()
    }

    // MARK: - Repo subscriptions

    func searchRepositories(matching query: String) async throws -> [Repository] {
        guard let token = Keychain.token else { throw GitHubError.badToken }
        return try await GitHubService.searchRepositories(matching: query, token: token)
    }

    /// The user's own repositories (owner/collaborator/org member),
    /// loaded once per session for the repo picker.
    @Published var myRepos: [Repository] = []
    @Published var isLoadingMyRepos = false
    private var myReposLoaded = false

    func loadMyReposIfNeeded() {
        guard !myReposLoaded, !isLoadingMyRepos, let token = Keychain.token else { return }
        isLoadingMyRepos = true
        Task {
            do {
                myRepos = try await GitHubService.userRepositories(token: token)
                myReposLoaded = true
            } catch {
                // Non-fatal — the picker just won't have a "yours" section;
                // retried next time the manage screen opens.
            }
            isLoadingMyRepos = false
        }
    }

    func isSubscribed(_ fullName: String) -> Bool {
        repos.contains { $0.caseInsensitiveCompare(fullName) == .orderedSame }
    }

    func subscribe(_ repo: Repository) async {
        guard !isSubscribed(repo.fullName) else { return }
        repos.append(repo.fullName)
        persistRepos()
        await refresh()
    }

    func removeRepo(_ fullName: String) {
        repos.removeAll { $0 == fullName }
        pullRequests[fullName] = nil
        openPRCounts[fullName] = nil
        repoErrors[fullName] = nil
        collapsedRepos.remove(fullName)
        mutedRepos.remove(fullName)
        UserDefaults.standard.removeObject(forKey: Self.seenKeyPrefix + fullName)
        persistRepos()
        persistCollapsed()
        persistMuted()
    }

    func isMuted(_ fullName: String) -> Bool {
        mutedRepos.contains(fullName)
    }

    func toggleMuted(_ fullName: String) {
        if mutedRepos.contains(fullName) {
            mutedRepos.remove(fullName)
        } else {
            mutedRepos.insert(fullName)
        }
        persistMuted()
    }

    private func persistMuted() {
        UserDefaults.standard.set(Array(mutedRepos), forKey: Self.mutedKey)
    }

    /// Moves a repo one position up or down in the display order.
    func moveRepo(_ fullName: String, up: Bool) {
        guard let index = repos.firstIndex(of: fullName) else { return }
        let target = up ? index - 1 : index + 1
        guard repos.indices.contains(target) else { return }
        repos.swapAt(index, target)
        persistRepos()
    }

    /// Drag reorder: places `moved` immediately before `target`, or at
    /// the end of the list when `target` is nil.
    func moveRepo(_ moved: String, before target: String?) {
        guard let from = repos.firstIndex(of: moved), moved != target else { return }
        repos.remove(at: from)
        if let target, let index = repos.firstIndex(of: target) {
            repos.insert(moved, at: index)
        } else {
            repos.append(moved)
        }
        persistRepos()
    }

    func isCollapsed(_ fullName: String) -> Bool {
        collapsedRepos.contains(fullName)
    }

    func toggleCollapsed(_ fullName: String) {
        if collapsedRepos.contains(fullName) {
            collapsedRepos.remove(fullName)
        } else {
            collapsedRepos.insert(fullName)
        }
        persistCollapsed()
    }

    private func persistCollapsed() {
        UserDefaults.standard.set(Array(collapsedRepos), forKey: Self.collapsedKey)
    }

    private func persistRepos() {
        UserDefaults.standard.set(repos, forKey: Self.reposKey)
    }

    // MARK: - Refresh & notifications

    func startPolling() {
        stopPolling()
        // App Nap defers timers indefinitely for background menu bar apps;
        // hold an activity assertion so the poll keeps firing on schedule.
        pollActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Polling GitHub for new pull requests"
        )
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor in
                await AppState.shared.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let pollActivity {
            ProcessInfo.processInfo.endActivity(pollActivity)
            self.pollActivity = nil
        }
    }

    func refresh() async {
        guard let token = Keychain.token, isSignedIn else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshed = Date()
        }

        // Recover the user if bootstrap ran offline.
        if user?.login == "…", let refreshed = try? await GitHubService.currentUser(token: token) {
            user = refreshed
        }

        var hadError = false
        var newPRCount = 0
        for repo in repos {
            do {
                let result = try await GitHubService.openPullRequests(repoFullName: repo, token: token)
                pullRequests[repo] = result.prs
                openPRCounts[repo] = result.totalOpen
                repoErrors[repo] = nil
                newPRCount += notifyAboutNewPRs(result.prs, in: repo)
            } catch {
                repoErrors[repo] = error.localizedDescription
                hadError = true
            }
        }
        if !hadError { lastError = nil }

        // Sparkle the menu bar badge only for genuinely new PRs — busy
        // repos change their raw totals on nearly every poll, and a
        // count-diff trigger would run the animation as a metronome.
        if newPRCount > 0 {
            triggerSparkle()
        }
    }

    func triggerSparkle() {
        sparkleTimer?.invalidate()
        endSparkleActivity()
        sparkleActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Menu bar badge animation"
        )
        showSparkle = true
        sparkleTicksRemaining = 14
        let timer = Timer(timeInterval: 0.42, repeats: true) { _ in
            Task { @MainActor in
                AppState.shared.tickSparkle()
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        sparkleTimer = timer
    }

    private func tickSparkle() {
        sparklePhase.toggle()
        if PreviewMode.isActive {
            print("SPARKLE tick phase=\(sparklePhase)")
            fflush(stdout)
        }
        sparkleTicksRemaining -= 1
        if sparkleTicksRemaining <= 0 {
            sparkleTimer?.invalidate()
            sparkleTimer = nil
            showSparkle = false
            endSparkleActivity()
        }
    }

    private func endSparkleActivity() {
        if let sparkleActivity {
            ProcessInfo.processInfo.endActivity(sparkleActivity)
            self.sparkleActivity = nil
        }
    }

    /// Notify for PR ids we haven't seen before, returning how many fired.
    /// The first fetch for a repo seeds the seen-set silently so
    /// subscribing doesn't fire a burst of notifications for already-open
    /// PRs.
    @discardableResult
    private func notifyAboutNewPRs(_ prs: [PullRequest], in repo: String) -> Int {
        let key = Self.seenKeyPrefix + repo
        let defaults = UserDefaults.standard
        let previouslySeen = Set((defaults.array(forKey: key) as? [Int]) ?? [])
        let currentIDs = Set(prs.map(\.id))

        var posted = 0
        if !previouslySeen.isEmpty {
            for pr in prs where !previouslySeen.contains(pr.id) {
                NotificationManager.shared.postNewPR(pr)
                posted += 1
            }
        }

        // Keep the union so a briefly-closed PR doesn't re-notify on reopen.
        defaults.set(Array(previouslySeen.union(currentIDs)), forKey: key)
        return posted
    }
}
