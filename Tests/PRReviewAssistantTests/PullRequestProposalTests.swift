import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("PR request proposal")
struct PullRequestProposalTests {
    @Test("Agent JSON 제안을 파싱하고 선택 필드에 기본값을 적용한다")
    func parsesProposal() throws {
        let output = """
        ```json
        {"skillName":"xp-pr-create","head":"sprint/s26/fix/mask","base":"sprint/s26/main","title":"Mask 수정","body":"## Summary\\n- 수정"}
        ```
        """

        let proposal = try CursorAgent.parsePullRequestProposal(output)

        #expect(proposal.skillName == "xp-pr-create")
        #expect(proposal.base == "sprint/s26/main")
        #expect(proposal.baseSource == "agent")
        #expect(proposal.reviewers.isEmpty)
        #expect(proposal.warnings.isEmpty)
        #expect(proposal.commitCount == 0)
        #expect(proposal.changedFiles == 0)
    }

    @Test("JSON이 없는 Agent 응답은 거부한다")
    func rejectsNonJSONProposal() {
        #expect(throws: (any Error).self) {
            try CursorAgent.parsePullRequestProposal("base는 sprint/s26/main입니다.")
        }
    }

    @Test("비정상 커밋 차단 기준을 고정한다")
    func keepsSuspiciousCommitLimit() {
        #expect(PullRequestProposalVerifier.suspiciousCommitLimit == 500)
    }

    @Test("검증기가 원격 base와 head를 대조해 실제 PR 범위를 계산한다")
    func verifiesGitRange() throws {
        let practice = LocalPracticeRepository()
        let fixture = try practice.create()
        defer { try? practice.remove(at: fixture.repository.localPath) }
        let branch = RepositoryBranch(
            repositoryID: fixture.repository.id,
            repositoryName: fixture.repository.fullName,
            name: fixture.pullRequest.headBranch,
            reference: "origin/\(fixture.pullRequest.headBranch)",
            sha: fixture.pullRequest.headSHA,
            subject: fixture.pullRequest.title,
            updatedAt: nil,
            isCurrent: false,
            isRemote: true
        )
        let proposal = PullRequestProposal(
            skillName: "fixture-pr-skill",
            head: branch.name,
            base: fixture.pullRequest.baseBranch,
            baseSource: "skill",
            reviewers: [],
            title: fixture.pullRequest.title,
            body: "테스트"
        )

        let verified = try PullRequestProposalVerifier().verify(
            proposal,
            repository: fixture.repository,
            branch: branch
        )

        #expect(verified.commitCount == 1)
        #expect(verified.changedFiles == 1)
    }
}
