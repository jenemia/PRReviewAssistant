---
name: unittest-csharp-base
description: 순수 C# 로직의 UnitTest 작성 공통 규칙. 파일·클래스·메서드 이름 규칙(SpecGuard 연결용), 프레임워크 맞추기, 경계값, 예외 검증, 기대값 출처. Triggers: namespace, class.
---

# C# UnitTest 공통 규칙

## 프레임워크와 스타일
- context의 `testFramework`와 기존 테스트 스타일 샘플(`testStyleSample`)을 따른다. 샘플이 있으면 using, assert 방식, 클래스 구조를 맞춘다. 샘플이 없을 때만 NUnit 3 기본값을 쓴다.
- 새 패키지·참조를 추가하지 않는다.

## 이름 규칙 (SpecGuard가 Spec과 연결하는 기준)
- 파일·클래스: `{대상클래스}Tests` (예: `ShopDiscountTests.cs`). 기본 생성기는 `{대상클래스}SpecGuardTests`를 쓴다. 둘 다 연결된다.
- 네임스페이스: 기존 테스트의 규칙을 따른다 (예: `Demo.Tests.Shop`).
- 메서드: `메서드_상황_기대결과` 또는 Spec 시나리오 식별 이름 (예: `Apply_Vip_Gives10PercentOff`).

## 케이스 작성
- 한 테스트는 한 가지만 검증한다. Arrange / Act / Assert 순서.
- **기대값은 Spec에서 가져온다.** 구현 코드를 실행해 나온 값을 그대로 기대값으로 쓰지 않는다.
- 경계값을 반드시 넣는다: 0, 1, 최대값, 최대값+1, 음수, 주기의 끝과 다음 주기 처음.
- 정수 나눗셈·반올림은 절사/올림 결과를 구체적인 값으로 고정한다.
- 잘못된 입력은 `Assert.Throws<예외타입>`으로 예외 타입까지 검증한다 (메시지 문자열은 검증하지 않는다).
- 값이 여러 개면 파라미터 테스트(`TestCase`/`InlineData`)로 묶는다.
- 테스트끼리 상태를 공유하지 않는다. 정적 필드, 파일, 시간, 난수에 의존하지 않는다.

## 하지 않는 것
- Production 코드 수정, 접근 제한자 변경, 리플렉션으로 private 호출.
- 의미 없는 assert (`Assert.IsNotNull(new X())`만 있는 테스트).
- Spec에 없는 동작을 추측해서 검증. 필요하면 `assumptions`에 적는다.
