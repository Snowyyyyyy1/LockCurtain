// PhoneSelfTest —— Windows 版手机配对协议（windows/LockCurtain/Phone/Protocol）的自测，不碰蓝牙、不碰 DPAPI
//
// 运行（在 Mac 上就能跑，不需要 Windows）：
//   cd windows/Tests/PhoneSelfTest && dotnet run
//
// 两部分：
//   1. 跨实现：Tests/PhoneVectors/vectors.json 是 Mac 的 Swift 实现算的（Tools/phone-vectors.swift），
//      这里用 C# 实现重算 / 解码，逐字节对上：CPace 生成元 / ISK / 标签、握手四条消息、命令签名、收据、状态、撤销、
//      问询 / 回答 / 结果、分帧、计数重放（同一串消息喂给两边的 PairingAuthority，结果一样）、LiftGate 全部场景。
//   2. 本地：对照 Sources/PairingSelfTest.swift 的握手 / 冒充 / 错码 / 重放 / 撤销测试（码规则按 Windows 文案：一个码错 3 次）。
//   3. 重连退避（Phone/ReconnectPolicy.cs）：封顶 5 分钟、配过对时早断只退避不停手、没配过时第 5 次硬停、限时不理、位图取交集；
//      「现在撤下」不看「走近撤下」开关。
// 全部通过返回 0，有失败返回 1。

using System.Text;
using System.Text.Json;
using LockCurtain.Phone;

var failures = 0;
var total = 0;
void Check(bool cond, string name)
{
    total++;
    if (!cond) { failures++; Console.WriteLine("  FAIL " + name); }
    else Console.WriteLine("  OK   " + name);
}

byte[] H(string s) => Convert.FromHexString(s);
bool Eq(byte[]? a, byte[]? b) => a != null && b != null && a.AsSpan().SequenceEqual(b);
string Hx(byte[]? b) => b == null ? "null" : Bytes.Hex(b);

var path = Path.Combine(AppContext.BaseDirectory, "vectors.json");
using var doc = JsonDocument.Parse(File.ReadAllText(path));
var root = doc.RootElement;
string S(JsonElement e, string name) => e.GetProperty(name).GetString()!;
byte[] B(JsonElement e, string name) => H(S(e, name));

// MARK: - CPace 草案向量
Console.WriteLine("== CPace（草案附录 B.1，Swift 重算过）==");
{
    var v = root.GetProperty("cpaceDraft");
    var (prs, ci, sid) = (B(v, "prs"), B(v, "ci"), B(v, "sid"));
    Check(Eq(CPace.GeneratorString(prs, ci, sid), B(v, "generatorString")), "generator_string");
    var g = CPace.CalculateGenerator(prs, ci, sid);
    Check(Eq(g, B(v, "g")) && Hx(g) == "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f", "生成元 g（Elligator2）");
    var ya = CPace.ScalarMult(B(v, "ya"), g);
    var yb = CPace.ScalarMult(B(v, "yb"), g);
    Check(Eq(ya, B(v, "Ya")) && Eq(yb, B(v, "Yb")), "Ya、Yb（BouncyCastle X25519）");
    var kA = CPace.ScalarMult(B(v, "ya"), yb!);
    var kB = CPace.ScalarMult(B(v, "yb"), ya!);
    Check(Eq(kA, B(v, "K")) && Eq(kB, B(v, "K")), "K 两边一样");
    Check(Eq(CPace.Isk(sid, kA!, ya!, B(v, "ada"), yb!, B(v, "adb")), B(v, "isk")), "ISK（发起方-应答方）");
    Check(Hx(CPace.PrependLen([])) == "00" && Hx(CPace.PrependLen("1234"u8.ToArray())) == "0431323334"
          && Hx(CPace.PrependLen(new byte[128]))[..4] == "8001", "prepend_len（LEB128）");
    Check(Hx(CPace.LvCat("1234"u8.ToArray(), "5"u8.ToArray(), [], "678"u8.ToArray())) == "043132333401350003363738", "lv_cat");
}

Console.WriteLine("== Elligator2 / 域运算 ==");
{
    var all = root.GetProperty("elligator2").EnumerateArray().ToList();
    var bad = all.Where(e => !Eq(CPace.Elligator2(B(e, "in")), B(e, "out"))).Select(e => S(e, "in")).ToList();
    Check(bad.Count == 0, $"Elligator2 {all.Count} 组和 Swift 一样{(bad.Count > 0 ? "，错：" + string.Join(",", bad) : "")}");
    var a = Field25519.FromBytes(H("86ef3110c37b8ca53ef79f8fa4c2ee6872938823efbd9251b19c500f8a22b309"));
    var minusOne = Field25519.Zero - Field25519.One;
    Check(Field25519.Equal(a * a.Inverse, Field25519.One) && Field25519.Equal(minusOne * minusOne, Field25519.One), "求逆、−1 的平方");
    Check(Hx(Field25519.FromBytes(H("03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed1d3")).ToBytes())
          == "03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed153", "decodeUCoordinate 去最高位");
}

Console.WriteLine("== X25519 低阶点 ==");
{
    var v = root.GetProperty("scalarMult");
    var s = B(v, "scalar");
    var cases = v.GetProperty("cases").EnumerateArray().ToList();
    var ok = cases.All(c =>
    {
        var o = CPace.ScalarMult(s, B(c, "u"));
        var want = c.GetProperty("out");
        return want.ValueKind == JsonValueKind.Null ? o == null : Eq(o, H(want.GetString()!));
    });
    Check(ok, $"{cases.Count} 个低阶 / 非规范点：中止的中止，结果和 CryptoKit 一样");
}

// MARK: - 握手
Console.WriteLine("== 握手（固定标量，逐字节）==");
foreach (var h in root.GetProperty("handshakes").EnumerateArray())
{
    var name = S(h, "name");
    var phoneID = Guid.Parse(S(h, "phoneID"));
    var sid = B(h, "sid");
    Check(Eq(PairingCrypto.IdBytes(phoneID), B(h, "phoneIDBytes")) && PairingCrypto.IdString(phoneID) == S(h, "phoneID"),
          $"{name}：phoneID 线上字节序（大端）和大写写法");
    Check(Eq(PairingCrypto.ChannelID(phoneID), B(h, "channelID")), $"{name}：CI");
    Check(Eq(CPace.GeneratorString(System.Text.Encoding.UTF8.GetBytes(S(h, "phoneCode")), PairingCrypto.ChannelID(phoneID), sid),
             B(h, "generatorString")), $"{name}：generator_string");
    Check(Eq(PairingCrypto.Generator(S(h, "phoneCode"), phoneID, sid), B(h, "gPhone"))
          && Eq(PairingCrypto.Generator(S(h, "macCode"), phoneID, sid), B(h, "gMac")), $"{name}：两边的生成元");

    var start = PairingCrypto.PhoneStart(S(h, "phoneCode"), phoneID, sid, B(h, "ya"))!.Value;
    Check(Eq(start.Request.Encoded(), B(h, "pairRequest")), $"{name}：PairRequest 字节");
    var decodedReq = PairRequest.Decode(B(h, "pairRequest"));
    Check(decodedReq.PhoneID == phoneID && Eq(decodedReq.Sid, sid) && Eq(decodedReq.Ya, B(h, "Ya")), $"{name}：PairRequest 解码");

    var respond = PairingCrypto.MacRespond(decodedReq, S(h, "macCode"), B(h, "yb"))!.Value;
    Check(Eq(respond.Response.Encoded(), B(h, "pairResponse")), $"{name}：PairResponse 字节（Yb + Tb）");
    Check(Eq(respond.Session.MacKey, B(h, "macMacKey")) && Eq(respond.Session.SharedKey, B(h, "macSharedKey")),
          $"{name}：电脑这边的 mac_key 和共享钥匙（HKDF）");
    var keys = PairingCrypto.DeriveHandshakeKeys(sid, B(h, "Kmac"), B(h, "Ya"), B(h, "Yb"));
    Check(Eq(CPace.Isk(sid, B(h, "Kmac"), B(h, "Ya"), [], B(h, "Yb"), []), B(h, "isk")) && Eq(keys.MacKey, B(h, "macMacKey")),
          $"{name}：ISK");

    var step = PairingCrypto.PhoneFinish(PairResponse.Decode(B(h, "pairResponse")), start.Session);
    var phoneAccepts = h.GetProperty("phoneAcceptsTb").GetBoolean();
    if (phoneAccepts)
    {
        Check(step.Kind == PhoneStepKind.Confirm && Eq(step.Confirm!.Encoded(), B(h, "pairConfirm"))
              && Eq(step.SharedKey, B(h, "phoneSharedKey")), $"{name}：手机验过 Tb，PairConfirm（Ta）字节一样");
        Check(PairingCrypto.MacCheckConfirm(PairConfirm.Decode(B(h, "pairConfirm")), respond.Session), $"{name}：电脑验过 Swift 手机的 Ta");
        Check(Eq(PairingCrypto.PairAccepted(phoneID, sid, respond.Session.SharedKey), B(h, "pairAccepted"))
              && PairingCrypto.VerifyPairAccepted(B(h, "pairAccepted"), phoneID, sid, B(h, "phoneSharedKey")),
              $"{name}：PairAccepted 字节一样、手机能验过");
    }
    else
    {
        Check(step.Kind == PhoneStepKind.WrongCode, $"{name}：码不一样，手机验 Tb 不过");
        Check(!PairingCrypto.MacCheckConfirm(PairConfirm.Decode(B(h, "pairConfirm")), respond.Session),
              $"{name}：码不一样，电脑验 Ta 不过");
    }
    Check(Eq(PairingCrypto.PairAbort(phoneID, sid), B(h, "pairAbort"))
          && PairingCrypto.DecodePairAbort(B(h, "pairAbort")) is { } ab && ab.PhoneID == phoneID && Eq(ab.Sid, sid),
          $"{name}：PairAbort 字节和解码");
}
{
    var r = root.GetProperty("pairReject");
    Check(Eq(PairingCrypto.PairReject(PairRejectReason.WrongCode), B(r, "wrongCode"))
          && Eq(PairingCrypto.PairReject(PairRejectReason.NoCode), B(r, "noCode"))
          && PairingCrypto.DecodePairReject(B(r, "wrongCode")) == PairRejectReason.WrongCode, "PairReject 字节");
}

// MARK: - 握手之后的消息
Console.WriteLine("== 命令 / 收据 / 状态 / 撤销 / 问询 / 回答 ==");
{
    var m = root.GetProperty("messages");
    var key = B(m, "key");
    var other = B(m, "otherKey");
    var phoneID = Guid.Parse(S(m, "phoneID"));
    var nonce = B(m, "nonce");
    foreach (var c in m.GetProperty("commands").EnumerateArray())
    {
        var counter = ulong.Parse(S(c, "counter"));
        var sealedBytes = PairingCrypto.SealCommand(S(c, "command"), phoneID, counter, key);
        var e = CommandEnvelope.Decode(B(c, "sealed"));
        Check(Eq(sealedBytes, B(c, "sealed")) && e.Command == S(c, "command") && e.Counter == counter && e.PhoneID == phoneID
              && PairingCrypto.VerifyCommand(e, key) && !PairingCrypto.VerifyCommand(e, other),
              $"命令「{S(c, "command")}」计数 {counter}：字节一样、解码、验签");
        Check(PairingCrypto.KindOf(B(c, "sealed")) == Kind.Command, $"命令「{S(c, "command")}」：类型 / 版本 1");
    }
    Check(PairingCrypto.SealCommand(new string('x', 201), phoneID, 1, key) == null, "命令超过 200 字节不签");
    foreach (var a in m.GetProperty("acks").EnumerateArray())
    {
        var st = (AckStatus)a.GetProperty("status").GetInt32();
        var bytes = PairingCrypto.MakeAck(phoneID, ulong.Parse(S(a, "counter")), st, key);
        var d = Ack.Decode(B(a, "bytes"));
        Check(Eq(bytes, B(a, "bytes")) && d.Status == st && PairingCrypto.VerifyAck(d, key) == (st == AckStatus.Accepted),
              $"收据 status {(int)st}：字节一样，只有带签名的「收下」算数");
    }
    foreach (var s in m.GetProperty("states").EnumerateArray())
    {
        var closed = s.GetProperty("closed").GetBoolean();
        var seq = ulong.Parse(S(s, "seq"));
        var bytes = PairingCrypto.MakeState(closed, seq, phoneID, key);
        Check(Eq(bytes, B(s, "bytes")) && PairingCrypto.OpenState(bytes, phoneID, key) == (seq, closed)
              && PairingCrypto.OpenState(bytes, Guid.NewGuid(), key) == null && PairingCrypto.OpenState(bytes, phoneID, other) == null,
              $"状态 {(closed ? "盖着" : "开着")}：字节一样，别的手机 / 钥匙验不过");
    }
    Check(Eq(PairingCrypto.MakeRevoke(phoneID, key), B(m, "revoke")) && PairingCrypto.VerifyRevoke(B(m, "revoke"), phoneID, key)
          && !PairingCrypto.VerifyRevoke(B(m, "revoke"), phoneID, other), "撤销通知：字节一样、验签");
    Check(Eq(PairingCrypto.MakePoll(nonce, phoneID, key), B(m, "poll")) && Eq(PairingCrypto.OpenPoll(B(m, "poll"), phoneID, key), nonce)
          && PairingCrypto.OpenPoll(B(m, "poll"), phoneID, other) == null, "问询：字节一样、手机能拿到 nonce");
    foreach (var p in m.GetProperty("presence").EnumerateArray())
    {
        var st = (PresenceStatus)p.GetProperty("status").GetInt32();
        var counter = ulong.Parse(S(p, "counter"));
        var d = PhoneAnswer.Decode(B(p, "bytes"));
        Check(Eq(PairingCrypto.SealPresence(st, nonce, phoneID, counter, key), B(p, "bytes")) && !d.IsLiftNow && d.Status == st
              && d.Counter == counter && Eq(d.Nonce, nonce) && PairingCrypto.VerifyAnswer(d, key) && !PairingCrypto.VerifyAnswer(d, other),
              $"Presence {st}：字节一样、解码、验签");
    }
    {
        var l = m.GetProperty("liftNow");
        var counter = ulong.Parse(S(l, "counter"));
        var d = PhoneAnswer.Decode(B(l, "bytes"));
        Check(Eq(PairingCrypto.SealLiftNow(nonce, phoneID, counter, key), B(l, "bytes")) && d.IsLiftNow && d.Counter == counter
              && PairingCrypto.VerifyAnswer(d, key), "LiftNow：字节一样、解码、验签");
    }
    foreach (var r in m.GetProperty("liftResults").EnumerateArray())
    {
        var st = (LiftStatus)r.GetProperty("status").GetInt32();
        var bytes = PairingCrypto.MakeLiftResult(st, 13, phoneID, key);
        Check(Eq(bytes, B(r, "bytes")) && PairingCrypto.OpenLiftResult(bytes, phoneID, key) == (13UL, st), $"LiftResult {st}：字节一样");
    }
    var cmd = PairingCrypto.SealCommand("away", phoneID, 3, key)!;
    var presence = PairingCrypto.SealPresence(PresenceStatus.Unlocked, nonce, phoneID, 3, key)!;
    Check(Throws(() => PhoneAnswer.Decode(cmd)) && Throws(() => CommandEnvelope.Decode(presence)), "命令不会被当成回答，回答也不会被当成命令");
    var v1 = PairingCrypto.PhoneStart("123456", phoneID)!.Value.Request.Encoded();
    v1[0] = 1;
    Check(PairingCrypto.KindOf(v1) == null, "版本 1 的配对请求不认");
}

// MARK: - protocol v3
Console.WriteLine("== protocol v3：保持唤醒 / 手机名 / 缺权限收据 ==");
{
    var m = root.GetProperty("messages");
    var key = B(m, "key");
    var other = B(m, "otherKey");
    var phoneID = Guid.Parse(S(m, "phoneID"));
    foreach (var c in m.GetProperty("commandsV3").EnumerateArray())
    {
        var counter = ulong.Parse(S(c, "counter"));
        var e = CommandEnvelope.Decode(B(c, "sealed"));
        Check(Eq(PairingCrypto.SealCommand(S(c, "command"), phoneID, counter, key), B(c, "sealed")) && e.Command == S(c, "command")
              && PairingCrypto.VerifyCommand(e, key), $"v3 命令「{S(c, "command")}」：字节一样、验签");
    }
    {
        var a = m.GetProperty("ackMissingPermission");
        var counter = ulong.Parse(S(a, "counter"));
        var bytes = PairingCrypto.MakeAck(phoneID, counter, AckStatus.MissingPermission, key);
        var d = Ack.Decode(B(a, "bytes"));
        Check(Eq(bytes, B(a, "bytes")) && d.Status == AckStatus.MissingPermission && PairingCrypto.VerifyAck(d, key)
              && !PairingCrypto.VerifyAck(d, other), "收据 status 4（缺权限）：字节一样、带签名");
    }
    foreach (var s in m.GetProperty("keepAwakeStates").EnumerateArray())
    {
        var seq = ulong.Parse(S(s, "seq"));
        var mode = (byte)s.GetProperty("mode").GetInt32();
        var ends = ulong.Parse(S(s, "endsAt"));
        var bytes = PairingCrypto.MakeKeepAwakeState(phoneID, seq, mode, ends, S(s, "appNameIn"), key);
        Check(Eq(bytes, B(s, "bytes")) && PairingCrypto.OpenKeepAwakeState(bytes, phoneID, key) == (seq, mode, ends, S(s, "appName"))
              && PairingCrypto.OpenKeepAwakeState(bytes, phoneID, other) == null && PairingCrypto.OpenKeepAwakeState(bytes, Guid.NewGuid(), key) == null,
              $"KeepAwakeState mode {mode}（app {Encoding.UTF8.GetByteCount(S(s, "appNameIn"))} 字节）：字节一样，别的手机 / 钥匙验不过");
    }

    Check(AwakeRequest.Parse("awake:off") == new AwakeRequest(AwakeRequestKind.Off)
          && AwakeRequest.Parse("awake:always") == new AwakeRequest(AwakeRequestKind.Always)
          && AwakeRequest.Parse("awake:1h") == new AwakeRequest(AwakeRequestKind.For, TimeSpan.FromHours(1))
          && AwakeRequest.Parse("awake:2h") == new AwakeRequest(AwakeRequestKind.For, TimeSpan.FromHours(2))
          && AwakeRequest.Parse("awake:5h") == new AwakeRequest(AwakeRequestKind.For, TimeSpan.FromHours(5)),
          "awake:off / always / 1h / 2h / 5h 都认");
    Check(AwakeRequest.Parse("awake:3h") == null && AwakeRequest.Parse("awake:") == null && AwakeRequest.Parse("away") == null,
          "不认识的 awake:xxx 当没收到");
    var end = new DateTime(2027, 1, 15, 8, 0, 0, DateTimeKind.Utc);
    var endSec = (ulong)new DateTimeOffset(end).ToUnixTimeSeconds();
    Check(KeepAwakeWireState.Make(KeepAwakeWireMode.Timed, end) == new KeepAwakeWireState(KeepAwakeWireMode.Timed, endSec, "")
          && KeepAwakeWireState.Make(KeepAwakeWireMode.UntilClock, end, "x") == new KeepAwakeWireState(KeepAwakeWireMode.UntilClock, endSec, "")
          && KeepAwakeWireState.Make(KeepAwakeWireMode.Always, end, "x") == new KeepAwakeWireState(KeepAwakeWireMode.Always, 0, "")
          && KeepAwakeWireState.Make(KeepAwakeWireMode.WhileApp, end, "微信") == new KeepAwakeWireState(KeepAwakeWireMode.WhileApp, 0, "微信"),
          "KeepAwakeState：只有定时长 / 到时刻带 endsAt，只有程序开着时带 appName");

    Check(PhoneName.Clean("  Snowy 的 iPhone\n") == "Snowy 的 iPhone" && PhoneName.Clean(" \t ") == null
          && Encoding.UTF8.GetByteCount(PhoneName.Clean(new string('应', 40))!) <= PhoneName.MaxBytes
          && PhoneName.Clean(new string('应', 40)) == new string('应', 20), "手机名：去控制字符和空白，截到 60 字节不切开字");

    // State 和 KeepAwakeState 共用一个严格递增的 seq，同一毫秒里也不重复
    var seqPc = new PairingAuthority(new MemoryPairingStore(), _ => { });
    var t = new DateTime(2026, 11, 4, 1, 0, 0, DateTimeKind.Utc);
    var s1 = seqPc.NextSeq(t);
    var s2 = seqPc.NextSeq(t);
    var s3 = seqPc.NextSeq(t.AddSeconds(-30));
    Check(s1 == (ulong)new DateTimeOffset(t).ToUnixTimeMilliseconds() && s2 == s1 + 1 && s3 == s2 + 1,
          "seq：毫秒时间，同一毫秒 / 钟往回拨也严格递增");
}

Console.WriteLine("== 界面上的字 / 启动器命令行 ==");
{
    var tz = TimeZoneInfo.CreateCustomTimeZone("UTC+8", TimeSpan.FromHours(8), "UTC+8", "UTC+8");
    var now = new DateTime(2026, 11, 4, 6, 0, 0, DateTimeKind.Utc);      // 本地 14:00
    Check(LockCurtain.UiText.Ago(now.AddSeconds(-30), now, tz) == "刚刚" && LockCurtain.UiText.Ago(now.AddMinutes(5), now, tz) == "刚刚"
          && LockCurtain.UiText.Ago(now.AddMinutes(-7), now, tz) == "7 分钟前"
          && LockCurtain.UiText.Ago(now.AddHours(-3), now, tz) == "3 小时前"
          && LockCurtain.UiText.Ago(now.AddHours(-15), now, tz) == "昨天"
          && LockCurtain.UiText.Ago(now.AddDays(-3), now, tz) == "11 月 1 日",
          "上次连上：刚刚 / N 分钟前 / N 小时前 / 昨天 / M 月 D 日");
    Check(LockCurtain.UiText.PhoneTitle("iPhone", now, tz) == "iPhone · 11 月 4 日配上" && LockCurtain.UiText.PhoneTitle("iPhone", null, tz) == "iPhone",
          "已配对那一行：「iPhone · 11 月 4 日配上」");
    Check(LockCurtain.UiText.PhoneStatus(true, now, now, tz) == "已连上"
          && LockCurtain.UiText.PhoneStatus(false, now.AddHours(-3), now, tz) == "没连上 · 上次连上：3 小时前"
          && LockCurtain.UiText.PhoneStatus(false, null, now, tz) == "没连上", "已连上 / 没连上 · 上次连上：…");
    Check(LockCurtain.UiText.Duration(TimeSpan.FromSeconds(40)) == "不到 1 分" && LockCurtain.UiText.Duration(TimeSpan.FromMinutes(59.9)) == "59 分"
          && LockCurtain.UiText.Duration(TimeSpan.FromHours(2)) == "2 小时" && LockCurtain.UiText.Duration(TimeSpan.FromMinutes(80)) == "1 小时 20 分",
          "时长：不到 1 分 / N 分 / N 小时 / N 小时 M 分");
    Check(LockCurtain.UiText.PhoneTitleParts("iPhone", now, tz) == ("iPhone", " · 11 月 4 日配上")
          && LockCurtain.UiText.PhoneTitleParts("iPhone", null, tz) == ("iPhone", null),
          "已配对那一行分两段：名字 / 「 · 11 月 4 日配上」（次要颜色）");
    Check(LockCurtain.UiText.Remaining(TimeSpan.FromSeconds(40)) == "不到 1 分钟"
          && LockCurtain.UiText.Remaining(TimeSpan.FromMinutes(80)) == "还剩 1 小时 20 分",
          "右键菜单保持唤醒剩余时间：还剩 1 小时 20 分 / 不到 1 分钟");

    Check(LockCurtain.CtlArgs.Parse([]).Action == LockCurtain.CtlAction.Launch && LockCurtain.CtlArgs.Parse(["--launch"]).Action == LockCurtain.CtlAction.Launch,
          "启动器：没参数 / --launch 起主程序");
    Check(LockCurtain.CtlArgs.Parse(["--send", "away"]) == new LockCurtain.CtlArgs(LockCurtain.CtlAction.Send, "away")
          && LockCurtain.CtlArgs.Parse(["away"]) == new LockCurtain.CtlArgs(LockCurtain.CtlAction.Send, "away")
          && LockCurtain.CtlArgs.Parse(["--send"]) == new LockCurtain.CtlArgs(LockCurtain.CtlAction.Send, "status"),
          "启动器：--send away 和旧写法 away 一样；--send 后面没命令 = status");
    Check(LockCurtain.CtlArgs.Parse(["--relaunch-after", "42"]) == new LockCurtain.CtlArgs(LockCurtain.CtlAction.Relaunch, Pid: 42)
          && LockCurtain.CtlArgs.Parse(["--relaunch-after"]).Pid == null, "启动器：--relaunch-after <pid>");
}

// MARK: - 分帧
Console.WriteLine("== 分帧 ==");
foreach (var f in root.GetProperty("framing").EnumerateArray())
{
    var msg = B(f, "message");
    var size = f.GetProperty("maxChunk").GetInt32();
    var want = f.GetProperty("chunks").EnumerateArray().Select(c => H(c.GetString()!)).ToList();
    var got = PairingFraming.Chunks(msg, size);
    var asm = new PairingFraming.Assembler();
    byte[]? rebuilt = null;
    foreach (var c in got) rebuilt = asm.Feed(c) ?? rebuilt;
    Check(got.Count == want.Count && got.Zip(want).All(p => Eq(p.First, p.Second)), $"{msg.Length} 字节按 {size} 切：块和 Swift 一样");
    // 块序号模 128：超过 128 块时第 129 块的序号又是 0，两边的拼装器都会从头再来（和 Swift 一样），这种长度实际不会出现
    if (got.Count <= 128) Check(Eq(rebuilt, msg), $"{msg.Length} 字节按 {size} 切：拼回来一样");
    else Check(!Eq(rebuilt, msg), $"{msg.Length} 字节按 {size} 切成 {got.Count} 块（> 128）：和 Swift 一样拼不回原消息");
}
{
    var parts = PairingFraming.Chunks(new byte[200], 20);
    var asm = new PairingFraming.Assembler();
    asm.Feed(parts[0]);
    Check(asm.Feed(parts[2]) == null, "漏块整条丢掉");
    var big = new PairingFraming.Assembler();
    byte[]? o = null;
    foreach (var c in PairingFraming.Chunks(new byte[1100], 100)) o = big.Feed(c) ?? o;
    Check(o == null, "超过 1024 字节的消息丢掉");
}

// MARK: - 计数 / 重放（和 Swift 的 PairingAuthority 同一串消息）
Console.WriteLine("== 计数 / 重放（和 Swift PairingAuthority 逐步一样）==");
{
    var r = root.GetProperty("replay");
    var store = new MemoryPairingStore();
    var phoneID = Guid.Parse(S(r, "phoneID"));
    store.Save(new PairingRecord(B(r, "key"), ulong.Parse(S(r, "initialCounter"))), phoneID);
    var authority = new PairingAuthority(store, _ => { });
    var i = 0;
    foreach (var step in r.GetProperty("steps").EnumerateArray())
    {
        i++;
        var bytes = B(step, "bytes");
        string result;
        var ackOK = true;
        if (S(step, "kind") == "command")
        {
            var o = authority.HandleCommand(bytes);
            result = o.Accepted ? "accepted" : Camel(o.Reason);
            var ack = step.GetProperty("ack");
            ackOK = ack.ValueKind == JsonValueKind.Null ? o.Ack == null : Eq(o.Ack, H(ack.GetString()!));
        }
        else
        {
            var o = authority.HandleAnswer(bytes);
            result = o.Accepted ? "accepted" : Camel(o.Reason);
        }
        Check(result == S(step, "result") && ackOK && store.Load(phoneID)!.LastCounter.ToString() == S(step, "storedCounter"),
              $"第 {i} 步 {S(step, "kind")}：{S(step, "result")}，计数 {S(step, "storedCounter")}{(result != S(step, "result") ? $"（C# 给的 {result}）" : "")}");
    }
}

// MARK: - LiftGate（Swift 跑出来的结果当期望值）
Console.WriteLine("== LiftGate 场景（和 Swift LiftGate 逐步一样）==");
{
    var lg = root.GetProperty("liftGate");
    Check(lg.GetProperty("nearMedianDBm").GetInt32() == LiftGate.NearMedianDBm && lg.GetProperty("rssiSamples").GetInt32() == LiftGate.RssiSamples
          && lg.GetProperty("rssiMaxAge").GetDouble() == LiftGate.RssiMaxAge && lg.GetProperty("challengeLifetime").GetDouble() == LiftGate.ChallengeLifetime
          && lg.GetProperty("maxOpenChallenges").GetInt32() == LiftGate.MaxOpenChallenges, "门槛常数和 Mac 一样（-65 dBm、3 次、7 s、5 s、4 个）");
    var t0 = new DateTime(2027, 1, 15, 8, 0, 0, DateTimeKind.Utc);
    foreach (var sc in lg.GetProperty("scenarios").EnumerateArray())
    {
        var g = new LiftGate();
        var mismatches = new List<string>();
        var n = 0;
        foreach (var st in sc.GetProperty("steps").EnumerateArray())
        {
            n++;
            var at = t0.AddSeconds(st.GetProperty("t").GetDouble());
            byte[] Nonce() => Enumerable.Repeat((byte)st.GetProperty("nonce").GetInt32(), 16).ToArray();
            LiftDecision? d = null;
            switch (S(st, "op"))
            {
                case "covered": g.Covered(at); break;
                case "uncovered": g.Uncovered(); break;
                case "rssi": g.RecordRSSI(st.GetProperty("v").GetInt32(), at); break;
                case "resetRSSI": g.ResetRSSI(); break;
                case "issue": g.Issue(Nonce(), at); break;
                case "presence": d = g.Presence((PresenceStatus)st.GetProperty("status").GetInt32(), Nonce(), at); break;
                case "liftNow": d = g.LiftNow(Nonce(), at); break;
            }
            if (d is { } dd)
            {
                if (dd.ToString() != S(st, "expect")) mismatches.Add($"步 {n}: {dd} ≠ {S(st, "expect")}");
                if (!dd.Lift && st.TryGetProperty("resultStatus", out var rs) && (int)LiftGate.ResultStatus(dd.Why) != rs.GetInt32())
                    mismatches.Add($"步 {n}: 结果码 {(int)LiftGate.ResultStatus(dd.Why)} ≠ {rs.GetInt32()}");
            }
            if (g.EdgeArmed != st.GetProperty("edgeArmed").GetBoolean()) mismatches.Add($"步 {n}: edgeArmed");
        }
        Check(mismatches.Count == 0, $"{S(sc, "name")}{(mismatches.Count > 0 ? "：" + string.Join("; ", mismatches) : "")}");
    }
}

// MARK: - 重连退避
Console.WriteLine("== 重连退避 ==");
{
    var t0 = new DateTime(2027, 1, 15, 8, 0, 0, DateTimeKind.Utc);
    TimeSpan Sec(double v) => TimeSpan.FromSeconds(v);
    var delays = Enumerable.Range(0, 8).Select(i => Reconnect.Delay(i, Sec(30), Reconnect.Cap).TotalSeconds).ToArray();
    Check(delays.SequenceEqual(new double[] { 30, 60, 120, 240, 300, 300, 300, 300 }), "退避：30 s 起翻倍，封顶 5 分钟");
    Check(Reconnect.Delay(1000, Sec(30), Reconnect.Cap) == Reconnect.Cap, "退避：次数很大也不溢出");

    var known = new ReconnectBackoff(Sec(10), Reconnect.Cap);
    var kd = Enumerable.Range(0, 7).Select(_ => known.Fail(t0).TotalSeconds).ToArray();
    Check(kd.SequenceEqual(new double[] { 10, 20, 40, 80, 160, 300, 300 }), "记得的地址：10 s → 20 s → … → 5 分钟");
    Check(known.Holding(t0.AddSeconds(299)) && !known.Holding(t0.AddSeconds(300)), "记得的地址：到点就放开");
    known.Reset();
    Check(!known.Holding(t0) && known.Fail(t0) == Sec(10), "记得的地址：看到我们的广播清零后从头算");

    var paired = new EarlyDropPolicy();
    var outs = Enumerable.Range(0, 12).Select(i => paired.NoteDrop(true, t0.AddSeconds(i))).ToList();
    Check(outs.Take(4).All(o => o.Outcome == EarlyDropOutcome.KeepGoing), "早断（配过对）：前 4 次照常");
    Check(outs.Skip(4).Take(5).Select(o => o.Delay.TotalSeconds).SequenceEqual(new double[] { 30, 60, 120, 240, 300 })
          && outs.Skip(4).All(o => o.Outcome == EarlyDropOutcome.Backoff), "早断（配过对）：第 5 次起退避 30/60/120/240/300 秒");
    Check(outs.All(o => o.Outcome != EarlyDropOutcome.Stop), "早断（配过对）：从不硬停");
    Check(paired.Holding(t0.AddSeconds(12)) && !paired.Holding(t0.AddSeconds(11 + 300)), "早断（配过对）：到点自己放开");
    paired.Reset();
    Check(paired.Drops == 0 && !paired.Holding(t0), "早断：订阅成功 / 唤醒 / 蓝牙打开后清零");
    var unpaired = new EarlyDropPolicy();
    var u = Enumerable.Range(0, 5).Select(_ => unpaired.NoteDrop(false, t0).Outcome).ToList();
    Check(u.Take(4).All(o => o == EarlyDropOutcome.KeepGoing) && u[4] == EarlyDropOutcome.Stop, "早断（没配过）：第 5 次硬停");

    var ign = new TimedIgnoreList<ulong>();
    Check(ign.Ignore(7, t0) == Sec(30) && ign.Contains(7, t0.AddSeconds(29)) && !ign.Contains(7, t0.AddSeconds(30)), "不理：第一次 30 秒，到点放出来");
    Check(ign.Expire(t0.AddSeconds(31)).SequenceEqual(new ulong[] { 7 }) && ign.Count == 0, "不理：自检把到点的清掉");
    var seq = Enumerable.Range(0, 6).Select(_ => ign.Ignore(7, t0).TotalSeconds).ToArray();
    Check(seq.SequenceEqual(new double[] { 60, 120, 240, 300, 300, 300 }), "不理：再犯翻倍，封顶 5 分钟，永远限时");
    ign.Forgive(7);
    Check(!ign.Contains(7, t0) && ign.Ignore(7, t0) == Sec(30), "不理：认出身份后从头算");

    // 认得的、配过对的手机说不出身份：8 s 断，静默 3 s → 5 s 封顶，不再翻倍；别的地址照旧长拉黑
    Check(NoIdentifyPolicy.KindOf(true, true) == NoIdentifyKind.KnownPaired && NoIdentifyPolicy.KindOf(true, false) == NoIdentifyKind.Timed
          && NoIdentifyPolicy.KindOf(false, true) == NoIdentifyKind.Timed && NoIdentifyPolicy.KnownIdentifyTimeout == Sec(8), "说不出身份：认得 + 配过对 8 秒就断，别的照旧");
    var hold = NoIdentifyPolicy.MakeKnownHoldList<ulong>();
    var holds = Enumerable.Range(0, 50).Select(_ => hold.Ignore(9, t0).TotalSeconds).ToArray();
    Check(holds.Take(3).SequenceEqual(new double[] { 3, 5, 5 }) && holds.All(h => h >= 3 && h <= 5), "说不出身份（认得 + 配过对）：静默 3 s → 5 s 封顶，反复 50 次不翻倍");
    Check(hold.Contains(9, t0.AddSeconds(4.9)) && !hold.Contains(9, t0.AddSeconds(5)), "说不出身份（认得 + 配过对）：到点放出来，永远限时");
    hold.Forgive(9);
    Check(hold.Ignore(9, t0) == Sec(3), "说不出身份（认得 + 配过对）：认出身份后从头算");

    byte[] Bits(params int[] on) { var b = new byte[16]; foreach (var i in on) b[i / 8] |= (byte)(1 << (i % 8)); return b; }
    var ours = 42;
    var learned = OverflowBitmap.Intersect(null, Bits(ours, 3, 77));
    learned = OverflowBitmap.Intersect(learned, Bits(ours, 77, 100));
    learned = OverflowBitmap.Intersect(learned, Bits(ours, 5));
    Check(learned.SequenceEqual(Bits(ours)), "位图：多次观察取交集，别的后台 App 的位筛掉");
    Check(OverflowBitmap.Contains(Bits(ours, 9, 120), learned) && !OverflowBitmap.Contains(Bits(9, 120), learned),
          "位图：别的后台 App 换了也对得上，没有我们那一位就对不上");
    Check(OverflowBitmap.Intersect(Bits(1), Bits(2)).SequenceEqual(Bits(2)), "位图：交集空了就从这次重新学");

    // 系统醒了：连报两次 Resume 只动手一次（只有最后那次的计时算）
    var rd = new ResumeDebounce();
    var first = rd.Arm();
    var second = rd.Arm();
    Check(!rd.Fire(first) && rd.Fire(second) && !rd.Fire(second), "醒来：两次 Resume 只留一个计时、只动手一次");
    var third = rd.Arm();
    rd.Cancel();
    Check(!rd.Fire(third) && !rd.Pending, "醒来：计时没到又睡了，作废");

    // 日志去重
    var th = new LogThrottle();
    var written = Enumerable.Range(0, 60).Count(k => th.ShouldLog("rssi", "ok", t0.AddSeconds(k * 2), TimeSpan.FromMinutes(1)));
    Check(written == 2, $"日志：每 2 秒一样的 RSSI，2 分钟只写 2 行（实际 {written}）");
    Check(th.ShouldLog("presence", "locked", t0, TimeSpan.FromMinutes(1)) && th.ShouldLog("presence", "unlocked", t0.AddSeconds(2), TimeSpan.FromMinutes(1)),
          "日志：状态变了马上写");
    Check(th.Changed("k", "hold 5") && !th.Changed("k", "hold 5") && th.Changed("k", "hold 6"), "日志：退避只在状态变了时写");

    // 「现在撤下」不看「走近撤下」开关（电脑这边的 LiftGate）
    var g = new LiftGate();
    g.Covered(t0);
    for (var i = 0; i < 3; i++) g.RecordRSSI(-60, t0.AddSeconds(i * 2));
    var n7 = Enumerable.Repeat((byte)7, 16).ToArray();
    var n2 = Enumerable.Repeat((byte)2, 16).ToArray();
    g.Issue(n7, t0.AddSeconds(5));
    var off = g.Presence(PresenceStatus.Off, n7, t0.AddSeconds(5.2));
    g.Issue(n2, t0.AddSeconds(6));
    Check(!off.Lift && off.Why == Refusal.ToggleOff && g.LiftNow(n2, t0.AddSeconds(6.5)).Lift, "现在撤下：「走近撤下」关着也撤（不看开关）");
}

// MARK: - 本地：握手 / 码规则 / 冒充（对照 PairingSelfTest.swift）
Console.WriteLine("== 本地：配对规则 ==");
{
    var logs = new List<string>();
    const string code = "482913";
    var phoneID = Guid.NewGuid();
    var store = new MemoryPairingStore();
    var pc = new PairingAuthority(store, logs.Add);
    pc.OpenWindow(code);
    var run = Handshake(pc, code, phoneID);
    Check(run.Responded && run.Key != null, "握手：电脑回了 Tb，手机验过；电脑验过 Ta，PairAccepted 验过");
    Check(pc.Code == "" && !pc.IsPaired, "握手：码用过一次就作废；没收到签名命令前不算配上");
    var ping = pc.HandleCommand(PairingCrypto.SealCommand("ping", phoneID, 1, run.Key!)!);
    Check(ping.Accepted && ping.ConfirmedPairing && PairingCrypto.VerifyAck(Ack.Decode(ping.Ack!), run.Key!), "握手：第一条签名命令确认配对，收据带签名");
    Check(pc.IsPaired && Eq(store.Load(phoneID)!.Key, run.Key) && store.Load(phoneID)!.LastCounter == 1, "握手：钥匙和计数写进存储");

    // 错码：每个码最多 3 次，之后「换一个码」能换出新码
    var wrong = new PairingAuthority(new MemoryPairingStore(), logs.Add);
    wrong.OpenWindow(code);
    var typo = Handshake(wrong, "000000", Guid.NewGuid());
    Check(typo.WrongCode && typo.AbortLeft == 2, "错码：手机说码不对，电脑记一次，还剩 2 次");
    Handshake(wrong, "000000", Guid.NewGuid());
    Handshake(wrong, "000000", Guid.NewGuid());
    Check(wrong.IsLocked && wrong.Code == "", "错 3 次：码作废");
    var late = wrong.HandlePair(PairingCrypto.PhoneStart(code, Guid.NewGuid())!.Value.Request.Encoded());
    Check(late.Kind == PairOutcomeKind.NoCode && PairingCrypto.DecodePairReject(late.Reply!) == PairRejectReason.NoCode, "错 3 次：之后真码也被拒");
    wrong.Refresh("135790");
    Check(!wrong.IsLocked && wrong.AttemptsLeft == 3 && Handshake(wrong, "135790", Guid.NewGuid()).Key != null, "「换一个码」：新码能配上，次数重新算");
    var exp = new PairingAuthority(new MemoryPairingStore(), logs.Add);
    exp.OpenWindow(code);
    exp.Expire();
    Check(exp.IsLocked && exp.HandlePair(PairingCrypto.PhoneStart(code, Guid.NewGuid())!.Value.Request.Encoded()).Kind == PairOutcomeKind.NoCode,
          "过期：码作废，真码也被拒");

    // 放着不确认也算一次
    var ghost = new PairingAuthority(new MemoryPairingStore(), logs.Add);
    ghost.OpenWindow(code);
    for (var i = 0; i < 3; i++) ghost.HandlePair(PairingCrypto.PhoneStart("000000", Guid.NewGuid())!.Value.Request.Encoded());
    Check(ghost.AttemptsLeft == 0
          && ghost.HandlePair(PairingCrypto.PhoneStart(code, Guid.NewGuid())!.Value.Request.Encoded()).Kind == PairOutcomeKind.NoCode
          && ghost.IsLocked, "放着不确认：每一轮都扣一次，扣完真码也被拒");

    // 冒充的手机：不管 Tb，照样发自己算的 Ta
    var imp = new PairingAuthority(new MemoryPairingStore(), logs.Add);
    imp.OpenWindow(code);
    var impID = Guid.NewGuid();
    var (req, ses) = PairingCrypto.PhoneStart("000000", impID)!.Value;
    var resp = PairResponse.Decode(imp.HandlePair(req.Encoded()).Reply!);
    var kAtt = CPace.ScalarMult(ses.Secret, resp.Yb)!;
    var attKeys = PairingCrypto.DeriveHandshakeKeys(ses.Sid, kAtt, ses.Ya, resp.Yb);
    var forgedConfirm = new PairConfirm(impID, ses.Sid, CPace.Tag(attKeys.MacKey, ses.Ya, []));
    var rej = imp.HandlePair(forgedConfirm.Encoded());
    Check(rej.Kind == PairOutcomeKind.Rejected && PairingCrypto.DecodePairReject(rej.Reply!) == PairRejectReason.WrongCode && rej.AttemptsLeft == 2,
          "冒充手机：电脑拒绝它的 Ta，记一次错");
    var forgedCmd = imp.HandleCommand(PairingCrypto.SealCommand("ping", impID, 1, attKeys.SharedKey)!);
    Check(!forgedCmd.Accepted && forgedCmd.Reason == RejectReason.UnknownPhone && !imp.IsPaired && imp.Code == code,
          "冒充手机：它签的命令不认，什么都不存，码还在");
    Check(imp.HandlePair(forgedConfirm.Encoded()).Kind == PairOutcomeKind.Rejected && imp.AttemptsLeft == 2,
          "冒充手机：同一轮再交 Ta 不给第二次机会，也不再扣");

    // 冒充的电脑
    var (preq, pses) = PairingCrypto.PhoneStart(code, phoneID)!.Value;
    var fake = PairingCrypto.MacRespond(preq, "111111")!.Value;
    Check(PairingCrypto.PhoneFinish(fake.Response, pses).Kind == PhoneStepKind.WrongCode, "冒充电脑：手机验 Tb 不过");
    Check(!PairingCrypto.VerifyPairAccepted(PairingCrypto.PairAccepted(phoneID, pses.Sid, fake.Session.SharedKey), phoneID, pses.Sid,
                                            PairingCrypto.MakeNonce().Concat(PairingCrypto.MakeNonce()).ToArray()),
          "冒充电脑：伪造的 PairAccepted 验不过");
    var low = fake.Response with { Yb = new byte[32] };
    Check(PairingCrypto.PhoneFinish(low, pses).Kind == PhoneStepKind.Invalid, "冒充电脑：Yb 是低阶点，手机中止");
    var lowReq = new PairRequest(phoneID, PairingCrypto.MakeNonce(), new byte[32]);
    var lowPc = new PairingAuthority(new MemoryPairingStore(), logs.Add);
    lowPc.OpenWindow(code);
    Check(lowPc.HandlePair(lowReq.Encoded()).Kind == PairOutcomeKind.Malformed && lowPc.AttemptsLeft == 3, "Ya 是低阶点：电脑拒绝，不扣次数");

    // sid 重用
    var reuse = new PairingAuthority(new MemoryPairingStore(), logs.Add);
    reuse.OpenWindow(code);
    var (rreq, rses) = PairingCrypto.PhoneStart(code, phoneID)!.Value;
    var rresp = PairResponse.Decode(reuse.HandlePair(rreq.Encoded()).Reply!);
    var rconf = PairingCrypto.PhoneFinish(rresp, rses).Confirm!;
    Check(reuse.HandlePair(rreq.Encoded()).Kind == PairOutcomeKind.Malformed && reuse.AttemptsLeft == 2, "同一个 sid 不收第二次，不扣次数");
    Check(reuse.HandlePair(rconf.Encoded()).Kind == PairOutcomeKind.Accepted, "重放的请求不打扰进行中的那一轮");
    Check(reuse.HandlePair(rconf.Encoded()).Kind == PairOutcomeKind.Rejected, "用过的一轮，同一个 Ta 再交不收");
    reuse.OpenWindow(code);
    var (r2, s2) = PairingCrypto.PhoneStart(code, phoneID)!.Value;
    var c2 = PairingCrypto.PhoneFinish(PairResponse.Decode(reuse.HandlePair(r2.Encoded()).Reply!), s2).Confirm!;
    reuse.Refresh("246802");
    Check(reuse.HandlePair(c2.Encoded()).Kind == PairOutcomeKind.Rejected, "换码后，进行中的那一轮作废");
    reuse.OpenWindow(code);
    var (r3, s3) = PairingCrypto.PhoneStart(code, phoneID)!.Value;
    var c3 = PairingCrypto.PhoneFinish(PairResponse.Decode(reuse.HandlePair(r3.Encoded()).Reply!), s3).Confirm!;
    reuse.CloseWindow();
    Check(reuse.HandlePair(c3.Encoded()).Kind == PairOutcomeKind.Rejected, "关窗口后，进行中的那一轮作废");

    // 命令 / 重放 / 撤销
    var key = run.Key!;
    var away = PairingCrypto.SealCommand("away", phoneID, 2, key)!;
    Check(pc.HandleCommand(away) is { Accepted: true, Command: "away", ConfirmedPairing: false }, "签名命令 away：收下");
    Check(pc.HandleCommand(away).Reason == RejectReason.Replay, "重放：同一条命令再来被拒");
    Check(pc.HandleCommand(Bytes.Concat("away"u8.ToArray())).Reason == RejectReason.Malformed, "明文命令被拒");
    store.FailSaves = true;
    var failing = pc.HandleCommand(PairingCrypto.SealCommand("away", phoneID, 3, key)!);
    Check(!failing.Accepted && failing.Reason == RejectReason.StoreFailed && store.Load(phoneID)!.LastCounter == 2, "存储写不进去：不收");
    store.FailSaves = false;
    var notices = pc.RevokeAll();
    Check(PairingCrypto.VerifyRevoke(notices[phoneID], phoneID, key) && !pc.IsPaired, "撤销：通知带签名，电脑的钥匙删掉了");
    Check(pc.HandleCommand(PairingCrypto.SealCommand("away", phoneID, 10, key)!).Reason == RejectReason.UnknownPhone
          && pc.PollMessage(PairingCrypto.MakeNonce(), phoneID) == null, "撤销：之后命令不认，也不发问询");

    // 多台手机：线格式按 phoneID 各管各的（为以后一台手机配多台电脑 / 一台电脑配多台手机留着）
    var multi = new PairingAuthority(new MemoryPairingStore(), logs.Add);
    var idA = Guid.NewGuid();
    var idB = Guid.NewGuid();
    multi.OpenWindow("111111");
    var kA = Handshake(multi, "111111", idA).Key!;
    multi.HandleCommand(PairingCrypto.SealCommand("ping", idA, 1, kA)!);
    multi.OpenWindow("222222");
    var kB = Handshake(multi, "222222", idB).Key!;
    multi.HandleCommand(PairingCrypto.SealCommand("ping", idB, 1, kB)!);
    Check(multi.PairedPhoneIDs.Count == 2 && multi.HandleCommand(PairingCrypto.SealCommand("away", idA, 2, kB)!).Reason == RejectReason.BadSignature,
          "两台手机各有各的钥匙，互相签不了");

    Check(!logs.Any(l => l.Contains(code)), "日志：不含配对码");
}

Console.WriteLine();
await NetworkTests.Run((ok, name) => Check(ok, name));

Console.WriteLine(failures == 0 ? $"全部通过：{total} 项" : $"{failures} / {total} 项没通过");
return failures == 0 ? 0 : 1;

static bool Throws(Action a)
{
    try { a(); return false; }
    catch (WireException) { return true; }
}

static string Camel(RejectReason r) => char.ToLowerInvariant(r.ToString()[0]) + r.ToString()[1..];

/// 手机用 code 和电脑走一遍完整握手（手机这边按 BLECurtainLink.pair 的步骤）
static HandshakeRun Handshake(PairingAuthority pc, string code, Guid phoneID)
{
    var run = new HandshakeRun();
    var (request, session) = PairingCrypto.PhoneStart(code, phoneID)!.Value;
    var first = pc.HandlePair(request.Encoded());
    if (first.Kind != PairOutcomeKind.Responded) return run;
    run.Responded = true;
    var step = PairingCrypto.PhoneFinish(PairResponse.Decode(first.Reply!), session);
    if (step.Kind != PhoneStepKind.Confirm)
    {
        run.WrongCode = true;
        run.AbortLeft = pc.HandlePair(PairingCrypto.PairAbort(phoneID, session.Sid)).AttemptsLeft;
        return run;
    }
    var accepted = pc.HandlePair(step.Confirm!.Encoded());
    if (accepted.Kind == PairOutcomeKind.Accepted && accepted.PhoneID == phoneID
        && PairingCrypto.VerifyPairAccepted(accepted.Reply!, phoneID, session.Sid, step.SharedKey!))
        run.Key = step.SharedKey;
    return run;
}

sealed class HandshakeRun
{
    public bool Responded;
    public bool WrongCode;
    public int AbortLeft = -1;
    public byte[]? Key;
}
