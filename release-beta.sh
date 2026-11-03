#!/bin/bash
# release-beta.sh —— 打测试版、签更新，发成 GitHub prerelease，并把测试通道的 appcast 换成这一版
#
#   LOCKCURTAIN_VERSION=1.0.4-beta.3 ./release-beta.sh windows|mac|both [--dry-run] [--dirty] [--notes-file <文件>]
#
#   windows|mac|both   发哪一边（both = 两边同一个版本号）
#   --dry-run          编译、签名、生成 appcast 都做，只是不上传（打印要跑的 gh 命令）
#   --dirty            工作区有没提交的改动也照样打包（只能和 --dry-run 一起用）
#   --notes-file       更新说明，格式同 release-notes/*.md；默认 release-notes/<版本>.md，没有就用
#                      release-notes/<正式版号>.md（比如 1.0.4-beta.3 用 1.0.4.md）
#
# 怎么运作：
#   版本号带 beta 的包（build.sh / windows/build.sh 按版本号决定）编译时写死读测试通道的 appcast：
#     https://github.com/Snowyyyyyy1/LockCurtain/releases/download/beta-channel/appcast-beta.xml          （Mac）
#     https://github.com/Snowyyyyyy1/LockCurtain/releases/download/beta-channel/appcast-beta-windows.xml  （Windows）
#   beta-channel 是一个固定的 prerelease（没有就建），只放这两份 appcast，每次用 --clobber 覆盖成最新那一版。
#   测试版本身发成 prerelease v<版本>（--latest=false），所以 releases/latest 永远是正式版，
#   正式版的 App 只读 releases/latest 的 appcast，永远看不到测试版。
#   release.sh 发正式版时也会把同一个条目覆盖到测试通道，装着测试版的人跟着升到正式版。
#
# 版本号顺序（两边的更新器都只在 appcast 里的版本比自己新时提示）：
#   1.0.3 < 1.0.4-beta.2 < 1.0.4-beta.3 < 1.0.4-beta.10 < 1.0.4
#   Windows（WinSparkle）直接比 1.0.4-beta.3；Mac 的 CFBundleVersion / sparkle:version 是去掉「-」的
#   1.0.4beta.3（Sparkle 2 遇到「-」就截断，见 release-common.sh）。版本号必须是 X.Y.Z-beta.N。
#
# 签名用和 release.sh 一样的 EdDSA 密钥（登录钥匙串 lockcurtain 账户，或 LOCKCURTAIN_ED_KEY_FILE），
# 公钥写进 App。产物在 dist/beta/。
set -euo pipefail
cd "$(dirname "$0")"
source ./release-common.sh

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; }
PLATFORM=""; DRY=0; DIRTY=0; NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    windows|mac|both) PLATFORM="$1" ;;
    --dry-run) DRY=1 ;;
    --dirty)   DIRTY=1 ;;
    --notes-file) NOTES="${2:?--notes-file 后面要跟文件}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数 $1"; usage; exit 2 ;;
  esac
  shift
done
[ -n "$PLATFORM" ] || { usage; exit 2; }
[ $DIRTY = 1 ] && [ $DRY = 0 ] && { echo "--dirty 只能和 --dry-run 一起用"; exit 2; }
DO_MAC=0; DO_WIN=0
case "$PLATFORM" in mac) DO_MAC=1 ;; windows) DO_WIN=1 ;; both) DO_MAC=1; DO_WIN=1 ;; esac

VERSION="${LOCKCURTAIN_VERSION:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$ ]] \
  || { echo "LOCKCURTAIN_VERSION 要是 X.Y.Z-beta.N（比如 1.0.4-beta.3），现在是「${VERSION}」"; exit 2; }
BASE="${VERSION%%-*}"
TAG="v$VERSION"
DL="https://github.com/$REPO/releases/download/$TAG"
OUT="dist/beta"
if [ -z "$NOTES" ]; then
  NOTES="release-notes/$VERSION.md"; [ -f "$NOTES" ] || NOTES="release-notes/$BASE.md"
fi
[ -f "$NOTES" ] || { echo "缺更新说明：release-notes/$VERSION.md 或 release-notes/$BASE.md（或用 --notes-file）"; exit 1; }

INPUTS=(Sources build.sh release-common.sh release-beta.sh Tools/make-icon.swift windows/LockCurtain windows/build.sh windows/install.ps1 windows/installer.nsi)
if [ $DIRTY = 0 ] && [ -n "$(git status --porcelain -- "${INPUTS[@]}")" ]; then
  echo "工作区有没提交的改动，测试包会和提交对不上："; git status --short -- "${INPUTS[@]}"; exit 1
fi

# 测试版必须比正式版和测试通道上现有的都新，否则装着的人收不到
check_order() {    # check_order <正式 appcast> <测试 appcast>
  local official beta
  official="$(feed_version "https://github.com/$REPO/releases/latest/download/$1")"
  beta="$(feed_version "$BETA_FEED/$2")"
  if [ -z "$official" ]; then echo "  读不到正式版的 $1（没网？），没核对版本顺序"
  elif [ "$(vercmp "$VERSION" "$official")" != 1 ]; then echo "$VERSION 不比正式版 $official 新"; exit 1
  fi
  if [ -n "$beta" ] && [ "$(vercmp "$VERSION" "$beta")" != 1 ]; then echo "$VERSION 不比测试通道上的 $beta 新"; exit 1; fi
  echo "  $2：正式版 ${official:-?}，测试通道 ${beta:-（空）} → $VERSION"
}
echo "== 版本顺序"
[ $DO_MAC = 1 ] && check_order appcast.xml appcast-beta.xml
[ $DO_WIN = 1 ] && check_order appcast-windows.xml appcast-beta-windows.xml

# 同一个版本号可以先发一边、再发另一边（同一个 prerelease 上补文件），但不能重发
EXISTING=""
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  [ "$(gh release view "$TAG" -R "$REPO" --json isPrerelease -q .isPrerelease)" = true ] || { echo "$TAG 是正式 Release，不能当测试版"; exit 1; }
  EXISTING="$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')"
fi

load_signing_key
unset LOCKCURTAIN_APPCAST_URL LOCKCURTAIN_RIDS    # 测试包只能指向测试通道，Windows 两个架构都要
export LOCKCURTAIN_VERSION="$VERSION"
rm -rf "$OUT" && mkdir -p "$OUT"
ASSETS=(); FEEDS=()

M="LockCurtain-$VERSION-mac.zip"
W64="LockCurtain-$VERSION-win-x64.zip"; WA="LockCurtain-$VERSION-win-arm64.zip"; SETUP="LockCurtain-$VERSION-setup.exe"
if [ $DO_MAC = 1 ]; then
  echo "== Mac $VERSION"
  ./build.sh | grep -E "^\[|signature|requirement"
  P=LockCurtain.app/Contents/Info.plist
  plist() { /usr/libexec/PlistBuddy -c "Print $1" "$P"; }
  [ "$(plist SUPublicEDKey)" = "$LOCKCURTAIN_EDDSA_PUBLIC_KEY" ]
  [ "$(plist SUFeedURL)" = "$BETA_FEED/appcast-beta.xml" ] || { echo "Info.plist 的 SUFeedURL 不是测试通道"; exit 1; }
  [ "$(plist CFBundleVersion)" = "$(mac_bundle_version "$VERSION")" ]
  [ "$(plist CFBundleShortVersionString)" = "$VERSION" ]
  ditto -c -k --keepParent LockCurtain.app "$OUT/$M"
  ASSETS+=("$OUT/$M"); FEEDS+=("$OUT/appcast-beta.xml")
fi

if [ $DO_WIN = 1 ]; then
  echo "== Windows $VERSION"
  rm -f windows/dist/LockCurtain-"$VERSION"-*
  windows/build.sh | grep -E "^\[|zip|setup"
  # 编进主程序的 appcast 地址和公钥（AssemblyMetadata，单文件 exe 里是压缩的，看 obj 里的 dll）
  TFM="$(sed -n 's:.*<TargetFramework>\(.*\)</TargetFramework>.*:\1:p' windows/LockCurtain/LockCurtain.csproj)"
  for rid in win-x64 win-arm64; do
    dll="windows/LockCurtain/obj/Release/$TFM/$rid/LockCurtainApp.dll"
    grep -aqF "$BETA_FEED/appcast-beta-windows.xml" "$dll" || { echo "$dll 里没有测试通道地址"; exit 1; }
    grep -aqF "$LOCKCURTAIN_EDDSA_PUBLIC_KEY" "$dll" || { echo "$dll 里没有公钥"; exit 1; }
  done
  cp "windows/dist/$W64" "windows/dist/$WA" "windows/dist/$SETUP" "$OUT/"
  ASSETS+=("$OUT/$SETUP" "$OUT/$W64" "$OUT/$WA"); FEEDS+=("$OUT/appcast-beta-windows.xml")
fi

for a in "${ASSETS[@]}"; do
  if grep -qxF "$(basename "$a")" <<<"$EXISTING"; then echo "$TAG 上已经有 $(basename "$a")，换个版本号"; exit 1; fi
done

echo "== 签名、appcast"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
[ $DO_MAC = 1 ] && mac_appcast "$DL" "$OUT/$M" > "$OUT/appcast-beta.xml"
[ $DO_WIN = 1 ] && win_appcast "$DL" "$OUT/$W64" "$OUT/$WA" > "$OUT/appcast-beta-windows.xml"
xmllint --noout "${FEEDS[@]}"
# 用公钥核一遍每个 enclosure 的签名
for f in "${FEEDS[@]}"; do
  sed -n 's:.*url="[^"]*/\([^"/]*\)" .*sparkle\:edSignature="\([^"]*\)".*:\1 \2:p' "$f" | while read -r file signature; do
    "$SPARKLE_BIN/sign_update" "${SIGN_ARGS[@]}" --verify "$OUT/$file" "$signature" >/dev/null \
      || { echo "$f 里 $file 的签名不对"; exit 1; }
    echo "  签名 OK  $file"
  done
done
notes_for all > "$OUT/release-notes.md"
ls -lh "$OUT" | awk 'NR > 1 {print "  " $5, $9}'

case "$PLATFORM" in mac) LABEL="Mac" ;; windows) LABEL="Windows" ;; both) LABEL="Mac + Windows" ;; esac
CMDS=()
gh release view "$BETA_TAG" -R "$REPO" >/dev/null 2>&1 \
  || CMDS+=("gh release create $BETA_TAG -R $REPO --prerelease --latest=false --title '$BETA_TITLE' --notes ''")
if [ -n "$EXISTING" ] || gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  CMDS+=("gh release upload $TAG -R $REPO ${ASSETS[*]}")
else
  CMDS+=("gh release create $TAG -R $REPO --prerelease --latest=false --target $(git rev-parse HEAD) --title 'LockCurtain ${VERSION}（$LABEL 测试版）' --notes-file $OUT/release-notes.md ${ASSETS[*]}")
fi
# 最后才换 appcast：它指向的文件已经传好了
CMDS+=("gh release upload $BETA_TAG -R $REPO --clobber ${FEEDS[*]}")

if [ $DRY = 1 ]; then
  echo; echo "--dry-run：没上传。正式发布时会跑："
  printf '  %s\n' "${CMDS[@]}"
  exit 0
fi
git fetch -q origin
[ -n "$(git branch -r --contains HEAD)" ] || { echo "HEAD 还没推送到 GitHub"; exit 1; }
for c in "${CMDS[@]}"; do echo "+ $c"; eval "$c"; done
echo "已发布 ${TAG}，测试通道已指向 $VERSION"
