// LiftGate.cs —— 「手机撤下幕布」的判断，逐条对照 Mac 的 Sources/LiftGate.swift（纯逻辑，时间从外面传进来）
//
// 一台手机一个 LiftGate。签名和计数在 PairingAuthority.HandleAnswer 里验过之后，才交给这里判断：
//   1. 幕布现在盖着（盖上的时刻 T）；
//   2. 回答绑的 nonce 是电脑在 T 之后发的、最近 5 秒内的、没用过的（每个 nonce 只用一次）；
//   3. 「走近撤下」开着（手机回 off 就不撤）；
//   4. 边沿：T 之后先见过这台手机回「锁着」，之后的「解锁着」才能撤（「现在撤下」不看这一条）；
//   5. 近：电脑自己量的 RSSI，最近 3 次的中位数 >= -65 dBm。
// Windows 上 RSSI 的来源和 Mac 不同（Mac 读连接的 RSSI，Windows 读手机广播包的 RSSI），见 PhoneLink.cs。

namespace LockCurtain.Phone;

internal enum Refusal { NotCovered, UnknownNonce, StaleNonce, ToggleOff, PhoneLocked, EdgeNotArmed, NotNear, NoRSSI }

/// Lift = true 撤；否则 Why 是原因，Value 是 NotNear 的中位数 / NoRSSI 的样本数
internal readonly record struct LiftDecision(bool Lift, Refusal Why = default, int Value = 0)
{
    public static readonly LiftDecision Lifted = new(true);
    public static LiftDecision Refuse(Refusal why, int value = 0) => new(false, why, value);

    /// 和 vectors.json 里 Swift 的写法一样："lift" / "phoneLocked" / "notNear(-70)" / "noRSSI(2)"
    public override string ToString() => Lift ? "lift" : Why switch
    {
        Refusal.NotNear => $"notNear({Value})",
        Refusal.NoRSSI => $"noRSSI({Value})",
        _ => char.ToLowerInvariant(Why.ToString()[0]) + Why.ToString()[1..],
    };
}

internal sealed class LiftGate
{
    /// 近不近的门槛（dBm）：最近 3 次 RSSI 的中位数不低于它才算近。和 Mac 一样取保守值 -65，宁可少撤
    public const int NearMedianDBm = -65;
    public const int RssiSamples = 3;
    /// 超过这么久的 RSSI 不算（秒）
    public const double RssiMaxAge = 7;
    /// 电脑发出的 nonce 多久之内的回答才算新鲜（秒）
    public const double ChallengeLifetime = 5;
    public const int MaxOpenChallenges = 4;

    readonly record struct Challenge(byte[] Nonce, DateTime IssuedAt);

    public DateTime? CoveredAt { get; private set; }
    /// 盖上之后见过这台手机锁着
    public bool EdgeArmed { get; private set; }
    readonly List<Challenge> challenges = new();
    readonly List<(int Value, DateTime At)> rssi = new();

    static double Seconds(DateTime later, DateTime earlier) => (later - earlier).TotalSeconds;

    // MARK: - 幕布

    public void Covered(DateTime time)
    {
        CoveredAt = time;
        EdgeArmed = false;
        challenges.Clear();     // 盖上之前发的 nonce 一律作废
    }

    public void Uncovered()
    {
        CoveredAt = null;
        EdgeArmed = false;
        challenges.Clear();
    }

    // MARK: - 问询

    /// 电脑发出一次问询。幕布没盖着就不记
    public void Issue(byte[] nonce, DateTime time)
    {
        if (CoveredAt == null) return;
        challenges.RemoveAll(c => Seconds(time, c.IssuedAt) > ChallengeLifetime);
        challenges.Add(new Challenge(nonce, time));
        if (challenges.Count > MaxOpenChallenges) challenges.RemoveRange(0, challenges.Count - MaxOpenChallenges);
    }

    /// 用掉一个 nonce：不认识 → UnknownNonce；太旧或早于盖上 → StaleNonce。不管哪种，这个 nonce 都作废
    Refusal? Consume(byte[] nonce, DateTime time)
    {
        var index = challenges.FindIndex(c => c.Nonce.AsSpan().SequenceEqual(nonce));
        if (index < 0) return Refusal.UnknownNonce;
        var challenge = challenges[index];
        challenges.RemoveAt(index);
        var age = Seconds(time, challenge.IssuedAt);
        if (age < 0 || age > ChallengeLifetime || CoveredAt is not { } coveredAt || challenge.IssuedAt < coveredAt)
            return Refusal.StaleNonce;
        return null;
    }

    // MARK: - RSSI

    /// 0 和正数（127 是 CoreBluetooth 的「读不到」）不算
    public void RecordRSSI(int value, DateTime time)
    {
        if (value >= 0) return;
        rssi.Add((value, time));
        if (rssi.Count > RssiSamples) rssi.RemoveRange(0, rssi.Count - RssiSamples);
    }

    public void ResetRSSI() => rssi.Clear();

    /// 最近 3 次（都不旧）的中位数；不够数就是 null
    public (int? Median, List<int> Samples) RssiMedian(DateTime time)
    {
        var fresh = rssi.Where(r => Seconds(time, r.At) <= RssiMaxAge).Select(r => r.Value).ToList();
        if (fresh.Count < RssiSamples) return (null, fresh);
        var sorted = fresh.Skip(fresh.Count - RssiSamples).OrderBy(v => v).ToList();
        return (sorted[sorted.Count / 2], fresh);
    }

    LiftDecision? NearRefusal(DateTime time)
    {
        var (median, samples) = RssiMedian(time);
        if (median is not { } m) return LiftDecision.Refuse(Refusal.NoRSSI, samples.Count);
        return m >= NearMedianDBm ? null : LiftDecision.Refuse(Refusal.NotNear, m);
    }

    /// 「现在撤下」没撤时回手机的结果
    public static LiftStatus ResultStatus(Refusal r) => r switch
    {
        Refusal.NotNear or Refusal.NoRSSI => LiftStatus.TooFar,
        Refusal.NotCovered => LiftStatus.NotCovered,
        _ => LiftStatus.Refused,
    };

    // MARK: - 判断

    /// 手机对问询的回答（签名、计数已经验过）
    public LiftDecision Presence(PresenceStatus status, byte[] nonce, DateTime time)
    {
        if (CoveredAt == null) return LiftDecision.Refuse(Refusal.NotCovered);
        if (Consume(nonce, time) is { } stale) return LiftDecision.Refuse(stale);
        switch (status)
        {
            case PresenceStatus.Off:
                return LiftDecision.Refuse(Refusal.ToggleOff);
            case PresenceStatus.Locked:
                EdgeArmed = true;
                return LiftDecision.Refuse(Refusal.PhoneLocked);
            default:
                if (!EdgeArmed) return LiftDecision.Refuse(Refusal.EdgeNotArmed);
                return NearRefusal(time) ?? LiftDecision.Lifted;
        }
    }

    /// 「现在撤下」（手机那边已经过了面容 / 密码）：不看边沿，照样要新鲜、要近
    public LiftDecision LiftNow(byte[] nonce, DateTime time)
    {
        if (CoveredAt == null) return LiftDecision.Refuse(Refusal.NotCovered);
        if (Consume(nonce, time) is { } stale) return LiftDecision.Refuse(stale);
        return NearRefusal(time) ?? LiftDecision.Lifted;
    }
}
