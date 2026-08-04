import Foundation
import Testing
@testable import PRReviewAssistant

@Suite("GitHub Release 응답")
struct GitHubReleaseTests {
    @Test("html_url을 업데이트 페이지 주소로 읽는다")
    func decodesReleasePageURL() throws {
        let data = Data("""
        {"tag_name":"v0.2.3","name":"PR Review Assistant 0.2.3","html_url":"https://github.com/jenemia/PRReviewAssistant/releases/tag/v0.2.3","body":null}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let release = try decoder.decode(GitHubRelease.self, from: data)

        #expect(release.tagName == "v0.2.3")
        #expect(release.htmlURL == "https://github.com/jenemia/PRReviewAssistant/releases/tag/v0.2.3")
    }
}
