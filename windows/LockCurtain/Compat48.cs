// Compat48.cs —— .NET Framework 4.8 缺的 .NET 10 API，补成同名的扩展成员，调用处照旧写
//
// 主程序编译成 net48（Windows 自带，发布包不用带运行时）；Phone/Protocol、Rules 等文件也被 Tests 里的 net10 测试编译，
// 所以这里整个文件只在 NETFRAMEWORK 下生效，net10 上用的还是系统自带的实现。
// 静态扩展（Math.Clamp、Environment.ProcessId…）靠 C# 14 的 extension 块；Index/Range/init 等语法要的类型由 PolySharp 生成。
// 每个补丁的行为照 .NET 10 的文档写；和原版有出入的地方在注释里写明。
// 这里只放不依赖 WinForms 的（PhoneSelfTest 的 net48 版也编它）；WinForms 的在 WinForms48.cs。
#if NETFRAMEWORK
using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace System.Security.Cryptography
{
    internal static class CryptographicOperations
    {
        /// 不论内容，比完全部字节才返回（长度不同直接 false，和 .NET 一样）
        [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
        public static bool FixedTimeEquals(ReadOnlySpan<byte> left, ReadOnlySpan<byte> right)
        {
            if (left.Length != right.Length) return false;
            var diff = 0;
            for (var i = 0; i < left.Length; i++) diff |= left[i] ^ right[i];
            return diff == 0;
        }

        [MethodImpl(MethodImplOptions.NoInlining | MethodImplOptions.NoOptimization)]
        public static void ZeroMemory(Span<byte> buffer) => buffer.Clear();
    }

    /// RFC 5869（只用到 SHA256，见 PairingCrypto）
    internal static class HKDF
    {
        public static byte[] DeriveKey(HashAlgorithmName hash, byte[] ikm, int outputLength, byte[]? salt = null, byte[]? info = null)
        {
            using var extract = Hmac(hash, salt is { Length: > 0 } ? salt : new byte[HashLength(hash)]);
            var prk = extract.ComputeHash(ikm);
            using var expand = Hmac(hash, prk);
            var output = new byte[outputLength];
            var previous = Array.Empty<byte>();
            for (int done = 0, counter = 1; done < outputLength; counter++)
            {
                var input = new byte[previous.Length + (info?.Length ?? 0) + 1];
                previous.CopyTo(input, 0);
                info?.CopyTo(input, previous.Length);
                input[input.Length - 1] = (byte)counter;
                previous = expand.ComputeHash(input);
                var n = Math.Min(previous.Length, outputLength - done);
                Array.Copy(previous, 0, output, done, n);
                done += n;
            }
            return output;
        }

        static HMAC Hmac(HashAlgorithmName hash, byte[] key) => hash.Name switch
        {
            "SHA256" => new HMACSHA256(key),
            "SHA512" => new HMACSHA512(key),
            _ => throw new CryptographicException($"HKDF: 不支持 {hash.Name}"),
        };

        static int HashLength(HashAlgorithmName hash) => hash.Name == "SHA512" ? 64 : 32;
    }
}

namespace System.IO.Pipes
{
    internal static class NamedPipeServerStreamAcl
    {
        public static NamedPipeServerStream Create(string pipeName, PipeDirection direction, int maxNumberOfServerInstances,
            PipeTransmissionMode transmissionMode, PipeOptions options, int inBufferSize, int outBufferSize, PipeSecurity? pipeSecurity) =>
            new(pipeName, direction, maxNumberOfServerInstances, transmissionMode, options, inBufferSize, outBufferSize, pipeSecurity);
    }
}

namespace System.Text
{
    /// .NET Framework 自带全部代码页，不用注册；给 Encoding.RegisterProvider 一个什么都不提供的
    internal sealed class CodePagesEncodingProvider : EncodingProvider
    {
        public static CodePagesEncodingProvider Instance { get; } = new();
        public override Encoding? GetEncoding(int codepage) => null;
        public override Encoding? GetEncoding(string name) => null;
    }
}

namespace LockCurtain
{
    internal static class Net48Compat
    {
        extension(Math)
        {
            public static int Clamp(int value, int min, int max) => value < min ? min : value > max ? max : value;
            public static long Clamp(long value, long min, long max) => value < min ? min : value > max ? max : value;
            public static float Clamp(float value, float min, float max) => value < min ? min : value > max ? max : value;
            public static double Clamp(double value, double min, double max) => value < min ? min : value > max ? max : value;
        }

        extension(double)
        {
            public static bool IsFinite(double d) => !double.IsNaN(d) && !double.IsInfinity(d);
        }

        extension(Environment)
        {
            public static string ProcessPath => ProcessPathValue;
            public static int ProcessId => ProcessIdValue;
            public static long TickCount64 => (long)GetTickCount64();
        }

        static readonly string ProcessPathValue = Process.GetCurrentProcess().MainModule!.FileName;
        static readonly int ProcessIdValue = Process.GetCurrentProcess().Id;

        extension(OperatingSystem)
        {
            public static bool IsWindows() => true;
        }

        extension(Enum)
        {
            public static T[] GetValues<T>() where T : struct, Enum => (T[])Enum.GetValues(typeof(T));
        }

        extension(Convert)
        {
            /// 大写十六进制，和 .NET 一样
            public static string ToHexString(ReadOnlySpan<byte> bytes)
            {
                var sb = new StringBuilder(bytes.Length * 2);
                foreach (var b in bytes) sb.Append(b.ToString("X2"));
                return sb.ToString();
            }

            public static byte[] FromHexString(string s)
            {
                if (s.Length % 2 != 0) throw new FormatException("十六进制字符串长度不是偶数");
                var bytes = new byte[s.Length / 2];
                for (var i = 0; i < bytes.Length; i++)
                    bytes[i] = byte.Parse(s.Substring(i * 2, 2), System.Globalization.NumberStyles.HexNumber,
                        System.Globalization.CultureInfo.InvariantCulture);
                return bytes;
            }
        }

        extension(RandomNumberGenerator)
        {
            public static byte[] GetBytes(int count)
            {
                var bytes = new byte[count];
                using var rng = RandomNumberGenerator.Create();
                rng.GetBytes(bytes);
                return bytes;
            }

            /// [fromInclusive, toExclusive) 里均匀取一个（拒绝采样，没有取模偏差）
            public static int GetInt32(int fromInclusive, int toExclusive)
            {
                if (fromInclusive >= toExclusive) throw new ArgumentException("范围是空的");
                var range = (uint)(toExclusive - fromInclusive - 1);
                var mask = range;
                mask |= mask >> 1; mask |= mask >> 2; mask |= mask >> 4; mask |= mask >> 8; mask |= mask >> 16;
                var buffer = new byte[4];
                using var rng = RandomNumberGenerator.Create();
                uint value;
                do
                {
                    rng.GetBytes(buffer);
                    value = BitConverter.ToUInt32(buffer, 0) & mask;
                } while (value > range);
                return (int)value + fromInclusive;
            }
        }

        extension(Random)
        {
            /// .NET 的 Random.Shared 线程安全；这里每个线程一个
            public static Random Shared => threadRandom ??= new Random(Guid.NewGuid().GetHashCode());
        }

        [ThreadStatic] static Random? threadRandom;

        extension(SHA512)
        {
            public static byte[] HashData(byte[] source)
            {
                using var sha = SHA512.Create();
                return sha.ComputeHash(source);
            }
        }

        extension(HMACSHA256)
        {
            public static byte[] HashData(byte[] key, byte[] source)
            {
                using var hmac = new HMACSHA256(key);
                return hmac.ComputeHash(source);
            }
        }


        extension(SocketOptionName)
        {
            // Winsock 的 TCP_KEEPALIVE / TCP_KEEPINTVL / TCP_KEEPCNT（Windows 10 1709 起），.NET Framework 的枚举里没有
            public static SocketOptionName TcpKeepAliveTime => (SocketOptionName)3;
            public static SocketOptionName TcpKeepAliveInterval => (SocketOptionName)17;
            public static SocketOptionName TcpKeepAliveRetryCount => (SocketOptionName)16;
        }

        extension(File)
        {
            /// overwrite 时用 MoveFileEx(MOVEFILE_REPLACE_EXISTING)，同一个卷上是原子替换，和 .NET 一样
            public static void Move(string sourceFileName, string destFileName, bool overwrite)
            {
                if (!overwrite) { File.Move(sourceFileName, destFileName); return; }
                const uint MOVEFILE_REPLACE_EXISTING = 1, MOVEFILE_COPY_ALLOWED = 2;
                if (!MoveFileExW(Path.GetFullPath(sourceFileName), Path.GetFullPath(destFileName), MOVEFILE_REPLACE_EXISTING | MOVEFILE_COPY_ALLOWED))
                    throw new IOException($"移动 {sourceFileName} → {destFileName} 失败", new Win32Exception(Marshal.GetLastWin32Error()));
            }
        }

        extension(Task task)
        {
            public bool IsCompletedSuccessfully => task.Status == TaskStatus.RanToCompletion;
        }

        /// 到时抛 TimeoutException，token 取消抛 OperationCanceledException；原来的任务不受影响，和 .NET 一样
        public static async Task<T> WaitAsync<T>(this Task<T> task, TimeSpan timeout, CancellationToken token)
        {
            if (task.IsCompleted) return await task.ConfigureAwait(false);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(token);
            var delay = Task.Delay(timeout, cts.Token);
            if (await Task.WhenAny(task, delay).ConfigureAwait(false) == task)
            {
                cts.Cancel();
                return await task.ConfigureAwait(false);
            }
            token.ThrowIfCancellationRequested();
            throw new TimeoutException();
        }

        /// 取消回调放到线程池上跑，不在调用方（可能拿着锁）里同步执行，和 .NET 的 CancelAsync 一样
        public static Task CancelAsync(this CancellationTokenSource cts) => Task.Run(cts.Cancel);

        public static Task<string?> ReadLineAsync(this StreamReader reader, CancellationToken token) =>
            reader.ReadLineAsync().WaitAsync(Timeout.InfiniteTimeSpan, token)!;

        public static Task<int> ReadAsync(this Stream stream, byte[] buffer, CancellationToken token = default) =>
            stream.ReadAsync(buffer, 0, buffer.Length, token);

        public static void Write(this Stream stream, byte[] buffer) => stream.Write(buffer, 0, buffer.Length);

        public static Task WriteAsync(this Stream stream, byte[] buffer, CancellationToken token = default) =>
            stream.WriteAsync(buffer, 0, buffer.Length, token);

        public static void CopyTo(this string s, Span<char> destination) => s.AsSpan().CopyTo(destination);

        public static bool StartsWith(this string s, char c) => s.Length > 0 && s[0] == c;
        public static bool EndsWith(this string s, char c) => s.Length > 0 && s[s.Length - 1] == c;
        public static string[] Split(this string s, char separator, int count) => s.Split(new[] { separator }, count);

        public static bool TryDequeue<T>(this Queue<T> queue, out T result)
        {
            if (queue.Count > 0) { result = queue.Dequeue(); return true; }
            result = default!;
            return false;
        }

        public static IOrderedEnumerable<T> Order<T>(this IEnumerable<T> source) => source.OrderBy(x => x);

        public static TValue? GetValueOrDefault<TKey, TValue>(this Dictionary<TKey, TValue> dictionary, TKey key) where TKey : notnull =>
            dictionary.TryGetValue(key, out var value) ? value : default;

        public static bool Remove<TKey, TValue>(this Dictionary<TKey, TValue> dictionary, TKey key, out TValue value) where TKey : notnull
        {
            if (!dictionary.TryGetValue(key, out value!)) return false;
            dictionary.Remove(key);
            return true;
        }

        public static void Deconstruct<TKey, TValue>(this KeyValuePair<TKey, TValue> pair, out TKey key, out TValue value)
        {
            key = pair.Key;
            value = pair.Value;
        }

        [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool MoveFileExW(string existing, string target, uint flags);
    }

    /// 和 HMACSHA256.HashData 编译后同名同参数，只能放在另一个类里
    internal static class Net48CompatHmac512
    {
        extension(HMACSHA512)
        {
            public static byte[] HashData(byte[] key, byte[] source)
            {
                using var hmac = new HMACSHA512(key);
                return hmac.ComputeHash(source);
            }
        }
    }
}
#endif
