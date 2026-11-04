// CtlArgs.cs —— LockCurtain.exe（启动器）的命令行怎么解析（纯函数，PhoneSelfTest 里测）
//
//   （无参数）/ --launch                 起主程序
//   --relaunch-after <pid>               旧更新器换完文件后：等 pid 退出再起（或自愈）
//   --send <cmd>                         发命令给正在运行的实例（设置 › 远程控制 教的就是这一种）；--send 后面没有命令 = status
//   <cmd>                                同上，旧写法照样认（away / hide / preview / status / settings）

namespace LockCurtain;

internal enum CtlAction { Launch, Relaunch, Send }

internal readonly record struct CtlArgs(CtlAction Action, string Command = "", int? Pid = null)
{
    public static CtlArgs Parse(IReadOnlyList<string> args)
    {
        if (args.Count == 0 || args.Contains("--launch")) return new(CtlAction.Launch);
        var list = args.ToList();
        var rel = list.IndexOf("--relaunch-after");
        if (rel >= 0)
            return new(CtlAction.Relaunch, Pid: rel + 1 < list.Count && int.TryParse(list[rel + 1], out var pid) ? pid : null);
        var send = list.IndexOf("--send");
        if (send >= 0) return new(CtlAction.Send, send + 1 < list.Count ? list[send + 1] : "status");
        return new(CtlAction.Send, list[0]);
    }
}
