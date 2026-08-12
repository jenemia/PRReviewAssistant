import Foundation

struct PullRequestProposal: Hashable, Decodable, Sendable {
    struct ExistingPullRequest: Hashable, Decodable, Sendable {
        let number: Int
        let state: String
        let url: String
    }

    var skillName: String
    var head: String
    var base: String
    var baseSource: String
    var reviewers: [String]
    var title: String
    var body: String
    var existingPullRequest: ExistingPullRequest?
    var warnings: [String]
    var commitCount: Int
    var changedFiles: Int

    private enum CodingKeys: String, CodingKey {
        case skillName, head, base, baseSource, reviewers, title, body
        case existingPullRequest, warnings, commitCount, changedFiles
    }

    init(
        skillName: String,
        head: String,
        base: String,
        baseSource: String,
        reviewers: [String],
        title: String,
        body: String,
        existingPullRequest: ExistingPullRequest? = nil,
        warnings: [String] = [],
        commitCount: Int = 0,
        changedFiles: Int = 0
    ) {
        self.skillName = skillName
        self.head = head
        self.base = base
        self.baseSource = baseSource
        self.reviewers = reviewers
        self.title = title
        self.body = body
        self.existingPullRequest = existingPullRequest
        self.warnings = warnings
        self.commitCount = commitCount
        self.changedFiles = changedFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skillName = try container.decode(String.self, forKey: .skillName)
        head = try container.decode(String.self, forKey: .head)
        base = try container.decode(String.self, forKey: .base)
        baseSource = try container.decodeIfPresent(String.self, forKey: .baseSource) ?? "agent"
        reviewers = try container.decodeIfPresent([String].self, forKey: .reviewers) ?? []
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        existingPullRequest = try container.decodeIfPresent(ExistingPullRequest.self, forKey: .existingPullRequest)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        commitCount = try container.decodeIfPresent(Int.self, forKey: .commitCount) ?? 0
        changedFiles = try container.decodeIfPresent(Int.self, forKey: .changedFiles) ?? 0
    }
}

struct PullRequestProposalVerifier: Sendable {
    static let suspiciousCommitLimit = 500

    private let runner = ProcessRunner()

    func verify(
        _ proposal: PullRequestProposal,
        repository: RegisteredRepository,
        branch: RepositoryBranch
    ) throws -> PullRequestProposal {
        let head = proposal.head.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = proposal.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == branch.name else {
            throw validationError("Agent가 선택한 head `\(head)`가 요청 브랜치 `\(branch.name)`와 다릅니다.")
        }
        guard !base.isEmpty, base != head else {
            throw validationError("Agent가 유효한 base 브랜치를 선택하지 못했습니다.")
        }
        _ = try runner.run(
            "git",
            arguments: ["check-ref-format", "--branch", base],
            workingDirectory: repository.localPath
        )

        let remote = repository.remoteName
        let baseReference = "refs/remotes/\(remote)/\(base)"
        let headReference = branch.reference
        let localBaseSHA = try resolvedSHA(baseReference, repositoryPath: repository.localPath)
        let localHeadSHA = try resolvedSHA(headReference, repositoryPath: repository.localPath)
        guard localHeadSHA.hasPrefix(branch.sha) || branch.sha.hasPrefix(localHeadSHA) else {
            throw validationError("선택한 브랜치가 갱신되었습니다. origin 브랜치를 새로 고친 뒤 다시 분석하세요.")
        }

        let remoteBaseSHA = try remoteSHA(remote: remote, branch: base, repositoryPath: repository.localPath)
        guard remoteBaseSHA == localBaseSHA else {
            throw validationError("로컬 `\(remote)/\(base)`가 원격보다 오래되었습니다. origin을 새로 고친 뒤 다시 분석하세요.")
        }
        let remoteHeadSHA = try remoteSHA(remote: remote, branch: head, repositoryPath: repository.localPath)
        guard remoteHeadSHA == localHeadSHA else {
            throw validationError("로컬 `\(remote)/\(head)`와 원격 head가 다릅니다. origin을 새로 고친 뒤 다시 분석하세요.")
        }

        let mergeBase = try runner.run(
            "git",
            arguments: ["merge-base", baseReference, headReference],
            workingDirectory: repository.localPath
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !mergeBase.isEmpty else {
            throw validationError("`\(base)`와 `\(head)`의 공통 Git 이력을 찾을 수 없습니다.")
        }

        let commitCount = try integerOutput(
            executable: "git",
            arguments: ["rev-list", "--count", "\(baseReference)..\(headReference)"],
            repositoryPath: repository.localPath
        )
        let changedFilesOutput = try runner.run(
            "git",
            arguments: ["diff", "--name-only", "\(baseReference)...\(headReference)", "--"],
            workingDirectory: repository.localPath
        ).output
        let changedFiles = changedFilesOutput.split(whereSeparator: \Character.isNewline).count

        guard commitCount > 0, changedFiles > 0 else {
            throw validationError("`\(base)` 기준으로 PR에 포함할 커밋이나 변경 파일이 없습니다.")
        }
        guard commitCount <= Self.suspiciousCommitLimit else {
            throw validationError("`\(base)` 기준 커밋이 \(commitCount)개입니다. 잘못된 base일 가능성이 높아 PR 생성을 차단했습니다.")
        }

        var verified = proposal
        verified.head = head
        verified.base = base
        verified.commitCount = commitCount
        verified.changedFiles = changedFiles
        if commitCount > 100 {
            verified.warnings.append("PR에 커밋 \(commitCount)개가 포함됩니다. base가 맞는지 다시 확인하세요.")
        }
        return verified
    }

    private func resolvedSHA(_ reference: String, repositoryPath: String) throws -> String {
        let output = try runner.run(
            "git",
            arguments: ["rev-parse", "--verify", "\(reference)^{commit}"],
            workingDirectory: repositoryPath
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw validationError("Git 참조 `\(reference)`를 찾을 수 없습니다.") }
        return output
    }

    private func remoteSHA(remote: String, branch: String, repositoryPath: String) throws -> String {
        let output = try runner.run(
            "git",
            arguments: ["ls-remote", remote, "refs/heads/\(branch)"],
            workingDirectory: repositoryPath,
            timeout: 30
        ).output
        guard let sha = output.split(whereSeparator: \Character.isWhitespace).first else {
            throw validationError("원격 브랜치 `\(remote)/\(branch)`를 찾을 수 없습니다.")
        }
        return String(sha)
    }

    private func integerOutput(executable: String, arguments: [String], repositoryPath: String) throws -> Int {
        let output = try runner.run(executable, arguments: arguments, workingDirectory: repositoryPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(output) else { throw validationError("Git 비교 결과를 숫자로 확인할 수 없습니다.") }
        return value
    }

    private func validationError(_ message: String) -> CommandError {
        .failed(.init(output: "", error: message, status: 1))
    }
}
