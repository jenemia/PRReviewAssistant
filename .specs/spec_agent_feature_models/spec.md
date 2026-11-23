# 기능별 에이전트 모델 지정

> 상태 🟢 구현 완료, QA 대기 · 최종 갱신 2026-11-23
> 진행 [PROGRESS.md](./PROGRESS.md)

---

## 문서 맵

| 문서 | 내용 | 주로 읽는 때 |
|---|---|---|
| [spec.md](./spec.md) | 범위, 동작, 수용 기준 | 구현 및 검토 |
| [PROGRESS.md](./PROGRESS.md) | 개발 및 QA 진행 | 상태 확인 |

## 목적과 범위

에이전트가 개입하는 기능마다 사용할 모델을 설정 창에서 따로 지정한다. 지정하지 않은 기능은 지금처럼 에이전트 기본 모델을 쓴다.

| 포함 | 미포함 |
|---|---|
| 기능 16개별 모델 덮어쓰기(에이전트별 저장) | 기능별 에이전트(제공자) 변경 |
| LLM Agent 탭의 "기능별 모델" 구역, "모두 기본으로" | 브랜치 리뷰 역할·단계별 모델 지정 |
| 기본 모델 프리셋 목록을 한 곳(`AgentProvider.modelPresets`)으로 모음 | 카드에서 일회성 모델 변경, CLI 모델 목록 자동 조회 |

## 결정

| 항목 | 결정 |
|---|---|
| 결정 — 지정 대상 | 모델만 지정한다. 에이전트는 앱 전체 설정을 따른다. |
| 결정 — 저장 단위 | 기능 × 에이전트. 에이전트마다 모델 ID 체계가 달라 에이전트를 바꿔도 각자의 덮어쓰기가 유지된다. |
| 결정 — 설정 단위 | 사용자가 보는 기능 16개. 브랜치 리뷰의 조사·리뷰·통합 단계와 UnitTest의 선별·생성은 한 설정으로 묶는다. |
| 결정 — 기본값 | 모든 기능이 "기본 모델 따름". 업데이트 직후 동작은 이전과 같다. |

## 기능 목록

| 묶음 | 기능(`AgentFeature`) | 진입점(`ReviewStore`) |
|---|---|---|
| 브랜치 | 브랜치 리뷰 `branchReview` | `runBranchReview` |
| | 브랜치 리뷰 추가 질문 `branchQuestion` | `runBranchMessage` |
| | 브랜치 추가 구현 `branchImplementation` | `implementBranchCard` |
| | PR 제안서 작성 `pullRequestProposal` | `preparePullRequestProposal` |
| | 브랜치 UnitTest `branchUnitTest` | `verifyUnitTests` |
| | 브랜치 퀴즈 `branchQuiz` | `makeBranchQuiz` |
| PR | 리뷰 코멘트 분석 `reviewAnalysis` | `startAnalysis` |
| | 카드 질문·대화 `reviewQuestion` | `runAgentMessage` |
| | 리뷰 반영 구현 `reviewImplementation` | `startImplementation` |
| | 머지 충돌 해결 `conflictResolution` | `resolveConflicts` |
| | 재리뷰 요청 메시지 `reReviewMessage` | `generateReReviewMessage` |
| | 리뷰 답변 초안 `reviewResponseDraft` | `generateReviewResponseDraft` |
| Spec·세션 | spec 기반 UnitTest `specUnitTest` | `verifySpecUnitTests` |
| | 세션 요약 `sessionSummary` | `summarizeCursorSession` |
| | 세션 spec 분류 `sessionSpecClassification` | `classifyCursorSessions` |
| 규칙 | 부모 브랜치 규칙 제안 `parentBranchRules` | `proposeParentBranchRules` |

## 구현부

- **모델 결정.** `ReviewStore.model(for:)`가 현재 에이전트의 해당 기능 덮어쓰기(앞뒤 공백 제거)를 돌려주고, 비어 있으면 `effectiveAgentModel`을 돌려준다. 위 16개 진입점은 실행 시작 시 이 값을 읽어 고정하므로 변경은 다음 실행부터 적용된다.
- **저장.** `PersistedState.agentFeatureModels: [AgentProvider: [AgentFeature: String]]`. 두 enum은 `CodingKeyRepresentable`이라 JSON 객체로 저장된다. 키가 없거나 읽을 수 없는 값(이후 버전에서 추가된 기능 등)이면 빈 값으로 읽는다.
- **화면.** `SettingsView.swift`의 `FeatureModelSection`을 Cursor·외부 에이전트 설정 Form 모두에 붙인다. 행마다 "기본 모델 따름 (현재값)", 프리셋, "직접 입력…"(모델 ID 입력칸 표시)을 고른다. "모두 기본으로"는 현재 에이전트의 덮어쓰기만 지운다.

## 사이드 이펙트

| 항목 | 영향과 완화 |
|---|---|
| 사이드 이펙트 — 대화 이어가기 | `AgentSession.matches`가 모델을 비교하므로 대화 중 모델을 바꾸면 새 세션으로 시작한다. 화면 안내문에 적는다. |
| 사이드 이펙트 — 브랜치 리뷰 조사 캐시 | 캐시 키에 모델이 있어 모델을 바꾸면 조사를 다시 한다. 의도한 동작. |
| 사이드 이펙트 — 잘못된 모델 ID | 앱에서 검증하지 않는다. CLI 오류가 기존처럼 카드에 표시된다. |
| 사이드 이펙트 — 저장 데이터 | 새 키 추가. 예전 저장 파일은 빈 값으로 읽힌다. |

## 테스트 시나리오

| 항목 | 상황 | 기대 결과 |
|---|---|---|
| 테스트 — 기본값 | 덮어쓰기 없음 | 모든 기능이 `effectiveAgentModel`을 쓴다. |
| 테스트 — 단일 덮어쓰기 | 한 기능만 덮어씀 | 그 기능만 지정 모델, 나머지는 기본 모델. |
| 테스트 — 에이전트 전환 | Claude Code에 덮어쓰기 후 Cursor로 전환, 다시 복귀 | Cursor에서는 기본 모델, 복귀하면 덮어쓰기 복원. |
| 테스트 — 공백 덮어쓰기 | 공백만 입력 | 기본 모델을 따른다. |
| 테스트 — 저장 | 저장 후 다시 읽기, 예전 저장 파일 | 덮어쓰기 유지, 예전 파일은 빈 값. |
| 테스트 — 실제 실행 인자 | 브랜치 리뷰와 추가 질문에 다른 모델 지정 후 실행 | 각 CLI 호출의 `--model`이 지정 모델이다. |

## 미결

없음.
