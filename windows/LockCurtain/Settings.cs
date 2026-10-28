// Settings.cs —— 用户设置，存在 %LOCALAPPDATA%\LockCurtain\settings.json
//
// 对应 Mac 版的 Preferences.swift（UserDefaults）。设置窗口每改一项就写盘并发 Changed，
// 托盘图标的显示开关跟着变；其余设置在下次显示遮罩时读。
// 文件不存在、读不了或格式坏了都用默认值，坏文件在下次改设置时被覆盖。

using System.Text.Json;
using System.Text.Json.Serialization;

namespace LockCurtain;

internal sealed class Settings
{
    public bool ShowTrayIcon { get; set; } = true;
    public CurtainArt CurtainArt { get; set; } = CurtainArt.MechEye;
    /// 自定义图片：设置目录里的文件名（CustomArt 存的）；null 时用账户头像
    public string? CurtainImage { get; set; }
    /// 自定义图片裁成圆形；关掉时按原比例放进方框
    public bool CurtainImageRound { get; set; } = true;
    /// 遮罩背景（CurtainBackground.cs），默认当前壁纸
    public CurtainBackground CurtainBackground { get; set; } = CurtainBackground.Wallpaper;
    /// 遮罩文字：图案下面的标题和提示，空字符串 = 不显示这一行（Mac 版 curtainTitle / curtainSubtitle）。
    /// settings.json 里手改成 null 也当空的，不然显示遮罩时建窗口出错
    public string CurtainTitle { get; set => field = value ?? ""; } = DefaultCurtainTitle;
    public string CurtainSubtitle { get; set => field = value ?? ""; } = DefaultCurtainSubtitle;
    public const string DefaultCurtainTitle = "LockCurtain is Using Your PC";
    public const string DefaultCurtainSubtitle = "Press any key or click to unlock";
    /// 离开模式下屏幕常亮；关掉时只防系统休眠，允许熄屏
    public bool AwayKeepDisplayOn { get; set; } = true;
    /// 离开模式下把内置屏亮度调到 0，撤遮罩时恢复
    public bool AwayDimBrightness { get; set; }
    /// 正在进行的保持唤醒，退出 LockCurtain 后下次启动接着来（见 KeepAwake.cs）；null 是没开
    public KeepAwakeSaved? KeepAwake { get; set; }
    /// 每天自动检查一次更新（Updater.cs），发现新版本时提示
    public bool AutoCheckUpdates { get; set; } = true;

    static readonly string FilePath = Path.Combine(Log.Dir, "settings.json");
    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static Settings Current { get; } = Load();
    public static event Action? Changed;

    static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath), Json) ?? new(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return new(); }
        catch (JsonException e)
        {
            Log.Write($"settings.json 格式不对，用默认设置: {e.Message}");
            return new();
        }
    }

    /// 改设置都走这里：改完写盘，再通知
    public static void Update(Action<Settings> change)
    {
        change(Current);
        try
        {
            Directory.CreateDirectory(Log.Dir);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(Current, Json));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Log.Write($"settings.json 写不进去: {e.Message}");
        }
        Changed?.Invoke();
    }
}
