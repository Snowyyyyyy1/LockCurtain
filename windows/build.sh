#!/bin/bash
# build.sh —— 在 Mac 上交叉编译 Windows 版
#
# 输出两个自带 .NET 运行时的单文件 exe，目标机器不用装 .NET：
#   dist/win-arm64/LockCurtain.exe   ARM 版 Windows（Apple Silicon 上的虚拟机、Snapdragon 笔记本）
#   dist/win-x64/LockCurtain.exe     普通 x64 电脑
# 每个目录里再放一份 install.ps1（装成登录时以最高权限运行，见文件头）。
# 需要 .NET SDK 10（brew install dotnet）。第一次会从 NuGet 下载 Windows 的运行时包。
set -euo pipefail
cd "$(dirname "$0")"

# exe 图标和 Mac 版是同一张图：图标脚本改过或 ico 不存在时才重画（和上一级 build.sh 画 icns 一样）
ICO=LockCurtain/LockCurtain.ico
if [ ! -f "$ICO" ] || [ ../Tools/make-icon.swift -nt "$ICO" ]; then
  echo "[icon] $ICO"
  T="$(mktemp -d)"
  xcrun swiftc -o "$T/make-icon" ../Tools/make-icon.swift
  "$T/make-icon" --ico "$ICO" >/dev/null
  rm -rf "$T"
fi

for rid in ${LOCKCURTAIN_RIDS:-win-arm64 win-x64}; do
  echo "[$rid] publish"
  dotnet publish LockCurtain/LockCurtain.csproj -c Release -r "$rid" --self-contained \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=none \
    -o "dist/$rid" | tail -1
  cp install.ps1 "dist/$rid/"
  ls -lh "dist/$rid/LockCurtain.exe" | awk '{print "  " $5, $9}'
done
