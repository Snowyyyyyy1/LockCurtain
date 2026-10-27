// PowerGuard.cs —— 离开模式下防休眠
//
// SetThreadExecutionState 的状态跟着调用线程走，所以只在 UI 线程上调用。
// 屏幕常亮：ES_DISPLAY_REQUIRED，屏幕不熄、屏保不启动。
// 只锁住时只要 ES_SYSTEM_REQUIRED，允许熄屏；熄屏后要不要密码看系统设置。

namespace LockCurtain;

internal sealed class PowerGuard
{
    bool engaged;

    public void Engage(bool keepDisplayOn)
    {
        var flags = Native.ES_CONTINUOUS | Native.ES_SYSTEM_REQUIRED;
        if (keepDisplayOn) flags |= Native.ES_DISPLAY_REQUIRED;
        engaged = Native.SetThreadExecutionState(flags) != 0;
        Log.Write($"PowerGuard engage (keepDisplayOn={keepDisplayOn}) -> {engaged}");
    }

    public void Release()
    {
        if (!engaged) return;
        Native.SetThreadExecutionState(Native.ES_CONTINUOUS);
        engaged = false;
        Log.Write("PowerGuard release");
    }
}
