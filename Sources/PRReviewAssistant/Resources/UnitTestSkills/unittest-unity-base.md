---
name: unittest-unity-base
description: Unity 코드(MonoBehaviour, ScriptableObject 등)가 섞인 대상의 UnitTest 판단 기준. 순수 로직과 엔진 의존을 구분하고, 테스트 불가능하면 억지로 만들지 않고 보고한다. EditMode와 PlayMode 구분. Triggers: UnityEngine, MonoBehaviour, ScriptableObject, GameObject, SerializeField.
---

# Unity 의존 코드의 UnitTest 기준

## 먼저 판별한다
| 대상 | 판단 |
|---|---|
| `UnityEngine` 참조가 없는 순수 C# 클래스 | 일반 UnitTest 가능 (`unittest-csharp-base`) |
| `MonoBehaviour`·`ScriptableObject` 상속, `GameObject`·`Transform`·`Debug.Log` 사용 | `unity_dependent`로 보고하고 파일을 만들지 않는다 |
| 순수 로직이 MonoBehaviour 안에 섞여 있음 | `needs_source_change`로 보고 (로직 분리가 필요하다고 이유에 적는다) |

## 하지 않는 것
- `UnityEngine`을 mock/stub으로 흉내 내거나 테스트 프로젝트에 Unity 어셈블리를 끌어오기.
- 테스트를 통과시키려고 대상 코드를 고치기. 분리 제안은 보고에만 적는다.
- `Debug.Log` 호출만 있는 코드처럼 검증할 동작이 없는 대상에 형식적인 테스트 만들기.

## 테스트 가능한 경우의 주의
- Unity 테스트 프레임워크 기준으로는 EditMode(엔진 없이 로직)가 대상이다. PlayMode(씬·프레임 필요)는 UnitTest 범위가 아니다.
- 프리팹, 씬, 에셋 변경은 UnitTest 대상이 아니다. 수동 검사로 남긴다.
