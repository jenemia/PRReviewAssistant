# 기능별 에이전트 모델 지정

> 상태 🟢 구현 완료, QA 대기 · 최종 갱신 2026-11-24
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
| 기능 16개별 에이전트(Cursor·Claude 등) 덮어쓰기 | 기능별 상세 모델 ID 덮어쓰기 |
| LLM Agent 탭: 에이전트 접힘 목록(연결·기본 모델·연결 확인), "기능별 에이전트" | 브랜치 리뷰 역할·단계별 모델·에이전트 지정 |
| 기본 모델 프리셋 목록을 한 곳(`AgentProvider.modelPresets`)으로 모음 | 카드에서 일회성 모델 변경, CLI 모델 목록 자동 조회 |
| 모델 목록 행: 모델별 연결 확인, 사용 여부 토글 | 직접 입력한 모델 ID의 행 표시·토글 |

## 결정

| 항목 | 결정 |
|---|---|
| 결정 — 지정 대상 | '기능별 에이전트' 목록은 에이전트만 고른다. 카테고리 단위로 전체 적용하거나, 끄고 기능별로 고른다. 상세 모델은 각 에이전트 접힘 안의 '기능별 모델'에서, 그 에이전트를 쓰는 기능에 한해 지정한다. 기본 에이전트는 이름 옆에 초록 '*활성화중'으로 표시한다. |
| 결정 — 저장 단위 | 기능 → 에이전트(`agentFeatureProviders`). 에이전트별 기본 모델은 기존 필드(`agentModel` 등)에 저장한다. |
| 결정 — 설정 단위 | 사용자가 보는 기능 16개. 브랜치 리뷰의 조사·리뷰·통합 단계와 UnitTest의 선별·생성은 한 설정으로 묶는다. |
| 결정 — 연결 확인 방식 | 모델마다 빈 임시 폴더에서 짧은 질문("Reply with exactly: OK")을 실제로 보낸다. 응답이 오면 연결됨. 자동 실행하지 않고 버튼으로만 실행한다. Cursor는 앱 전용 고정 폴더(`ModelCheckWorkspace`)에서 실행하고, 작업 공간 신뢰가 필요하면 Terminal에서 승인한 뒤 다시 확인한다(`needsWorkspaceTrust`). |
| 결정 — 사용 여부 | 끈 모델은 기본 모델·기능별 모델 선택 목록에서 숨긴다. 사용 중인 모델(기본 모델, 기능별 모델)은 끌 수 없다. |
| 결정 — 에이전트 사용 여부 | 에이전트(Cursor·Codex·Claude)마다 켜고 끈다(`disabledAgentProviders`). 끄면 그 에이전트를 지정한 기능은 기본 에이전트로 실행하고, 기능별 선택 목록에서도 숨긴다. 지정값은 지우지 않아 다시 켜면 복원된다. 기본 에이전트는 끌 수 없다(다른 에이전트를 기본으로 지정한 뒤 끈다). |
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

- **에이전트·모델 결정.** `ReviewStore.provider(for:)`가 기능 덮어쓰기 또는 앱 기본 `agentProvider`를 돌려준다. `ReviewStore.model(for:)`는 그 에이전트의 `effectiveAgentModel(for:)`을 돌려준다. 위 16개 진입점은 `agent(for:)`와 `model(for:)`를 실행 시작 시 고정하므로 변경은 다음 실행부터 적용된다.
- **에이전트 끄기.** `provider(for:)`는 덮어쓰기 에이전트가 꺼져 있으면 `agentProvider`를 돌려준다. 토글은 `ProviderAgentFold` 라벨에 있고 `setAgentProvider`가 기본 에이전트 끄기를 막는다.
- **저장.** `PersistedState.agentFeatureProviders: [AgentFeature: AgentProvider]`. 기능별 모델은 `agentFeatureModels: [AgentProvider: [AgentFeature: String]]`에 저장하고 `model(for:)`가 비어 있지 않으면 우선한다. 기능별 모델로 쓰는 모델은 끌 수 없다.
- **모델 목록.** `ProviderModelListSection`이 에이전트 접힘 안에서 프리셋을 행으로 보여 준다(연결 확인·사용 토글). 기본 모델 선택은 라디오 목록이다.
- **화면.** LLM Agent 탭은 `ScrollView` 안에 기본 에이전트 라디오, `ProviderAgentFold`(접힘), `FeatureProviderSection`(기능별 에이전트 이름만) 순이다.

## 사이드 이펙트

| 항목 | 영향과 완화 |
|---|---|
| 사이드 이펙트 — 대화 이어가기 | `AgentSession.matches`가 모델을 비교하므로 대화 중 모델을 바꾸면 새 세션으로 시작한다. 화면 안내문에 적는다. |
| 사이드 이펙트 — 브랜치 리뷰 조사 캐시 | 캐시 키에 모델이 있어 모델을 바꾸면 조사를 다시 한다. 의도한 동작. |
| 사이드 이펙트 — 잘못된 모델 ID | 앱에서 검증하지 않는다. CLI 오류가 기존처럼 카드에 표시된다. |
| 사이드 이펙트 — 연결 확인 비용 | 확인마다 모델 호출이 한 번 일어난다(Cursor는 수 초~수십 초). 버튼으로만 실행하고 안내문에 적는다. |
| 사이드 이펙트 — 저장 데이터 | 새 키 추가. 예전 저장 파일은 빈 값으로 읽힌다. |

## 테스트 시나리오

| 항목 | 상황 | 기대 결과 |
|---|---|---|
| 테스트 — 기본값 | 덮어쓰기 없음 | 모든 기능이 `effectiveAgentModel`을 쓴다. |
| 테스트 — 단일 덮어쓰기 | 한 기능만 덮어씀 | 그 기능만 지정 모델, 나머지는 기본 모델. |
| 테스트 — 에이전트 전환 | Claude Code에 덮어쓰기 후 Cursor로 전환, 다시 복귀 | Cursor에서는 기본 모델, 복귀하면 덮어쓰기 복원. |
| 테스트 — 공백 덮어쓰기 | 공백만 입력 | 기본 모델을 따른다. |
| 테스트 — 저장 | 저장 후 다시 읽기, 예전 저장 파일 | 덮어쓰기 유지, 예전 파일은 빈 값. |
| 테스트 — 모델 끄기 | 사용 중이 아닌 모델을 끔 | 선택 목록에서 빠지고 다시 켜면 돌아온다. |
| 테스트 — 사용 중 모델 | 기본 모델·기능별 모델로 쓰는 모델을 끄려 함 | 꺼지지 않는다(토글 비활성). |
| 테스트 — 끈 모델 저장 | 저장 후 다시 읽기, 예전 저장 파일 | 유지, 예전 파일은 빈 값. |
| 테스트 — 에이전트 끄기 | 기능에 Codex를 지정한 뒤 Codex를 끔, 다시 켬 | 끄면 기본 에이전트와 그 모델, 켜면 Codex로 복원. |
| 테스트 — 기본 에이전트 끄기 | 기본 에이전트를 끄려 함 | 꺼지지 않는다(토글 비활성). |
| 테스트 — 끈 에이전트 저장 | 저장 후 다시 읽기, 예전 저장 파일 | 유지, 예전 파일은 빈 값. |
| 테스트 — 기능별 모델 | 기능 에이전트와 모델을 지정, 공백으로 변경 | 지정 모델 사용, 공백이면 에이전트 기본 모델. |
| 테스트 — 신뢰 오류 구분 | 작업 공간 신뢰 필요 오류 | 연결 상태가 `needsWorkspaceTrust`. |
| 테스트 — 연결 확인 | 정상 모델과 잘못된 모델 확인 | 정상 모델은 연결됨, 잘못된 모델은 오류 내용 표시. |
| 테스트 — 실제 실행 인자 | 브랜치 리뷰와 추가 질문에 다른 모델 지정 후 실행 | 각 CLI 호출의 `--model`이 지정 모델이다. |

## 미결

없음.
