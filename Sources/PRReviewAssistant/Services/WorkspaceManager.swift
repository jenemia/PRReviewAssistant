import Foundation

struct WorkspaceManager: Sendable {
    private let runner = ProcessRunner()

    /// Prepares the registered repository itself as the single PR work folder.
    /// The PR's local branch is checked out (never detached) so the agent and user
    /// always work from an attached HEAD. A dirty checkout is stashed first.
    func prepareRepositoryWorkspace(repository: RegisteredRepository, pullRequest: PullRequest) throws -> String {
        let path = repository.localPath
        let remoteRef = "refs/heads/\(pullRequest.headBranch):refs/remotes/\(repository.remoteName)/\(pullRequest.headBranch)"
        _ = try runner.run("git", arguments: ["fetch", repository.remoteName, remoteRef], workingDirectory: path)
        let target = try runner.run("git", arguments: ["rev-parse", "\(repository.remoteName)/\(pullRequest.headBranch)"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.hasPrefix(pullRequest.headSHA) else {
            throw CommandError.failed(.init(output: "", error: "가져온 PR 브랜치가 최신 PR HEAD와 다릅니다. 새로 고침 후 다시 시도하세요.", status: 1))
        }

        // A newly cloned remote with a misconfigured default branch can have an
        // unborn HEAD. Treat it as a checkout that needs preparing instead of
        // failing before we can attach the explicit PR branch below.
        let current = try? runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentBranch = try? runner.run("git", arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current != target || currentBranch != pullRequest.headBranch else { return path }

        // A completed work card may already have created one or more local
        // commits on this same PR branch. Keep that history when starting the
        // next card instead of force-resetting the branch back to remote HEAD.
        if let current, currentBranch == pullRequest.headBranch,
           (try? runner.run("git", arguments: ["merge-base", "--is-ancestor", target, current], workingDirectory: path)) != nil {
            return path
        }

        let changes = try runner.run("git", arguments: ["status", "--porcelain=v1"], workingDirectory: path).output
        if !changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let message = "PR Review Assistant: PR #\(pullRequest.number) 작업 전 임시 보관"
            _ = try runner.run("git", arguments: ["stash", "push", "--include-untracked", "--message", message], workingDirectory: path)
        }
        // Reset only this local PR branch to the SHA fetched above, then attach HEAD
        // to it.  This avoids the "HEAD (no branch)" state caused by --detach.
        _ = try runner.run("git", arguments: ["switch", "--force-create", pullRequest.headBranch, target], workingDirectory: path)
        _ = try runner.run("git", arguments: ["branch", "--set-upstream-to=\(repository.remoteName)/\(pullRequest.headBranch)", pullRequest.headBranch], workingDirectory: path)
        return path
    }

    func verifyHead(_ workspacePath: String, expectedSHA: String, expectedBranch: String) throws {
        let sha = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: workspacePath).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sha.hasPrefix(expectedSHA) else { throw CommandError.failed(.init(output: "", error: "작업 폴더의 SHA가 최신 PR HEAD와 다릅니다.", status: 1)) }
        let branch = try runner.run("git", arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: workspacePath).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch == expectedBranch else { throw CommandError.failed(.init(output: "", error: "작업 폴더가 PR 브랜치에 체크아웃되지 않았습니다.", status: 1)) }
    }

    func changes(at path: String) throws -> String { try runner.run("git", arguments: ["diff", "--stat"], workingDirectory: path).output }
    func changes(at path: String, files: [String]) throws -> String {
        try runner.run("git", arguments: ["diff", "--stat", "--"] + files, workingDirectory: path).output
    }
    func changedFiles(at path: String) throws -> [String] {
        let unstaged = try runner.run("git", arguments: ["diff", "--name-only"], workingDirectory: path).output
        let staged = try runner.run("git", arguments: ["diff", "--cached", "--name-only"], workingDirectory: path).output
        let untracked = try runner.run("git", arguments: ["ls-files", "--others", "--exclude-standard"], workingDirectory: path).output
        return Set([unstaged, staged, untracked]
            .flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) })
            .sorted()
    }
    func developerName(at path: String) throws -> String {
        let subjects = try runner.run("git", arguments: ["log", "-20", "--format=%s"], workingDirectory: path).output
        if let name = subjects
            .split(whereSeparator: \.isNewline)
            .compactMap({ developerName(fromCommitSubject: String($0)) })
            .first {
            return name
        }
        let configuredName = try? runner.run("git", arguments: ["config", "user.name"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredName, !configuredName.isEmpty { return configuredName }
        let recentAuthor = try? runner.run("git", arguments: ["log", "-1", "--format=%an"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return recentAuthor?.isEmpty == false ? recentAuthor! : "개발자"
    }

    private func developerName(fromCommitSubject subject: String) -> String? {
        let pattern = #"^\[개발\s*-\s*([^\]]+)\]"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)),
              let range = Range(match.range(at: 1), in: subject) else { return nil }
        let name = subject[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
    func verifyRemoteHead(_ remote: String, branch: String, expectedSHA: String, at path: String) throws {
        let result = try runner.run("git", arguments: ["ls-remote", remote, "refs/heads/\(branch)"], workingDirectory: path)
        guard let sha = result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init), sha.hasPrefix(expectedSHA) else {
            throw CommandError.failed(.init(output: "", error: "원격 브랜치가 분석 기준 SHA 이후 변경되었습니다. 새로 고침 후 다시 분석하세요.", status: 1))
        }
    }
    func test(at path: String, command: String) throws -> CommandResult { try runner.run("/bin/zsh", arguments: ["-lc", command], workingDirectory: path) }

    func commit(at path: String, message: String, files: [String], branch: String, expectedSHA: String, remote: String = "origin") throws -> String {
        try verifyHead(path, expectedSHA: expectedSHA, expectedBranch: branch)
        try verifyRemoteHead(remote, branch: branch, expectedSHA: expectedSHA, at: path)
        guard !files.isEmpty else {
            throw CommandError.failed(.init(output: "", error: "이 작업 카드에서 변경된 파일을 찾을 수 없습니다.", status: 1))
        }
        _ = try runner.run("git", arguments: ["commit", "--only", "-m", message, "--"] + files, workingDirectory: path)
        return try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pushCommittedChanges(at path: String, branch: String, expectedRemoteSHA: String, committedSHA: String, remote: String = "origin") throws {
        let localSHA = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard localSHA == committedSHA else {
            throw CommandError.failed(.init(output: "", error: "로컬 HEAD가 승인된 커밋과 다릅니다. 다시 테스트하고 커밋하세요.", status: 1))
        }
        let currentBranch = try runner.run("git", arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == branch else {
            throw CommandError.failed(.init(output: "", error: "작업 폴더가 PR 브랜치에 체크아웃되지 않았습니다.", status: 1))
        }
        let result = try runner.run("git", arguments: ["ls-remote", remote, "refs/heads/\(branch)"], workingDirectory: path)
        guard let remoteSHA = result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) else {
            throw CommandError.failed(.init(output: "", error: "원격 PR 브랜치의 HEAD를 확인할 수 없습니다.", status: 1))
        }
        guard remoteSHA == committedSHA || remoteSHA.hasPrefix(expectedRemoteSHA) else {
            throw CommandError.failed(.init(output: "", error: "원격 브랜치가 커밋 기준 SHA 이후 변경되었습니다. 새로 고침 후 다시 분석하세요.", status: 1))
        }
        _ = try runner.run("git", arguments: ["push", remote, "HEAD:\(branch)"], workingDirectory: path)
        let confirmed = try runner.run("git", arguments: ["ls-remote", remote, "refs/heads/\(branch)"], workingDirectory: path)
        let confirmedSHA = confirmed.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
        guard confirmedSHA == committedSHA else {
            throw CommandError.failed(.init(output: "", error: "푸시 후 원격 PR 브랜치 SHA를 확인하지 못했습니다.", status: 1))
        }
    }
}
