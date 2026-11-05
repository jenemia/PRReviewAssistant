---
name: unittest-writer
description: Spec의 테스트 시나리오에서 UnitTest 케이스를 뽑아 작성하는 진입점. 코드를 읽고 어떤 케이스별 skill(C#, Unity, 시간·시즌, 재화)을 함께 적용할지 고른다. 사람이 Claude Code로 테스트를 쓸 때 사용한다. Triggers: 테스트 작성해, 테스트 만들어, UnitTest 작성, write unit test.
---

# UnitTest 작성 (진입점)

## 절차

1. 대상 Spec의 `## 5. 테스트 시나리오`(상황 → 기대 결과)를 케이스 목록으로 삼는다. 시나리오가 없으면 Spec `## 2. 규칙`의 문장 하나당 케이스 하나를 만든다.
2. 대상 코드의 public API와 시그니처만 확인한다. 기대값은 코드가 아니라 **Spec에서** 가져온다. 코드와 Spec이 다르면 코드에 맞춰 assert하지 말고 불일치를 보고한다.
3. 아래 skill을 해당될 때만 함께 읽는다.

| 코드 특징 | 함께 적용 |
|---|---|
| 항상 | `unittest-csharp-base` |
| `UnityEngine`, `MonoBehaviour`, `ScriptableObject` 참조 | `unittest-unity-base` (순수 로직이 아니면 테스트하지 않고 보고) |
| 시각, 일차, 주기, 시즌, 기간, 만료 | `unittest-domain-time-season` |
| 골드, 가격, 할인, 차감, 지급, 보상 | `unittest-domain-currency` |

4. Production 코드는 수정하지 않는다. 테스트하려면 코드 변경이 필요하면 `needs_source_change`로 보고한다.
5. 만든 테스트의 이름 규칙은 `unittest-csharp-base`를 따른다. 그래야 SpecGuard가 Spec과 연결한다.
