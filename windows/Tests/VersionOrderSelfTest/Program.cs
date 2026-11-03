// VersionOrderSelfTest —— 验证测试版的版本号在 Windows 的自动更新里排得对
//
// 更新器（Updater.cs）把 Application.ProductVersion 去掉「+提交号」交给 WinSparkle，
// WinSparkle 用自己的 CompareVersions 和 appcast 里的 sparkle:version 比，appcast 里的版本更新才提示。
// 这里的 Compare 逐行照抄 WinSparkle 0.9.4 的 src/updatechecker.cpp（UpdateChecker::CompareVersions，
// windows/build.sh 固定用 0.9.4）；换 WinSparkle 版本时要对着新源码重新核一遍。
//
// 运行（在 Mac 上也能跑，不需要 Windows）：
//   cd windows/Tests/VersionOrderSelfTest && dotnet run
//
// Mac 那边对应 Tests/VersionOrderSelfTest.swift（用的是 Sparkle 2 本身的比较器）。全部通过返回 0，有失败返回 1。

var failures = 0;
var total = 0;

void Check(bool cond, string name)
{
    total++;
    Console.WriteLine((cond ? "  OK   " : "  FAIL ") + name);
    if (!cond) failures++;
}

void Older(string a, string b)
{
    Check(Compare(a, b) < 0 && Compare(b, a) > 0, $"{a} < {b}");
}

// 测试版之间、测试版和正式版之间
Older("1.0.4-beta.2", "1.0.4-beta.3");
Older("1.0.4-beta.3", "1.0.4");
Older("1.0.3", "1.0.4-beta.1");
Older("1.0.3", "1.0.4-beta.3");
Older("1.0.4-beta.9", "1.0.4-beta.10");
Older("1.0.4-beta.3", "1.0.4-rc.1");
Older("1.0.4", "1.0.5-beta.1");
Older("1.0.4-beta.3", "1.0.5-beta.1");
Older("1.0.4-beta.3", "1.0.4.1");
// 正式版之间照旧
Older("1.0.2", "1.0.3");
Older("1.0.3", "1.0.10");
Check(Compare("1.0.4-beta.3", "1.0.4-beta.3") == 0, "1.0.4-beta.3 == 1.0.4-beta.3");
Check(Compare("1.0.4", "1.0.4") == 0, "1.0.4 == 1.0.4");
// 已经发出去的 1.0.4-beta.1 / beta.2（读的是正式 appcast）：正式版 1.0.4 出来时能升上去
Older("1.0.4-beta.1", "1.0.4");
Older("1.0.4-beta.2", "1.0.4");

// Updater.Version：ProductVersion 去掉「+提交号」
Check("1.0.4-beta.3+d40be8d".Split('+')[0] == "1.0.4-beta.3", "ProductVersion 1.0.4-beta.3+<提交号> → 1.0.4-beta.3");

Console.WriteLine(failures == 0 ? $"全部通过（{total} 项）" : $"{failures}/{total} 项失败");
return failures == 0 ? 0 : 1;

// ---- 以下照抄 WinSparkle 0.9.4 src/updatechecker.cpp ----

static int Classify(char c) => c == '.' ? 1 : c >= '0' && c <= '9' ? 0 : 2;    // Type_Number 0, Type_Period 1, Type_String 2

static List<string> Split(string version)
{
    var list = new List<string>();
    if (version.Length == 0) return list;
    var s = version[0].ToString();
    var prevType = Classify(version[0]);
    for (var i = 1; i < version.Length; i++)
    {
        var c = version[i];
        var newType = Classify(c);
        if (prevType != newType || prevType == 1)
        {
            list.Add(s);
            s = c.ToString();
        }
        else s += c;
        prevType = newType;
    }
    list.Add(s);
    return list;
}

static int Compare(string verA, string verB)
{
    var partsA = Split(verA);
    var partsB = Split(verB);
    var n = Math.Min(partsA.Count, partsB.Count);
    for (var i = 0; i < n; i++)
    {
        string a = partsA[i], b = partsB[i];
        int typeA = Classify(a[0]), typeB = Classify(b[0]);
        if (typeA == typeB)
        {
            if (typeA == 2)
            {
                var result = string.CompareOrdinal(a, b);    // std::string::compare
                if (result != 0) return result;
            }
            else if (typeA == 0)
            {
                var intA = int.Parse(a);
                var intB = int.Parse(b);
                if (intA > intB) return 1;
                if (intA < intB) return -1;
            }
        }
        else
        {
            if (typeA != 2 && typeB == 2) return 1;
            if (typeA == 2 && typeB != 2) return -1;
            return typeA == 0 ? 1 : -1;
        }
    }
    if (partsA.Count == partsB.Count) return 0;
    int shorterResult, longerResult, missingPartType;
    if (partsA.Count > partsB.Count)
    {
        missingPartType = Classify(partsA[n][0]);
        shorterResult = -1;
        longerResult = 1;
    }
    else
    {
        missingPartType = Classify(partsB[n][0]);
        shorterResult = 1;
        longerResult = -1;
    }
    return missingPartType == 2 ? shorterResult : longerResult;
}
