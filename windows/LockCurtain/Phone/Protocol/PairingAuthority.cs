// PairingAuthority.cs —— 电脑端的配对 / 验签规则（和蓝牙无关，测试直接在进程里跑），对照 Mac 的 Sources/PairingAuthority.swift
//
// 和 Mac 一样的：
//   * 握手是 CPace：回 Yb/Tb 的那一刻就把这一轮记成一次错码，只有手机的确认标签 Ta 验过才算成。
//     Ta 不对、手机放弃、半路不来都算错，这一轮作废。同一时间只有一轮；sid 用过不再收；换码 / 关窗口时进行中的那一轮作废。
//   * 握手过了的手机先记在内存里（pending），等它用新钥匙签的第一条命令验过，才写进存储、算真的配上。
//   * 命令 / 回答：签名对、手机认识、计数比上次大，才收；收之前先把新计数写进存储。
// Windows 版的配对窗口文案（task brief §8）定的码规则和 Mac 不同：
//   * 一个码最多错 3 次（Mac 是一个窗口 5 次），错满或过期就作废，窗口显示「这几个数作废了，点「换一个码」重新来。」；
//   * 「换一个码」总能换出新码（次数重新算）。每换一次都要人在电脑前点一下，在线猜码的次数仍然受人手限制。
//
// 走网络（Transport.Network，对照 Mac 的 PairingAuthority）：同样的签名 / 计数，但
//   * 只认已确认配上的手机（钥匙在存储里），不看握手刚过、还没确认的 pending；
//   * 签名和计数验过之后命令还要在白名单里（NetworkPolicy，默认拒绝：只有 ping / away / awake:* / name:），
//     撤下 / 解除配对 / 预览 / 设置 / 配对 / Presence / LiftNow 一律拒绝（签名的 Ack 5，计数照记，重放不了）；
//   * 除 ping 外命令必须是 n1:<nonce>:<命令>，nonce 是电脑刚发的签名 Poll（NetworkPollMessage）里的，只能用一次、有寿命（90 秒），
//     每台手机最多同时留 4 个；
//   * 配对消息（PairRequest / PairConfirm / PairAbort）、Presence、LiftNow 走网络：在验签之前就拒绝，不动码、不耗计数、够不到 LiftGate。
// 日志只写步骤和结果，不写码、不写钥匙。

namespace LockCurtain.Phone;

internal sealed record PairingRecord(byte[] Key, ulong LastCounter)
{
    /// 存储格式：32 字节钥匙 + 8 字节大端计数（和 Mac 钥匙串里的一样）
    public byte[] Encoded() => Bytes.Concat(Key, PairingCrypto.BigEndian(LastCounter));

    public static PairingRecord? Decode(byte[] b) =>
        b.Length == 40 ? new PairingRecord(b.Slice(..32), PairingCrypto.UInt64(b, 32)) : null;
}

internal interface IPairingRecordStore
{
    PairingRecord? Load(Guid phoneID);
    bool Save(PairingRecord record, Guid phoneID);
    void Delete(Guid phoneID);
    IReadOnlyList<Guid> AllPhoneIDs();
}

/// 测试用
internal sealed class MemoryPairingStore : IPairingRecordStore
{
    readonly Dictionary<Guid, PairingRecord> records = new();
    public bool FailSaves { get; set; }
    public PairingRecord? Load(Guid id) => records.GetValueOrDefault(id);
    public bool Save(PairingRecord r, Guid id)
    {
        if (FailSaves) return false;
        records[id] = r;
        return true;
    }
    public void Delete(Guid id) => records.Remove(id);
    public IReadOnlyList<Guid> AllPhoneIDs() => records.Keys.ToList();
}

internal enum PairOutcomeKind { Responded, Accepted, Rejected, Aborted, NoCode, Malformed }

/// Reply：要回给手机的消息（Aborted 没有）；PhoneID：Accepted 时是哪台
internal sealed record PairOutcome(PairOutcomeKind Kind, byte[]? Reply, int AttemptsLeft, Guid? PhoneID = null);

/// NetworkForbidden：走网络不许这条命令 / 这类消息；BadNonce：网络命令的 nonce 缺、不对、用过或过期
internal enum RejectReason { Malformed, UnknownPhone, BadSignature, Replay, StoreFailed, NetworkForbidden, BadNonce }

internal sealed record CommandOutcome(bool Accepted, string Command, Guid? PhoneID, ulong Counter, bool ConfirmedPairing,
                                      byte[]? Ack, RejectReason Reason = default);

internal sealed record AnswerOutcome(PhoneAnswer? Answer, RejectReason Reason, Guid? PhoneID)
{
    public bool Accepted => Answer != null;
}

internal sealed class PairingAuthority(IPairingRecordStore store, Action<string> log)
{
    /// 一个码最多错几次
    public const int MaxCodeAttempts = 3;

    /// 网络问询 nonce 的寿命、每台手机最多同时留几个（和 Mac 一样）
    public static readonly TimeSpan NetworkNonceLifetime = TimeSpan.FromSeconds(90);
    public const int NetworkNonceLimit = 4;
    /// 测试可以换时钟
    public Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;
    /// 每台手机发出去、还没用的网络 nonce（旧的在前）
    readonly Dictionary<Guid, List<(byte[] Nonce, DateTime IssuedAt)>> networkNonces = new();

    public IPairingRecordStore Store => store;
    /// 现在有效的码；空 = 没有码可配
    public string Code { get; private set; } = "";
    public int AttemptsLeft { get; private set; } = MaxCodeAttempts;
    /// 这个码错满了 / 过期了：作废，「换一个码」才有新码
    public bool IsLocked { get; private set; }
    /// 握手过了、还没用新钥匙签过命令的手机
    readonly Dictionary<Guid, byte[]> pending = new();
    /// 回过 Yb/Tb、还在等 Ta 的那一轮
    MacSession? inFlight;
    /// 收过的 sid（本次运行内），同一个 sid 不收第二次
    readonly HashSet<string> usedSessions = new();

    public IReadOnlyList<Guid> PairedPhoneIDs => store.AllPhoneIDs();
    public bool IsPaired => PairedPhoneIDs.Count > 0;

    static string Who(Guid id) => PairingCrypto.IdString(id);

    // MARK: - 码

    /// 打开配对窗口：新码、错码次数清零
    public void OpenWindow(string code)
    {
        Code = code;
        AttemptsLeft = MaxCodeAttempts;
        IsLocked = false;
        inFlight = null;
    }

    /// 「换一个码」：新码，次数重新算；进行中的那一轮作废
    public void Refresh(string code)
    {
        if (inFlight != null) log("code refreshed: run in progress burned");
        OpenWindow(code);
    }

    /// 码过期（窗口开着太久）：作废，等「换一个码」
    public void Expire()
    {
        if (Code.Length == 0 || IsLocked) return;
        Code = "";
        IsLocked = true;
        inFlight = null;
        log("code expired; press 换一个码 for a new one");
    }

    public void CloseWindow()
    {
        Code = "";
        IsLocked = false;
        pending.Clear();
        inFlight = null;
    }

    // MARK: - 握手

    /// 握手消息（PairRequest / PairConfirm / PairAbort）都从这里进
    public PairOutcome HandlePair(byte[] data, Transport via = Transport.Bluetooth)
    {
        // 配对只走蓝牙：不碰码、不碰握手状态，调用方应当断开
        if (via != Transport.Bluetooth)
        {
            log("pair message over network refused");
            return Malformed();
        }
        switch (PairingCrypto.KindOf(data))
        {
            case Kind.PairRequest: return HandleRequest(data);
            case Kind.PairConfirm: return HandleConfirm(data);
            case Kind.PairAbort: return HandleAbort(data);
            default:
                log("pair message malformed");
                return Malformed();
        }
    }

    PairOutcome Malformed() => new(PairOutcomeKind.Malformed, PairingCrypto.PairReject(PairRejectReason.NoCode), AttemptsLeft);

    /// 这一轮没成：次数已经在回 Yb/Tb 时扣过，扣完了就锁
    void LockIfExhausted()
    {
        if (AttemptsLeft > 0 || IsLocked) return;
        Code = "";
        IsLocked = true;
        inFlight = null;
        log($"code invalidated after {MaxCodeAttempts} wrong attempts; press 换一个码 for a new one");
    }

    PairOutcome HandleRequest(byte[] data)
    {
        log("pair request received");
        PairRequest request;
        try { request = PairRequest.Decode(data); }
        catch (WireException)
        {
            log("pair request malformed");
            return Malformed();
        }
        var who = Who(request.PhoneID);
        if (usedSessions.Contains(Bytes.Hex(request.Sid)))
        {
            log($"pair request from {who} reuses a session id; refused");
            return Malformed();
        }
        if (inFlight != null)
        {
            log("previous pairing run abandoned; it stays counted");
            inFlight = null;
        }
        LockIfExhausted();
        if (Code.Length == 0 || IsLocked)
        {
            log($"pair request from {who} but no code open{(IsLocked ? " (code invalidated)" : "")}");
            return new(PairOutcomeKind.NoCode, PairingCrypto.PairReject(PairRejectReason.NoCode), AttemptsLeft);
        }
        usedSessions.Add(Bytes.Hex(request.Sid));
        if (PairingCrypto.MacRespond(request, Code) is not { } r)
        {
            log($"pair request from {who} has an invalid point; refused");
            return Malformed();
        }
        AttemptsLeft--;
        inFlight = r.Session;
        log($"pair run started with {who}; counted as an attempt until confirmed (attempts left {AttemptsLeft})");
        return new(PairOutcomeKind.Responded, r.Response.Encoded(), AttemptsLeft);
    }

    PairOutcome HandleConfirm(byte[] data)
    {
        PairConfirm confirm;
        try { confirm = PairConfirm.Decode(data); }
        catch (WireException)
        {
            log("pair confirmation malformed");
            return Malformed();
        }
        var who = Who(confirm.PhoneID);
        if (inFlight is not { } session || session.PhoneID != confirm.PhoneID || !session.Sid.AsSpan().SequenceEqual(confirm.Sid))
        {
            log($"pair confirmation from {who} for no running session; refused");
            return new(PairOutcomeKind.Rejected, PairingCrypto.PairReject(PairRejectReason.WrongCode), AttemptsLeft);
        }
        inFlight = null;    // 不管成不成，这一轮都用完了
        if (!PairingCrypto.MacCheckConfirm(confirm, session))
        {
            log($"pair confirmation bad from {who}, attempts left {AttemptsLeft}");
            LockIfExhausted();
            return new(PairOutcomeKind.Rejected, PairingCrypto.PairReject(PairRejectReason.WrongCode), AttemptsLeft);
        }
        log($"pair confirmation ok from {who}; code used up, waiting for first signed command");
        Code = "";
        pending[confirm.PhoneID] = session.SharedKey;
        return new(PairOutcomeKind.Accepted, PairingCrypto.PairAccepted(confirm.PhoneID, confirm.Sid, session.SharedKey),
                   AttemptsLeft, confirm.PhoneID);
    }

    PairOutcome HandleAbort(byte[] data)
    {
        if (PairingCrypto.DecodePairAbort(data) is not { } abort)
        {
            log("pair abort malformed");
            return Malformed();
        }
        if (inFlight is { } s && s.PhoneID == abort.PhoneID && s.Sid.AsSpan().SequenceEqual(abort.Sid))
        {
            inFlight = null;
            log($"phone {Who(abort.PhoneID)} gave up the run (code mismatch), attempts left {AttemptsLeft}");
            LockIfExhausted();
        }
        return new(PairOutcomeKind.Aborted, null, AttemptsLeft);
    }

    // MARK: - 命令

    public static string Describe(RejectReason r) => r switch
    {
        RejectReason.Malformed => "malformed or unsigned",
        RejectReason.UnknownPhone => "unknown phone",
        RejectReason.BadSignature => "bad signature",
        RejectReason.Replay => "old counter (replay)",
        RejectReason.NetworkForbidden => "not allowed on network",
        RejectReason.BadNonce => "network nonce missing, stale or reused",
        _ => "store write failed",
    };

    public CommandOutcome HandleCommand(byte[] data, Transport via = Transport.Bluetooth)
    {
        CommandEnvelope e;
        try { e = CommandEnvelope.Decode(data); }
        catch (WireException)
        {
            log($"command rejected: {Describe(RejectReason.Malformed)}");
            return new(false, "", null, 0, false, null, RejectReason.Malformed);
        }
        var id = e.PhoneID;
        CommandOutcome Reject(RejectReason reason, AckStatus status, byte[]? key = null)
        {
            log($"command rejected from {Who(id)}: {Describe(reason)} (counter {e.Counter})");
            return new(false, "", id, e.Counter, false, PairingCrypto.MakeAck(id, e.Counter, status, key), reason);
        }

        var stored = store.Load(id);
        var network = via == Transport.Network;
        // 网络只认已经确认配上的手机，不看刚握手、还没确认的 pending
        var isPending = !network && stored == null && pending.ContainsKey(id);
        var record = stored ?? (!network && pending.TryGetValue(id, out var k) ? new PairingRecord(k, 0) : null);
        if (record == null) return Reject(RejectReason.UnknownPhone, AckStatus.UnknownOrBadSignature);
        if (!PairingCrypto.VerifyCommand(e, record.Key)) return Reject(RejectReason.BadSignature, AckStatus.UnknownOrBadSignature);
        if (e.Counter <= record.LastCounter) return Reject(RejectReason.Replay, AckStatus.Replay);
        if (!store.Save(record with { LastCounter = e.Counter }, id)) return Reject(RejectReason.StoreFailed, AckStatus.Malformed);
        var command = e.Command;
        if (network)
        {
            // 签名和计数已过（计数已记），再看白名单：签了名的撤下也一样拒绝
            var parsed = NetworkCommand.Unwrap(e.Command);
            var inner = parsed?.Command ?? e.Command;
            if (parsed is not { } p || !NetworkPolicy.Allows(inner))
            {
                log($"network command from {Who(id)} refused: not on the allow-list");
                return Reject(RejectReason.NetworkForbidden, AckStatus.NotAllowedOnNetwork, record.Key);
            }
            // ping 不用 nonce（它是拿 nonce 的办法）；带了就照样核对。其余必须带，nonce 只用一次
            if (inner.ToLowerInvariant() != "ping" || p.Nonce != null)
                if (p.Nonce is not { } nonce || !ConsumeNetworkNonce(nonce, id))
                    return Reject(RejectReason.BadNonce, AckStatus.Replay);
            command = inner;
        }
        if (isPending)
        {
            pending.Remove(id);
            log($"pairing confirmed with {Who(id)} (first signed command verified, key stored)");
        }
        log($"command accepted from {Who(id)}: \"{command}\" counter {e.Counter}{(network ? " (network)" : "")}");
        return new(true, command, id, e.Counter, isPending, PairingCrypto.MakeAck(id, e.Counter, AckStatus.Accepted, record.Key));
    }

    // MARK: - 撤下幕布：手机的回答

    /// 只认已经确认配上的手机（钥匙在存储里）；和命令共用同一个计数
    public AnswerOutcome HandleAnswer(byte[] data, Transport via = Transport.Bluetooth)
    {
        // 走网络一律拒绝：在验签之前就返回，不耗计数，LiftGate / OnLift 都够不到
        if (via != Transport.Bluetooth)
        {
            log("answer over network refused (lift is bluetooth-only)");
            return new(null, RejectReason.NetworkForbidden, null);
        }
        PhoneAnswer a;
        try { a = PhoneAnswer.Decode(data); }
        catch (WireException)
        {
            log($"answer rejected: {Describe(RejectReason.Malformed)}");
            return new(null, RejectReason.Malformed, null);
        }
        var id = a.PhoneID;
        AnswerOutcome Reject(RejectReason reason)
        {
            log($"answer rejected from {Who(id)}: {Describe(reason)} (counter {a.Counter})");
            return new(null, reason, id);
        }
        if (store.Load(id) is not { } record) return Reject(RejectReason.UnknownPhone);
        if (!PairingCrypto.VerifyAnswer(a, record.Key)) return Reject(RejectReason.BadSignature);
        if (a.Counter <= record.LastCounter) return Reject(RejectReason.Replay);
        if (!store.Save(record with { LastCounter = a.Counter }, id)) return Reject(RejectReason.StoreFailed);
        return new(a, default, id);
    }

    // MARK: - 网络 nonce（防止被扣住的命令事后再送到）

    /// 发一条签名的 Poll 给走网络的手机，里面的 nonce 记下来（单次、有寿命）。不进 LiftGate。手机不认识（没配上）返回 null
    public byte[]? NetworkPollMessage(Guid phoneID)
    {
        if (store.Load(phoneID) == null) return null;
        var nonce = PairingCrypto.MakeNonce();
        if (PollMessage(nonce, phoneID) is not { } message) return null;
        var now = Clock();
        var list = networkNonces.GetValueOrDefault(phoneID)?.Where(n => now - n.IssuedAt < NetworkNonceLifetime).ToList() ?? [];
        list.Add((nonce, now));
        if (list.Count > NetworkNonceLimit) list.RemoveRange(0, list.Count - NetworkNonceLimit);
        networkNonces[phoneID] = list;
        return message;
    }

    /// 用掉一个 nonce：没发过、用过了、过期了都是 false
    bool ConsumeNetworkNonce(byte[] nonce, Guid phoneID)
    {
        var now = Clock();
        if (!networkNonces.TryGetValue(phoneID, out var list)) return false;
        var index = list.FindIndex(n => n.Nonce.AsSpan().SequenceEqual(nonce));
        if (index < 0) return false;
        var entry = list[index];
        list.RemoveAt(index);
        return now - entry.IssuedAt < NetworkNonceLifetime;
    }

    /// 这台手机的网络 nonce 都作废（断开 / 撤销时）
    public void DropNetworkNonces(Guid phoneID) => networkNonces.Remove(phoneID);

    public byte[]? PollMessage(byte[] nonce, Guid phoneID) =>
        store.Load(phoneID) is { } r ? PairingCrypto.MakePoll(nonce, phoneID, r.Key) : null;

    public byte[]? LiftResultMessage(LiftStatus status, ulong counter, Guid phoneID) =>
        store.Load(phoneID) is { } r ? PairingCrypto.MakeLiftResult(status, counter, phoneID, r.Key) : null;

    // MARK: - 发给手机的东西

    ulong lastSeq;

    /// seq 用毫秒时间，但保证严格递增（同一毫秒里发 State 和 KeepAwakeState 也不重复）：手机拿它挡重放的旧状态。
    /// State 和 KeepAwakeState 共用这一个计数（protocol v3 §3）
    public ulong NextSeq(DateTime? now = null)
    {
        var ms = (ulong)new DateTimeOffset(DateTime.SpecifyKind(now ?? DateTime.UtcNow, DateTimeKind.Utc)).ToUnixTimeMilliseconds();
        lastSeq = Math.Max(lastSeq + 1, ms);
        return lastSeq;
    }

    public byte[]? StateMessage(bool closed, Guid phoneID) =>
        store.Load(phoneID) is { } r ? PairingCrypto.MakeState(closed, NextSeq(), phoneID, r.Key) : null;

    /// 保持唤醒的现状（kind 0x0F），只发给确认配上的手机
    public byte[]? KeepAwakeStateMessage(KeepAwakeWireState state, Guid phoneID) =>
        store.Load(phoneID) is { } r ? state.Seal(phoneID, NextSeq(), r.Key) : null;

    /// 撤销一台：先签好撤销通知再删钥匙
    public byte[]? Revoke(Guid phoneID)
    {
        var notice = store.Load(phoneID) is { } r ? PairingCrypto.MakeRevoke(phoneID, r.Key) : null;
        store.Delete(phoneID);
        pending.Remove(phoneID);
        networkNonces.Remove(phoneID);
        log($"pairing deleted for {Who(phoneID)}");
        return notice;
    }

    /// 撤销全部，返回每台手机的撤销通知
    public Dictionary<Guid, byte[]> RevokeAll()
    {
        var notices = new Dictionary<Guid, byte[]>();
        foreach (var id in PairedPhoneIDs)
            if (Revoke(id) is { } n) notices[id] = n;
        pending.Clear();
        return notices;
    }
}
