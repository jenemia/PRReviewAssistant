---
name: unittest-writer
description: Spec의 테스트 시나리오에서 UnitTest 케이스를 뽑아 작성하는 진입점. 코드를 읽고 어떤 케이스별 skill(C#, Unity, 시간·시즌, 재화)을 함께 적용할지 고른다. 사람이 Claude Code로 테스트를 쓸 때 사용한다. Triggers: 테스트 작성해, 테스트 만들어, UnitTest 작성, write unit test.
---

# UnitTest 작성 (진입점)

## 절차

1. 대상 Spec의 `## 5. 테스트 시나리오`(상황 → 기대 결과)를 케이스 목록으로 삼는다. 시나리오가 없으면 Spec `## 2. 규칙`의 문장 하나당 케이스 하나를 만든다.
2. 테스트를 쓰기 전에 변경에서 비즈니스 모델을 추출한다. 계산식, 지급·자격 조건, 기간·주기, 상태 전이, 불변식을 `입력·조건 → 기대 결과` 규칙 하나씩으로 쓰고, 기대값 출처를 spec / diff / code로 표시한다. code 출처 규칙은 경계와 불변식만 검증한다. 규칙마다 테스트를 하나 이상 대응시킨다.
3. 대상 코드의 public API와 시그니처만 확인한다. 기대값은 코드가 아니라 **Spec에서** 가져온다. 코드와 Spec이 다르면 코드에 맞춰 assert하지 말고 불일치를 보고한다.
4. 아래 skill을 해당될 때만 함께 읽는다.

| 코드 특징 | 함께 적용 |
|---|---|
| 항상 | `unittest-csharp-base` |
| `UnityEngine`, `MonoBehaviour`, `ScriptableObject` 참조 | `unittest-unity-base` (순수 로직이 아니면 테스트하지 않고 보고) |
| 시각, 일차, 주기, 시즌, 기간, 만료 | `unittest-domain-time-season` |
| 골드, 가격, 할인, 차감, 지급, 보상 | `unittest-domain-currency` |
| 확률, 가챠, 드랍, 가중치, 천장, 상태 전이 | `unittest-domain-probability` |

5. Production 코드는 수정하지 않는다. 원본의 public API를 호출할 수 있으면 그것을 쓰고, 컴파일·생성이 안 되면 규칙을 테스트 안에 옮겨 검증한다(`unittest-unity-base`의 원본 로직 복제). 옮길 규칙이 없을 때만 `needs_source_change`로 보고한다.
6. 만든 테스트의 이름 규칙은 `unittest-csharp-base`를 따른다. 그래야 SpecGuard가 Spec과 연결한다.
