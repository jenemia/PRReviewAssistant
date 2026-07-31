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
