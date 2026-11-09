import Foundation

/// UnityEngine stand-in compiled into the validation project of Unity repositories.
/// Pure members (Mathf, Vector*, attributes, ScriptableObject.CreateInstance) match Unity;
/// engine-only members compile but fail the running test, so no stub-only pass is accepted.
enum UnityEngineShim {
    static let path = "Source/UnityShim/UnityEngine.cs"
    /// Unity compiles C# 9; newer syntax must fail here too.
    static let buildProps = "<Project><PropertyGroup><LangVersion>9.0</LangVersion></PropertyGroup></Project>\n"

    static let source = #"""
    // PR Review Assistant UnitTest 검증용 UnityEngine 대체 소스.
    // 실제 Unity API 중 엔진 없이 같은 결과를 내는 일부만 같은 이름과 의미로 제공한다.
    // Time, Random, GameObject, Transform, PlayerPrefs 등 엔진 전용 API는 컴파일만 되고 실행하면 그 테스트가 실패한다.
    // 여기에 없는 API는 컴파일 오류가 되어 Unity 의존으로 판정된다.
    using System;
    using System.Collections;
    using System.Reflection;

    [assembly: PRReviewAssistant.UnityShim.ShimGuard]

    namespace PRReviewAssistant.UnityShim
    {
        // 엔진이 필요한 API 실행과 처리되지 않은 LogError를 기록하고, 예외를 잡았더라도 해당 테스트를 실패시킨다.
        [AttributeUsage(AttributeTargets.Assembly)]
        internal sealed class ShimGuard : Attribute, NUnit.Framework.ITestAction
        {
            [ThreadStatic] private static string violation;
            public NUnit.Framework.ActionTargets Targets => NUnit.Framework.ActionTargets.Test;
            public void BeforeTest(NUnit.Framework.Interfaces.ITest test) => violation = null;
            public void AfterTest(NUnit.Framework.Interfaces.ITest test)
            {
                var message = violation;
                violation = null;
                if (message != null) NUnit.Framework.Assert.Fail("Unity 엔진 없이는 같은 결과를 보장할 수 없어 실패 처리합니다: " + message);
            }

            internal static void Record(string message) { if (violation == null) violation = message; }

            internal static Exception EngineRequired(string api)
            {
                Record(api + "는 Unity 엔진이 필요합니다");
                return new NotSupportedException(api + "는 Unity 엔진이 필요합니다. 값을 인자로 받도록 분리된 로직만 검증하세요.");
            }
        }
    }

    namespace UnityEngine
    {
        using PRReviewAssistant.UnityShim;

        public class Object
        {
            public string name { get; set; }
            public static implicit operator bool(Object exists) => !ReferenceEquals(exists, null);
            public static void Destroy(Object obj) { }
            public static void DestroyImmediate(Object obj) { }
            public static T Instantiate<T>(T original) where T : Object => throw ShimGuard.EngineRequired("Object.Instantiate");
            public static T Instantiate<T>(T original, Transform parent) where T : Object => throw ShimGuard.EngineRequired("Object.Instantiate");
            public static T Instantiate<T>(T original, Vector3 position, Quaternion rotation) where T : Object => throw ShimGuard.EngineRequired("Object.Instantiate");
            public static T Instantiate<T>(T original, Vector3 position, Quaternion rotation, Transform parent) where T : Object => throw ShimGuard.EngineRequired("Object.Instantiate");
            public static T FindObjectOfType<T>() where T : Object => throw ShimGuard.EngineRequired("Object.FindObjectOfType");
        }

        // 아래 엔진 전용 멤버는 컴파일만 되게 한다. 실행하면 위반으로 기록되어 테스트가 실패한다.
        public class Component : Object
        {
            public Transform transform => throw ShimGuard.EngineRequired("Component.transform");
            public GameObject gameObject => throw ShimGuard.EngineRequired("Component.gameObject");
            public string tag { get => throw ShimGuard.EngineRequired("Component.tag"); set => throw ShimGuard.EngineRequired("Component.tag"); }
            public bool CompareTag(string tag) => throw ShimGuard.EngineRequired("Component.CompareTag");
            public T GetComponent<T>() => throw ShimGuard.EngineRequired("Component.GetComponent");
            public Component GetComponent(Type type) => throw ShimGuard.EngineRequired("Component.GetComponent");
            public bool TryGetComponent<T>(out T component) => throw ShimGuard.EngineRequired("Component.TryGetComponent");
            public T GetComponentInChildren<T>() => throw ShimGuard.EngineRequired("Component.GetComponentInChildren");
            public T[] GetComponentsInChildren<T>() => throw ShimGuard.EngineRequired("Component.GetComponentsInChildren");
            public T GetComponentInParent<T>() => throw ShimGuard.EngineRequired("Component.GetComponentInParent");
        }

        public class Behaviour : Component { public bool enabled { get; set; } = true; }

        public class MonoBehaviour : Behaviour
        {
            // 엔진 없이는 GameObject에 붙일 수 없다. 순수 로직 분리 전에는 static 멤버만 검증할 수 있다.
            public MonoBehaviour() { throw ShimGuard.EngineRequired("MonoBehaviour 생성"); }
            public Coroutine StartCoroutine(IEnumerator routine) => throw ShimGuard.EngineRequired("MonoBehaviour.StartCoroutine");
            public void StopCoroutine(Coroutine routine) => throw ShimGuard.EngineRequired("MonoBehaviour.StopCoroutine");
            public void StopAllCoroutines() => throw ShimGuard.EngineRequired("MonoBehaviour.StopAllCoroutines");
            public void Invoke(string methodName, float time) => throw ShimGuard.EngineRequired("MonoBehaviour.Invoke");
            public void CancelInvoke() => throw ShimGuard.EngineRequired("MonoBehaviour.CancelInvoke");
        }

        public sealed class GameObject : Object
        {
            public GameObject() { throw ShimGuard.EngineRequired("GameObject 생성"); }
            public GameObject(string name) { throw ShimGuard.EngineRequired("GameObject 생성"); }
            public Transform transform => throw ShimGuard.EngineRequired("GameObject.transform");
            public bool activeSelf => throw ShimGuard.EngineRequired("GameObject.activeSelf");
            public bool activeInHierarchy => throw ShimGuard.EngineRequired("GameObject.activeInHierarchy");
            public void SetActive(bool value) => throw ShimGuard.EngineRequired("GameObject.SetActive");
            public T GetComponent<T>() => throw ShimGuard.EngineRequired("GameObject.GetComponent");
            public T AddComponent<T>() where T : Component => throw ShimGuard.EngineRequired("GameObject.AddComponent");
        }

        public class Transform : Component, IEnumerable
        {
            protected Transform() { throw ShimGuard.EngineRequired("Transform 생성"); }
            public Vector3 position { get => throw ShimGuard.EngineRequired("Transform.position"); set => throw ShimGuard.EngineRequired("Transform.position"); }
            public Vector3 localPosition { get => throw ShimGuard.EngineRequired("Transform.localPosition"); set => throw ShimGuard.EngineRequired("Transform.localPosition"); }
            public Quaternion rotation { get => throw ShimGuard.EngineRequired("Transform.rotation"); set => throw ShimGuard.EngineRequired("Transform.rotation"); }
            public Vector3 localScale { get => throw ShimGuard.EngineRequired("Transform.localScale"); set => throw ShimGuard.EngineRequired("Transform.localScale"); }
            public Transform parent { get => throw ShimGuard.EngineRequired("Transform.parent"); set => throw ShimGuard.EngineRequired("Transform.parent"); }
            public int childCount => throw ShimGuard.EngineRequired("Transform.childCount");
            public Transform GetChild(int index) => throw ShimGuard.EngineRequired("Transform.GetChild");
            public Transform Find(string n) => throw ShimGuard.EngineRequired("Transform.Find");
            public void SetParent(Transform p) => throw ShimGuard.EngineRequired("Transform.SetParent");
            public void SetParent(Transform p, bool worldPositionStays) => throw ShimGuard.EngineRequired("Transform.SetParent");
            public IEnumerator GetEnumerator() => throw ShimGuard.EngineRequired("Transform 순회");
        }

        public sealed class Coroutine { private Coroutine() { } }
        public class YieldInstruction { }
        public sealed class WaitForSeconds : YieldInstruction { public WaitForSeconds(float seconds) { } }
        public sealed class WaitForEndOfFrame : YieldInstruction { }
        public sealed class WaitForFixedUpdate : YieldInstruction { }

        // 시간과 난수는 결정적으로 바꿀 수 없으므로 실행하면 실패한다. 값을 인자로 주입하는 로직을 검증한다.
        public static class Time
        {
            public static float time => throw ShimGuard.EngineRequired("Time.time");
            public static float deltaTime => throw ShimGuard.EngineRequired("Time.deltaTime");
            public static float unscaledDeltaTime => throw ShimGuard.EngineRequired("Time.unscaledDeltaTime");
            public static float fixedDeltaTime => throw ShimGuard.EngineRequired("Time.fixedDeltaTime");
            public static float realtimeSinceStartup => throw ShimGuard.EngineRequired("Time.realtimeSinceStartup");
            public static int frameCount => throw ShimGuard.EngineRequired("Time.frameCount");
            public static float timeScale { get => throw ShimGuard.EngineRequired("Time.timeScale"); set => throw ShimGuard.EngineRequired("Time.timeScale"); }
        }

        public static class Random
        {
            public static float value => throw ShimGuard.EngineRequired("Random.value");
            public static float Range(float minInclusive, float maxInclusive) => throw ShimGuard.EngineRequired("Random.Range");
            public static int Range(int minInclusive, int maxExclusive) => throw ShimGuard.EngineRequired("Random.Range");
            public static void InitState(int seed) => throw ShimGuard.EngineRequired("Random.InitState");
        }

        public static class Application
        {
            public static bool isPlaying => throw ShimGuard.EngineRequired("Application.isPlaying");
            public static string persistentDataPath => throw ShimGuard.EngineRequired("Application.persistentDataPath");
        }

        public static class PlayerPrefs
        {
            public static int GetInt(string key, int defaultValue = 0) => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static void SetInt(string key, int value) => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static float GetFloat(string key, float defaultValue = 0F) => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static void SetFloat(string key, float value) => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static string GetString(string key, string defaultValue = "") => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static void SetString(string key, string value) => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static bool HasKey(string key) => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static void DeleteKey(string key) => throw ShimGuard.EngineRequired("PlayerPrefs");
            public static void Save() => throw ShimGuard.EngineRequired("PlayerPrefs");
        }

        public static class Resources
        {
            public static T Load<T>(string path) where T : Object => throw ShimGuard.EngineRequired("Resources.Load");
        }

        public class ScriptableObject : Object
        {
            [ThreadStatic] private static bool creating;

            public ScriptableObject()
            {
                if (!creating) throw ShimGuard.EngineRequired("ScriptableObject를 new로 생성 (CreateInstance 사용)");
            }

            public static T CreateInstance<T>() where T : ScriptableObject => (T)CreateInstance(typeof(T));

            public static ScriptableObject CreateInstance(Type type)
            {
                creating = true;
                ScriptableObject instance;
                try { instance = (ScriptableObject)Activator.CreateInstance(type, true); }
                finally { creating = false; }
                Invoke(instance, "Awake");
                Invoke(instance, "OnEnable");
                return instance;
            }

            // Unity는 Awake와 OnEnable을 접근 제한자와 관계없이 이름으로 호출한다.
            private static void Invoke(ScriptableObject instance, string message)
            {
                for (var type = instance.GetType(); type != null && type != typeof(ScriptableObject); type = type.BaseType)
                {
                    var method = type.GetMethod(message, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly, null, Type.EmptyTypes, null);
                    if (method == null) continue;
                    try { method.Invoke(instance, null); }
                    catch (TargetInvocationException error) when (error.InnerException != null) { throw error.InnerException; }
                    return;
                }
            }
        }

        // Unity 테스트는 LogAssert로 예상하지 않은 LogError·LogException·Assert 실패를 테스트 실패로 본다. 흐름은 계속되고 테스트 끝에 실패한다.
        public static class Debug
        {
            public static void Log(object message) => Console.WriteLine(message);
            public static void Log(object message, Object context) => Console.WriteLine(message);
            public static void LogFormat(string format, params object[] args) => Console.WriteLine(format, args);
            public static void LogWarning(object message) => Console.WriteLine(message);
            public static void LogWarning(object message, Object context) => Console.WriteLine(message);
            public static void LogWarningFormat(string format, params object[] args) => Console.WriteLine(format, args);
            public static void LogError(object message) => ShimGuard.Record("Debug.LogError: " + message);
            public static void LogError(object message, Object context) => LogError(message);
            public static void LogErrorFormat(string format, params object[] args) => LogError(string.Format(format, args));
            public static void LogException(Exception exception) => ShimGuard.Record("Debug.LogException: " + exception);
            public static void LogException(Exception exception, Object context) => LogException(exception);
            public static void Assert(bool condition) { if (!condition) LogError("Assertion failed"); }
            public static void Assert(bool condition, object message) { if (!condition) LogError(message); }
        }

        [Serializable]
        public struct Quaternion
        {
            public float x;
            public float y;
            public float z;
            public float w;
            public Quaternion(float x, float y, float z, float w) { this.x = x; this.y = y; this.z = z; this.w = w; }
            public static Quaternion identity => new Quaternion(0F, 0F, 0F, 1F);
        }

        public static class Mathf
        {
            public const float PI = (float)Math.PI;
            public const float Infinity = float.PositiveInfinity;
            public const float NegativeInfinity = float.NegativeInfinity;
            public const float Deg2Rad = PI * 2F / 360F;
            public const float Rad2Deg = 1F / Deg2Rad;
            public static readonly float Epsilon = float.Epsilon;

            public static float Sin(float f) => (float)Math.Sin(f);
            public static float Cos(float f) => (float)Math.Cos(f);
            public static float Sqrt(float f) => (float)Math.Sqrt(f);
            public static float Pow(float f, float p) => (float)Math.Pow(f, p);
            public static float Exp(float power) => (float)Math.Exp(power);
            public static float Log(float f) => (float)Math.Log(f);
            public static float Log(float f, float p) => (float)Math.Log(f, p);
            public static float Log10(float f) => (float)Math.Log10(f);
            public static float Abs(float f) => Math.Abs(f);
            public static int Abs(int value) => Math.Abs(value);
            public static float Min(float a, float b) => a < b ? a : b;
            public static int Min(int a, int b) => a < b ? a : b;
            public static float Max(float a, float b) => a > b ? a : b;
            public static int Max(int a, int b) => a > b ? a : b;

            public static float Min(params float[] values)
            {
                if (values.Length == 0) return 0;
                var result = values[0];
                for (var i = 1; i < values.Length; i++) if (values[i] < result) result = values[i];
                return result;
            }

            public static int Min(params int[] values)
            {
                if (values.Length == 0) return 0;
                var result = values[0];
                for (var i = 1; i < values.Length; i++) if (values[i] < result) result = values[i];
                return result;
            }

            public static float Max(params float[] values)
            {
                if (values.Length == 0) return 0;
                var result = values[0];
                for (var i = 1; i < values.Length; i++) if (values[i] > result) result = values[i];
                return result;
            }

            public static int Max(params int[] values)
            {
                if (values.Length == 0) return 0;
                var result = values[0];
                for (var i = 1; i < values.Length; i++) if (values[i] > result) result = values[i];
                return result;
            }

            // Math.Round의 기본값과 같이 .5는 가까운 짝수로 반올림한다 (Mathf.Round(2.5f) == 2).
            public static float Round(float f) => (float)Math.Round(f);
            public static float Floor(float f) => (float)Math.Floor(f);
            public static float Ceil(float f) => (float)Math.Ceiling(f);
            public static int RoundToInt(float f) => (int)Math.Round(f);
            public static int FloorToInt(float f) => (int)Math.Floor(f);
            public static int CeilToInt(float f) => (int)Math.Ceiling(f);
            public static float Sign(float f) => f >= 0F ? 1F : -1F;

            public static float Clamp(float value, float min, float max) => value < min ? min : (value > max ? max : value);
            public static int Clamp(int value, int min, int max) => value < min ? min : (value > max ? max : value);
            public static float Clamp01(float value) => value < 0F ? 0F : (value > 1F ? 1F : value);
            public static float Lerp(float a, float b, float t) => a + (b - a) * Clamp01(t);
            public static float LerpUnclamped(float a, float b, float t) => a + (b - a) * t;
            public static float InverseLerp(float a, float b, float value) => a != b ? Clamp01((value - a) / (b - a)) : 0F;
            public static float MoveTowards(float current, float target, float maxDelta) => Abs(target - current) <= maxDelta ? target : current + Sign(target - current) * maxDelta;
            public static float Repeat(float t, float length) => Clamp(t - Floor(t / length) * length, 0F, length);
            public static float PingPong(float t, float length) => length - Abs(Repeat(t, length * 2F) - length);
            public static bool Approximately(float a, float b) => Abs(b - a) < Max(0.000001f * Max(Abs(a), Abs(b)), Epsilon * 8);
        }

        [Serializable]
        public struct Vector2 : IEquatable<Vector2>
        {
            public const float kEpsilon = 0.00001F;
            public float x;
            public float y;

            public Vector2(float x, float y) { this.x = x; this.y = y; }

            public static Vector2 zero => new Vector2(0F, 0F);
            public static Vector2 one => new Vector2(1F, 1F);
            public static Vector2 up => new Vector2(0F, 1F);
            public static Vector2 down => new Vector2(0F, -1F);
            public static Vector2 left => new Vector2(-1F, 0F);
            public static Vector2 right => new Vector2(1F, 0F);

            public float sqrMagnitude => x * x + y * y;
            public float magnitude => (float)Math.Sqrt(x * x + y * y);
            public Vector2 normalized { get { var m = magnitude; return m > kEpsilon ? this / m : zero; } }

            public static float Dot(Vector2 lhs, Vector2 rhs) => lhs.x * rhs.x + lhs.y * rhs.y;
            public static float Distance(Vector2 a, Vector2 b) => (a - b).magnitude;
            public static Vector2 Lerp(Vector2 a, Vector2 b, float t) { t = Mathf.Clamp01(t); return new Vector2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t); }

            public static Vector2 operator +(Vector2 a, Vector2 b) => new Vector2(a.x + b.x, a.y + b.y);
            public static Vector2 operator -(Vector2 a, Vector2 b) => new Vector2(a.x - b.x, a.y - b.y);
            public static Vector2 operator -(Vector2 a) => new Vector2(-a.x, -a.y);
            public static Vector2 operator *(Vector2 a, float d) => new Vector2(a.x * d, a.y * d);
            public static Vector2 operator *(float d, Vector2 a) => new Vector2(a.x * d, a.y * d);
            public static Vector2 operator /(Vector2 a, float d) => new Vector2(a.x / d, a.y / d);
            // Unity의 ==는 근사 비교다 (차이의 제곱 길이 < kEpsilon²). Equals는 정확히 비교한다.
            public static bool operator ==(Vector2 lhs, Vector2 rhs) { float dx = lhs.x - rhs.x, dy = lhs.y - rhs.y; return dx * dx + dy * dy < kEpsilon * kEpsilon; }
            public static bool operator !=(Vector2 lhs, Vector2 rhs) => !(lhs == rhs);
            public bool Equals(Vector2 other) => x == other.x && y == other.y;
            public override bool Equals(object other) => other is Vector2 v && Equals(v);
            public override int GetHashCode() => x.GetHashCode() ^ (y.GetHashCode() << 2);
        }

        [Serializable]
        public struct Vector3 : IEquatable<Vector3>
        {
            public const float kEpsilon = 0.00001F;
            public float x;
            public float y;
            public float z;

            public Vector3(float x, float y, float z) { this.x = x; this.y = y; this.z = z; }
            public Vector3(float x, float y) { this.x = x; this.y = y; z = 0F; }

            public static Vector3 zero => new Vector3(0F, 0F, 0F);
            public static Vector3 one => new Vector3(1F, 1F, 1F);
            public static Vector3 up => new Vector3(0F, 1F, 0F);
            public static Vector3 down => new Vector3(0F, -1F, 0F);
            public static Vector3 left => new Vector3(-1F, 0F, 0F);
            public static Vector3 right => new Vector3(1F, 0F, 0F);
            public static Vector3 forward => new Vector3(0F, 0F, 1F);
            public static Vector3 back => new Vector3(0F, 0F, -1F);

            public float sqrMagnitude => x * x + y * y + z * z;
            public float magnitude => (float)Math.Sqrt(x * x + y * y + z * z);
            public Vector3 normalized { get { var m = magnitude; return m > kEpsilon ? this / m : zero; } }

            public static float Dot(Vector3 lhs, Vector3 rhs) => lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z;
            public static float Distance(Vector3 a, Vector3 b) => (a - b).magnitude;
            public static Vector3 Lerp(Vector3 a, Vector3 b, float t) { t = Mathf.Clamp01(t); return new Vector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t); }

            public static Vector3 operator +(Vector3 a, Vector3 b) => new Vector3(a.x + b.x, a.y + b.y, a.z + b.z);
            public static Vector3 operator -(Vector3 a, Vector3 b) => new Vector3(a.x - b.x, a.y - b.y, a.z - b.z);
            public static Vector3 operator -(Vector3 a) => new Vector3(-a.x, -a.y, -a.z);
            public static Vector3 operator *(Vector3 a, float d) => new Vector3(a.x * d, a.y * d, a.z * d);
            public static Vector3 operator *(float d, Vector3 a) => new Vector3(a.x * d, a.y * d, a.z * d);
            public static Vector3 operator /(Vector3 a, float d) => new Vector3(a.x / d, a.y / d, a.z / d);
            public static bool operator ==(Vector3 lhs, Vector3 rhs) { float dx = lhs.x - rhs.x, dy = lhs.y - rhs.y, dz = lhs.z - rhs.z; return dx * dx + dy * dy + dz * dz < kEpsilon * kEpsilon; }
            public static bool operator !=(Vector3 lhs, Vector3 rhs) => !(lhs == rhs);
            public bool Equals(Vector3 other) => x == other.x && y == other.y && z == other.z;
            public override bool Equals(object other) => other is Vector3 v && Equals(v);
            public override int GetHashCode() => x.GetHashCode() ^ (y.GetHashCode() << 2) ^ (z.GetHashCode() >> 2);
        }

        [Serializable]
        public struct Vector2Int : IEquatable<Vector2Int>
        {
            public int x;
            public int y;

            public Vector2Int(int x, int y) { this.x = x; this.y = y; }

            public static Vector2Int zero => new Vector2Int(0, 0);
            public static Vector2Int one => new Vector2Int(1, 1);

            public static Vector2Int operator +(Vector2Int a, Vector2Int b) => new Vector2Int(a.x + b.x, a.y + b.y);
            public static Vector2Int operator -(Vector2Int a, Vector2Int b) => new Vector2Int(a.x - b.x, a.y - b.y);
            public static Vector2Int operator *(Vector2Int a, int b) => new Vector2Int(a.x * b, a.y * b);
            public static bool operator ==(Vector2Int lhs, Vector2Int rhs) => lhs.x == rhs.x && lhs.y == rhs.y;
            public static bool operator !=(Vector2Int lhs, Vector2Int rhs) => !(lhs == rhs);
            public bool Equals(Vector2Int other) => this == other;
            public override bool Equals(object other) => other is Vector2Int v && Equals(v);
            public override int GetHashCode() => x.GetHashCode() ^ (y.GetHashCode() << 2);
        }

        [Serializable]
        public struct Vector3Int : IEquatable<Vector3Int>
        {
            public int x;
            public int y;
            public int z;

            public Vector3Int(int x, int y, int z) { this.x = x; this.y = y; this.z = z; }

            public static Vector3Int zero => new Vector3Int(0, 0, 0);
            public static Vector3Int one => new Vector3Int(1, 1, 1);

            public static Vector3Int operator +(Vector3Int a, Vector3Int b) => new Vector3Int(a.x + b.x, a.y + b.y, a.z + b.z);
            public static Vector3Int operator -(Vector3Int a, Vector3Int b) => new Vector3Int(a.x - b.x, a.y - b.y, a.z - b.z);
            public static Vector3Int operator *(Vector3Int a, int b) => new Vector3Int(a.x * b, a.y * b, a.z * b);
            public static bool operator ==(Vector3Int lhs, Vector3Int rhs) => lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z;
            public static bool operator !=(Vector3Int lhs, Vector3Int rhs) => !(lhs == rhs);
            public bool Equals(Vector3Int other) => this == other;
            public override bool Equals(object other) => other is Vector3Int v && Equals(v);
            public override int GetHashCode() => x.GetHashCode() ^ (y.GetHashCode() << 4) ^ (z.GetHashCode() >> 4);
        }

        [AttributeUsage(AttributeTargets.Field)] public sealed class SerializeField : Attribute { }
        [AttributeUsage(AttributeTargets.Field)] public sealed class SerializeReference : Attribute { }
        [AttributeUsage(AttributeTargets.Field)] public sealed class HideInInspector : Attribute { }
        [AttributeUsage(AttributeTargets.Field, AllowMultiple = true)] public class HeaderAttribute : Attribute { public readonly string header; public HeaderAttribute(string header) { this.header = header; } }
        [AttributeUsage(AttributeTargets.Field)] public class TooltipAttribute : Attribute { public readonly string tooltip; public TooltipAttribute(string tooltip) { this.tooltip = tooltip; } }
        [AttributeUsage(AttributeTargets.Field)] public sealed class RangeAttribute : Attribute { public readonly float min; public readonly float max; public RangeAttribute(float min, float max) { this.min = min; this.max = max; } }
        [AttributeUsage(AttributeTargets.Field)] public sealed class MinAttribute : Attribute { public readonly float min; public MinAttribute(float min) { this.min = min; } }
        [AttributeUsage(AttributeTargets.Field, AllowMultiple = true)] public class SpaceAttribute : Attribute { public readonly float height; public SpaceAttribute() { height = 8; } public SpaceAttribute(float height) { this.height = height; } }
        [AttributeUsage(AttributeTargets.Field)] public sealed class TextAreaAttribute : Attribute { public TextAreaAttribute() { } public TextAreaAttribute(int minLines, int maxLines) { } }
        [AttributeUsage(AttributeTargets.Field)] public sealed class MultilineAttribute : Attribute { public MultilineAttribute() { } public MultilineAttribute(int lines) { } }
        [AttributeUsage(AttributeTargets.Class)] public sealed class CreateAssetMenuAttribute : Attribute { public string menuName { get; set; } public string fileName { get; set; } public int order { get; set; } }
        [AttributeUsage(AttributeTargets.Class, AllowMultiple = true)] public sealed class RequireComponent : Attribute { public RequireComponent(Type requiredComponent) { } public RequireComponent(Type requiredComponent, Type requiredComponent2) { } public RequireComponent(Type requiredComponent, Type requiredComponent2, Type requiredComponent3) { } }
        [AttributeUsage(AttributeTargets.Class)] public sealed class DisallowMultipleComponent : Attribute { }
        [AttributeUsage(AttributeTargets.Class)] public sealed class ExecuteAlways : Attribute { }
        [AttributeUsage(AttributeTargets.Class)] public sealed class ExecuteInEditMode : Attribute { }
        [AttributeUsage(AttributeTargets.Class)] public sealed class AddComponentMenu : Attribute { public AddComponentMenu(string menuName) { } public AddComponentMenu(string menuName, int order) { } }
        [AttributeUsage(AttributeTargets.Class)] public class DefaultExecutionOrder : Attribute { public DefaultExecutionOrder(int order) { this.order = order; } public int order { get; } }
        [AttributeUsage(AttributeTargets.Method, AllowMultiple = true)] public sealed class ContextMenu : Attribute { public ContextMenu(string itemName) { } public ContextMenu(string itemName, bool isValidateFunction) { } }
    }

    namespace UnityEngine.Serialization
    {
        [AttributeUsage(AttributeTargets.Field, AllowMultiple = true)]
        public class FormerlySerializedAsAttribute : Attribute
        {
            public FormerlySerializedAsAttribute(string oldName) { this.oldName = oldName; }
            public string oldName { get; }
        }
    }

    """#
}
