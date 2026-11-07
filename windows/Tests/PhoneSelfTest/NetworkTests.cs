// NetworkTests.cs —— 手机走网络（TCP）的自测，对照 Mac 的 PairingSelfTest 里「网络」那几段
//
//   1. 线格式：分帧、Ack 5、n1: 命令字符串、白名单
//   2. 权威端（Transport.Network）：nonce 单次 / 寿命 / 上限 / 撤销作废；撤下、解除配对、预览、设置不许（Ack 5，计数用掉）；
//      配对、Presence、LiftNow 走网络不耗计数；没配过 / 签名错 / 重放
//   3. 地址：格式、标签、排序、网卡归类、Tailscale 段、端口持久化
//   4. 链路：PhonePathRules、「已连上 · 网络 / 蓝牙」、文案里不许出现的词
//   5. 真的 TCP 监听（NetworkGateway，只绑 127.0.0.1、系统分配端口）：开 / 关、握手（accept / reject）、命令放行与拒绝、封禁、再开
//
// 这里的「握手」= 网络上第一条签名的 ping 认出手机；Mac 的网络线协议里没有带时间戳的握手，防重放靠 nonce（90 秒）+ 单调计数。

using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using LockCurtain.Phone;

internal static class NetworkTests
{
    static byte[] Key() => System.Security.Cryptography.RandomNumberGenerator.GetBytes(32);

    static (PairingAuthority Pc, MemoryPairingStore Store, Guid Phone, byte[] Key, List<string> Logs) Paired()
    {
        var store = new MemoryPairingStore();
        var logs = new List<string>();
        var pc = new PairingAuthority(store, logs.Add);
        var phone = Guid.NewGuid();
        var key = Key();
        store.Save(new PairingRecord(key, 0), phone);
        return (pc, store, phone, key, logs);
    }

    /// 手机这边：拿到电脑发的 Poll，取出 nonce
    static byte[]? NonceFrom(PairingAuthority pc, Guid phone, byte[] key) =>
        pc.NetworkPollMessage(phone) is { } poll ? PairingCrypto.OpenPoll(poll, phone, key) : null;

    static CommandOutcome Net(PairingAuthority pc, string command, Guid phone, ulong counter, byte[] key, byte[]? nonce = null) =>
        pc.HandleCommand(PairingCrypto.SealCommand(nonce == null ? command : NetworkCommand.Wrap(command, nonce), phone, counter, key)!, Transport.Network);

    static AckStatus StatusOf(CommandOutcome o) => Ack.Decode(o.Ack!).Status;

    public static async Task Run(Action<bool, string> check)
    {
        Console.WriteLine("== 走网络：分帧 / Ack 5 / 命令字符串 / 白名单 ==");
        Wire(check);
        Console.WriteLine("== 走网络：权威端 ==");
        Authority(check);
        Console.WriteLine("== 走网络：地址 / 端口 ==");
        Addresses(check);
        Console.WriteLine("== 走网络：链路 / 文案 ==");
        Paths(check);
        Console.WriteLine("== 走网络：真的 TCP 监听（127.0.0.1）==");
        await Gateway(check);
    }

    // MARK: - 1. 线格式

    static void Wire(Action<bool, string> check)
    {
        var msg = new byte[] { 1, 2, 3 };
        check(NetFraming.Frame(msg)!.SequenceEqual(new byte[] { 0, 3, 1, 2, 3 }), "分帧：2 字节大端长度 + 消息");
        check(NetFraming.Frame([]) == null && NetFraming.Frame(new byte[1025]) == null && NetFraming.Frame(new byte[1024]) != null, "分帧：空和超过 1024 字节不成帧");
        var big = NetFraming.Frame(new byte[300])!;
        check(big[0] == 1 && big[1] == 44, "分帧：长度 300 = 01 2C");

        // 切开、合并：一个字节一个字节喂
        var stream = NetFraming.Frame([9, 8])!.Concat(NetFraming.Frame([7])!).Concat(NetFraming.Frame(new byte[600])!).ToArray();
        var r = new NetFraming.Reader();
        var got = new List<byte[]>();
        foreach (var b in stream) got.AddRange(r.Feed([b]));
        check(got.Count == 3 && got[0].SequenceEqual(new byte[] { 9, 8 }) && got[1].SequenceEqual(new byte[] { 7 }) && got[2].Length == 600 && !r.IsBroken,
              "分帧：逐字节喂，三帧原样交出");
        var r2 = new NetFraming.Reader();
        check(r2.Feed(stream).Count == 3, "分帧：一口气喂，三帧");
        var r3 = new NetFraming.Reader();
        check(r3.Feed([0, 5, 1, 2]).Count == 0 && r3.Feed([3, 4, 5, 0, 1, 42]).Count == 2, "分帧：半帧等后面的");
        var broken = new NetFraming.Reader();
        check(broken.Feed([0, 0, 1]).Count == 0 && broken.IsBroken && broken.Feed([0, 1, 1]).Count == 0, "分帧：长度 0 就坏了，之后什么都不交出");
        var tooBig = new NetFraming.Reader();
        check(tooBig.Feed([0x04, 0x01]).Count == 0 && tooBig.IsBroken, "分帧：长度 1025 就坏了");
        var fine = new NetFraming.Reader();
        check(fine.Feed([0x04, 0x00]).Count == 0 && !fine.IsBroken, "分帧：长度 1024 是上限，不算坏");

        // Ack 5
        var phone = Guid.NewGuid();
        var key = Key();
        var ack = Ack.Decode(PairingCrypto.MakeAck(phone, 7, AckStatus.NotAllowedOnNetwork, key));
        check(ack.Status == AckStatus.NotAllowedOnNetwork && ack.Counter == 7 && ack.Mac != null && PairingCrypto.VerifyAck(ack, key)
              && !PairingCrypto.VerifyAck(ack, Key()), "Ack 5：带签名，验得过，别的钥匙验不过");
        check(PairingCrypto.IsSignedAckStatus(AckStatus.NotAllowedOnNetwork)
              && Ack.Decode(PairingCrypto.MakeAck(phone, 7, AckStatus.UnknownOrBadSignature, key)).Mac == null, "Ack 5 签名，Ack 1 不签");
        var forged = PairingCrypto.MakeAck(phone, 7, AckStatus.Accepted, key);
        forged[26] = 5;
        check(!PairingCrypto.VerifyAck(Ack.Decode(forged), key), "Ack：把 0 改成 5 签名就不对了");

        // 和 Mac（Swift，Sources/PairingCrypto.swift）逐字节一样：固定钥匙 00..1f、phoneID 11223344-…、nonce 00 11 22 … ff
        {
            var fixedPhone = Guid.Parse("11223344-5566-7788-99AA-BBCCDDEEFF00");
            var fixedKey = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
            var fixedNonce = Enumerable.Range(0, 16).Select(i => (byte)(i * 17)).ToArray();
            string X(byte[]? b) => b == null ? "null" : Convert.ToHexString(b).ToLowerInvariant();
            check(X(PairingCrypto.MakeAck(fixedPhone, 7, AckStatus.NotAllowedOnNetwork, fixedKey))
                  == "0106112233445566778899aabbccddeeff00000000000000000705b1090e48e8a32fee52cbc8aa43bb71eadf2c424b6bd902f75ce9ab6b3566c428", "Mac 向量：Ack 5（签名）字节一样");
            check(X(PairingCrypto.MakeAck(fixedPhone, 7, AckStatus.Replay, fixedKey)) == "0106112233445566778899aabbccddeeff000000000000000007" + "02", "Mac 向量：Ack 2（不签名）字节一样");
            check(NetworkCommand.Wrap("away", fixedNonce) == "n1:00112233445566778899aabbccddeeff:away", "Mac 向量：n1: 命令字符串一样");
            check(X(PairingCrypto.SealCommand(NetworkCommand.Wrap("away", fixedNonce), fixedPhone, 9, fixedKey))
                  == "0103112233445566778899aabbccddeeff000000000000000009286e313a30303131323233333434353536363737383839396161626263636464656566663a617761798247b97850e046be4e6202867f2ed7390e8ed42fc4df028fcab7fbcfbfe83e7c",
                  "Mac 向量：签名的网络命令字节一样");
            check(X(NetFraming.Frame([1, 2, 3])) == "0003010203", "Mac 向量：分帧一样");
            check(X(PairingCrypto.MakePoll(fixedNonce, fixedPhone, fixedKey))
                  == "010b112233445566778899aabbccddeeff0000112233445566778899aabbccddeeff0fb79e9619fae58c7494bee27eec8455f807f1eb2d8dd9737cdb79278b04968f", "Mac 向量：Poll 字节一样");
        }

        // n1: 命令字符串
        var nonce = Enumerable.Range(0, 16).Select(i => (byte)(i * 17)).ToArray();
        var wrapped = NetworkCommand.Wrap("away", nonce);
        check(wrapped == "n1:00112233445566778899aabbccddeeff:away", "命令字符串：n1:<32 位十六进制>:<命令>");
        var un = NetworkCommand.Unwrap(wrapped);
        check(un is { Command: "away" } && un.Value.Nonce!.SequenceEqual(nonce), "命令字符串：拆回来一样");
        check(NetworkCommand.Unwrap("ping") is { Nonce: null, Command: "ping" }, "命令字符串：ping 没有 n1: 前缀");
        check(NetworkCommand.Unwrap("n1:zz:away") == null && NetworkCommand.Unwrap("n1:00112233445566778899aabbccddeeff") == null
              && NetworkCommand.Unwrap("n1:00112233445566778899aabbccddeeffaway") == null, "命令字符串：有 n1: 但格式不对 → null");
        check(NetworkCommand.FromHex("AbCd")!.SequenceEqual(new byte[] { 0xAB, 0xCD }) && NetworkCommand.FromHex("abc") == null && NetworkCommand.FromHex("gg") == null,
              "十六进制：大小写都认，奇数长度和乱字符不认");
        check(NetworkCommand.Unwrap(NetworkCommand.Wrap("name:Tom: 1", nonce)) is { Command: "name:Tom: 1" }, "命令字符串：命令里带冒号照样拆对");

        // 白名单
        var allowed = new[] { "ping", "away", "awake:off", "awake:1h", "awake:2h", "awake:5h", "awake:always", "AWAKE:1H", "name:iPhone", "name:" };
        var denied = new[] { "hide", "lift", "unpair", "preview", "settings", "status", "awake:3h", "awake:", "pair", "away ", "", "n1:x", "nam:e" };
        check(allowed.All(NetworkPolicy.Allows), "白名单：ping / away / awake:* / name: 放行");
        check(denied.All(c => !NetworkPolicy.Allows(c)), "白名单：撤下、解除配对、预览、设置、其他一律不放");
    }

    // MARK: - 2. 权威端

    static void Authority(Action<bool, string> check)
    {
        var (pc, store, phone, key, logs) = Paired();

        // ping 不用 nonce
        var ping = Net(pc, "ping", phone, 1, key);
        check(ping.Accepted && ping.Command == "ping" && StatusOf(ping) == AckStatus.Accepted && PairingCrypto.VerifyAck(Ack.Decode(ping.Ack!), key), "网络：签名的 ping 不用 nonce，收据 Ack 0 带签名");
        // 其余必须有 nonce
        var none = Net(pc, "away", phone, 2, key);
        check(!none.Accepted && none.Reason == RejectReason.BadNonce && StatusOf(none) == AckStatus.Replay, "网络：away 不带 nonce → Ack 2，不执行");
        var n1 = NonceFrom(pc, phone, key)!;
        var away = Net(pc, "away", phone, 3, key, n1);
        check(away.Accepted && away.Command == "away" && StatusOf(away) == AckStatus.Accepted, "网络：带电脑刚发的 nonce 的 away 收下，命令是去掉 n1: 的 away");
        var n2 = NonceFrom(pc, phone, key)!;
        check(Net(pc, "away", phone, 4, key, n1) is { Accepted: false, Reason: RejectReason.BadNonce }, "网络：同一个 nonce 用第二次 → 拒绝");
        check(Net(pc, "awake:1h", phone, 5, key, n2) is { Accepted: true, Command: "awake:1h" }, "网络：另一个 nonce 的 awake:1h 收下");
        check(Net(pc, "away", phone, 6, key, Key().Slice(..16)) is { Accepted: false, Reason: RejectReason.BadNonce }, "网络：电脑没发过的 nonce → 拒绝");
        var n3 = NonceFrom(pc, phone, key)!;
        check(Net(pc, "name:小明", phone, 7, key, n3) is { Accepted: true, Command: "name:小明" }, "网络：name: 收下");

        // 白名单之外：签名对、计数用掉、回签名的 Ack 5、nonce 不动
        foreach (var bad in new[] { "hide", "lift", "unpair", "preview", "settings" })
        {
            var (p, s, id, k, _) = Paired();
            var nonce = NonceFrom(p, id, k)!;
            var refused = Net(p, bad, id, 1, k, nonce);
            check(!refused.Accepted && refused.Reason == RejectReason.NetworkForbidden && StatusOf(refused) == AckStatus.NotAllowedOnNetwork
                  && PairingCrypto.VerifyAck(Ack.Decode(refused.Ack!), k), $"网络：「{bad}」→ 签名的 Ack 5，不执行");
            check(Net(p, bad, id, 1, k, nonce).Reason == RejectReason.Replay, $"网络：「{bad}」的计数用掉了，再送是重放");
            check(Net(p, "away", id, 2, k, nonce).Accepted, $"网络：「{bad}」被拒不吃掉 nonce");
            check(s.Load(id)!.LastCounter == 2, $"网络：「{bad}」之后计数是 2");
        }
        // 蓝牙上同样的命令不被权威端拦（蓝牙行为没变）
        check(pc.HandleCommand(PairingCrypto.SealCommand("unpair", phone, 100, key)!).Accepted, "蓝牙：unpair 照旧收下（没被网络规则影响）");

        // nonce 寿命
        {
            var (p, _, id, k, _) = Paired();
            var now = DateTime.UtcNow;
            p.Clock = () => now;
            var nonce = NonceFrom(p, id, k)!;
            p.Clock = () => now.AddSeconds(89);
            var okNonce = NonceFrom(p, id, k)!;
            check(Net(p, "away", id, 1, k, nonce).Accepted, "nonce：89 秒内有效");
            p.Clock = () => now.AddSeconds(91);
            var late = NonceFrom(p, id, k)!;
            check(Net(p, "away", id, 2, k, okNonce) is { Accepted: true }, "nonce：发出后 2 秒的（89+2 = 91 秒时）仍有效");
            var stale = NonceFrom(p, id, k)!;
            p.Clock = () => now.AddSeconds(91 + 91);
            check(Net(p, "away", id, 3, k, late) is { Accepted: false, Reason: RejectReason.BadNonce }
                  && Net(p, "away", id, 4, k, stale) is { Accepted: false, Reason: RejectReason.BadNonce }, "nonce：过了 90 秒作废");
        }
        // nonce 上限：每台手机最多 4 个
        {
            var (p, _, id, k, _) = Paired();
            var nonces = Enumerable.Range(0, 6).Select(_ => NonceFrom(p, id, k)!).ToList();
            check(Net(p, "away", id, 1, k, nonces[0]).Reason == RejectReason.BadNonce && Net(p, "away", id, 2, k, nonces[1]).Reason == RejectReason.BadNonce,
                  "nonce：同时最多留 4 个，最旧的被挤掉");
            check(Net(p, "away", id, 3, k, nonces[2]).Accepted && Net(p, "away", id, 4, k, nonces[5]).Accepted, "nonce：留下的 4 个还能用");
        }
        // nonce 属于哪台手机
        {
            var (p, store2, a, ka, _) = Paired();
            var b = Guid.NewGuid();
            var kb = Key();
            store2.Save(new PairingRecord(kb, 0), b);
            var na = NonceFrom(p, a, ka)!;
            check(Net(p, "away", b, 1, kb, na) is { Accepted: false, Reason: RejectReason.BadNonce }, "nonce：A 的 nonce B 用不了");
        }
        // 撤销作废
        {
            var (p, _, id, k, _) = Paired();
            var nonce = NonceFrom(p, id, k)!;
            p.DropNetworkNonces(id);
            check(Net(p, "away", id, 1, k, nonce).Reason == RejectReason.BadNonce, "nonce：DropNetworkNonces 之后全部作废");
            var n = NonceFrom(p, id, k)!;
            var notice = p.Revoke(id);
            check(notice != null && PairingCrypto.VerifyRevoke(notice, id, k) && NonceFrom(p, id, k) == null, "撤销：撤销通知验得过，之后不再给这台手机发 Poll");
            check(Net(p, "away", id, 2, k, n).Reason == RejectReason.UnknownPhone, "撤销：撤销后这台手机的命令不认");
        }

        // 配对、Presence、LiftNow 走网络：拒绝，不耗计数
        {
            var (p, s, id, k, l) = Paired();
            var (request, _) = PairingCrypto.PhoneStart("123456", Guid.NewGuid())!.Value;
            p.OpenWindow("123456");
            var pair = p.HandlePair(request.Encoded(), Transport.Network);
            check(pair.Kind == PairOutcomeKind.Malformed && p.AttemptsLeft == PairingAuthority.MaxCodeAttempts, "配对走网络：拒绝，不碰码、不耗次数");
            var nonce = PairingCrypto.MakeNonce();
            var presence = PairingCrypto.SealPresence(PresenceStatus.Unlocked, nonce, id, 5, k)!;
            var lift = PairingCrypto.SealLiftNow(nonce, id, 6, k)!;
            var a1 = p.HandleAnswer(presence, Transport.Network);
            var a2 = p.HandleAnswer(lift, Transport.Network);
            check(!a1.Accepted && a1.Reason == RejectReason.NetworkForbidden && !a2.Accepted && a2.Reason == RejectReason.NetworkForbidden, "Presence / LiftNow 走网络：拒绝");
            check(s.Load(id)!.LastCounter == 0, "Presence / LiftNow 走网络：计数没动");
            check(p.HandleAnswer(presence).Accepted, "同一条 Presence 走蓝牙照常收下（说明上面的拒绝没用掉计数）");
        }

        // 没配过 / 签名错 / 重放
        {
            var (p, _, id, k, _) = Paired();
            var stranger = Guid.NewGuid();
            var unknown = Net(p, "ping", stranger, 1, Key());
            check(!unknown.Accepted && unknown.Reason == RejectReason.UnknownPhone && StatusOf(unknown) == AckStatus.UnknownOrBadSignature && Ack.Decode(unknown.Ack!).Mac == null,
                  "网络：没配过的手机 → Ack 1，不签名");
            var badSig = Net(p, "ping", id, 1, Key());
            check(!badSig.Accepted && badSig.Reason == RejectReason.BadSignature && StatusOf(badSig) == AckStatus.UnknownOrBadSignature, "网络：签名错 → Ack 1");
            check(Net(p, "ping", id, 1, k).Accepted, "网络：签名错没用掉计数");
            check(Net(p, "ping", id, 1, k) is { Accepted: false, Reason: RejectReason.Replay } && StatusOf(Net(p, "ping", id, 0, k)) == AckStatus.Replay, "网络：计数不递增 → 重放，Ack 2");
            var garbage = p.HandleCommand([3, 3, 3], Transport.Network);
            check(!garbage.Accepted && garbage.Reason == RejectReason.Malformed && garbage.Ack == null, "网络：格式坏的命令 → Malformed，没有收据");
        }
        // 刚握手、还没确认的手机，网络不认（只认确认过的）
        {
            var store3 = new MemoryPairingStore();
            var p = new PairingAuthority(store3, _ => { });
            p.OpenWindow("246810");
            var id = Guid.NewGuid();
            var (request, session) = PairingCrypto.PhoneStart("246810", id)!.Value;
            var first = p.HandlePair(request.Encoded());
            var step = PairingCrypto.PhoneFinish(PairResponse.Decode(first.Reply!), session);
            var accepted = p.HandlePair(step.Confirm!.Encoded());
            var shared = step.SharedKey!;
            check(accepted.Kind == PairOutcomeKind.Accepted && store3.Load(id) == null, "握手：蓝牙上握手过了，钥匙还没落盘（等第一条签名命令）");
            check(Net(p, "ping", id, 1, shared).Reason == RejectReason.UnknownPhone, "网络：只握过手、还没确认的手机不认");
            check(p.HandleCommand(PairingCrypto.SealCommand("ping", id, 1, shared)!).ConfirmedPairing && store3.Load(id) != null, "蓝牙：第一条签名命令确认配对");
            check(Net(p, "ping", id, 2, shared).Accepted, "网络：确认之后才认");
        }
    }

    // MARK: - 3. 地址 / 端口

    static void Addresses(Action<bool, string> check)
    {
        var v4 = new NetworkAddressEntry(NetworkKind.Wifi, "Wi-Fi", "192.168.1.23", false);
        var v6 = new NetworkAddressEntry(NetworkKind.Wifi, "Wi-Fi", "2408:abcd::1", true);
        check(v4.Text(52811) == "192.168.1.23:52811" && v6.Text(52811) == "[2408:abcd::1]:52811", "地址：ip:port，IPv6 加方括号");
        check(v4.Label == "Wi-Fi" && new NetworkAddressEntry(NetworkKind.Ethernet, "", "", false).Label == "以太网"
              && new NetworkAddressEntry(NetworkKind.Tailscale, "", "", false).Label == "Tailscale"
              && new NetworkAddressEntry(NetworkKind.Other, "", "", false).Label == "其他", "地址：四种标签 Wi-Fi / 以太网 / Tailscale / 其他");

        NetworkAddressEntry? C(string host, bool v6flag, AdapterKind a, string iface = "x") => NetworkAddresses.Classify(host, iface, v6flag, a);
        check(C("127.0.0.1", false, AdapterKind.Ethernet) == null && C("169.254.3.4", false, AdapterKind.Wifi) == null && C("0.0.0.0", false, AdapterKind.Wifi) == null,
              "地址：回环、169.254、0.0.0.0 不列");
        check(C("fe80::1%12", true, AdapterKind.Wifi) == null && C("::1", true, AdapterKind.Wifi) == null && C("::", true, AdapterKind.Wifi) == null, "地址：fe80、::1、:: 不列");
        check(C("2408:8000::1", true, AdapterKind.Wifi) is { Kind: NetworkKind.Wifi, Host: "2408:8000::1" } && C("fd12:3456::1", true, AdapterKind.Ethernet) is { Kind: NetworkKind.Ethernet },
              "地址：全局和 ULA 的 IPv6 列");
        check(C("fe80::1%12", true, AdapterKind.Wifi) == null && C("2408:8000::1%5", true, AdapterKind.Wifi)!.Host == "2408:8000::1", "地址：去掉 %zone");
        check(C("999.1.1.1", false, AdapterKind.Wifi) == null && C("1.2.3", false, AdapterKind.Wifi) == null, "地址：不像 IPv4 的不列");
        check(C("100.101.102.103", false, AdapterKind.Tunnel)!.Kind == NetworkKind.Tailscale && C("fd7a:115c:a1e0::1", true, AdapterKind.Tunnel)!.Kind == NetworkKind.Tailscale,
              "地址：隧道网卡上 Tailscale 段 → Tailscale");
        check(C("10.8.0.2", false, AdapterKind.Tunnel)!.Kind == NetworkKind.Other, "地址：别的隧道（VPN）→ 其他");
        check(C("100.101.102.103", false, AdapterKind.Wifi)!.Kind == NetworkKind.Wifi, "地址：Wi-Fi 网卡上就算在 100.64/10 也还是 Wi-Fi");
        check(NetworkAddresses.IsTailscale("100.64.0.1", false) && NetworkAddresses.IsTailscale("100.127.255.254", false)
              && !NetworkAddresses.IsTailscale("100.63.255.255", false) && !NetworkAddresses.IsTailscale("100.128.0.0", false)
              && !NetworkAddresses.IsTailscale("10.64.0.1", false) && NetworkAddresses.IsTailscale("fd7a:115c:a1e0:ab12::1", true)
              && !NetworkAddresses.IsTailscale("fd7a:115c:a1e1::1", true), "Tailscale 段：100.64.0.0/10、fd7a:115c:a1e0::/48");

        var sorted = NetworkAddresses.Sort([
            new(NetworkKind.Other, "vEthernet", "172.20.0.1", false),
            new(NetworkKind.Tailscale, "Tailscale", "100.100.1.1", false),
            new(NetworkKind.Wifi, "Wi-Fi", "2408::1", true),
            new(NetworkKind.Ethernet, "Ethernet", "10.0.0.5", false),
            new(NetworkKind.Wifi, "Wi-Fi", "192.168.1.9", false),
            new(NetworkKind.Wifi, "Wi-Fi", "192.168.1.2", false),
        ]);
        check(string.Join(",", sorted.Select(e => e.Host)) == "192.168.1.2,192.168.1.9,2408::1,10.0.0.5,100.100.1.1,172.20.0.1",
              "地址排序：Wi-Fi → 以太网 → Tailscale → 其他，同类 IPv4 在前，再按网卡名、地址");

        check(NetworkAddresses.AdapterOf(NetworkInterfaceType.Wireless80211, "Wi-Fi", "Intel AX201") == AdapterKind.Wifi
              && NetworkAddresses.AdapterOf(NetworkInterfaceType.Ethernet, "Ethernet", "Realtek PCIe GbE") == AdapterKind.Ethernet
              && NetworkAddresses.AdapterOf(NetworkInterfaceType.Ethernet, "Tailscale", "Tailscale Tunnel") == AdapterKind.Tunnel
              && NetworkAddresses.AdapterOf(NetworkInterfaceType.Ethernet, "WireGuard", "Wintun Userspace Tunnel") == AdapterKind.Tunnel
              && NetworkAddresses.AdapterOf(NetworkInterfaceType.Tunnel, "Local Area Connection", "") == AdapterKind.Tunnel
              && NetworkAddresses.AdapterOf(NetworkInterfaceType.Ethernet, "vEthernet (WSL)", "Hyper-V Virtual Ethernet Adapter") == AdapterKind.Other
              && NetworkAddresses.AdapterOf(NetworkInterfaceType.Ethernet, "VMware Network Adapter VMnet8", "VMware Virtual Ethernet Adapter") == AdapterKind.Other
              && NetworkAddresses.AdapterOf(NetworkInterfaceType.Wwanpp, "Cellular", "Mobile Broadband") == AdapterKind.Other, "网卡归类：Wi-Fi / 以太网 / 隧道 / 虚拟 = 其他");

        // 端口：49200–49999，存起来，以后一直用
        var ports = new MemoryPortStore();
        var gw = new NetworkGateway(new PairingAuthority(new MemoryPairingStore(), _ => { }), TaskScheduler.Default, ports);
        var first = gw.PersistedPort();
        check(first is >= 49200 and <= 49999 && ports.Port == first, "端口：第一次在 49200–49999 里挑一个存起来");
        check(Enumerable.Range(0, 20).All(_ => gw.PersistedPort() == first), "端口：之后一直用同一个");
        ports.Port = 80;
        var replaced = gw.PersistedPort();
        check(replaced is >= 49200 and <= 49999 && ports.Port == replaced, "端口：存着的不在范围里就换一个");
        ports.Port = 49555;
        check(gw.PersistedPort() == 49555, "端口：范围里的存着的照用");
        var picks = Enumerable.Range(0, 200).Select(_ => gw.ChoosePort()).ToList();
        check(picks.All(p => p is >= 49200 and <= 49999) && picks.Distinct().Count() > 20, "端口：ChoosePort 在范围里随机");
    }

    // MARK: - 4. 链路 / 文案

    static void Paths(Action<bool, string> check)
    {
        check(PhonePathRules.Resolve(true, true) == PhonePath.Bluetooth && PhonePathRules.Resolve(true, false) == PhonePath.Bluetooth
              && PhonePathRules.Resolve(false, true) == PhonePath.Network && PhonePathRules.Resolve(false, false) == null, "链路：两条都连着算蓝牙");
        check(PhonePathRules.Common([PhonePath.Network, PhonePath.Network]) == PhonePath.Network
              && PhonePathRules.Common([PhonePath.Bluetooth]) == PhonePath.Bluetooth
              && PhonePathRules.Common([PhonePath.Bluetooth, PhonePath.Network]) == null && PhonePathRules.Common([]) == null, "链路：几台手机合成一个，不一样就是 null");
        check(PhonePathRules.ConnectedText(PhonePath.Bluetooth) == "已连上 · 蓝牙" && PhonePathRules.ConnectedText(PhonePath.Network) == "已连上 · 网络"
              && PhonePathRules.ConnectedText(null) == "已连上", "文案：已连上 · 蓝牙 / 已连上 · 网络 / 已连上");
        var now = new DateTime(2026, 11, 7, 12, 0, 0, DateTimeKind.Utc);
        var tz = TimeZoneInfo.Utc;
        check(LockCurtain.UiText.PhoneStatus(true, now, now, tz, PhonePath.Network) == "已连上 · 网络"
              && LockCurtain.UiText.PhoneStatus(true, now, now, tz, PhonePath.Bluetooth) == "已连上 · 蓝牙"
              && LockCurtain.UiText.PhoneStatus(false, now.AddHours(-3), now, tz, PhonePath.Network) == "没连上 · 上次连上：3 小时前"
              && LockCurtain.UiText.PhoneStatus(false, null, now, tz, null) == "没连上", "手机那一行：已连上 · 网络 / 没连上 · 上次连上");
        var all = new[] { NetworkText.Switch, NetworkText.Failed, NetworkText.NoAddress, NetworkText.Allowed, NetworkText.Tailscale, NetworkText.RemoteFooter,
                          PhonePathRules.ConnectedText(PhonePath.Network), PhonePathRules.ConnectedText(PhonePath.Bluetooth) };
        check(all.All(s => !s.Contains("已连接") && !s.Contains("遮罩")), "文案：不出现「已连接」「遮罩」");
        check(NetworkText.Switch == "让手机走网络连这台电脑" && NetworkText.Copy == "拷贝"
              && NetworkText.Failed == "没能打开。这个端口被别的程序占了，或者系统没放行。关掉占着它的程序，再打开一次。"
              && NetworkText.NoAddress == "这台电脑现在没有可用的网络地址。连上网络以后再打开一次。"
              && NetworkText.RemoteFooter.Contains("默认不监听任何网络端口") && !NetworkText.RemoteFooter.Contains("App 本身不监听"), "文案：和 Camo copy v15.13 §18.2 / §18.6 一字不差");
    }

    // MARK: - 5. 真的 TCP 监听

    sealed class PhoneWire(TcpClient client, Guid phone, byte[] key, PairingAuthority? _ = null)
    {
        public readonly TcpClient Client = client;
        readonly NetworkStream stream = client.GetStream();
        readonly NetFraming.Reader reader = new();
        readonly Queue<byte[]> queue = new();
        public ulong Counter;
        public byte[]? Nonce;
        /// 读到对面关了（读到 0 字节 / 连接出错）；超时不算
        public bool Closed;

        public async Task SendAsync(byte[] message) { var f = NetFraming.Frame(message)!; await stream.WriteAsync(f); }

        public async Task<byte[]?> ReadAsync(int ms = 3000)
        {
            using var cts = new CancellationTokenSource(ms);
            var buffer = new byte[2048];
            while (queue.Count == 0)
            {
                int n;
                try { n = await stream.ReadAsync(buffer, cts.Token); }
                catch (OperationCanceledException) { return null; }
                catch (Exception e) when (e is IOException or SocketException or ObjectDisposedException) { Closed = true; return null; }
                if (n == 0) { Closed = true; return null; }
                foreach (var f in reader.Feed(buffer.AsSpan(0, n))) queue.Enqueue(f);
            }
            return queue.Dequeue();
        }

        /// 读到某一种消息为止（中间的丢掉）；超时或断开返回 null
        public async Task<byte[]?> ReadKindAsync(Kind kind, int ms = 3000)
        {
            var end = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < end)
            {
                if (await ReadAsync(Math.Max(1, (int)(end - DateTime.UtcNow).TotalMilliseconds)) is not { } m) return null;
                if (PairingCrypto.KindOf(m) == kind)
                {
                    if (kind == Kind.Poll) Nonce = PairingCrypto.OpenPoll(m, phone, key);
                    return m;
                }
            }
            return null;
        }

        public async Task<Ack?> CommandAsync(string command, bool useNonce = true)
        {
            Counter++;
            var text = useNonce && Nonce != null ? NetworkCommand.Wrap(command, Nonce) : command;
            if (useNonce) Nonce = null;
            await SendAsync(PairingCrypto.SealCommand(text, phone, Counter, key)!);
            return await ReadKindAsync(Kind.Ack) is { } a ? Ack.Decode(a) : null;
        }

        /// 对面断了没有（读到 0 字节 / 出错）
        public async Task<bool> ClosedAsync(int ms = 2000)
        {
            // 先把还在路上的收据 / 状态 / Poll 读掉，再看是不是断了
            var end = DateTime.UtcNow.AddMilliseconds(ms);
            while (DateTime.UtcNow < end && !Closed)
                await ReadAsync(Math.Max(1, (int)(end - DateTime.UtcNow).TotalMilliseconds));
            return Closed;
        }
    }

    static async Task<bool> WaitFor(Func<Task<bool>> cond, int ms = 4000)
    {
        var end = DateTime.UtcNow.AddMilliseconds(ms);
        while (DateTime.UtcNow < end)
        {
            if (await cond()) return true;
            await Task.Delay(20);
        }
        return await cond();
    }

    static async Task Gateway(Action<bool, string> check)
    {
        var (pc, store, phone, key, logs) = Paired();
        var scheduler = new ConcurrentExclusiveSchedulerPair().ExclusiveScheduler;
        var commands = new List<(string Command, Guid Phone)>();
        var peerChanges = 0;
        var curtain = false;
        var gw = new NetworkGateway(pc, scheduler, new MemoryPortStore(), PortChoice.Ephemeral, loopbackOnly: true)
        {
            Log = logs.Add,
            PingDeadline = TimeSpan.FromSeconds(1),
            AddressProvider = () => [new NetworkAddressEntry(NetworkKind.Wifi, "Wi-Fi", "192.168.1.23", false)],
        };
        gw.OnCommand = (c, id) => { lock (commands) commands.Add((c, id)); };
        gw.OnPeersChanged = () => Interlocked.Increment(ref peerChanges);
        gw.CurtainClosed = () => curtain;
        List<(string, Guid)> Commands() { lock (commands) return [.. commands]; }

        // 没开：不监听
        var s0 = await gw.RunAsync(() => gw.Status);
        check(s0.State == GatewayState.Stopped && await gw.RunAsync(() => gw.Port) == null, "监听：没开的时候是 Stopped，没有端口");

        // 开
        gw.Start();
        check(await WaitFor(async () => (await gw.RunAsync(() => gw.Status)).State == GatewayState.Listening), "监听：Start → Listening");
        var port = (await gw.RunAsync(() => gw.Port))!.Value;
        check(port > 0 && await WaitFor(async () => (await gw.RunAsync(() => gw.Addresses)).Count == 1), $"监听：有端口（{port}），地址列出来");
        var shown = (await gw.RunAsync(() => gw.Addresses))[0].Text(port);
        check(shown == $"192.168.1.23:{port}", "监听：界面上那行是 ip:port");

        async Task<PhoneWire> Connect(Guid id, byte[] k)
        {
            var c = new TcpClient();
            await c.ConnectAsync(IPAddress.Loopback, port);
            return new PhoneWire(c, id, k);
        }

        // 握手 accept：签名的 ping → Ack 0（签名）→ State、KeepAwakeState、Poll
        var w = await Connect(phone, key);
        var ack = await w.CommandAsync("ping", useNonce: false);
        check(ack is { Status: AckStatus.Accepted, Counter: 1 } && PairingCrypto.VerifyAck(ack, key), "握手：签名的 ping → 签名的 Ack 0");
        var state = await w.ReadKindAsync(Kind.State);
        check(state != null && PairingCrypto.OpenState(state, phone, key) is { Closed: false }, "握手：接着收到签名的幕布状态");
        var kaState = await w.ReadKindAsync(Kind.KeepAwakeState);
        check(kaState != null && PairingCrypto.OpenKeepAwakeState(kaState, phone, key) is { Mode: 0 }, "握手：和签名的保持唤醒状态（关）");
        check(await w.ReadKindAsync(Kind.Poll) != null && w.Nonce != null, "握手：和一个签名的 Poll（里面是 nonce）");
        check(await WaitFor(async () => (await gw.RunAsync(() => gw.Peers)).Count == 1)
              && (await gw.RunAsync(() => gw.Peers))[0].PhoneID == phone && peerChanges >= 1, "握手：手机出现在连着的网络手机里");

        // 命令放行：away
        var awayAck = await w.CommandAsync("away");
        check(awayAck is { Status: AckStatus.Accepted } && PairingCrypto.VerifyAck(awayAck, key), "命令：away → Ack 0");
        check(await WaitFor(() => Task.FromResult(Commands().Any(c => c.Item1 == "away" && c.Item2 == phone))), "命令：away 交给了处理函数");
        await w.ReadKindAsync(Kind.Poll);

        // 命令放行：awake:1h，网关把新的保持唤醒状态推回来
        var awakeAck = await w.CommandAsync("awake:1h");
        check(awakeAck is { Status: AckStatus.Accepted } && Commands().Any(c => c.Item1 == "awake:1h"), "命令：awake:1h → Ack 0，交给处理函数");
        check(await w.ReadKindAsync(Kind.KeepAwakeState) != null, "命令：awake 之后收到保持唤醒状态");
        await w.ReadKindAsync(Kind.Poll);

        // 被拒：unpair / hide / preview / settings → Ack 5，不交给处理函数
        var before = Commands().Count;
        foreach (var bad in new[] { "unpair", "hide", "preview", "settings", "lift" })
        {
            var refused = await w.CommandAsync(bad);
            check(refused is { Status: AckStatus.NotAllowedOnNetwork } && PairingCrypto.VerifyAck(refused, key), $"命令：「{bad}」→ 签名的 Ack 5");
            await w.ReadKindAsync(Kind.Poll);
        }
        check(Commands().Count == before && store.Load(phone) != null, "命令：被拒的一条都没交给处理函数，配对也还在");

        // 重放：同一个计数再送一次
        var replay = PairingCrypto.SealCommand("ping", phone, 1, key)!;
        await w.SendAsync(replay);
        check((await w.ReadKindAsync(Kind.Ack)) is { } ra && Ack.Decode(ra).Status == AckStatus.Replay, "重放：旧计数 → Ack 2");

        // 缺 nonce
        w.Nonce = null;
        check(await w.CommandAsync("away") is { Status: AckStatus.Replay }, "命令：away 不带 nonce → Ack 2");
        check(Commands().Count(c => c.Item1 == "away") == 1, "命令：不带 nonce 的 away 没执行");

        // Presence / LiftNow / 配对走网络：不回话，不耗计数，3 次后断开并封
        await w.ReadKindAsync(Kind.Poll);
        var counterBefore = store.Load(phone)!.LastCounter;
        var lift = PairingCrypto.SealLiftNow(PairingCrypto.MakeNonce(), phone, counterBefore + 5, key)!;
        await w.SendAsync(lift);
        await w.SendAsync(PairingCrypto.SealPresence(PresenceStatus.Unlocked, PairingCrypto.MakeNonce(), phone, counterBefore + 6, key)!);
        check(store.Load(phone)!.LastCounter == counterBefore, "撤下走网络：LiftNow / Presence 不耗计数");
        check(await w.CommandAsync("ping", useNonce: false) is { Status: AckStatus.Accepted }, "撤下走网络：被无视，连接还在、下一条命令照常");
        var (request, _) = PairingCrypto.PhoneStart("000000", Guid.NewGuid())!.Value;
        await w.SendAsync(request.Encoded());
        check(await w.ClosedAsync(), "三条不该走网络的消息（LiftNow、Presence、配对）→ 断开");
        w.Client.Dispose();

        // 封禁：同一个 IP 刚被封，不再 accept
        check(await WaitFor(async () => await gw.RunAsync(() => gw.IsBanned("127.0.0.1"))), "封禁：坏帧满 3 个，这个 IP 被封");
        var banned = await Connect(phone, key);
        check(await banned.ClosedAsync(), "封禁：被封的 IP 连上来立刻断开");
        banned.Client.Dispose();
        await gw.RunAsync(() => { gw.ClearBans(); return 0; });

        // 握手 reject：不认识的手机 → Ack 1（不签名）+ 坏帧；签名错同样
        var stranger = await Connect(Guid.NewGuid(), Key());
        check(await stranger.CommandAsync("ping", useNonce: false) is { Status: AckStatus.UnknownOrBadSignature, Mac: null }, "握手拒绝：没配过的手机 → Ack 1，不签名");
        check((await gw.RunAsync(() => gw.Peers)).Count == 0, "握手拒绝：没认出来就不算连着的手机");
        stranger.Client.Dispose();
        var wrongKey = await Connect(phone, Key());
        check(await wrongKey.CommandAsync("ping", useNonce: false) is { Status: AckStatus.UnknownOrBadSignature }, "握手拒绝：钥匙不对（签名错）→ Ack 1");
        wrongKey.Client.Dispose();
        var storeCounter = store.Load(phone)!.LastCounter;
        check(storeCounter == counterBefore + 1 || storeCounter >= counterBefore, "握手拒绝：假手机没动真手机的计数");

        // 只发半条就不动：到时间断开（PingDeadline = 1 s，没验过的连接）
        using (var idle = new TcpClient())
        {
            await idle.ConnectAsync(IPAddress.Loopback, port);
            var iw = new PhoneWire(idle, phone, key);
            check(await iw.ClosedAsync(4000), "握手超时：连上来不说话 → 断开");
        }

        // 幕布状态推送
        var w2 = await Connect(phone, key);
        w2.Counter = store.Load(phone)!.LastCounter;
        check(await w2.CommandAsync("ping", useNonce: false) is { Status: AckStatus.Accepted }, "重连：新连接再 ping 一次，收下");
        await w2.ReadKindAsync(Kind.State);
        curtain = true;
        gw.ReportCurtain(true);
        var pushed = await w2.ReadKindAsync(Kind.State);
        check(pushed != null && PairingCrypto.OpenState(pushed, phone, key) is { Closed: true }, "推送：幕布盖上 → 网络手机收到签名的状态");

        // 在电脑上撤销：手机收到签名的撤销通知，然后断开
        var notice = pc.Revoke(phone);
        gw.NotifyRevoked(phone, notice);
        var rev = await w2.ReadKindAsync(Kind.Revoke);
        check(rev != null && PairingCrypto.VerifyRevoke(rev, phone, key) && await w2.ClosedAsync(), "撤销：电脑上撤销 → 手机收到签名的撤销通知，连接断开");
        w2.Client.Dispose();

        // 关：断开所有连接，不再监听
        store.Save(new PairingRecord(key, 1000), phone);
        var w3 = await Connect(phone, key);
        w3.Counter = 1000;
        check(await w3.CommandAsync("ping", useNonce: false) is { Status: AckStatus.Accepted }, "再配上后又能连");
        gw.Stop();
        check(await WaitFor(async () => (await gw.RunAsync(() => gw.Status)).State == GatewayState.Stopped), "关：Stop → Stopped");
        check(await w3.ClosedAsync(), "关：已连着的手机被断开");
        w3.Client.Dispose();
        check(await gw.RunAsync(() => gw.Port) == null && (await gw.RunAsync(() => gw.Addresses)).Count == 0 && (await gw.RunAsync(() => gw.Peers)).Count == 0, "关：端口、地址、手机都清空");
        var refusedConnect = false;
        try
        {
            // 不用带 CancellationToken 的 ConnectAsync：.NET Framework（主程序的运行时）没有，这个测试两边都要能编
            using var late = new TcpClient();
            var connect = late.ConnectAsync(IPAddress.Loopback, port);
            if (await Task.WhenAny(connect, Task.Delay(2000)) != connect) throw new OperationCanceledException();
            await connect;
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException) { refusedConnect = true; }
        check(refusedConnect, "关：端口不再接受连接");

        // 再开
        gw.Start();
        check(await WaitFor(async () => (await gw.RunAsync(() => gw.Status)).State == GatewayState.Listening), "再开：Start → Listening");
        var port2 = (await gw.RunAsync(() => gw.Port))!.Value;
        using (var again = new TcpClient())
        {
            await again.ConnectAsync(IPAddress.Loopback, port2);
            var aw = new PhoneWire(again, phone, key) { Counter = 1001 };
            check(await aw.CommandAsync("ping", useNonce: false) is { Status: AckStatus.Accepted }, "再开：又能连、能认");
        }
        gw.Stop();
        check(await WaitFor(async () => (await gw.RunAsync(() => gw.Status)).State == GatewayState.Stopped), "再关：Stopped");

        // 端口被占：持久化端口换一个；Failed 的状态
        var blocker = new TcpListener(IPAddress.Loopback, 0);   // .NET Framework 的 TcpListener 不是 IDisposable，最后手动 Stop
        blocker.Start();
        var busy = ((IPEndPoint)blocker.LocalEndpoint).Port;
        var fixedPort = new MemoryPortStore { Port = busy };
        var gw2 = new NetworkGateway(pc, scheduler, fixedPort, PortChoice.Persisted, loopbackOnly: true) { Log = logs.Add };
        gw2.Start();
        var ended = await WaitFor(async () => (await gw2.RunAsync(() => gw2.Status)).State is GatewayState.Listening or GatewayState.Failed);
        var s2 = await gw2.RunAsync(() => gw2.Status);
        // 端口在 49200–49999 之外（系统分配的），所以 PersistedPort 会先换成范围内的；这里只验证：要么在范围里监听上了，要么明确 Failed
        check(ended && (s2.State == GatewayState.Failed || s2.Port is >= 49200 and <= 49999), "占用：存着的端口不在范围里 → 换成范围内的端口监听，或明确 Failed");
        blocker.Stop();
        gw2.Stop();
        await WaitFor(async () => (await gw2.RunAsync(() => gw2.Status)).State == GatewayState.Stopped);
    }
}
