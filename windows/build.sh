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

for rid in ${LOCKCURTAIN_RIDS:-win-arm64 win-x64}; do
  echo "[$rid] publish"
  dotnet publish LockCurtain/LockCurtain.csproj -c Release -r "$rid" --self-contained \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:EnableCompressionInSingleFile=true -p:DebugType=none \
    -o "dist/$rid" | tail -1
  cp install.ps1 "dist/$rid/"
  ls -lh "dist/$rid/LockCurtain.exe" | awk '{print "  " $5, $9}'
done
