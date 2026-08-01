import SwiftUI

struct ManageReposView: View {
    @EnvironmentObject private var state: AppState
    @Binding var screen: MenuScreen

    // Env hook so `--preview` screenshots can start with a live search.
    @State private var query = ProcessInfo.processInfo.environment["TALLY_PREVIEW_QUERY"] ?? ""
    @State private var results: [Repository] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Repos the user owns / collaborates on that match the query —
    /// fuzzy, so "eventrise/web" finds "eventriseapp/web". With no
    /// query, the most recently pushed ones (like GitHub's picker).
    private var yourMatches: [Repository] {
        if trimmedQuery.isEmpty {
            return Array(state.myRepos.prefix(6))
        }
        return Array(
            state.myRepos
                .filter { RepoMatcher.matches($0.fullName, query: trimmedQuery) }
                .prefix(10)
        )
    }

    /// Global search results, minus anything already in the yours section.
    private var globalMatches: [Repository] {
        let local = Set(yourMatches.map { $0.fullName.lowercased() })
        return results.filter { !local.contains($0.fullName.lowercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            resultsArea
            Divider()
            subscribedList
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                searchFocused = true
            }
            state.loadMyReposIfNeeded()
            if !query.isEmpty {
                scheduleSearch(query)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                screen = .pullRequests
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .controlSize(.small)

            Spacer()

            Text("Manage Repositories")
                .font(.subheadline.weight(.semibold))

            Spacer()

            // Balances the back button so the title stays centered.
            Label("Back", systemImage: "chevron.left")
                .controlSize(.small)
                .hidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search GitHub repositories…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(9)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
    }

    private var resultsArea: some View {
        ScrollView {
            GlassEffectContainer(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    if !yourMatches.isEmpty {
                        sectionLabel("Your repositories")
                        ForEach(yourMatches) { repo in
                            SearchResultRow(repo: repo)
                        }
                    } else if state.isLoadingMyRepos {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Loading your repositories…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    } else if trimmedQuery.isEmpty {
                        Text("Type to search all of GitHub.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(6)
                    }

                    if !trimmedQuery.isEmpty {
                        sectionLabel("GitHub search")
                        if globalMatches.isEmpty && !isSearching {
                            Text("No other repositories found")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                        }
                        ForEach(globalMatches) { repo in
                            SearchResultRow(repo: repo)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        // ScrollView collapses to ~zero ideal height in the self-sizing
        // MenuBarExtra panel, so size it to the content explicitly.
        .frame(height: resultsHeight)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }

    private var resultsHeight: CGFloat {
        var rows = CGFloat(yourMatches.count)
        var headers: CGFloat = yourMatches.isEmpty ? 0 : 1
        if trimmedQuery.isEmpty {
            if yourMatches.isEmpty { rows += 1 }  // loading / hint line
        } else {
            rows += CGFloat(max(globalMatches.count, 1))
            headers += 1
        }
        return min(max(rows * 56 + headers * 24 + 14, 64), 320)
    }

    private var subscribedList: some View {
        Group {
            if state.repos.isEmpty {
                EmptyStateView(
                    icon: "folder.badge.plus",
                    title: "Nothing subscribed",
                    message: "Search above to find repositories to watch — try “vercel/next.js” or just “react”."
                )
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SUBSCRIBED")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)

                    ScrollView {
                        GlassEffectContainer(spacing: 8) {
                            VStack(spacing: 8) {
                                ForEach(state.repos, id: \.self) { repo in
                                    RepoRowView(repo: repo)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                    .frame(height: min(CGFloat(state.repos.count) * 62 + 18, 280))
                }
            }
        }
    }

    private func scheduleSearch(_ rawQuery: String) {
        searchTask?.cancel()
        errorMessage = nil
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            // Debounce so we don't hit the search API on every keystroke.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await state.searchRepositories(matching: trimmed)
                guard !Task.isCancelled else { return }
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isSearching = false
        }
    }
}

private struct SearchResultRow: View {
    @EnvironmentObject private var state: AppState
    let repo: Repository
    @State private var justAdded = false

    private var subscribed: Bool {
        state.isSubscribed(repo.fullName) || justAdded
    }

    var body: some View {
        Button {
            guard !subscribed else { return }
            justAdded = true
            Task { await state.subscribe(repo) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(repo.fullName)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        if repo.isPrivate == true {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let description = repo.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let stars = repo.stargazersCount {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                        Text(stars.formatted(.number.notation(.compactName)))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Image(systemName: subscribed ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(subscribed ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
            }
            .padding(9)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .disabled(subscribed)
        .help(subscribed ? "Already subscribed" : "Subscribe to \(repo.fullName)")
    }
}

private struct RepoRowView: View {
    @EnvironmentObject private var state: AppState
    let repo: String
    @State private var trashHovering = false

    private var index: Int? { state.repos.firstIndex(of: repo) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(repo)
                    .font(.callout.weight(.medium))
                Text(
                    state.isMuted(repo)
                        ? "\(state.openPRCounts[repo] ?? state.pullRequests[repo]?.count ?? 0) open PRs · hidden from badge"
                        : "\(state.openPRCounts[repo] ?? state.pullRequests[repo]?.count ?? 0) open PRs"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Reorder controls — the order here is the display order
            // of the PR list.
            VStack(spacing: 2) {
                Button {
                    state.moveRepo(repo, up: true)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == 0 ? .tertiary : .secondary)
                .disabled(index == 0)
                .help("Move up")

                Button {
                    state.moveRepo(repo, up: false)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == state.repos.count - 1 ? .tertiary : .secondary)
                .disabled(index == state.repos.count - 1)
                .help("Move down")
            }

            Button {
                state.removeRepo(repo)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(trashHovering ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .onHover { trashHovering = $0 }
            .help("Unsubscribe")
        }
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
}
