// CurtainArt.cs —— 遮罩中间的图案，设置窗口里可以换（对应 Mac 版 CurtainArt.swift）
//
// 动画图案都是「时间 t → 一帧」的纯函数；同一个 t 永远画出同一帧，Tools/EyePreview 靠这一点离线出预览。
// 两只眼还会盯光标，多一个参数 MechEye.Stare，记着光标什么时候动过、眼球最近一跳的起止点。
// t 和 Mac 版一样是从 2001-01-01 UTC 起的秒数，机械表靠它显示本机当前时间。
// 新加一种图案：在 CurtainArt 里加一个值，补上 Title / Draw（尺寸不一样再补 Size / OffsetY）。
// 自定义图片不动，不走 Draw，由 CustomArt 画。

using System.Drawing;

namespace LockCurtain;

/// 存进 settings.json 的名字和 Mac 版 curtainArt 的取值一样（mechEye / clock / none …）
internal enum CurtainArt { MechEye, DemonEye, Talisman, Clock, Vault, Padlock, Custom, None }

internal static class CurtainArts
{
    static readonly DateTime ReferenceDate = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    /// 现在对应的 t
    public static double Now => (DateTime.UtcNow - ReferenceDate).TotalSeconds;

    /// t 对应的本机时间，取整到秒（Swift 的 Calendar.current）
    public static DateTime LocalTime(double t) => ReferenceDate.AddSeconds(Math.Floor(t)).ToLocalTime();

    public static string Title(this CurtainArt art) => art switch
    {
        CurtainArt.MechEye => "机械眼",
        CurtainArt.DemonEye => "魔瞳",
        CurtainArt.Talisman => "镇宅符",
        CurtainArt.Clock => "机械表",
        CurtainArt.Vault => "保险库",
        CurtainArt.Padlock => "挂锁",
        CurtainArt.Custom => "自定义图片",
        _ => "不显示",
    };

    /// 在遮罩上的边长（逻辑像素）
    public static float Size(this CurtainArt art) => art == CurtainArt.Custom ? 140 : 160;

    /// 中心相对屏幕中心的竖直偏移（逻辑像素，负数在上方），和下面的文案留出间距
    public static float OffsetY(this CurtainArt art) => art == CurtainArt.Custom ? -78 : -88;

    /// 动画图案的画法：把图案画进 (0,0)-(side,side) 的方块；最后一个参数是盯光标的状态，只有两只眼用，其余忽略。
    /// 自定义图片和不显示为 null
    public static Action<Graphics, float, double, MechEye.Stare?>? Draw(this CurtainArt art) => art switch
    {
        CurtainArt.MechEye => MechEye.Draw,
        CurtainArt.DemonEye => DemonEye.Draw,
        CurtainArt.Talisman => (g, s, t, _) => TalismanArt.Draw(g, s, t),
        CurtainArt.Clock => (g, s, t, _) => ClockArt.Draw(g, s, t),
        CurtainArt.Vault => (g, s, t, _) => VaultArt.Draw(g, s, t),
        CurtainArt.Padlock => (g, s, t, _) => PadlockArt.Draw(g, s, t),
        _ => null,
    };

    /// 会不会转过去盯着光标（遮罩上才用，设置窗口里的缩略图不用）
    public static bool Stares(this CurtainArt art) => art is CurtainArt.MechEye or CurtainArt.DemonEye;

    /// 停在一帧时画哪一刻：镇宅符停在写完、余光还在的时候，魔瞳避开眨眼，不然可能停在一张白纸或一只闭着的眼上
    public static double StillTime(this CurtainArt art, double t) => art switch
    {
        CurtainArt.Talisman => t - t % TalismanArt.Cycle + TalismanArt.Still,
        CurtainArt.DemonEye => DemonEye.PoseAt(t).Open < 0.95 ? t - 0.5 : t,
        _ => t,
    };
}
