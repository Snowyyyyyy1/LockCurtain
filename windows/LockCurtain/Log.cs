// Log.cs —— 运行日志，写到 %LOCALAPPDATA%\LockCurtain\lockcurtain.log
//
// Mac 版用 NSLog；Windows 的 GUI 进程没有控制台，日志只能落文件。
// 超过 1 MB 时把旧日志改名成 .old，只保留一份。

namespace LockCurtain;

internal static class Log
{
    public static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LockCurtain");
    static readonly string FilePath = Path.Combine(Dir, "lockcurtain.log");
    static readonly object Gate = new();
    static readonly System.Text.UTF8Encoding Utf8Bom = new(encoderShouldEmitUTF8Identifier: true);

    public static void Write(string message)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{Environment.ProcessId}] {message}{Environment.NewLine}";
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 1 << 20) File.Move(FilePath, FilePath + ".old", overwrite: true);
                // 新文件带 BOM，否则 Windows PowerShell 5.1 的 Get-Content 会按 GBK 读，中文全是乱码
                File.AppendAllText(FilePath, line, Utf8Bom);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        System.Diagnostics.Debug.Write(line);
    }

    public static void OpenDir()
    {
        Directory.CreateDirectory(Dir);
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Dir) { UseShellExecute = true });
    }
}
