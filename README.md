# PR Review Assistant for macOS

사람 리뷰어의 GitHub PR 피드백을 감지하고, PR 브랜치를 명시적으로 체크아웃한 상태에서 Cursor Agent로 대응을 분석하는 macOS 앱입니다.

## 제공 기능

- GitHub CLI 인증 상태 확인 및 로컬 GitHub 저장소 등록
- 등록 저장소의 열린 PR·라인 코멘트 폴링과 macOS 알림
- PR의 `head`/`base`/SHA 표시 및 댓글별 검토
- PR 브랜치 체크아웃, 최신 SHA·브랜치 연결 상태 검증, Cursor 읽기 전용 분석
- 사용자 승인 후 테스트 실행, 커밋·일반 푸시, 재리뷰 요청
- 등록 저장소·처리한 코멘트·분석 결과의 로컬 보관
- macOS 기본 UI와 기본/다크 테마

## 실행

배포본은 `dist/PR Review Assistant.app`입니다. Finder에서 열거나 아래 명령으로 실행할 수 있습니다.

```zsh
open "dist/PR Review Assistant.app"
```

개발 실행:

```zsh
swift run PRReviewAssistant
```

배포본 재생성:

```zsh
scripts/package-app.sh
```

## 사전 조건

- macOS 14 이상
- GitHub CLI 설치 및 로그인: `gh auth login`
- Git 설치
- Cursor Agent 로그인(분석 기능): `cursor agent login`

앱은 GitHub 토큰을 저장하지 않고 `gh` 인증을 사용합니다. 분석은 기본적으로 읽기 전용이며, 푸시와 재리뷰 요청은 앱에서 각각 승인해야 합니다.

## 역할별 리뷰

앱은 실행할 때 `~/.cursor/agents/`의 전역 역할 파일을 읽고, 담당별로 독립된 Cursor CLI 세션을 실행합니다. 전역 파일을 수정하면 다음 리뷰부터 적용됩니다. 모든 리뷰 세션은 앱에서 선택한 모델과 읽기 전용 ask 모드를 사용합니다. JSON 완료 응답의 성공 상태와 최종 본문을 검증하며, 계획 생성 도구를 보고서 출력으로 사용하지 않습니다.

- **브랜치 리뷰:** `spec-search-agent`와 `structure-agent`가 병렬 조사한 뒤, `code-reviewer`와 `maintenance-reviewer`가 병렬 검토합니다. 구현 담당은 `scope-guard` 기준도 적용하고, 유지보수 담당은 위험한 변경에 `risk-guard` 기준을 적용합니다. 마지막 통합 세션이 근거를 확인하고 중복·충돌을 정리합니다.
- **리뷰 코멘트 검토:** PR 전체 분석과 코멘트 카드의 첫 분석·재시도에 적용됩니다. `structure-agent`가 관련 기능별 실제 경로와 방어 로직을 조사하고, `code-reviewer`가 코멘트별 지적의 타당성과 제안한 수정의 적절성을 따로 검토합니다. 마지막 통합 세션이 판단과 검증 공백을 정리합니다. 카드의 후속 질문은 기존 단일 세션으로 답변합니다.

필요한 역할의 `.md` 파일이 없거나 비어 있으면 모델 호출 전에 오류를 표시합니다. 단계가 실패하거나 빈 응답을 반환하면 후속 단계와 결과 저장을 진행하지 않습니다. 코드는 시작 시 고정한 SHA를 기준으로 조사하며, 완료 시 head 또는 base가 바뀌었으면 재검토가 필요합니다. 테스트·빌드 실행은 리뷰에 포함하지 않고 필요한 검증으로 보고합니다.

Cursor CLI가 종료 코드 0과 함께 표준 오류(stderr)에만 승인·인증 요청을 반환해도 해당 안내를 보존합니다. 코멘트 카드에서는 기존 권한 승인 창으로 연결하며, 오류에는 실패한 담당 단계도 표시합니다.

브랜치 리뷰는 총 5회, 코멘트 검토는 총 3회 모델을 호출하므로 단일 세션보다 사용량이 늘고 시간이 더 걸릴 수 있습니다. 전역 역할은 복사하거나 변경하지 않습니다. 이 흐름은 현재 앱의 Cursor 실행 경로에 적용되며 Codex 역할 파일은 사용하지 않습니다.

# 배포용 DMG 만들기

다른 Mac에서 보안 경고 없이 앱을 열려면, DMG 파일 자체가 아니라 앱을 **Developer ID Application** 인증서로 서명하고 Apple 공증(notarization)을 받아야 합니다. `scripts/package-release-dmg.sh`는 이 과정을 수행합니다.

```sh
export SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='PRReviewAssistantNotary'
scripts/package-release-dmg.sh
```

`NOTARY_PROFILE`은 한 번만 아래 명령으로 로그인 키체인에 만들어 둡니다.

```sh
xcrun notarytool store-credentials 'PRReviewAssistantNotary'
```
