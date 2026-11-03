// UiWatchdog.cs —— UI 线程卡住时往 ble.log 写一行
//
// 自己的线程每秒往 UI 线程 Post 一个空活儿，记下它多久才被执行。超过 2 秒还没执行，就写
// 「watchdog: UI thread not responding for N ms」加上 PhoneLink 的状态（UI 上最后进入的蓝牙处理、连着谁、在连谁…），
// 之后每 10 秒再写一次；恢复了写一行一共卡了多久。Windows 判「无响应」要 5 秒，这里 2 秒就记，下次日志里能看到卡在哪。

namespace LockCurtain.Phone;

internal sealed class UiWatchdog
{
    const int StallMs = 2000, RepeatMs = 10_000;
    readonly SynchronizationContext ui;
    readonly Func<string> describe;
    long postedAt;      // 0 = 没有在等的
    long ackedAt;

    public UiWatchdog(SynchronizationContext ui, Func<string> describe)
    {
        this.ui = ui;
        this.describe = describe;
    }

    public void Start() => new Thread(Run) { IsBackground = true, Name = "ui watchdog" }.Start();

    void Run()
    {
        long reportedAt = 0, stallStart = 0;
        while (true)
        {
            Thread.Sleep(500);
            var now = Environment.TickCount64;
            var posted = Interlocked.Read(ref postedAt);
            if (posted == 0)
            {
                if (stallStart != 0)
                {
                    PhoneLog.Write($"watchdog: UI thread responding again after {Interlocked.Read(ref ackedAt) - stallStart} ms");
                    stallStart = reportedAt = 0;
                }
                if (Interlocked.CompareExchange(ref postedAt, now, 0) == 0)
                    ui.Post(_ =>
                    {
                        Interlocked.Exchange(ref ackedAt, Environment.TickCount64);
                        Interlocked.Exchange(ref postedAt, 0);
                    }, null);
                continue;
            }
            var waited = now - posted;
            if (waited < StallMs) continue;
            if (stallStart == 0) stallStart = posted;
            if (reportedAt != 0 && now - reportedAt < RepeatMs) continue;
            reportedAt = now;
            string state;
            try { state = describe(); } catch (Exception e) { state = $"(no state: {e.GetType().Name})"; }
            PhoneLog.Write($"watchdog: UI thread not responding for {waited} ms; {state}");
            Log.Write($"watchdog: UI 线程 {waited} ms 没有响应（详情见 ble.log）");
        }
    }
}
