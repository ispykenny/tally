import Foundation

struct GitHubUser: Codable, Equatable {
    let login: String
    let avatarURL: URL?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
        case name
    }
}

struct PullRequest: Codable, Identifiable, Equatable {
    struct Author: Codable, Equatable {
        let login: String
        let avatarURL: URL?

        enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatar_url"
        }
    }

    let id: Int
    let number: Int
    let title: String
    let htmlURL: URL
    let user: Author?
    let createdAt: Date
    let draft: Bool?

    /// Injected after decoding — the "owner/name" this PR belongs to.
    var repoFullName: String = ""

    /// Filled from the GraphQL fetch; not part of the REST payload.
    var approvals: Int = 0
    var commentsCount: Int = 0

    /// Your relationship to this PR (also GraphQL-only).
    var viewerReviewState: String? = nil
    var viewerReviewRequested: Bool = false
    var viewerDidAuthor: Bool = false

    var viewerStatus: ViewerReviewStatus? {
        switch viewerReviewState {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        default: break
        }
        if viewerReviewRequested { return .reviewRequested }
        if viewerReviewState == "COMMENTED" { return .commented }
        return nil
    }

    var isDraft: Bool { draft ?? false }

    enum CodingKeys: String, CodingKey {
        case id, number, title, user, draft
        case htmlURL = "html_url"
        case createdAt = "created_at"
    }
}

struct Repository: Codable, Identifiable {
    let fullName: String
    let htmlURL: URL
    let description: String?
    let stargazersCount: Int?
    let isPrivate: Bool?

    var id: String { fullName }

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case htmlURL = "html_url"
        case description
        case stargazersCount = "stargazers_count"
        case isPrivate = "private"
    }
}

/// The signed-in user's review relationship to a PR.
enum ViewerReviewStatus {
    case approved
    case changesRequested
    case commented
    case reviewRequested

    var icon: String {
        switch self {
        case .approved: return "checkmark.seal.fill"
        case .changesRequested: return "exclamationmark.circle.fill"
        case .commented: return "text.bubble.fill"
        case .reviewRequested: return "eye.circle.fill"
        }
    }

    var help: String {
        switch self {
        case .approved: return "You approved this PR"
        case .changesRequested: return "You requested changes"
        case .commented: return "You reviewed with comments"
        case .reviewRequested: return "Your review was requested"
        }
    }
}

enum RepoMatcher {
    /// Fuzzy match for the repo picker: every token (split on "/" and
    /// spaces) must appear somewhere in the full name, so a query of
    /// "eventrise/web" matches "eventriseapp/web".
    static func matches(_ fullName: String, query: String) -> Bool {
        let name = fullName.lowercased()
        let tokens = query.lowercased().split { $0 == "/" || $0 == " " }
        return !tokens.isEmpty && tokens.allSatisfy { name.contains($0) }
    }
}
