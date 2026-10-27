// PowerGuard.cs —— 离开模式下防休眠、压低亮度
//
// 只在离开模式生效。两个用户设置（设置窗口「离开模式」页，见 Settings.cs）：
//   屏幕常亮（默认开）    ES_DISPLAY_REQUIRED，屏幕不熄、屏保不启动。
//                         关掉则只要 ES_SYSTEM_REQUIRED，允许熄屏；熄屏后要不要重新登录看系统设置
//   亮度调到最低（默认关） 见 Brightness.cs。WMI 第一次连接要几百毫秒，放到后台做，不拖慢遮罩上屏
//
// SetThreadExecutionState 的状态跟着调用线程走，所以只在 UI 线程上调用。

namespace LockCurtain;

internal sealed class PowerGuard
{
    bool engaged;
    Task<Dictionary<string, byte>>? dimmed;

    public void Engage()
    {
        var settings = Settings.Current;
        var flags = Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED;
        if (settings.AwayKeepDisplayOn) flags |= Native.ES_DISPLAY_REQUIRED;
        engaged = Native.SetThreadExecutionState(flags) != 0;
        Log.Write($"PowerGuard engage (keepDisplayOn={settings.AwayKeepDisplayOn}) -> {engaged}");
        if (settings.AwayDimBrightness) dimmed = Task.Run(Brightness.Dim);
    }

    public void Release()
    {
        if (engaged)
        {
            Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
            engaged = false;
            Log.Write("PowerGuard release");
        }
        // 调暗还没做完就等它做完再恢复；WMI 卡住时不无限等。
        // 这里在撤遮罩的路上，抛出去遮罩就撤不掉了，什么错都只记日志
        var d = dimmed;
        dimmed = null;
        try
        {
            if (d != null && d.Wait(3000)) Brightness.Restore(d.Result);
        }
        catch (Exception e)
        {
            Log.Write($"PowerGuard: 恢复亮度出错 {e}");
        }
    }
}
