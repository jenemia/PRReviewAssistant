import Foundation

struct WorkspaceManager: Sendable {
    /// Generous because fetch and push on a large repository can be slow.
    private let runner = ProcessRunner(defaultTimeout: 600)

    func currentBranch(in repository: RegisteredRepository) throws -> String {
        try runner.run("git", arguments: ["branch", "--show-current"], workingDirectory: repository.localPath)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func checkout(branch: String, in repository: RegisteredRepository) throws {
        let path = repository.localPath
        let changes = try runner.run("git", arguments: ["status", "--porcelain=v1"], workingDirectory: path).output
        guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError.failed(.init(output: "", error: "미커밋 변경 사항이 있습니다. 변경 사항을 커밋하거나 보관한 뒤 다시 시도하세요.", status: 1))
        }
        let local = try? runner.run("git", arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], workingDirectory: path)
        if local != nil {
            _ = try runner.run("git", arguments: ["switch", "--", branch], workingDirectory: path)
        } else {
            _ = try runner.run("git", arguments: ["switch", "-c", branch, "--track", "\(repository.remoteName)/\(branch)"], workingDirectory: path)
        }
    }

    func localBranches(in repository: RegisteredRepository) throws -> [RepositoryBranch] {
        let output = try runner.run("git", arguments: ["for-each-ref", "--format=%(refname:short)%00%(objectname:short)%00%(subject)", "refs/heads/"], workingDirectory: repository.localPath).output
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            return RepositoryBranch(repositoryID: repository.id, repositoryName: repository.fullName, name: parts[0], reference: "refs/heads/\(parts[0])", sha: parts[1], subject: parts[2], updatedAt: nil, isCurrent: false, isRemote: false)
        }
    }

    /// Reads the origin branches without switching the repository's working
    /// tree.  PR requests must use GitHub-visible branches, so the picker is
    /// deliberately backed by `refs/remotes/origin` rather than only local
    /// branches that may never have been pushed.
    func branches(in repository: RegisteredRepository, fetch: Bool = true) throws -> [RepositoryBranch] {
        // Keep the autocomplete current, but do not change the checked-out
        // branch or any worktree files.
        if fetch {
            _ = try? runner.run(
                "git",
                arguments: ["fetch", repository.remoteName, "--prune"],
                workingDirectory: repository.localPath
            )
        }
        let currentBranch = try? runner.run(
            "git",
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            workingDirectory: repository.localPath
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try runner.run(
            "git",
            arguments: ["for-each-ref", "--format=%(refname:short)%00%(objectname:short)%00%(subject)%00%(committerdate:iso-strict)", "refs/remotes/\(repository.remoteName)"],
            workingDirectory: repository.localPath
        ).output
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4,
                  parts[0] != "\(repository.remoteName)/HEAD",
                  parts[0].hasPrefix("\(repository.remoteName)/") else { return nil }
            let name = String(parts[0].dropFirst(repository.remoteName.count + 1))
            guard !name.isEmpty else { return nil }
            let date = ISO8601DateFormatter().date(from: parts[3])
            return RepositoryBranch(
                repositoryID: repository.id,
                repositoryName: repository.fullName,
                name: name,
                reference: parts[0],
                sha: parts[1],
                subject: parts[2],
                updatedAt: date,
                isCurrent: currentBranch == name,
                isRemote: true
            )
        }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }

    /// Prepares the registered repository itself as the single PR work folder.
    /// The PR's local branch is checked out (never detached) so the agent and user
    /// always work from an attached HEAD. A dirty checkout is stashed first.
    func prepareRepositoryWorkspace(repository: RegisteredRepository, pullRequest: PullRequest) throws -> String {
        let path = repository.localPath
        let remoteRef = "refs/heads/\(pullRequest.headBranch):refs/remotes/\(repository.remoteName)/\(pullRequest.headBranch)"
        _ = try runner.run("git", arguments: ["fetch", repository.remoteName, remoteRef], workingDirectory: path)
        let target = try runner.run("git", arguments: ["rev-parse", "\(repository.remoteName)/\(pullRequest.headBranch)"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)

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

    /// The freshly fetched PR branch is the source of truth. The GitHub list
    /// snapshot can be stale while a user is already working on that branch.
    func verifyHead(_ workspacePath: String, expectedSHA: String, expectedBranch: String) throws {
        _ = try verifiedHead(workspacePath, expectedSHA: expectedSHA, expectedBranch: expectedBranch)
    }

    /// Branch-card implementation never changes checkout or resets local history.
    func validateBranchReviewWorkspace(at path: String, branch: RepositoryBranch, reviewedSHA: String) throws -> String {
        guard !reviewedSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError.failed(.init(output: "", error: "검토한 커밋을 찾을 수 없습니다. 브랜치를 다시 리뷰하세요.", status: 1))
        }
        let head = try verifiedHead(path, expectedSHA: reviewedSHA, expectedBranch: branch.name)
        let reviewed = try runner.run("git", arguments: ["rev-parse", "--verify", "--end-of-options", "\(reviewedSHA)^{commit}"], workingDirectory: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = try runner.run("git", arguments: ["rev-parse", "--verify", "--end-of-options", "\(branch.reference)^{commit}"], workingDirectory: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == reviewed, remote == reviewed else {
            throw CommandError.failed(.init(output: "", error: "현재 브랜치 또는 원격 추적 브랜치가 검토한 커밋과 다릅니다. 변경 상태를 확인하고 다시 리뷰하세요.", status: 1))
        }
        return head
    }

    func verifiedHead(_ workspacePath: String, expectedSHA: String, expectedBranch: String) throws -> String {
        _ = expectedSHA
        let sha = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: workspacePath).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = try runner.run("git", arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: workspacePath).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard branch == expectedBranch else { throw CommandError.failed(.init(output: "", error: "작업 폴더가 PR 브랜치에 체크아웃되지 않았습니다.", status: 1)) }
        return sha
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

    /// Records the whole working tree, including untracked files, as a Git tree
    /// without touching the real index. Comparing two snapshots tells a card's
    /// own work apart from changes that were already in the folder.
    func snapshotTree(at path: String) throws -> String {
        let realIndex = try runner.run("git", arguments: ["rev-parse", "--git-path", "index"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return try withTemporaryIndex { index, environment in
            // Reusing the real index's stat cache avoids rehashing a large repository.
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: realIndex, relativeTo: URL(fileURLWithPath: path, isDirectory: true)),
                to: index
            )
            _ = try runner.run("git", arguments: ["add", "-A"], workingDirectory: path, environment: environment)
            return try runner.run("git", arguments: ["write-tree"], workingDirectory: path, environment: environment)
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func changedFiles(at path: String, from baselineTree: String, to resultTree: String) throws -> [String] {
        try runner.run("git", arguments: ["diff", "--name-only", "-z", "--no-renames", baselineTree, resultTree], workingDirectory: path)
            .output.split(separator: "\0").map(String.init)
    }

    func changes(at path: String, from baselineTree: String, to resultTree: String) throws -> String {
        try runner.run("git", arguments: ["diff", "--stat", baselineTree, resultTree], workingDirectory: path).output
    }

    private func withTemporaryIndex<Value>(_ body: (URL, [String: String]) throws -> Value) throws -> Value {
        let index = FileManager.default.temporaryDirectory.appending(path: "pr-review-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        return try body(index, ["GIT_INDEX_FILE": index.path])
    }

    /// The point where the PR branch left its base branch, so a re-review message
    /// can read the PR's whole history from its first commit.
    func pullRequestStart(at path: String, baseBranch: String, remote: String = "origin") throws -> String {
        _ = try runner.run("git", arguments: ["fetch", remote, "refs/heads/\(baseBranch):refs/remotes/\(remote)/\(baseBranch)"], workingDirectory: path)
        return try runner.run("git", arguments: ["merge-base", "\(remote)/\(baseBranch)", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads only committed review work after the PR snapshot, never drafts or
    /// commits from unrelated branches. Full bodies retain multi-line summaries.
    func reviewCommits(at path: String, branch: String, baseSHA: String, committedSHA: String) throws -> [(sha: String, message: String)] {
        let head = try verifiedHead(path, expectedSHA: baseSHA, expectedBranch: branch)
        let base = try runner.run("git", arguments: ["rev-parse", "--verify", "--end-of-options", "\(baseSHA)^{commit}"], workingDirectory: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Commits the developer added (and maybe pushed) after the app's review
        // commit belong to the same review work, so read up to the current HEAD.
        let end = head
        try requireAncestor(committedSHA, of: end, at: path)
        _ = try runner.run("git", arguments: ["merge-base", "--is-ancestor", base, end], workingDirectory: path)
        let log = try runner.run("git", arguments: ["log", "--reverse", "--format=%H%x00%B%x00", "\(base)..\(end)", "--"], workingDirectory: path).output
        let fields = log.components(separatedBy: "\0")
        return stride(from: 0, to: max(0, fields.count - 1), by: 2).map { index in
            (sha: fields[index].trimmingCharacters(in: .whitespacesAndNewlines),
             message: fields[index + 1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
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
        _ = expectedSHA
        let result = try runner.run("git", arguments: ["ls-remote", remote, "refs/heads/\(branch)"], workingDirectory: path)
        guard let remoteSHA = result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) else {
            throw CommandError.failed(.init(output: "", error: "원격 PR 브랜치의 HEAD를 확인할 수 없습니다.", status: 1))
        }
        let fetchedSHA = try runner.run("git", arguments: ["rev-parse", "\(remote)/\(branch)"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteSHA == fetchedSHA else {
            throw CommandError.failed(.init(output: "", error: "작업 폴더 준비 이후 원격 PR 브랜치가 변경되었습니다. 다시 시도하세요.", status: 1))
        }
    }
    func test(at path: String, command: String) throws -> CommandResult { try runner.run("/bin/zsh", arguments: ["-lc", command], workingDirectory: path) }

    func commit(at path: String, message: String, files: [String], branch: String, expectedSHA: String, remote: String = "origin") throws -> String {
        try verifyHead(path, expectedSHA: expectedSHA, expectedBranch: branch)
        try verifyRemoteHead(remote, branch: branch, expectedSHA: expectedSHA, at: path)
        guard !files.isEmpty else {
            throw CommandError.failed(.init(output: "", error: "이 작업 카드에서 변경된 파일을 찾을 수 없습니다.", status: 1))
        }
        // `git commit --only` does not add an untracked file by itself. Stage
        // only the reviewed paths first, then keep the commit scoped to those
        // paths so unrelated staged work is never included.
        _ = try runner.run("git", arguments: ["add", "--"] + files, workingDirectory: path)
        _ = try runner.run("git", arguments: ["commit", "--only", "-m", message, "--"] + files, workingDirectory: path)
        return try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits exactly what changed between two snapshots of a card's run.
    /// Earlier uncommitted work and edits made after the run stay in the working
    /// tree, even when they are in the same file as the card's work.
    func commit(at path: String, message: String, baselineTree: String, resultTree: String, branch: String, expectedSHA: String, remote: String = "origin") throws -> String {
        try verifyHead(path, expectedSHA: expectedSHA, expectedBranch: branch)
        try verifyRemoteHead(remote, branch: branch, expectedSHA: expectedSHA, at: path)
        let files = try changedFiles(at: path, from: baselineTree, to: resultTree)
        guard !files.isEmpty else {
            throw CommandError.failed(.init(output: "", error: "이 작업 카드에서 변경된 내용을 찾을 수 없습니다.", status: 1))
        }
        // A file keeps the patch byte-exact for non-UTF-8 sources, and explicit
        // options keep user diff settings from producing an unappliable patch.
        let patch = FileManager.default.temporaryDirectory.appending(path: "pr-review-patch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: patch) }
        _ = try runner.run("git", arguments: [
            "diff", "--binary", "--full-index", "--no-renames", "--no-color", "--no-ext-diff", "--no-textconv",
            "--src-prefix=a/", "--dst-prefix=b/", "--output=\(patch.path)", baselineTree, resultTree
        ], workingDirectory: path)
        try withTemporaryIndex { _, environment in
            _ = try runner.run("git", arguments: ["read-tree", "HEAD"], workingDirectory: path, environment: environment)
            do {
                _ = try runner.run("git", arguments: ["apply", "--cached", "--whitespace=nowarn", patch.path], workingDirectory: path, environment: environment)
            } catch CommandError.failed(let result) {
                throw CommandError.failed(.init(output: "", error: "이 코멘트의 변경을 현재 HEAD에 적용할 수 없습니다. 같은 부분을 수정한 미커밋 작업이 있으면 먼저 커밋하세요.\n\(result.error)", status: result.status))
            }
            _ = try runner.run("git", arguments: ["commit", "-m", message], workingDirectory: path, environment: environment)
        }
        // The commit used a temporary index, so realign the real one for these paths.
        _ = try runner.run("git", arguments: ["--literal-pathspecs", "reset", "-q", "--"] + files, workingDirectory: path)
        return try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gives one work card its own detached checkout of `sha`, so several cards
    /// can be implemented at once without mixing edits. Large binary files are
    /// left as LFS pointers because the agent only edits text sources.
    func createCardWorktree(at path: String, sha: String, root: URL = WorkspaceManager.cardWorktreeRoot) throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let worktree = root.appending(path: UUID().uuidString).path
        _ = try runner.run("git", arguments: ["worktree", "add", "--detach", worktree, sha], workingDirectory: path, environment: ["GIT_LFS_SKIP_SMUDGE": "1"])
        return worktree
    }

    func removeCardWorktree(_ worktree: String, from path: String) {
        if (try? runner.run("git", arguments: ["worktree", "remove", "--force", worktree], workingDirectory: path)) == nil {
            try? FileManager.default.removeItem(atPath: worktree)
            _ = try? runner.run("git", arguments: ["worktree", "prune"], workingDirectory: path)
        }
    }

    static var cardWorktreeRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "PRReviewAssistant/CardWorktrees", directoryHint: .isDirectory)
    }

    /// Commits a card worked in its own worktree on top of the branch's current
    /// HEAD. A 3-way merge keeps commits other cards made since the card started,
    /// and the commit holds only this card's change. The checkout's files are
    /// updated afterward, so they must have no uncommitted edits of their own.
    func commitCardWork(at path: String, message: String, baselineTree: String, resultTree: String, branch: String, remote: String = "origin") throws -> String {
        let head = try verifiedHead(path, expectedSHA: "", expectedBranch: branch)
        try verifyRemoteHead(remote, branch: branch, expectedSHA: "", at: path)
        let files = try changedFiles(at: path, from: baselineTree, to: resultTree)
        guard !files.isEmpty else {
            throw CommandError.failed(.init(output: "", error: "이 작업 카드에서 변경된 내용을 찾을 수 없습니다.", status: 1))
        }
        let dirty = try runner.run("git", arguments: ["--literal-pathspecs", "status", "--porcelain=v1", "--untracked-files=all", "--"] + files, workingDirectory: path).output
        guard dirty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError.failed(.init(output: "", error: "작업 폴더에 이 카드가 수정한 파일의 미커밋 변경이 있습니다. 먼저 커밋하거나 보관한 뒤 다시 커밋하세요.\n\(dirty)", status: 1))
        }
        func git(_ arguments: [String]) throws -> String {
            try runner.run("git", arguments: arguments, workingDirectory: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let baseCommit = try git(["commit-tree", baselineTree, "-m", "PR Review Assistant card base"])
        let resultCommit = try git(["commit-tree", resultTree, "-p", baseCommit, "-m", "PR Review Assistant card result"])
        let mergedTree: String
        do {
            mergedTree = try git(["merge-tree", "--write-tree", "--name-only", "--merge-base=\(baseCommit)", head, resultCommit])
        } catch CommandError.failed(let result) {
            let conflicted = result.output.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .prefix(while: { !$0.isEmpty }).joined(separator: "\n")
            throw CommandError.failed(.init(output: "", error: "다른 커밋과 같은 부분을 수정해 이 카드를 커밋할 수 없습니다. 최신 HEAD에서 다시 구현하세요.\n충돌 파일:\n\(conflicted)", status: result.status))
        }
        guard mergedTree != (try git(["rev-parse", "\(head)^{tree}"])) else {
            throw CommandError.failed(.init(output: "", error: "이 카드의 변경이 이미 현재 HEAD에 모두 들어 있습니다.", status: 1))
        }
        let commit = try git(["commit-tree", mergedTree, "-p", head, "-m", message])
        // Compare-and-swap: fails instead of dropping a commit made meanwhile.
        let committedFiles = try runner.run("git", arguments: ["diff", "--name-only", "-z", "--no-renames", head, commit], workingDirectory: path)
            .output.split(separator: "\0").map(String.init)
        _ = try git(["update-ref", "-m", "PR Review Assistant: card commit", "refs/heads/\(branch)", commit, head])
        _ = try git(["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree", "--"] + committedFiles)
        return commit
    }

    /// Starts merging the PR's base branch into the checked-out PR branch without
    /// committing. Returns the conflicted files (empty when the merge was clean
    /// or already up to date). The checkout must have no uncommitted edits.
    func beginBaseMerge(at path: String, baseBranch: String, remote: String = "origin") throws -> (conflicted: [String], inProgress: Bool) {
        let status = try runner.run("git", arguments: ["status", "--porcelain=v1"], workingDirectory: path).output
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError.failed(.init(output: "", error: "작업 폴더에 커밋되지 않은 변경이 있습니다. 커밋하거나 정리한 뒤 다시 시도하세요.", status: 1))
        }
        _ = try runner.run("git", arguments: ["fetch", remote, "refs/heads/\(baseBranch):refs/remotes/\(remote)/\(baseBranch)"], workingDirectory: path)
        _ = try? runner.run("git", arguments: ["merge", "--no-commit", "--no-ff", "\(remote)/\(baseBranch)"], workingDirectory: path)
        let inProgress = (try? runner.run("git", arguments: ["rev-parse", "-q", "--verify", "MERGE_HEAD"], workingDirectory: path)) != nil
        return (try unmergedFiles(at: path), inProgress)
    }

    func unmergedFiles(at path: String) throws -> [String] {
        try runner.run("git", arguments: ["diff", "--name-only", "--diff-filter=U"], workingDirectory: path).output
            .split(separator: "\n").map(String.init)
    }

    func abortMerge(at path: String) {
        _ = try? runner.run("git", arguments: ["merge", "--abort"], workingDirectory: path)
    }

    /// Commits the in-progress base merge after confirming that no file is still
    /// unmerged and that no resolved file keeps conflict markers.
    func commitBaseMerge(at path: String, resolvedFiles: [String], message: String) throws -> String {
        _ = try runner.run("git", arguments: ["add", "-u"], workingDirectory: path)
        guard try unmergedFiles(at: path).isEmpty else {
            throw CommandError.failed(.init(output: "", error: "아직 해결되지 않은 충돌 파일이 있습니다.", status: 1))
        }
        for file in resolvedFiles {
            guard let text = try? String(contentsOfFile: "\(path)/\(file)", encoding: .utf8) else { continue }
            let hasMarker = text.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { $0.hasPrefix("<<<<<<< ") || $0.hasPrefix(">>>>>>> ") }
            guard !hasMarker else {
                throw CommandError.failed(.init(output: "", error: "\(file)에 충돌 표시(<<<<<<<)가 남아 있습니다.", status: 1))
            }
        }
        _ = try runner.run("git", arguments: ["commit", "-m", message], workingDirectory: path)
        return try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func pushCommittedChanges(at path: String, branch: String, expectedRemoteSHA: String, committedSHA: String, remote: String = "origin") throws {
        _ = expectedRemoteSHA
        let localSHA = try runner.run("git", arguments: ["rev-parse", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireAncestor(committedSHA, of: localSHA, at: path)
        let currentBranch = try runner.run("git", arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentBranch == branch else {
            throw CommandError.failed(.init(output: "", error: "작업 폴더가 PR 브랜치에 체크아웃되지 않았습니다.", status: 1))
        }
        let result = try runner.run("git", arguments: ["ls-remote", remote, "refs/heads/\(branch)"], workingDirectory: path)
        guard let remoteSHA = result.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init) else {
            throw CommandError.failed(.init(output: "", error: "원격 PR 브랜치의 HEAD를 확인할 수 없습니다.", status: 1))
        }
        let fetchedSHA = try runner.run("git", arguments: ["rev-parse", "\(remote)/\(branch)"], workingDirectory: path)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remoteSHA == localSHA || remoteSHA == fetchedSHA else {
            throw CommandError.failed(.init(output: "", error: "작업 폴더 준비 이후 원격 PR 브랜치가 변경되었습니다. 다시 시도하세요.", status: 1))
        }
        _ = try runner.run("git", arguments: ["push", remote, "HEAD:\(branch)"], workingDirectory: path)
        let confirmed = try runner.run("git", arguments: ["ls-remote", remote, "refs/heads/\(branch)"], workingDirectory: path)
        let confirmedSHA = confirmed.output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
        guard confirmedSHA == localSHA else {
            throw CommandError.failed(.init(output: "", error: "푸시 후 원격 PR 브랜치 SHA를 확인하지 못했습니다.", status: 1))
        }
    }

    /// The app's recorded review commit must still be in HEAD's history; later
    /// commits are allowed, but a reset or rewrite that dropped it is not.
    private func requireAncestor(_ committedSHA: String, of head: String, at path: String) throws {
        guard (try? runner.run("git", arguments: ["merge-base", "--is-ancestor", committedSHA, head], workingDirectory: path)) != nil else {
            throw CommandError.failed(.init(output: "", error: "작업 폴더 HEAD에 마지막 리뷰 반영 커밋이 없습니다. 브랜치를 되돌렸거나 커밋을 다시 썼는지 확인하세요.", status: 1))
        }
    }
}
