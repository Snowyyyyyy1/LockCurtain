#!/bin/bash
# release.sh —— 打发布包、签更新、生成 appcast，确认后发到 GitHub Release
#
#   ./release.sh              编译 Mac 和 Windows 版，产物放进 dist/，最后打印发布命令
#   ./release.sh --publish    同上，再用 gh 建 Release、上传
#   ./release.sh --dirty      工作区有没提交的改动也照样打包（只用来本地试，不能和 --publish 一起用）
#
# 发版前：改 VERSION；写 release-notes/<版本>.md（「- 」开头一行一条）；提交并推送到 GitHub。
# 只对一边成立的写成「- [mac] …」「- [win] …」：更新窗口里只给对应平台看，
# Release 正文里全列出来，后面注明「仅 Mac」「仅 Windows」。
#
# 更新签名用 Sparkle 的 EdDSA 密钥，存在登录钥匙串的 lockcurtain 账户下
# （.cache/Sparkle-*/bin/generate_keys --account lockcurtain 生成；和别的 Sparkle 项目分开），
# Mac 和 Windows 共用：Windows 的 WinSparkle 认 Sparkle sign_update 签出来的签名（虚拟机实测）。
# 测试时可以用 LOCKCURTAIN_ED_KEY_FILE 指定私钥文件，同时用 LOCKCURTAIN_EDDSA_PUBLIC_KEY 给公钥。
#
# 产物：
#   dist/LockCurtain-<版本>-mac.zip                Mac 版，手动下载和自动更新都用它
#   dist/LockCurtain-<版本>-win-x64.zip / -win-arm64.zip   Windows 版（windows/build.sh 打的包）
#   dist/appcast.xml / appcast-windows.xml       更新清单，只放这一个版本；
#                                                App 从 releases/latest/download/ 读，所以总是最新那个 Release 的
#   dist/appcast-beta.xml / appcast-beta-windows.xml  同样的条目，--publish 时覆盖到测试通道（tag beta-channel），
#                                                让装着测试版的人也升到这个正式版；测试通道不存在、
#                                                或上面已经是更新的测试版时跳过（见 release-beta.sh）
# 共用的签名、appcast 函数在 release-common.sh。
set -euo pipefail
cd "$(dirname "$0")"
source ./release-common.sh

PUBLISH=0; DIRTY=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --dirty)   DIRTY=1 ;;
    *) echo "未知参数 $a"; exit 2 ;;
  esac
done
[ $PUBLISH = 1 ] && [ $DIRTY = 1 ] && { echo "--dirty 不能和 --publish 一起用"; exit 2; }

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"
DL="https://github.com/$REPO/releases/download/$TAG"

[ -f "$NOTES" ] || { echo "缺 $NOTES"; exit 1; }
# 参与编译的文件（含未跟踪的）有改动就不发，否则发布包和提交对不上
INPUTS=(Sources build.sh release-common.sh VERSION Tools/make-icon.swift windows/LockCurtain windows/build.sh windows/install.ps1)
if [ $DIRTY = 0 ] && [ -n "$(git status --porcelain -- "${INPUTS[@]}")" ]; then
  echo "工作区有没提交的改动，发布包会和提交对不上："; git status --short -- "${INPUTS[@]}"; exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "$TAG 已经发过了，先改 VERSION"; exit 1
fi

# 发布包只能指向正式的 appcast、用 VERSION 文件的版本号，Windows 两个架构都要
unset LOCKCURTAIN_APPCAST_URL LOCKCURTAIN_RIDS LOCKCURTAIN_VERSION

echo "== Mac $VERSION"
load_signing_key
./build.sh | grep -E "^\[|signature|requirement"
[ "$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" LockCurtain.app/Contents/Info.plist)" = "$LOCKCURTAIN_EDDSA_PUBLIC_KEY" ]

rm -rf dist && mkdir dist
ditto -c -k --keepParent LockCurtain.app "dist/LockCurtain-$VERSION-mac.zip"

echo "== Windows $VERSION"
rm -f windows/dist/LockCurtain-*.zip
windows/build.sh | grep -E "^\[|zip"
cp "windows/dist/LockCurtain-$VERSION-win-x64.zip" "windows/dist/LockCurtain-$VERSION-win-arm64.zip" \
   "windows/dist/LockCurtain-$VERSION-setup.exe" dist/

echo "== 签名、appcast"
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
M="LockCurtain-$VERSION-mac.zip"
W64="LockCurtain-$VERSION-win-x64.zip"; WA="LockCurtain-$VERSION-win-arm64.zip"; SETUP="LockCurtain-$VERSION-setup.exe"
mac_appcast "$DL" "dist/$M" > dist/appcast.xml
win_appcast "$DL" "dist/$W64" "dist/$WA" > dist/appcast-windows.xml
# 测试通道用同一份：条目一样，只是文件名不同
cp dist/appcast.xml dist/appcast-beta.xml
cp dist/appcast-windows.xml dist/appcast-beta-windows.xml

notes_for all > dist/release-notes.md
xmllint --noout dist/appcast.xml dist/appcast-windows.xml dist/appcast-beta.xml dist/appcast-beta-windows.xml
ls -lh dist | awk 'NR > 1 {print "  " $5, $9}'

CMD=(gh release create "$TAG" -R "$REPO" --target "$(git rev-parse HEAD)" --title "LockCurtain $VERSION" --notes-file dist/release-notes.md
     "dist/$M" "dist/$W64" "dist/$WA" "dist/$SETUP" dist/appcast.xml dist/appcast-windows.xml)
if [ $PUBLISH = 1 ]; then
  git fetch -q origin
  git merge-base --is-ancestor HEAD origin/main || { echo "HEAD 还没推送到 origin/main"; exit 1; }
  "${CMD[@]}"
  # 测试通道：把装着测试版的人带到这个正式版。上面已经是更新的测试版（比如发 1.0.4 时已经在测 1.0.5-beta.1）就不动它
  if gh release view "$BETA_TAG" -R "$REPO" >/dev/null 2>&1; then
    BETA_UP=()
    for f in appcast-beta.xml appcast-beta-windows.xml; do
      cur="$(feed_version "$BETA_FEED/$f")"
      if [ -n "$cur" ] && [ "$(vercmp "$cur" "$VERSION")" = 1 ]; then
        echo "测试通道 $f 上是更新的 ${cur}，不覆盖"
      else
        BETA_UP+=("dist/$f")
      fi
    done
    [ ${#BETA_UP[@]} = 0 ] || gh release upload "$BETA_TAG" -R "$REPO" --clobber "${BETA_UP[@]}"
  else
    echo "没有测试通道（${BETA_TAG}），跳过"
  fi
else
  echo; echo "确认无误后发布：./release.sh --publish  （等于 ${CMD[*]}，"
  echo "  再把 dist/appcast-beta*.xml 覆盖到测试通道 ${BETA_TAG}：gh release upload $BETA_TAG -R $REPO --clobber dist/appcast-beta.xml dist/appcast-beta-windows.xml）"
fi
