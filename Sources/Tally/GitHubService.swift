import Foundation

enum GitHubError: LocalizedError {
    case badToken
    case notFound(String)
    case http(Int, String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .badToken:
            return "GitHub rejected the token. Check that it's valid and has the `repo` scope."
        case .notFound(let repo):
            return "Repository \"\(repo)\" not found (or the token can't see it)."
        case .http(let code, let message):
            return "GitHub API error (\(code)): \(message)"
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

enum GitHubService {
    private static let apiBase = URL(string: "https://api.github.com")!

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func request(path: String, token: String, query: [URLQueryItem] = []) async throws -> Data {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitHubError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(0, "No HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw GitHubError.badToken
        case 404:
            throw GitHubError.notFound(path)
        default:
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw GitHubError.http(http.statusCode, String(message.prefix(200)))
        }
    }

    static func currentUser(token: String) async throws -> GitHubUser {
        let data = try await request(path: "user", token: token)
        return try decoder.decode(GitHubUser.self, from: data)
    }

    static func repository(fullName: String, token: String) async throws -> Repository {
        do {
            let data = try await request(path: "repos/\(fullName)", token: token)
            return try decoder.decode(Repository.self, from: data)
        } catch GitHubError.notFound {
            throw GitHubError.notFound(fullName)
        }
    }

    private struct RepoSearchResults: Codable {
        let items: [Repository]
    }

    static func searchRepositories(matching query: String, token: String) async throws -> [Repository] {
        // "owner/name" input targets that repo exactly; anything else is a
        // free-text search.
        let isExact = query.contains("/")
            && query.split(separator: "/").count == 2
            && !query.contains(" ")
        do {
            return try await runRepoSearch(q: isExact ? "repo:\(query)" : query, token: token)
        } catch GitHubError.http(422, _) where isExact {
            // repo:owner/name 422s when the repo doesn't exist or isn't
            // visible to the token — retry as free text.
            return try await runRepoSearch(
                q: query.replacingOccurrences(of: "/", with: " "),
                token: token
            )
        }
    }

    private static func runRepoSearch(q: String, token: String) async throws -> [Repository] {
        let data = try await request(
            path: "search/repositories",
            token: token,
            query: [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "per_page", value: "8"),
            ]
        )
        return try decoder.decode(RepoSearchResults.self, from: data).items
    }

    /// All repositories the token can see as owner, collaborator, or org
    /// member — newest activity first, like GitHub's own repo picker.
    static func userRepositories(token: String) async throws -> [Repository] {
        var all: [Repository] = []
        for page in 1...3 {
            let data = try await request(
                path: "user/repos",
                token: token,
                query: [
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: "\(page)"),
                    URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
                    URLQueryItem(name: "sort", value: "pushed"),
                ]
            )
            let repos = try decoder.decode([Repository].self, from: data)
            all.append(contentsOf: repos)
            if repos.count < 100 { break }
        }
        return all
    }

    // MARK: - Pull requests (GraphQL — the REST list endpoint has no
    // review/comment counts, GraphQL gets everything in one request)

    private struct GraphQLPRResponse: Codable {
        struct ErrorItem: Codable { let message: String }
        struct DataObject: Codable { let repository: Repo? }
        struct Repo: Codable { let pullRequests: Connection }
        struct Connection: Codable {
            let totalCount: Int
            let nodes: [Node]
        }
        struct Count: Codable { let totalCount: Int }
        struct Actor: Codable {
            let login: String
            let avatarUrl: URL?
        }
        struct Review: Codable { let state: String }
        struct ReviewRequest: Codable { let id: String }
        struct Node: Codable {
            let databaseId: Int?
            let number: Int
            let title: String
            let url: URL
            let isDraft: Bool
            let createdAt: Date
            let author: Actor?
            let comments: Count
            let reviewThreads: Count
            let approvedReviews: Count
            let viewerDidAuthor: Bool
            let viewerLatestReview: Review?
            let viewerLatestReviewRequest: ReviewRequest?
        }

        let data: DataObject?
        let errors: [ErrorItem]?
    }

    private static let openPRsQuery = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(states: OPEN, first: 50, orderBy: {field: CREATED_AT, direction: DESC}) {
          totalCount
          nodes {
            databaseId
            number
            title
            url
            isDraft
            createdAt
            author { login avatarUrl }
            comments { totalCount }
            reviewThreads { totalCount }
            approvedReviews: reviews(states: APPROVED) { totalCount }
            viewerDidAuthor
            viewerLatestReview { state }
            viewerLatestReviewRequest { id }
          }
        }
      }
    }
    """

    /// The newest 50 open PRs plus the repo's true open-PR total —
    /// big repos exceed the page, and badges should show the real count.
    struct OpenPRs {
        let prs: [PullRequest]
        let totalOpen: Int
    }

    static func openPullRequests(repoFullName: String, token: String) async throws -> OpenPRs {
        let parts = repoFullName.split(separator: "/")
        guard parts.count == 2 else { throw GitHubError.notFound(repoFullName) }

        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": openPRsQuery,
            "variables": ["owner": String(parts[0]), "name": String(parts[1])],
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GitHubError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.http(0, "No HTTP response")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw GitHubError.badToken }
            let message = String(data: data, encoding: .utf8) ?? "unknown"
            throw GitHubError.http(http.statusCode, String(message.prefix(200)))
        }

        let decoded = try decoder.decode(GraphQLPRResponse.self, from: data)
        guard let repo = decoded.data?.repository else {
            if let message = decoded.errors?.first?.message, !message.lowercased().contains("could not resolve") {
                throw GitHubError.http(200, message)
            }
            throw GitHubError.notFound(repoFullName)
        }

        let prs = repo.pullRequests.nodes.map { node in
            PullRequest(
                id: node.databaseId ?? node.number,
                number: node.number,
                title: node.title,
                htmlURL: node.url,
                user: node.author.map { PullRequest.Author(login: $0.login, avatarURL: $0.avatarUrl) },
                createdAt: node.createdAt,
                draft: node.isDraft,
                repoFullName: repoFullName,
                approvals: node.approvedReviews.totalCount,
                commentsCount: node.comments.totalCount + node.reviewThreads.totalCount,
                viewerReviewState: node.viewerLatestReview?.state,
                viewerReviewRequested: node.viewerLatestReviewRequest != nil,
                viewerDidAuthor: node.viewerDidAuthor
            )
        }
        return OpenPRs(prs: prs, totalOpen: repo.pullRequests.totalCount)
    }
}
