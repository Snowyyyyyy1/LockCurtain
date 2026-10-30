; installer.nsi —— LockCurtain 单文件安装器（Mac 上用 makensis 编，见 build.sh）
; 双击即装：弹 UAC（管理员）→ 按 CPU 自动选 x64/ARM64 的那份 → 解压到临时目录 → 跑 install.ps1
;（install.ps1 负责拷进 Program Files、本机自签证书、注册登录时以最高权限运行的计划任务、启动）。
; 两种架构的产物都编进同一个 exe，运行时只解压匹配 CPU 的那一份。
; VERSION 由 build.sh 用 -DVERSION 传进来。
Unicode true
Name "LockCurtain"
OutFile "dist/LockCurtain-${VERSION}-setup.exe"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
ShowInstDetails show

!include "MUI2.nsh"
!include "x64.nsh"

!define MUI_ICON "LockCurtain/LockCurtain.ico"
!define MUI_FINISHPAGE_TITLE "LockCurtain 已安装"
!define MUI_FINISHPAGE_TEXT "已装到 C:\Program Files\LockCurtain，并在登录时以最高权限自动启动。"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "Install"
  SetOutPath "$TEMP\LockCurtainSetup"
  ${If} ${IsNativeARM64}
    DetailPrint "架构：ARM64"
    File "dist/win-arm64/LockCurtain.exe"
    File "dist/win-arm64/LockCurtainApp.exe"
    File "dist/win-arm64/LockCurtainCtl.exe"
    File "dist/win-arm64/WinSparkle.dll"
    File "dist/win-arm64/install.ps1"
  ${ElseIf} ${IsNativeAMD64}
    DetailPrint "架构：x64"
    File "dist/win-x64/LockCurtain.exe"
    File "dist/win-x64/LockCurtainApp.exe"
    File "dist/win-x64/LockCurtainCtl.exe"
    File "dist/win-x64/WinSparkle.dll"
    File "dist/win-x64/install.ps1"
  ${Else}
    MessageBox MB_ICONSTOP "LockCurtain 需要 64 位 Windows（x64 或 ARM64）。"
    Abort
  ${EndIf}

  DetailPrint "正在安装…"
  ; 安装器 stub 是 x86，在 64 位 Windows（x64/ARM64）上直接跑 powershell 会被 WOW64
  ; 重定向成 32 位，于是 install.ps1 里的 $env:ProgramFiles 变成「Program Files (x86)」、装错地方。
  ; 用 Sysnative（32 位进程访问原生 System32 的别名）显式调原生 64 位 PowerShell，确保装进 C:\Program Files。
  nsExec::ExecToLog '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$TEMP\LockCurtainSetup\install.ps1"'
  Pop $0
  SetOutPath "$TEMP"
  RMDir /r "$TEMP\LockCurtainSetup"
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "安装失败（PowerShell 退出码 $0）。请把安装窗口里的红色错误截图发来。"
    Abort
  ${EndIf}
SectionEnd
