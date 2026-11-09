---
name: unittest-unity-base
description: Unity 코드(MonoBehaviour, ScriptableObject, Mathf, Vector3 등)가 섞인 대상의 UnitTest 판단 기준. 앱의 UnityEngine 대체 소스로 실행 가능한 범위, 엔진 전용 API, Humble Object 분리 보고, EditMode와 PlayMode 구분. Triggers: UnityEngine, MonoBehaviour, ScriptableObject, GameObject, SerializeField, Mathf, Vector3.
---

# Unity 의존 코드의 UnitTest 기준

Unity 프로젝트(`ProjectSettings/ProjectVersion.txt`가 있는 저장소)는 UnityEngine 대체 소스와 함께 C# 9로 검증한다. 대체 소스는 실제 Unity와 같은 결과를 내는 API만 실행을 허용한다.

## 먼저 판별한다
| 대상 | 판단 |
|---|---|
| `UnityEngine` 참조가 없는 순수 C# 클래스 | 일반 UnitTest (`unittest-csharp-base`) |
| Mathf, Vector2/3, Vector2Int/3Int, Inspector 특성, Debug.Log만 쓰는 클래스 | 일반 UnitTest. 테스트에서도 이 API는 쓸 수 있다 |
| ScriptableObject 설정·데이터 | `ScriptableObject.CreateInstance<T>()`로 만들어 public API 검증. Awake·OnEnable이 호출된다. `[SerializeField] private` 값은 기본값만 검증 |
| MonoBehaviour 안의 static 순수 메서드 | 클래스를 만들지 않고 static 메서드만 호출해 검증 |
| MonoBehaviour 인스턴스 메서드, 싱글톤·풀·이벤트·서버 시각에 묶인 규칙 | 원본 로직 복제(`verification: "replica"`)로 검증 |
| Time, Random, PlayerPrefs, Application, Resources를 내부에서 읽음 | 값을 인자로 받는 public 경로가 있으면 그것을, 없으면 복제 방식에서 그 값을 인자로 바꿔 검증 |
| UI, TMPro, Addressables 등 대체 소스에 없는 API 때문에 컴파일 불가 | 원본 로직 복제로 검증 |
| 연출·렌더링·물리처럼 엔진 동작 자체, 옮길 결정 로직이 없음 | `unity_dependent` |

## 검증 방식 우선순위
1. **원본 직접 호출** (`verification: "source"`): public 또는 public static API로 규칙을 호출할 수 있고 컴파일되면 반드시 이것을 쓴다.
2. **원본 로직 복제** (`verification: "replica"`): 규칙 부분(조건·계산·상태 전이)만 테스트 파일 안 private 중첩 클래스로 옮긴다. 싱글톤·엔진·시간 값은 메서드 인자로 바꾸고, 연산자·경계·상수는 원본과 똑같이 옮긴다. 고치거나 개선하지 않는다. 옮긴 메서드 위에 `// 원본: <대상 경로>`와 원본 메서드 이름을 단다. 대상 소스는 컴파일하지 않으므로 원본 타입을 참조하지 않는다. 순수 C# enum·데이터 타입은 dependencies로 넣어 쓸 수 있다.
3. **생성 불가**: 옮길 규칙이 하나도 없을 때만.

복제 테스트는 원본이 바뀌어도 따라가지 않는다. 결과에 "원본 로직 복제 검증"으로 표시되며, 장기적으로는 규칙을 순수 C# 클래스로 분리(Humble Object)해 원본 직접 호출로 바꾸는 것이 좋다. 분리 제안은 reason에 적고 코드는 고치지 않는다.

## 대체 소스에서 지켜야 할 Unity 동작
- `Mathf.RoundToInt`/`Round`는 .5에서 짝수 쪽으로 반올림한다 (2.5 → 2, 3.5 → 4).
- `Mathf.Sign(0)`은 1이다. `Clamp`는 min > max여도 값을 바꾸지 않는다.
- `Vector3 ==`는 근사 비교(차이 길이 < 1e-5), `Equals`는 정확 비교다.
- 예상하지 않은 `Debug.LogError`·`LogException`·`Debug.Assert` 실패는 테스트 실패다. 오류 로그 경로를 통과 테스트로 만들지 않는다.

## 하지 않는 것
- MonoBehaviour·GameObject를 `new`로 만들기, 엔진 API 예외를 잡아서 통과시키기.
- 원본 직접 호출이 가능한데 복제 방식을 쓰기.
- `LogAssert`, `[UnityTest]`, `UnityEngine.TestTools`, `UnityEditor` 사용 (대체 소스에 없다).
- 테스트를 통과시키려고 대상 코드를 고치기. 분리 제안은 보고에만 적는다.
- 프리팹, 씬, 에셋 변경 테스트. PlayMode(프레임·물리·코루틴)는 UnitTest 범위가 아니다.
