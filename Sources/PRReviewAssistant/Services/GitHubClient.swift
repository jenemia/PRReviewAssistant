import Foundation

struct GitHubIdentity: Codable, Hashable {
    let login: String
    let hostname: String
}

struct GitHubClient: Sendable {
    private let runner = ProcessRunner()

    func authentication() throws -> GitHubIdentity {
        let result = try runner.run("gh", arguments: ["api", "user"])
        return try githubDecoder.decode(GitHubUser.self, from: Data(result.output.utf8)).identity
    }

    /// SourceTree normally writes this value to the global Git configuration,
    /// so it also provides a useful fallback when GitHub CLI is unavailable.
    func localGitAuthorName() throws -> String {
        try runner.run("git", arguments: ["config", "--global", "user.name"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func localGitAccount() throws -> String {
        let name = try localGitAuthorName()
        let email = try runner.run("git", arguments: ["config", "--global", "user.email"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !email.isEmpty else { throw CommandError.failed(.init(output: "", error: "Git 작성자 이름 또는 이메일이 설정되지 않았습니다.", status: 1)) }
        return "\(name) <\(email)>"
    }

    func startLogin() throws {
        try runner.launchInTerminal(command: "export PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH\"; gh auth login --web --git-protocol https; echo; echo \"인증 완료 후 PR Review Assistant에서 다시 확인하세요.\"; exec $SHELL -l")
    }

    func inspectRepository(at path: String) throws -> RegisteredRepository {
        let remote = try runner.run("git", arguments: ["remote", "get-url", "origin"], workingDirectory: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = try repositoryName(from: remote)
        let defaultBranch = try runner.run("git", arguments: ["symbolic-ref", "refs/remotes/origin/HEAD", "--short"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").dropFirst().joined(separator: "/")
        return RegisteredRepository(localPath: path, fullName: name, defaultBranch: defaultBranch.isEmpty ? "main" : defaultBranch)
    }

    func pullRequests(for repository: RegisteredRepository) throws -> [PullRequest] {
        let fields = "number,title,author,headRefName,baseRefName,headRefOid,updatedAt,isDraft,reviewDecision,url"
        let result = try runner.run("gh", arguments: ["pr", "list", "--repo", repository.fullName, "--state", "open", "--json", fields, "--limit", "100"])
        let items = try githubDecoder.decode([GitHubPullRequest].self, from: Data(result.output.utf8))
        return items.map { item in
            PullRequest(id: stableID(repository.fullName, item.number), repository: repository.fullName, number: item.number, title: item.title, author: item.author.login, headBranch: item.headRefName, baseBranch: item.baseRefName, headSHA: String(item.headRefOid.prefix(12)), reviewer: item.reviewDecision?.reviewer ?? "리뷰 대기", commentCount: 0, updatedAt: item.updatedAt, reviewState: item.reviewDecision?.state ?? .commented, analysisStatus: .needsAnalysis, summary: "최신 리뷰와 코멘트를 확인하려면 PR을 선택하세요.", files: [])
        }
    }

    /// Returns every human-review surface GitHub exposes for a PR: review bodies,
    /// general conversation comments, line comments, and replies to line comments.
    func comments(repository: String, number: Int) throws -> [ReviewComment] {
        let reviews: [GitHubReview] = try paged("repos/\(repository)/pulls/\(number)/reviews")
        let issueComments: [GitHubIssueComment] = try paged("repos/\(repository)/issues/\(number)/comments")
        let lineComments: [GitHubReviewComment] = try paged("repos/\(repository)/pulls/\(number)/comments")

        let reviewItems = reviews.compactMap { review -> ReviewComment? in
            guard !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ReviewComment(id: "review-\(review.id)", author: review.user.login, body: review.body, path: nil, line: nil, createdAt: review.submittedAt ?? review.createdAt ?? .distantPast, kind: .review, reviewState: ReviewState(githubValue: review.state), parentID: nil)
        }
        let generalItems = issueComments.map {
            ReviewComment(id: "issue-\($0.id)", author: $0.user.login, body: $0.body, path: nil, line: nil, createdAt: $0.createdAt, kind: .general, reviewState: nil, parentID: nil)
        }
        let lineItems = lineComments.map { comment in
            let parentID = comment.inReplyToID.map { "line-\($0)" }
            return ReviewComment(id: "line-\(comment.id)", author: comment.user.login, body: comment.body, path: comment.path, line: comment.line, createdAt: comment.createdAt, kind: parentID == nil ? .line : .reply, reviewState: nil, parentID: parentID)
        }
        return (reviewItems + generalItems + lineItems).sorted { $0.createdAt < $1.createdAt }
    }

    func requestReview(repository: String, number: Int, reviewers: [String]) throws {
        let body = try JSONEncoder().encode(["reviewers": reviewers])
        _ = try runner.run("gh", arguments: ["api", "repos/\(repository)/pulls/\(number)/requested_reviewers", "--method", "POST", "--input", "-"], input: String(decoding: body, as: UTF8.self))
    }

    func addComment(repository: String, number: Int, body: String) throws {
        let input = try JSONEncoder().encode(["body": body])
        _ = try runner.run(
            "gh",
            arguments: ["api", "repos/\(repository)/issues/\(number)/comments", "--method", "POST", "--input", "-"],
            input: String(decoding: input, as: UTF8.self)
        )
    }

    private func repositoryName(from remote: String) throws -> String {
        let normalized = remote.replacingOccurrences(of: ".git", with: "")
        if let range = normalized.range(of: "github.com[:/]", options: .regularExpression) {
            return String(normalized[range.upperBound...])
        }
        throw CommandError.failed(CommandResult(output: "", error: "GitHub origin remote를 찾을 수 없습니다: \(remote)", status: 1))
    }

    private func stableID(_ name: String, _ number: Int) -> UUID {
        // A prefix-based UUID collides when repository names exceed 16 bytes.
        // Hash the complete repository + PR number instead.
        let key = "\(name)#\(number)"
        let first = fnv1a64(key)
        let second = fnv1a64("pr-review-assistant:\(key)")
        var bytes = (0..<8).map { UInt8(truncatingIfNeeded: first >> UInt64(56 - ($0 * 8))) }
        bytes += (0..<8).map { UInt8(truncatingIfNeeded: second >> UInt64(56 - ($0 * 8))) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func fnv1a64(_ value: String) -> UInt64 {
        value.utf8.reduce(0xcbf29ce484222325) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }

    private func paged<T: Decodable>(_ endpoint: String) throws -> [T] {
        let result = try runner.run("gh", arguments: ["api", endpoint, "--paginate", "--slurp"])
        return try githubDecoder.decode([[T]].self, from: Data(result.output.utf8)).flatMap { $0 }
    }
}

private let githubDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
        let value = try decoder.singleValueContainer().decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        guard let date = plain.date(from: value) else { throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid GitHub date") }
        return date
    }
    return decoder
}()

private struct GitHubUser: Codable { let login: String; let html_url: String?; var identity: GitHubIdentity { .init(login: login, hostname: "github.com") } }
private struct GitHubAuthor: Codable { let login: String }
private struct GitHubPullRequest: Codable {
    let number: Int; let title: String; let author: GitHubAuthor; let headRefName: String; let baseRefName: String; let headRefOid: String; let updatedAt: Date; let isDraft: Bool; let reviewDecision: GitHubReviewDecision?; let url: String
}
private struct GitHubReviewDecision: Codable {
    let state: ReviewState; let reviewer: String?
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value { case "CHANGES_REQUESTED": state = .changesRequested; case "APPROVED": state = .approved; default: state = .commented }
        reviewer = nil
    }
}
private struct GitHubReview: Codable { let id: Int; let body: String; let state: String; let submittedAt: Date?; let createdAt: Date?; let user: GitHubAuthor }
private struct GitHubIssueComment: Codable { let id: Int; let body: String; let createdAt: Date; let user: GitHubAuthor }
private struct GitHubReviewComment: Codable { let id: Int; let body: String; let path: String?; let line: Int?; let createdAt: Date; let user: GitHubAuthor; let inReplyToID: Int? }

private extension ReviewState {
    init(githubValue: String) {
        switch githubValue {
        case "CHANGES_REQUESTED": self = .changesRequested
        case "APPROVED": self = .approved
        default: self = .commented
        }
    }
}
