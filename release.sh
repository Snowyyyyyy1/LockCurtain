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
set -euo pipefail
cd "$(dirname "$0")"

PUBLISH=0; DIRTY=0
for a in "$@"; do
  case "$a" in
    --publish) PUBLISH=1 ;;
    --dirty)   DIRTY=1 ;;
    *) echo "未知参数 $a"; exit 2 ;;
  esac
done
[ $PUBLISH = 1 ] && [ $DIRTY = 1 ] && { echo "--dirty 不能和 --publish 一起用"; exit 2; }

REPO="Snowyyyyyy1/LockCurtain"
VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
NOTES="release-notes/$VERSION.md"
SPARKLE_BIN=".cache/Sparkle-2.10.1/bin"
DL="https://github.com/$REPO/releases/download/$TAG"

[ -f "$NOTES" ] || { echo "缺 $NOTES"; exit 1; }
# 参与编译的文件（含未跟踪的）有改动就不发，否则发布包和提交对不上
INPUTS=(Sources build.sh VERSION Tools/make-icon.swift windows/LockCurtain windows/build.sh windows/install.ps1)
if [ $DIRTY = 0 ] && [ -n "$(git status --porcelain -- "${INPUTS[@]}")" ]; then
  echo "工作区有没提交的改动，发布包会和提交对不上："; git status --short -- "${INPUTS[@]}"; exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  echo "$TAG 已经发过了，先改 VERSION"; exit 1
fi

# 平时用登录钥匙串里的私钥签；测试时可以换成私钥文件
KEY_ACCOUNT="lockcurtain"
SIGN_ARGS=(--account "$KEY_ACCOUNT")
if [ -n "${LOCKCURTAIN_ED_KEY_FILE:-}" ]; then SIGN_ARGS=(--ed-key-file "$LOCKCURTAIN_ED_KEY_FILE"); fi

echo "== Mac $VERSION"
if [ -z "${LOCKCURTAIN_EDDSA_PUBLIC_KEY:-}" ]; then
  [ -x "$SPARKLE_BIN/generate_keys" ] || ./build.sh >/dev/null    # 只为下载 Sparkle 的工具
  LOCKCURTAIN_EDDSA_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p)" \
    || { echo "钥匙串里没有 EdDSA 密钥，先跑 $SPARKLE_BIN/generate_keys --account $KEY_ACCOUNT"; exit 1; }
fi
export LOCKCURTAIN_EDDSA_PUBLIC_KEY
unset LOCKCURTAIN_APPCAST_URL LOCKCURTAIN_RIDS    # 发布包只能指向正式的 appcast，Windows 两个架构都要
./build.sh | grep -E "^\[|signature|requirement"
[ "$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" LockCurtain.app/Contents/Info.plist)" = "$LOCKCURTAIN_EDDSA_PUBLIC_KEY" ]

rm -rf dist && mkdir dist
ditto -c -k --keepParent LockCurtain.app "dist/LockCurtain-$VERSION-mac.zip"

echo "== Windows $VERSION"
rm -f windows/dist/LockCurtain-*.zip
windows/build.sh | grep -E "^\[|zip"
cp "windows/dist/LockCurtain-$VERSION-win-x64.zip" "windows/dist/LockCurtain-$VERSION-win-arm64.zip" dist/

echo "== 签名、appcast"
# sign_update 输出 sparkle:edSignature="…" length="…"，原样塞进 enclosure
sig() { "$SPARKLE_BIN/sign_update" "${SIGN_ARGS[@]}" "$1"; }
DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# 按平台挑说明：notes_for mac|win 只留通用的和这一边的；notes_for all 全留，标上平台
notes_for() {
  awk -v p="$1" '
    /^- \[(mac|win)\] / {
      tag = substr($0, 4, 3); sub(/\[(mac|win)\] /, "")
      if (p == "all") $0 = $0 (tag == "mac" ? "（仅 Mac）" : "（仅 Windows）")
      else if (p != tag) next
    }
    { print }' "$NOTES"
}
# 「- 」开头的行变成列表项，其余非空行变成段落
notes_html() {
  notes_for "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' | awk '
    /^- / { if (!ul) { print "<ul>"; ul = 1 } sub(/^- /, ""); print "<li>" $0 "</li>"; next }
    { if (ul) { print "</ul>"; ul = 0 } }
    NF { print "<p>" $0 "</p>" }
    END { if (ul) print "</ul>" }'
}
# Mac：跟着系统深浅色走。Windows：WinSparkle 的窗口只有浅色，深色模式下不写死颜色会黑底黑字（Windows 会话实测）
MAC_HTML="<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><style>body{font:13px -apple-system,sans-serif}ul{padding-left:20px}</style></head><body>$(notes_html mac)</body></html>"
WIN_HTML="<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light\"><style>html{background:#fff;color:#1a1a1a;font:14px \"Segoe UI\",\"Microsoft YaHei UI\",sans-serif}body{margin:10px 12px}ul{padding-left:20px;margin:0}li{margin:4px 0}</style></head><body>$(notes_html win)</body></html>"

appcast() {    # appcast <描述 HTML> <enclosure 行…>
  local html="$1"; shift
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LockCurtain</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <description><![CDATA[$html]]></description>
$(printf '      %s\n' "$@")
    </item>
  </channel>
</rss>
XML
}

M="LockCurtain-$VERSION-mac.zip"
appcast "$MAC_HTML" \
  "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>" \
  "<enclosure url=\"$DL/$M\" $(sig "dist/$M") type=\"application/octet-stream\"/>" > dist/appcast.xml

W64="LockCurtain-$VERSION-win-x64.zip"; WA="LockCurtain-$VERSION-win-arm64.zip"
appcast "$WIN_HTML" \
  "<enclosure url=\"$DL/$W64\" sparkle:os=\"windows-x64\" $(sig "dist/$W64") type=\"application/octet-stream\"/>" \
  "<enclosure url=\"$DL/$WA\" sparkle:os=\"windows-arm64\" $(sig "dist/$WA") type=\"application/octet-stream\"/>" > dist/appcast-windows.xml

notes_for all > dist/release-notes.md
xmllint --noout dist/appcast.xml dist/appcast-windows.xml
ls -lh dist | awk 'NR > 1 {print "  " $5, $9}'

CMD=(gh release create "$TAG" -R "$REPO" --target "$(git rev-parse HEAD)" --title "LockCurtain $VERSION" --notes-file dist/release-notes.md
     "dist/$M" "dist/$W64" "dist/$WA" dist/appcast.xml dist/appcast-windows.xml)
if [ $PUBLISH = 1 ]; then
  git fetch -q origin
  git merge-base --is-ancestor HEAD origin/main || { echo "HEAD 还没推送到 origin/main"; exit 1; }
  "${CMD[@]}"
else
  echo; echo "确认无误后发布：./release.sh --publish  （等于 ${CMD[*]}）"
fi
