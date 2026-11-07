#!/bin/bash
# build.sh —— 在 Mac 上交叉编译 Windows 版
#
# 主程序和启动器都编成 .NET Framework 4.8（Windows 10 1903 起自带，目标机器不用装 .NET，包里也不用带运行时）、AnyCPU：
# x64 和 ARM64 用同一份文件。dist/win/ 里是：
#     LockCurtain.exe        入口启动器（计划任务和双击都从它起主程序），非 uiAccess
#     LockCurtainApp.exe     uiAccess 主程序（install.ps1 给它签名），旁边是它的 .config 和依赖的 dll
#     x64\WinSparkle.dll、arm64\WinSparkle.dll   自动更新，主程序按自己进程的架构挑（AnyCPU 在 ARM64 上是 x64 仿真，用的是 x64 那份）
#     install.ps1
#     WinSparkle.dll、LockCurtainCtl.exe   占位文件，给旧版更新器查名字用（见下面打包处）
# 打成 dist/LockCurtain-<版本>-win-x64.zip 和 -win-arm64.zip（内容一样，名字照旧：旧版更新器按架构找包，README 也按架构写），
# 发到 GitHub Release，也是自动更新下载的包（LockCurtain/Updater.cs）。
#   dist/LockCurtain-<版本>-setup.exe  单文件安装器（双击即装），需 makensis（brew install makensis）
#
# 版本号读仓库根目录的 VERSION。环境变量：
#   LOCKCURTAIN_EDDSA_PUBLIC_KEY   自动更新验签的公钥（release.sh 传进来）；没有时编出来的版本不检查更新
#   LOCKCURTAIN_VERSION            测试包用：不改 VERSION 文件，换一个版本号（如 1.0.4-beta.1）。
#                                  带 beta 的版本读测试通道的 appcast-beta-windows.xml（release-beta.sh 发），
#                                  会自动更新到更新的测试版和正式版；不带 beta 的读正式的 appcast-windows.xml
#   LOCKCURTAIN_APPCAST_URL        测试用：换掉更新清单的地址（默认按上一条）
# 需要 .NET SDK 10（brew install dotnet，只用它的编译器，编出来的是 .NET Framework 4.8 程序）。第一次会从 NuGet 下载依赖，从 GitHub 下载 WinSparkle。
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${LOCKCURTAIN_VERSION:-$(tr -d '[:space:]' < ../VERSION)}"
# 正式版用 LockCurtain.csproj 里的默认地址（releases/latest 的 appcast-windows.xml）
case "$VERSION" in
  *beta*) APPCAST_URL="${LOCKCURTAIN_APPCAST_URL:-https://github.com/Snowyyyyyy1/LockCurtain/releases/download/beta-channel/appcast-beta-windows.xml}" ;;
  *)      APPCAST_URL="${LOCKCURTAIN_APPCAST_URL:-}" ;;
esac

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

OUT=dist/win
rm -rf "$OUT" dist/win-x64 dist/win-arm64 dist/ctl
echo "[win] publish $VERSION"
dotnet publish LockCurtain/LockCurtain.csproj -c Release -p:DebugType=none \
  -p:AllowedReferenceRelatedFileExtensions=none -p:GenerateDocumentationFile=false \
  -p:Version="$VERSION" -p:EdDSAPublicKey="${LOCKCURTAIN_EDDSA_PUBLIC_KEY:-}" \
  ${APPCAST_URL:+-p:AppcastUrl="$APPCAST_URL"} \
  -o "$OUT" | tail -1
# 不带 uiAccess 的入口启动器（AssemblyName=LockCurtain → LockCurtain.exe）：计划任务 ShellExecute 起主程序，也给 agent 发命令
dotnet publish LockCurtainCtl/LockCurtainCtl.csproj -c Release -p:DebugType=none -p:Version="$VERSION" \
  -o dist/ctl | tail -1
cp dist/ctl/LockCurtain.exe dist/ctl/LockCurtain.exe.config "$OUT/"
rm -rf dist/ctl
# WinSparkle.dll 放在子目录里按完整路径加载，不打进 exe：解压到普通权限能写的临时目录再以最高权限加载，就成了提权漏洞
for arch in x64 arm64; do
  case "$arch" in arm64) src=ARM64 ;; x64) src=x64 ;; esac
  mkdir -p "$OUT/$arch"
  unzip -p "$WINSPARKLE_ZIP" "WinSparkle-$WINSPARKLE/$src/Release/WinSparkle.dll" > "$OUT/$arch/WinSparkle.dll"
done
# 占位文件：1.0.0 起的更新器都要求包里有 WinSparkle.dll，1.0.2 起还要 LockCurtainCtl.exe。1.0.2 起只查名字在不在；
# 1.0.0/1.0.1 会把 WinSparkle.dll 就地换进安装目录，接着启动器发现没有 LockCurtainApp.exe，跑 install.ps1 自愈，
# 这期间没人加载它。install.ps1 不装这两个文件
for name in LockCurtainCtl.exe WinSparkle.dll; do
  printf '%s\n' "LockCurtain compat placeholder. Older updaters require a zip entry named $name (presence only); nothing uses it. See windows/build.sh." > "$OUT/$name"
done
cp install.ps1 "$OUT/"
for rid in win-x64 win-arm64; do
  zip="dist/LockCurtain-$VERSION-$rid.zip"
  rm -f "$zip"
  (cd "$OUT" && zip -qrX "../$(basename "$zip")" .)
done
ls -lh "$OUT/LockCurtainApp.exe" "$OUT/LockCurtain.exe" "dist/LockCurtain-$VERSION-win-x64.zip" | awk '{print "  " $5, $9}'

# 单文件安装器（NSIS）：解压 dist/win 到临时目录再跑 install.ps1
setup="dist/LockCurtain-$VERSION-setup.exe"
rm -f "$setup"
makensis -DVERSION="$VERSION" installer.nsi | tail -2
ls -lh "$setup" | awk '{print "  " $5, $9}'
