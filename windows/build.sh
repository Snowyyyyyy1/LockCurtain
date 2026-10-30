#!/bin/bash
# build.sh —— 在 Mac 上交叉编译 Windows 版
#
# 输出两个自带 .NET 运行时的单文件 exe，目标机器不用装 .NET：
#   dist/win-arm64/ 和 dist/win-x64/ 里各有：
#     LockCurtain.exe      入口启动器（计划任务和双击都从它起主程序），非 uiAccess
#     LockCurtainApp.exe   uiAccess 主程序（install.ps1 给它签名）
# 每个目录里再放自动更新用的 WinSparkle.dll、install.ps1，和启动器的同名副本 LockCurtainCtl.exe
#（为兼容 1.0.2 的更新器，它写死要求更新包里有这个名字），一起打成 dist/LockCurtain-<版本>-<架构>.zip：
# 发到 GitHub Release，也是自动更新下载的包（LockCurtain/Updater.cs）。
#   dist/LockCurtain-<版本>-setup.exe  单文件安装器（双击即装，自动识别 x64/ARM64），需 makensis（brew install makensis）
#
# 版本号读仓库根目录的 VERSION。环境变量：
#   LOCKCURTAIN_EDDSA_PUBLIC_KEY   自动更新验签的公钥（release.sh 传进来）；没有时编出来的版本不检查更新
#   LOCKCURTAIN_APPCAST_URL        测试用：换掉更新清单的地址（默认是 GitHub Release 上的 appcast-windows.xml）
# 需要 .NET SDK 10（brew install dotnet）。第一次会从 NuGet 下载 Windows 的运行时包，从 GitHub 下载 WinSparkle。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(tr -d '[:space:]' < ../VERSION)"

# exe 图标和 Mac 版是同一张图：图标脚本改过或 ico 不存在时才重画（和上一级 build.sh 画 icns 一样）
ICO=LockCurtain/LockCurtain.ico
if [ ! -f "$ICO" ] || [ ../Tools/make-icon.swift -nt "$ICO" ]; then
  echo "[icon] $ICO"
  T="$(mktemp -d)"
  xcrun swiftc -o "$T/make-icon" ../Tools/make-icon.swift
  "$T/make-icon" --ico "$ICO" >/dev/null
  rm -rf "$T"
fi

# WinSparkle 固定一个版本，下载一次缓存起来，每次都核对 GitHub 上记录的 sha256
WINSPARKLE=0.9.4
WINSPARKLE_SHA256=6037df37fc263bd1650a1c4949681a9d40ffe991d01f35892a406cb5d103c976
WINSPARKLE_ZIP=".cache/WinSparkle-$WINSPARKLE.zip"
if [ ! -f "$WINSPARKLE_ZIP" ]; then
  echo "[winsparkle] $WINSPARKLE"
  mkdir -p .cache
  # 先下到 .part，下完再改名：中途断了不会留下半个 zip，让以后每次都卡在校验上
  curl -fsSL -o "$WINSPARKLE_ZIP.part" "https://github.com/vslavik/winsparkle/releases/download/v$WINSPARKLE/WinSparkle-$WINSPARKLE.zip"
  mv "$WINSPARKLE_ZIP.part" "$WINSPARKLE_ZIP"
fi
echo "$WINSPARKLE_SHA256  $WINSPARKLE_ZIP" | shasum -a 256 -c --quiet -

for rid in ${LOCKCURTAIN_RIDS:-win-arm64 win-x64}; do
  echo "[$rid] publish $VERSION"
  # WinSparkle.dll 不打进单文件：打进去会在运行时解压到普通权限能写的临时目录，以最高权限加载就成了提权漏洞
  dotnet publish LockCurtain/LockCurtain.csproj -c Release -r "$rid" --self-contained \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=none \
    -p:Version="$VERSION" -p:EdDSAPublicKey="${LOCKCURTAIN_EDDSA_PUBLIC_KEY:-}" \
    ${LOCKCURTAIN_APPCAST_URL:+-p:AppcastUrl="$LOCKCURTAIN_APPCAST_URL"} \
    -o "dist/$rid" | tail -1
  case "$rid" in win-arm64) arch=ARM64 ;; win-x64) arch=x64 ;; esac
  unzip -p "$WINSPARKLE_ZIP" "WinSparkle-$WINSPARKLE/$arch/Release/WinSparkle.dll" > "dist/$rid/WinSparkle.dll"
  # 不带 uiAccess 的入口启动器（AssemblyName=LockCurtain → LockCurtain.exe）：计划任务 ShellExecute 起主程序，也给 agent 发命令
  dotnet publish LockCurtainCtl/LockCurtainCtl.csproj -c Release -r "$rid" --self-contained \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=none -p:Version="$VERSION" \
    -o "dist/$rid-ctl" | tail -1
  cp "dist/$rid-ctl/LockCurtain.exe" "dist/$rid/"
  # 再拷一份叫 LockCurtainCtl.exe：1.0.2 的更新器写死要求更新包里有这个名字，否则 1.0.2 用户更新会失败
  cp "dist/$rid-ctl/LockCurtain.exe" "dist/$rid/LockCurtainCtl.exe"
  rm -rf "dist/$rid-ctl"
  cp install.ps1 "dist/$rid/"
  zip="dist/LockCurtain-$VERSION-$rid.zip"
  rm -f "$zip"
  (cd "dist/$rid" && zip -qX "../$(basename "$zip")" LockCurtainApp.exe LockCurtain.exe WinSparkle.dll install.ps1 LockCurtainCtl.exe)
  ls -lh "dist/$rid/LockCurtainApp.exe" "dist/$rid/LockCurtain.exe" "$zip" | awk '{print "  " $5, $9}'
done

# 把两种架构的产物打成一个「自动识别 CPU」的单文件安装器（NSIS）。
# File 命令编译期把两份都塞进同一个 exe，运行时按 ${IsNativeARM64} 只解压匹配的那份，再跑 install.ps1。
# 需要 makensis（brew install makensis）。只有同时编了 x64 和 ARM64 才产出。
if [ -d dist/win-x64 ] && [ -d dist/win-arm64 ]; then
  setup="dist/LockCurtain-$VERSION-setup.exe"
  rm -f "$setup"
  makensis -DVERSION="$VERSION" installer.nsi | tail -2
  ls -lh "$setup" | awk '{print "  " $5, $9}'
else
  echo "[setup] 跳过单文件安装器：需要同时构建 win-x64 和 win-arm64"
fi
