#!/bin/bash
# build.sh —— 编译并签署 LockCurtain
#
# 为什么用固定证书签而不是 ad-hoc：
#   ad-hoc 签名的 designated requirement 就是 cdhash，
#   每次重新编译都会让系统权限授权失效（auth_value 变回 0）。
#   用固定证书签，requirement 变成 identifier + certificate leaf，
#   重编译 / 改代码 / 改 Info.plist 都不影响已授予的权限。
set -euo pipefail
cd "$(dirname "$0")"

CERT="${LOCKCURTAIN_CERT:--}"
BUNDLE_ID="dev.local.lockcurtain"
APP="LockCurtain.app"
BIN="$APP/Contents/MacOS/LockCurtain"
SRC="Sources"

echo "[1/5] 准备 bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>LockCurtain</string>
    <key>CFBundleDisplayName</key>        <string>LockCurtain</string>
    <key>CFBundleIdentifier</key>         <string>dev.local.lockcurtain</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleExecutable</key>         <string>LockCurtain</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>LockCurtain 需要屏幕录制权限来读取当前壁纸，用于绘制遮罩背景。</string>
</dict>
</plist>
PLIST

echo "[2/5] 图标"
# 图标脚本改过或 icns 不存在时才重画
ICNS="$APP/Contents/Resources/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ Tools/make-icon.swift -nt "$ICNS" ]; then
  T="$(mktemp -d)"
  xcrun swiftc -o "$T/make-icon" Tools/make-icon.swift
  "$T/make-icon" "$T/AppIcon.iconset" >/dev/null
  iconutil -c icns "$T/AppIcon.iconset" -o "$ICNS"
  rm -rf "$T"
fi

echo "[3/5] 编译"
xcrun swiftc -O -o "$BIN" "$SRC"/*.swift

echo "[4/5] 签署 ($CERT)"
codesign --force --deep --sign "$CERT" --identifier "$BUNDLE_ID" "$APP"

echo "[5/5] 验证"
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
USAGE
