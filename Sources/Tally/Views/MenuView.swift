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

/// Section frames in the list's coordinate space, for hit-testing drags.
private struct SectionFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct PRListView: View {
    @EnvironmentObject private var state: AppState
    @State private var statusFilter: StatusFilter = .all
    @State private var authorFilter: String?

    // Reordering is a plain drag *gesture*, not system drag-and-drop —
    // NSItemProvider drag sessions don't reliably start inside the
    // non-activating MenuBarExtra panel.
    @State private var sectionFrames: [String: CGRect] = [:]
    @State private var draggingRepo: String?
    @State private var dragTranslation: CGFloat = 0
    /// The dragged section's resting frame, captured at drag start — its
    /// live frame moves with the drag and would double-count the offset.
    @State private var dragOriginFrame: CGRect = .zero

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
            } else if !state.hasAnyOpenPRs && state.repoErrors.isEmpty {
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
            return total + 38 + rows + 10
        }
        return min(max(content + 24, 120), 460)
    }

    /// Repos with a visible section, in display order.
    private var visibleRepos: [String] {
        state.repos.filter { repo in
            let visible = filtered(state.pullRequests[repo] ?? [])
            return !(isFiltering && visible.isEmpty && state.repoErrors[repo] == nil)
        }
    }

    /// The repo the dragged section would land before (nil = end of list).
    private var insertionBefore: String? {
        guard let draggingRepo else { return nil }
        let pointerY = dragOriginFrame.midY + dragTranslation
        return visibleRepos.first { repo in
            repo != draggingRepo && pointerY < (sectionFrames[repo]?.midY ?? -.infinity)
        }
    }

    /// Collision avoidance: sections between the drag origin and the
    /// current insertion point step aside by the dragged section's height,
    /// opening a live gap where the drop will land.
    private func sectionOffset(for repo: String) -> CGFloat {
        guard let draggingRepo else { return 0 }
        if repo == draggingRepo { return dragTranslation }
        let order = visibleRepos
        guard let from = order.firstIndex(of: draggingRepo),
              let index = order.firstIndex(of: repo)
        else { return 0 }
        let to: Int
        if let target = insertionBefore, let targetIndex = order.firstIndex(of: target) {
            to = targetIndex
        } else {
            to = order.count
        }
        let gap = dragOriginFrame.height + 10
        if to > from {
            return (index > from && index < to) ? -gap : 0
        } else {
            return (index >= to && index < from) ? gap : 0
        }
    }

    /// True when releasing now would leave the order unchanged.
    private var dropIsNoop: Bool {
        guard let draggingRepo else { return true }
        let order = visibleRepos
        guard let from = order.firstIndex(of: draggingRepo) else { return true }
        if let target = insertionBefore {
            return order.firstIndex(of: target) == from + 1
        }
        return from == order.count - 1
    }

    private func finishDrag() {
        defer {
            draggingRepo = nil
            dragTranslation = 0
        }
        guard let moved = draggingRepo, abs(dragTranslation) > 4, !dropIsNoop else { return }
        let target = insertionBefore
        withAnimation(.easeOut(duration: 0.22)) {
            state.moveRepo(moved, before: target)
        }
    }

    private var prList: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                GlassEffectContainer(spacing: 10) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleRepos, id: \.self) { repo in
                            let visible = filtered(state.pullRequests[repo] ?? [])
                            let isDragged = draggingRepo == repo
                            RepoSectionView(
                                repo: repo,
                                prs: visible,
                                // Filtered views count what's visible;
                                // otherwise the repo's true open total.
                                badgeCount: isFiltering
                                    ? visible.count
                                    : (state.openPRCounts[repo] ?? visible.count),
                                error: state.repoErrors[repo],
                                now: context.date,
                                onDragChanged: { translation in
                                    if draggingRepo != repo {
                                        draggingRepo = repo
                                        dragOriginFrame = sectionFrames[repo] ?? .zero
                                    }
                                    dragTranslation = translation
                                },
                                onDragEnded: finishDrag
                            )
                            // Composite each section's layout changes so
                            // its children move as one unit while the
                            // list resizes.
                            .geometryGroup()
                            // Drag offsets stay OUTSIDE the geometry group
                            // so live drag motion bypasses layout compositing.
                            // The dragged section tracks the pointer raw;
                            // bystanders animate as they step aside.
                            .offset(y: sectionOffset(for: repo))
                            .animation(
                                isDragged ? nil : .easeOut(duration: 0.18),
                                value: sectionOffset(for: repo)
                            )
                            .shadow(color: .black.opacity(isDragged ? 0.25 : 0), radius: 10, y: 3)
                            .zIndex(isDragged ? 1 : 0)
                        }
                    }
                    .padding(12)
                    .coordinateSpace(name: "repoList")
                }
            }
        }
        .onPreferenceChange(SectionFramesKey.self) { frames in
            // Frozen while dragging: the moving section re-reports its
            // frame every pixel, which would churn state and drop math.
            guard draggingRepo == nil else { return }
            sectionFrames = frames
        }
    }
}

private struct RepoSectionView: View {
    @EnvironmentObject private var state: AppState
    let repo: String
    let prs: [PullRequest]
    let badgeCount: Int
    let error: String?
    let now: Date
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    private var collapsed: Bool { state.isCollapsed(repo) }
    private var muted: Bool { state.isMuted(repo) }
    private var index: Int? { state.repos.firstIndex(of: repo) }
    private var owner: String { repo.split(separator: "/").first.map(String.init) ?? "" }
    private var name: String { repo.split(separator: "/").dropFirst().joined(separator: "/") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !collapsed {
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 8)
                } else if prs.isEmpty {
                    Text("No open PRs")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                } else {
                    ForEach(Array(prs.enumerated()), id: \.element.id) { index, pr in
                        PRRowView(pr: pr, now: now)
                            // Skips re-rendering unchanged rows — a drag
                            // re-evaluates the list on every mouse event.
                            .equatable()
                            .transition(.rowCascade(index: index))
                    }
                    // The fetch caps at the newest 50 — say so instead of
                    // letting the list silently impersonate the whole repo.
                    if badgeCount > prs.count {
                        Button {
                            if let url = URL(string: "https://github.com/\(repo)/pulls") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("Showing newest \(prs.count) of \(badgeCount) — view all on GitHub ↗")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SectionFramesKey.self,
                    value: [repo: proxy.frame(in: .named("repoList"))]
                )
            }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) {
                    state.toggleCollapsed(repo)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))

                    // Org/user logo — GitHub serves it at github.com/<owner>.png
                    RemoteImage(url: URL(string: "https://github.com/\(owner).png?size=64")) {
                        Image(systemName: "building.2.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                    (Text(owner).foregroundStyle(.secondary).fontWeight(.regular)
                        + Text(" / ").foregroundStyle(.tertiary).fontWeight(.regular)
                        + Text(name))
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.head)

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand \(repo)" : "Collapse \(repo)")

            // Deliberately not hover-revealed: tooltip tracking areas on
            // these icons conflict with a hover-driven fade and make them
            // vanish under the cursor. This grip is the drag handle — the
            // rest of the header is buttons, which swallow drag gestures.
            // A plain gesture (not .draggable): system drag sessions don't
            // start reliably in the non-activating MenuBarExtra panel.
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .gesture(
                    // Global space: the section moves with the drag, so a
                    // local-space translation feeds back on itself and
                    // oscillates.
                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                        .onChanged { onDragChanged($0.translation.height) }
                        .onEnded { _ in onDragEnded() }
                )
                .help("Drag to reorder")

            Button {
                state.toggleMuted(repo)
            } label: {
                Image(systemName: muted ? "eye.slash.fill" : "eye")
                    .font(.caption)
                    .foregroundStyle(muted ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .help(
                muted
                    ? "Hidden from the menu bar badge — click to count it again"
                    : "Hide this repo's PRs from the menu bar badge"
            )

            Text("\(badgeCount)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(badgeCount == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // Static glass: the interactive variant claims mouse events and
        // blocks drag gestures from starting on the header.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(collapsed ? "Expand" : "Collapse") {
                withAnimation(.easeOut(duration: 0.22)) {
                    state.toggleCollapsed(repo)
                }
            }
            Button(muted ? "Show in Badge Count" : "Hide from Badge Count") {
                state.toggleMuted(repo)
            }
            Divider()
            Button("Move Up") { state.moveRepo(repo, up: true) }
                .disabled(index == 0)
            Button("Move Down") { state.moveRepo(repo, up: false) }
                .disabled(index == state.repos.count - 1)
            Divider()
            Button("Open on GitHub") {
                if let url = URL(string: "https://github.com/\(repo)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

private extension AnyTransition {
    /// Expanding a section cascades its rows in top-to-bottom; collapsing
    /// is a single quick fade (staggered removal reads as lag). The delay
    /// caps after the first several rows so long lists settle fast. Also
    /// fires when a poll inserts a newly opened PR mid-list.
    static func rowCascade(index: Int) -> AnyTransition {
        // Tight stagger tuned to finish inside the container's height
        // animation — longer delays leave visible empty slots ("popcorn").
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: -6))
                .animation(
                    .spring(response: 0.28, dampingFraction: 0.85)
                        .delay(min(Double(index), 5) * 0.03)
                ),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }
}

private struct PRRowView: View, Equatable {
    let pr: PullRequest
    let now: Date
    @State private var hovering = false

    static func == (lhs: PRRowView, rhs: PRRowView) -> Bool {
        lhs.pr == rhs.pr && lhs.now == rhs.now
    }

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
        RemoteImage(url: url) {
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
