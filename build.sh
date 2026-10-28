#!/bin/bash
# build.sh —— 编译并签署 LockCurtain
#
# 为什么用固定证书签而不是 ad-hoc：
#   ad-hoc 签名的 designated requirement 就是 cdhash，
#   每次重新编译都会让系统权限授权失效（auth_value 变回 0）。
#   用固定证书签，requirement 变成 identifier + certificate leaf，
#   重编译 / 改代码 / 改 Info.plist 都不影响已授予的权限。
#   证书名取环境变量 LOCKCURTAIN_CERT，没有就读 .signing-cert（一行证书名，不进 git），
#   都没有才退回 ad-hoc。自建证书：钥匙串访问 → 证书助理 → 创建证书，类型选「代码签名」。
#
# 自动更新（Sparkle）：环境变量 LOCKCURTAIN_EDDSA_PUBLIC_KEY 给了公钥才打开，release.sh 会传；
# 自己从源码编的版本没有公钥，不检查更新，也就不会被官方版本覆盖。
#
# ./build.sh --debug 编调试版 LockCurtain Debug.app：bundle ID 是 dev.local.lockcurtain.debug，
# 系统权限、设置、运行时目录（~/Library/Application Support/LockCurtain Debug）都和正式版分开，
# 可以和 /Applications 里的正式版同时开着测试；同一张证书签，永远不检查更新。
set -euo pipefail
cd "$(dirname "$0")"

CERT="${LOCKCURTAIN_CERT:-$(cat .signing-cert 2>/dev/null || true)}"
CERT="${CERT:--}"
if [ "${1:-}" = "--debug" ]; then
  NAME="LockCurtain Debug"
  BUNDLE_ID="dev.local.lockcurtain.debug"
  LOCKCURTAIN_EDDSA_PUBLIC_KEY=""
else
  NAME="LockCurtain"
  BUNDLE_ID="dev.local.lockcurtain"
fi
VERSION="$(cat VERSION)"
APP="$NAME.app"
BIN="$APP/Contents/MacOS/LockCurtain"
SRC="Sources"
# LOCKCURTAIN_APPCAST_URL 只给测试用（换成本机 http 地址），release.sh 会清掉
FEED="${LOCKCURTAIN_APPCAST_URL:-https://github.com/Snowyyyyyy1/LockCurtain/releases/latest/download/appcast.xml}"

# Sparkle 固定版本，下载后核对 sha256，缓存在 .cache（不进 git）
SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE=".cache/Sparkle-$SPARKLE_VERSION"

echo "[1/6] Sparkle $SPARKLE_VERSION"
if [ ! -d "$SPARKLE/Sparkle.framework" ]; then
  T="$(mktemp -d)"
  curl -fsSL -o "$T/s.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $T/s.tar.xz" | shasum -a 256 -c - >/dev/null
  mkdir -p "$SPARKLE" && tar -xf "$T/s.tar.xz" -C "$SPARKLE"
  rm -rf "$T"
fi

echo "[2/6] 准备 bundle ($VERSION)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
# XPC 服务只有沙盒 App 才用得到，删掉少签两个包
rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

if [ -n "${LOCKCURTAIN_EDDSA_PUBLIC_KEY:-}" ]; then
  UPDATE_KEYS="<key>SUPublicEDKey</key>              <string>$LOCKCURTAIN_EDDSA_PUBLIC_KEY</string>"
else
  UPDATE_KEYS=""
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>$NAME</string>
    <key>CFBundleDisplayName</key>        <string>$NAME</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleExecutable</key>         <string>LockCurtain</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <!-- 界面只有中文：声明成只有 zh_CN，Sparkle 的更新窗口和系统标准菜单才会跟着用中文 -->
    <key>CFBundleDevelopmentRegion</key>  <string>zh_CN</string>
    <key>CFBundleLocalizations</key>      <array><string>zh_CN</string></array>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>LockCurtain 需要屏幕录制权限来读取当前壁纸，用于绘制遮罩背景。</string>
    <key>SUFeedURL</key>                  <string>$FEED</string>
    <key>SUEnableAutomaticChecks</key>    <true/>
    <key>SUAllowsAutomaticUpdates</key>   <false/>
    $UPDATE_KEYS
</dict>
</plist>
PLIST

echo "[3/6] 图标"
# 图标脚本改过或 icns 不存在时才重画
ICNS="$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ Tools/make-icon.swift -nt "$ICNS" ]; then
  T="$(mktemp -d)"
  xcrun swiftc -o "$T/make-icon" Tools/make-icon.swift
  "$T/make-icon" "$T/AppIcon.iconset" >/dev/null
  iconutil -c icns "$T/AppIcon.iconset" -o "$ICNS"
  rm -rf "$T"
fi

echo "[4/6] 编译"
xcrun swiftc -O -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  -o "$BIN" "$SRC"/*.swift

echo "[5/6] 签署 ($CERT)"
if [ "$CERT" = "-" ]; then echo "  没有证书，用 ad-hoc 签：每次重新编译都要重新授予系统权限（见文件头）"; fi
# 由里到外签。不能对整个 App 用 --deep：--identifier 会被套到 Sparkle 的每个部件上
F="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$CERT" "$F/Versions/B/Autoupdate"
codesign --force --sign "$CERT" "$F/Versions/B/Updater.app"
codesign --force --sign "$CERT" "$F"
codesign --force --sign "$CERT" --identifier "$BUNDLE_ID" "$APP"

echo "[6/6] 验证"
codesign --verify --deep --strict "$APP" && echo "  signature OK"
echo -n "  requirement: "
codesign -d -r- "$APP" 2>&1 | tail -1

echo
echo "系统权限:"
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, auth_value from access where client='$BUNDLE_ID'" 2>/dev/null \
  | awk -F'|' '{printf "  %-28s %s\n", $1, ($2==2?"allowed":($2==0?"denied":"?"))}'

cat <<'USAGE'

用法:
  open LockCurtain.app                       # 运行；已在运行时再打开一次会弹出设置窗口
  open -n LockCurtain.app --args --status    # 查看系统权限（一次性进程）
  open -n LockCurtain.app --args --capture   # 抓取壁纸（一次性进程）
  LockCurtain.app/Contents/MacOS/LockCurtain --send away|hide|status|settings
  调试版（./build.sh --debug）把上面的 LockCurtain.app 换成 "LockCurtain Debug.app"
USAGE
