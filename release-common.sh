# release-common.sh —— release.sh（正式版）和 release-beta.sh（测试版）共用的函数，source 进来用，不单独跑
#
# 用到调用方设的变量：REPO、SPARKLE_BIN、NOTES（说明文件）、DATE

REPO="Snowyyyyyy1/LockCurtain"
SPARKLE_BIN=".cache/Sparkle-2.10.1/bin"
# 测试通道：一个固定的 prerelease（tag beta-channel），只放两份 appcast，每次发测试版用 --clobber 覆盖。
# 测试版（版本号带 beta）编译时写死读这里（build.sh / windows/build.sh），正式版只读 releases/latest 的 appcast
BETA_TAG="beta-channel"
BETA_TITLE="测试通道（自动更新用，不要下载）"
BETA_FEED="https://github.com/$REPO/releases/download/$BETA_TAG"

# Mac 的 CFBundleVersion / sparkle:version：版本号去掉「-」。
# Sparkle 2 比较版本时遇到「-」就截断（1.0.4-beta.3 和 1.0.4 算一样），去掉后 1.0.4beta.3 按「1.0.4b3 < 1.0.4」的规则排：
#   1.0.3 < 1.0.4beta.2 < 1.0.4beta.3 < 1.0.4beta.10 < 1.0.4rc.1 < 1.0.4
# 正式版号里没有「-」，不受影响。Windows 的 WinSparkle 0.9.4 不截断，直接用带「-」的原样版本号。
# 显示用的版本（CFBundleShortVersionString / sparkle:shortVersionString）两边都是原样的 1.0.4-beta.3。
mac_bundle_version() { printf '%s' "${1//-/}"; }

# vercmp A B：打印 -1 / 0 / 1。和 WinSparkle 0.9.4 的 CompareVersions（移植自 Sparkle 1 的
# SUStandardVersionComparator）一样的规则，先去掉「-」，所以 Mac 的 sparkle:version 和 Windows 的版本号都能直接比
vercmp() {
  LC_ALL=C awk -v a="${1//-/}" -v b="${2//-/}" '
    function cls(c) { return c == "." ? "p" : (c ~ /^[0-9]$/ ? "n" : "s") }
    function parts(v, P,   n, i, c, s, t, pt) {
      n = 0; if (v == "") return 0
      s = substr(v, 1, 1); pt = cls(s)
      for (i = 2; i <= length(v); i++) {
        c = substr(v, i, 1); t = cls(c)
        if (t != pt || pt == "p") { P[++n] = s; s = c } else s = s c
        pt = t
      }
      P[++n] = s; return n
    }
    function out(r) { print r; exit }
    BEGIN {
      na = parts(a, A); nb = parts(b, B); n = na < nb ? na : nb
      for (i = 1; i <= n; i++) {
        ta = cls(substr(A[i], 1, 1)); tb = cls(substr(B[i], 1, 1))
        if (ta == tb) {
          if (ta == "s") { if (A[i] "" < B[i] "") out(-1); if (A[i] "" > B[i] "") out(1) }
          else if (ta == "n") { if (A[i] + 0 > B[i] + 0) out(1); if (A[i] + 0 < B[i] + 0) out(-1) }
        } else if (ta != "s" && tb == "s") out(1)
        else if (ta == "s" && tb != "s") out(-1)
        else out(ta == "n" ? 1 : -1)
      }
      if (na == nb) out(0)
      if (na > nb) out(cls(substr(A[n + 1], 1, 1)) == "s" ? -1 : 1)
      out(cls(substr(B[n + 1], 1, 1)) == "s" ? 1 : -1)
    }'
}

# appcast 里第一个 sparkle:version；拿不到（没网、还没有这个文件）打印空
feed_version() {
  curl -fsSL --max-time 20 "$1" 2>/dev/null | sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' | head -1 || true
}

# 平时用登录钥匙串（lockcurtain 账户）里的 EdDSA 私钥签；测试时可以用 LOCKCURTAIN_ED_KEY_FILE 换成私钥文件，
# 同时用 LOCKCURTAIN_EDDSA_PUBLIC_KEY 给公钥。私钥只交给 sign_update，不打印、不落盘。
# 设好 SIGN_ARGS，导出 LOCKCURTAIN_EDDSA_PUBLIC_KEY（build.sh 写进 App）
KEY_ACCOUNT="lockcurtain"
load_signing_key() {
  SIGN_ARGS=(--account "$KEY_ACCOUNT")
  if [ -n "${LOCKCURTAIN_ED_KEY_FILE:-}" ]; then SIGN_ARGS=(--ed-key-file "$LOCKCURTAIN_ED_KEY_FILE"); fi
  if [ -z "${LOCKCURTAIN_EDDSA_PUBLIC_KEY:-}" ]; then
    [ -x "$SPARKLE_BIN/generate_keys" ] || ./build.sh >/dev/null    # 只为下载 Sparkle 的工具
    LOCKCURTAIN_EDDSA_PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p)" \
      || { echo "钥匙串里没有 EdDSA 密钥，先跑 $SPARKLE_BIN/generate_keys --account $KEY_ACCOUNT"; exit 1; }
  fi
  export LOCKCURTAIN_EDDSA_PUBLIC_KEY
}

# sign_update 输出 sparkle:edSignature="…" length="…"，原样塞进 enclosure
sig() { "$SPARKLE_BIN/sign_update" "${SIGN_ARGS[@]}" "$1"; }

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
mac_html() { echo "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\"><style>body{font:13px -apple-system,sans-serif}ul{padding-left:20px}</style></head><body>$(notes_html mac)</body></html>"; }
win_html() { echo "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light\"><style>html{background:#fff;color:#1a1a1a;font:14px \"Segoe UI\",\"Microsoft YaHei UI\",sans-serif}body{margin:10px 12px}ul{padding-left:20px;margin:0}li{margin:4px 0}</style></head><body>$(notes_html win)</body></html>"; }

appcast() {    # appcast <sparkle:version> <显示版本> <描述 HTML> <enclosure 行…>
  local version="$1" short="$2" html="$3"; shift 3
  cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>LockCurtain</title>
    <item>
      <title>$short</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$short</sparkle:shortVersionString>
      <description><![CDATA[$html]]></description>
$(printf '      %s\n' "$@")
    </item>
  </channel>
</rss>
XML
}

# mac_appcast <下载地址前缀> <zip>：Mac 的 appcast（单个条目）
mac_appcast() {
  appcast "$(mac_bundle_version "$VERSION")" "$VERSION" "$(mac_html)" \
    "<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>" \
    "<enclosure url=\"$1/$(basename "$2")\" $(sig "$2") type=\"application/octet-stream\"/>"
}
# win_appcast <下载地址前缀> <x64 zip> <arm64 zip>
win_appcast() {
  appcast "$VERSION" "$VERSION" "$(win_html)" \
    "<enclosure url=\"$1/$(basename "$2")\" sparkle:os=\"windows-x64\" $(sig "$2") type=\"application/octet-stream\"/>" \
    "<enclosure url=\"$1/$(basename "$3")\" sparkle:os=\"windows-arm64\" $(sig "$3") type=\"application/octet-stream\"/>"
}
