// PhoneStore.cs —— 手机配对的钥匙和计数（DPAPI，当前用户）+ 记得的手机蓝牙地址
//
//   %LOCALAPPDATA%\LockCurtain\phone-pairing.bin   ProtectedData.Protect(CurrentUser)，里面是 JSON：
//       { "phones": { "<phoneID 大写>": "<base64：32 字节钥匙 + 8 字节大端计数>" } }
//     对应 Mac 的钥匙串（KeychainPairingStore）。每收一条命令 / 回答都要先把新计数写进去，所以写盘走「先写临时文件再改名」。
//     换了 Windows 账户或重装系统，DPAPI 解不开，就当没配过（手机那边重新输码）。
//   %LOCALAPPDATA%\LockCurtain\phone-link.json     不是秘密：配过的手机最后一次的蓝牙地址（重连用），
//     和这台手机后台广播时苹果「溢出区」里的位图（见 PhoneLink.cs）。

using System.Security.Cryptography;
using System.Text.Json;

namespace LockCurtain.Phone;

internal sealed class DpapiPairingStore : IPairingRecordStore
{
    static readonly byte[] Entropy = "LockCurtain phone pairing v1"u8.ToArray();
    readonly string path;
    readonly Dictionary<Guid, PairingRecord> records;

    public DpapiPairingStore(string? path = null)
    {
        this.path = path ?? Path.Combine(Log.Dir, "phone-pairing.bin");
        records = Read();
    }

    Dictionary<Guid, PairingRecord> Read()
    {
        var o = new Dictionary<Guid, PairingRecord>();
        try
        {
            if (!File.Exists(path)) return o;
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            using var doc = JsonDocument.Parse(plain);
            foreach (var p in doc.RootElement.GetProperty("phones").EnumerateObject())
                if (Guid.TryParse(p.Name, out var id) && PairingRecord.Decode(Convert.FromBase64String(p.Value.GetString() ?? "")) is { } r)
                    o[id] = r;
            CryptographicOperations.ZeroMemory(plain);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException or JsonException
                                      or FormatException or KeyNotFoundException or InvalidOperationException)
        {
            PhoneLog.Write($"pairing store unreadable, treating as not paired: {e.GetType().Name}");
        }
        return o;
    }

    bool Write()
    {
        try
        {
            var json = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, Dictionary<string, string>>
            {
                ["phones"] = records.ToDictionary(r => PairingCrypto.IdString(r.Key), r => Convert.ToBase64String(r.Value.Encoded())),
            });
            var blob = ProtectedData.Protect(json, Entropy, DataProtectionScope.CurrentUser);
            CryptographicOperations.ZeroMemory(json);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";
            File.WriteAllBytes(tmp, blob);
            File.Move(tmp, path, overwrite: true);
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or CryptographicException)
        {
            PhoneLog.Write($"pairing store write failed: {e.Message}");
            return false;
        }
    }

    public PairingRecord? Load(Guid phoneID) => records.GetValueOrDefault(phoneID);

    public bool Save(PairingRecord record, Guid phoneID)
    {
        var old = records.GetValueOrDefault(phoneID);
        records[phoneID] = record;
        if (Write()) return true;
        if (old == null) records.Remove(phoneID); else records[phoneID] = old;
        return false;
    }

    public void Delete(Guid phoneID)
    {
        if (records.Remove(phoneID)) Write();
    }

    public IReadOnlyList<Guid> AllPhoneIDs() => records.Keys.ToList();
}

/// 记得的手机（不是秘密）
internal sealed class PhoneDeviceMemory
{
    public ulong? Address { get; private set; }
    /// 苹果溢出区位图（16 字节）：这台手机在后台广播时，我们服务 UUID 落在哪几位
    public byte[]? OverflowMask { get; private set; }

    readonly string path = Path.Combine(Log.Dir, "phone-link.json");

    sealed class Saved
    {
        public string? Address { get; set; }
        public string? OverflowMask { get; set; }
    }

    public PhoneDeviceMemory()
    {
        try
        {
            if (!File.Exists(path)) return;
            var s = JsonSerializer.Deserialize<Saved>(File.ReadAllText(path));
            if (s?.Address is { } a && ulong.TryParse(a, System.Globalization.NumberStyles.HexNumber, null, out var v)) Address = v;
            if (s?.OverflowMask is { Length: 32 } m) OverflowMask = Convert.FromHexString(m);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or FormatException) { }
    }

    public void Remember(ulong address)
    {
        if (Address == address) return;
        Address = address;
        Write();
    }

    public void LearnOverflowMask(byte[] mask)
    {
        if (OverflowMask != null && OverflowMask.AsSpan().SequenceEqual(mask)) return;
        OverflowMask = mask;
        Write();
    }

    public void Forget()
    {
        Address = null;
        OverflowMask = null;
        try { File.Delete(path); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    void Write()
    {
        try
        {
            Directory.CreateDirectory(Log.Dir);
            File.WriteAllText(path, JsonSerializer.Serialize(new Saved
            {
                Address = Address?.ToString("X12"),
                OverflowMask = OverflowMask == null ? null : Convert.ToHexString(OverflowMask),
            }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// 蓝牙这条链路上的每个事件都写一行（和 Mac 的 /tmp/lockcurtain-ble.log 同样的行格式，「lift:」开头的行一字不差）。
/// 写到 %LOCALAPPDATA%\LockCurtain\ble.log，超过 2 MB 改名成 ble.log.old。不写码、不写钥匙。
internal static class PhoneLog
{
    public static readonly string FilePath = Path.Combine(Log.Dir, "ble.log");
    static readonly object Gate = new();
    static readonly System.Text.UTF8Encoding Utf8Bom = new(encoderShouldEmitUTF8Identifier: true);

    public static void Write(string text)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {text}{Environment.NewLine}";
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Log.Dir);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 2 << 20) File.Move(FilePath, FilePath + ".old", overwrite: true);
                File.AppendAllText(FilePath, line, Utf8Bom);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        System.Diagnostics.Debug.Write("BLE " + line);
    }
}
