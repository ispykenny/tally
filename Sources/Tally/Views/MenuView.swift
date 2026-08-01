import SwiftUI

/// "x ago" text that stays fresh. SwiftUI's `.relative` format style
/// renders once and never ticks — and unchanged rows skip re-rendering
/// entirely — so timestamps must be formatted against a date supplied
/// by an enclosing TimelineView.
private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
}()

private func relativeText(_ date: Date, now: Date) -> String {
    // Clamp so minor clock skew never yields "in 5 seconds".
    relativeFormatter.localizedString(for: min(date, now), relativeTo: now)
}

enum MenuScreen {
    case pullRequests
    case manageRepos
}

struct MenuView: View {
    @EnvironmentObject private var state: AppState
    // Env hook so `--preview` screenshots can open a specific screen.
    @State private var screen: MenuScreen =
        ProcessInfo.processInfo.environment["TALLY_PREVIEW_SCREEN"] == "repos" ? .manageRepos : .pullRequests

    var body: some View {
        Group {
            if state.isSignedIn {
                signedInBody
            } else {
                LoginView()
            }
        }
        .frame(width: 380)
        .background(WindowActivator())
        .onAppear {
            Task { await state.refresh() }
        }
    }

    private var signedInBody: some View {
        VStack(spacing: 0) {
            HeaderView(screen: $screen)
            Divider()

            switch screen {
            case .pullRequests:
                PRListView()
            case .manageRepos:
                ManageReposView(screen: $screen)
            }

            Divider()
            FooterView()
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var state: AppState
    @Binding var screen: MenuScreen

    var body: some View {
        HStack(spacing: 10) {
            AppIconTile(size: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Tally")
                    .font(.headline)
                if let user = state.user {
                    Text("@\(user.login)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                Task { await state.refresh() }
            } label: {
                Group {
                    if state.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Refresh now")

            Menu {
                Button("Manage Repositories…") { screen = .manageRepos }
                Button("Check for Updates…") { Updater.controller.checkForUpdates(nil) }
                Divider()
                Button("Sign Out") { state.signOut() }
                Button("Quit Tally") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: Circle())
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - PR list

private enum StatusFilter: String, CaseIterable {
    case all = "All"
    case ready = "Ready"
    case draft = "Draft"
}

private struct PRListView: View {
    @EnvironmentObject private var state: AppState
    @State private var statusFilter: StatusFilter = .all
    @State private var authorFilter: String?

    private var isFiltering: Bool {
        statusFilter != .all || authorFilter != nil
    }

    private var allAuthors: [String] {
        Set(
            state.repos
                .flatMap { state.pullRequests[$0] ?? [] }
                .compactMap { $0.user?.login }
        )
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func filtered(_ prs: [PullRequest]) -> [PullRequest] {
        prs.filter { pr in
            switch statusFilter {
            case .all: break
            case .ready: if pr.isDraft { return false }
            case .draft: if !pr.isDraft { return false }
            }
            if let authorFilter, pr.user?.login != authorFilter { return false }
            return true
        }
    }

    private var filteredTotal: Int {
        state.repos.reduce(0) { $0 + filtered(state.pullRequests[$1] ?? []).count }
    }

    var body: some View {
        Group {
            if state.repos.isEmpty {
                EmptyStateView(
                    icon: "folder.badge.plus",
                    title: "No repositories yet",
                    message: "Open the gear menu and add repos to watch their open pull requests."
                )
            } else if state.totalPRCount == 0 && state.repoErrors.isEmpty {
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "All clear",
                    message: "No open pull requests in your subscribed repositories."
                )
            } else {
                VStack(spacing: 0) {
                    filterBar
                    if isFiltering && filteredTotal == 0 && state.repoErrors.isEmpty {
                        EmptyStateView(
                            icon: "line.3.horizontal.decrease.circle",
                            title: "No matches",
                            message: "No open pull requests match the current filters."
                        )
                    } else {
                        prList
                            .frame(height: estimatedListHeight)
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(StatusFilter.allCases, id: \.self) { option in
                    Button {
                        statusFilter = option
                    } label: {
                        if statusFilter == option {
                            Label(option.rawValue, systemImage: "checkmark")
                        } else {
                            Text(option.rawValue)
                        }
                    }
                }
            } label: {
                Label(
                    statusFilter == .all ? "Status" : statusFilter.rawValue,
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.caption)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                Button {
                    authorFilter = nil
                } label: {
                    if authorFilter == nil {
                        Label("All Authors", systemImage: "checkmark")
                    } else {
                        Text("All Authors")
                    }
                }
                Divider()
                ForEach(allAuthors, id: \.self) { author in
                    Button {
                        authorFilter = author
                    } label: {
                        if authorFilter == author {
                            Label(author, systemImage: "checkmark")
                        } else {
                            Text(author)
                        }
                    }
                }
            } label: {
                Label(authorFilter ?? "Author", systemImage: "person")
                    .font(.caption)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .menuIndicator(.hidden)
            .fixedSize()

            if isFiltering {
                Button {
                    statusFilter = .all
                    authorFilter = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filters")

                Text("\(filteredTotal) match\(filteredTotal == 1 ? "" : "es")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// ScrollView reports a tiny ideal height, which collapses the
    /// MenuBarExtra window — so estimate the content height and clamp it.
    private var estimatedListHeight: CGFloat {
        let content = state.repos.reduce(CGFloat(0)) { total, repo in
            let count = filtered(state.pullRequests[repo] ?? []).count
            if isFiltering && count == 0 && state.repoErrors[repo] == nil {
                return total
            }
            let rows: CGFloat
            if state.isCollapsed(repo) {
                rows = 0
            } else if count > 0 {
                rows = CGFloat(count) * 68
            } else {
                rows = 26
            }
            return total + 26 + rows + 10
        }
        return min(max(content + 24, 120), 460)
    }

    private var prList: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                GlassEffectContainer(spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(state.repos, id: \.self) { repo in
                            let visible = filtered(state.pullRequests[repo] ?? [])
                            if !(isFiltering && visible.isEmpty && state.repoErrors[repo] == nil) {
                                RepoSectionView(
                                    repo: repo,
                                    prs: visible,
                                    error: state.repoErrors[repo],
                                    now: context.date
                                )
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

private struct RepoSectionView: View {
    @EnvironmentObject private var state: AppState
    let repo: String
    let prs: [PullRequest]
    let error: String?
    let now: Date

    private var collapsed: Bool { state.isCollapsed(repo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.toggleCollapsed(repo)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Image(systemName: "book.closed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(repo)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand \(repo)" : "Collapse \(repo)")

                Button {
                    state.toggleMuted(repo)
                } label: {
                    Image(systemName: state.isMuted(repo) ? "eye.slash.fill" : "eye")
                        .font(.caption)
                        .foregroundStyle(state.isMuted(repo) ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.plain)
                .help(
                    state.isMuted(repo)
                        ? "Hidden from the menu bar badge — click to count it again"
                        : "Hide this repo's PRs from the menu bar badge"
                )

                Text("\(prs.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: Capsule())
            }
            .padding(.horizontal, 4)

            if !collapsed {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                } else if prs.isEmpty {
                    Text("No open PRs")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                } else {
                    ForEach(prs) { pr in
                        PRRowView(pr: pr, now: now)
                    }
                }
            }
        }
    }
}

private struct PRRowView: View {
    let pr: PullRequest
    let now: Date
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(pr.htmlURL)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(url: pr.user?.avatarURL)

                VStack(alignment: .leading, spacing: 3) {
                    Text(pr.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(verbatim: "#\(pr.number)")
                        Text("by \(pr.user?.login ?? "unknown")")
                        Text(relativeText(pr.createdAt, now: now))

                        HStack(spacing: 2) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("\(pr.approvals)")
                        }
                        .foregroundStyle(pr.approvals > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        .help("\(pr.approvals) approving reviews")

                        HStack(spacing: 2) {
                            Image(systemName: "bubble.left.fill")
                            Text("\(pr.commentsCount)")
                        }
                        .foregroundStyle(pr.commentsCount > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .help("\(pr.commentsCount) comments")

                        if pr.isDraft {
                            Text("Draft")
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 5) {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.3)
                    if let status = pr.viewerStatus {
                        Image(systemName: status.icon)
                            .font(.caption)
                            .foregroundStyle(statusColor(status))
                            .help(status.help)
                    }
                }
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassEffect(
            hovering ? .regular.interactive() : .regular,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .onHover { hovering = $0 }
        .help("Open on GitHub")
    }

    private func statusColor(_ status: ViewerReviewStatus) -> Color {
        switch status {
        case .approved: return .green
        case .changesRequested: return .orange
        case .commented: return .secondary
        case .reviewRequested: return .blue
        }
    }
}

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 26

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.tertiary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Empty state & footer

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

private struct FooterView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack {
            if let error = state.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let refreshed = state.lastRefreshed {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text("Updated \(relativeText(refreshed, now: context.date))")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Tally")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption2)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
