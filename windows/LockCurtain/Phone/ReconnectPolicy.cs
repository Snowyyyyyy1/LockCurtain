// ReconnectPolicy.cs —— 断线重连的退避规则（纯函数，不碰蓝牙；和 Mac 的 Sources/ReconnectPolicy.swift 同一套）
//
// 不变式（三端一样）：配过对 + 蓝牙开着 + 没连上 ⇒ 总有东西在一直重试，只是间隔拉开、最长 5 分钟；
// 配过对时没有任何「永久停手」。只有「没配过、开着配对窗口」时，连续早断 5 次还是硬停（等重新打开窗口）。
// 退避只拉开「失败的连接尝试」之间的间隔：扫描器一直开着，一看到手机的广播就马上连、退避清零。
// 认得的、配过对的手机订阅上了却不表明身份：8 s 就断开，只静默 3 s → 5 s（NoIdentifyPolicy，不翻倍成长拉黑），
// 手机 App 一打开几秒内就连上；别的地址照旧 30 s → … → 5 min。
//
// 自测：windows/Tests/PhoneSelfTest（「重连退避」那一节）。

namespace LockCurtain.Phone;

internal static class Reconnect
{
    /// 所有重连退避的上限（三端一样）
    public static readonly TimeSpan Cap = TimeSpan.FromMinutes(5);

    /// baseDelay·2^step，封顶 cap
    public static TimeSpan Delay(int step, TimeSpan baseDelay, TimeSpan cap)
    {
        if (step <= 0) return baseDelay < cap ? baseDelay : cap;
        if (step >= 30) return cap;
        var d = TimeSpan.FromTicks((long)Math.Min(baseDelay.Ticks * Math.Pow(2, step), cap.Ticks));
        return d < cap ? d : cap;
    }
}

/// 翻倍退避
internal sealed class ReconnectBackoff(TimeSpan baseDelay, TimeSpan cap)
{
    public int Step { get; private set; }
    public DateTime? Until { get; private set; }

    /// 又失败了一次：返回这次要等多久
    public TimeSpan Fail(DateTime now)
    {
        var d = Reconnect.Delay(Step, baseDelay, cap);
        Step++;
        Until = now + d;
        return d;
    }

    public void Reset()
    {
        Step = 0;
        Until = null;
    }

    public bool Holding(DateTime now) => Until is { } u && now < u;
    public TimeSpan Remaining(DateTime now) => Until is { } u && u > now ? u - now : TimeSpan.Zero;
}

internal enum EarlyDropOutcome { KeepGoing, Backoff, Stop }

/// 连上了却在订阅好之前就断（早断）
internal sealed class EarlyDropPolicy
{
    public const int MaxEarlyDrops = 5;
    public static readonly TimeSpan BackoffBase = TimeSpan.FromSeconds(30);

    public int Drops { get; private set; }
    public DateTime? HoldUntil { get; private set; }

    /// 没配过：第 5 次 Stop（硬停，等重新打开配对窗口）；配过：第 5 次起 Backoff（30 s → … → 5 min），永不 Stop
    public (EarlyDropOutcome Outcome, TimeSpan Delay) NoteDrop(bool paired, DateTime now)
    {
        Drops++;
        if (Drops < MaxEarlyDrops) return (EarlyDropOutcome.KeepGoing, TimeSpan.Zero);
        if (!paired) return (EarlyDropOutcome.Stop, TimeSpan.Zero);
        var d = Reconnect.Delay(Drops - MaxEarlyDrops, BackoffBase, Reconnect.Cap);
        HoldUntil = now + d;
        return (EarlyDropOutcome.Backoff, d);
    }

    public void Reset()
    {
        Drops = 0;
        HoldUntil = null;
    }

    public bool Holding(DateTime now) => HoldUntil is { } u && now < u;
    public TimeSpan Remaining(DateTime now) => HoldUntil is { } u && u > now ? u - now : TimeSpan.Zero;
}

/// 暂时不理的地址：每次再被拉黑时间翻倍（30 s → 5 min），到点自动放出来；认出身份清零
internal sealed class TimedIgnoreList<TKey>(TimeSpan baseDelay, TimeSpan cap) where TKey : notnull
{
    public static readonly TimeSpan Base = TimeSpan.FromSeconds(30);

    /// 默认 30 s → 5 min；认得的手机用短档（NoIdentifyPolicy.MakeKnownHoldList）
    public TimedIgnoreList() : this(Base, Reconnect.Cap) { }

    readonly Dictionary<TKey, DateTime> until = new();
    readonly Dictionary<TKey, int> strikes = new();

    public TimeSpan Ignore(TKey key, DateTime now)
    {
        var n = strikes.GetValueOrDefault(key);
        strikes[key] = n + 1;
        var d = Reconnect.Delay(n, baseDelay, cap);
        until[key] = now + d;
        return d;
    }

    public bool Contains(TKey key, DateTime now) => until.TryGetValue(key, out var u) && now < u;

    /// 到点的放出来：返回放出来的那些
    public List<TKey> Expire(DateTime now)
    {
        var done = until.Where(kv => now >= kv.Value).Select(kv => kv.Key).ToList();
        foreach (var k in done) until.Remove(k);
        return done;
    }

    public void Forgive(TKey key)
    {
        until.Remove(key);
        strikes.Remove(key);
    }

    /// 蓝牙重新打开 / 唤醒 / 打开配对窗口：都给一次机会（拉黑次数也清掉）
    public void Clear()
    {
        until.Clear();
        strikes.Clear();
    }

    public int Count => until.Count;
}

internal enum NoIdentifyKind { KnownPaired, Timed }

/// 认得的、配过对的手机订阅上了却不表明身份（手机 App 没在跑，系统替它留着服务）：只做短周期，不长拉黑
/// （和 Mac 的 NoIdentifyPolicy 一样；Windows 没有「没有服务」那条路，也没有「永久不理」）。
/// 认得 + 配过对：订阅上 8 s 还不说就断开，静默 3 s → 5 s（封顶 5 s，不翻倍到更长）再连；别的地址照旧 30 s → … → 5 min。
internal static class NoIdentifyPolicy
{
    public static readonly TimeSpan KnownIdentifyTimeout = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan KnownHoldBase = TimeSpan.FromSeconds(3);
    public static readonly TimeSpan KnownHoldCap = TimeSpan.FromSeconds(5);

    public static NoIdentifyKind KindOf(bool paired, bool known) => paired && known ? NoIdentifyKind.KnownPaired : NoIdentifyKind.Timed;

    public static TimedIgnoreList<TKey> MakeKnownHoldList<TKey>() where TKey : notnull => new(KnownHoldBase, KnownHoldCap);
}

/// 苹果「溢出区」位图（16 字节）。手机后台广播时，位图里除了我们服务的那几位，还有别的后台 App 的位：
/// 学的是多次观察的交集（只留每次都在的位），交集空了就从这次重新学
internal static class OverflowBitmap
{
    public const int Length = 16;

    public static byte[] Intersect(byte[]? learned, byte[] observed)
    {
        if (learned is not { Length: Length }) return (byte[])observed.Clone();
        var r = new byte[Length];
        for (var i = 0; i < Length; i++) r[i] = (byte)(learned[i] & observed[i]);
        return IsEmpty(r) ? (byte[])observed.Clone() : r;
    }

    public static bool Contains(byte[] bits, byte[] mask)
    {
        for (var i = 0; i < Length; i++)
            if ((bits[i] & mask[i]) != mask[i]) return false;
        return true;
    }

    public static bool IsEmpty(byte[] bits) => bits.All(b => b == 0);
}

/// 系统「醒了」只留一个重启计时：再来一次 Resume 就重新计时（不再另开一个），
/// 只有最后一次的计时到点才动手——两个计时各自到点，第二个会把第一个刚连上的连接全断掉
internal sealed class ResumeDebounce
{
    int generation;
    bool pending;

    /// 又来一次 Resume：返回这一次的编号（旧的作废）
    public int Arm()
    {
        pending = true;
        return ++generation;
    }

    /// 计时到点：只有最新的那一次、而且还没动过手才算
    public bool Fire(int armed)
    {
        if (!pending || armed != generation) return false;
        pending = false;
        return true;
    }

    /// 又睡了：没到点的作废
    public void Cancel() => pending = false;

    public bool Pending => pending;
}

/// 日志去重：同一个 key 的内容没变就每 every 最多写一次；变了马上写（和 Mac 的 LogThrottle 一样）
internal sealed class LogThrottle
{
    readonly Dictionary<string, (string Value, DateTime At)> last = new();

    public bool ShouldLog(string key, string value, DateTime now, TimeSpan every)
    {
        if (last.TryGetValue(key, out var prev) && prev.Value == value && now - prev.At < every) return false;
        last[key] = (value, now);
        return true;
    }

    /// 只在内容变了时写
    public bool Changed(string key, string value)
    {
        if (last.TryGetValue(key, out var prev) && prev.Value == value) return false;
        last[key] = (value, DateTime.UtcNow);
        return true;
    }
}
