; installer.nsi —— LockCurtain 单文件安装器（Mac 上用 makensis 编，见 build.sh）
; 双击即装：弹 UAC（管理员）→ 解压 dist/win 到临时目录 → 跑 install.ps1
;（install.ps1 负责拷进 Program Files、本机自签证书、注册登录时以最高权限运行的计划任务、启动）。
; 程序是 .NET Framework 4.8 的 AnyCPU，x64 和 ARM64 用同一份文件（WinSparkle.dll 两种都带，程序按自己的架构挑）。
; VERSION 由 build.sh 用 -DVERSION 传进来。
Unicode true
Name "LockCurtain"
OutFile "dist/LockCurtain-${VERSION}-setup.exe"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
ShowInstDetails hide

!include "MUI2.nsh"
!include "x64.nsh"

!define MUI_ICON "LockCurtain/LockCurtain.ico"
!define MUI_FINISHPAGE_TITLE "LockCurtain 已安装"
!define MUI_FINISHPAGE_TEXT "已装到 C:\Program Files\LockCurtain。以后每次登录 Windows 都会自动启动。"
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "Install"
  ${IfNot} ${IsNativeARM64}
  ${AndIfNot} ${IsNativeAMD64}
    MessageBox MB_ICONSTOP "LockCurtain 需要 64 位 Windows（x64 或 ARM64）。"
    Abort
  ${EndIf}
  ; 上次没装完留下的文件先清掉，免得 install.ps1 把旧文件一起装进去
  RMDir /r "$TEMP\LockCurtainSetup"
  SetOutPath "$TEMP\LockCurtainSetup"
  File /r "dist/win/*"

  DetailPrint "正在安装…"
  ; 安装器 stub 是 x86，在 64 位 Windows（x64/ARM64）上直接跑 powershell 会被 WOW64
  ; 重定向成 32 位，于是 install.ps1 里的 $env:ProgramFiles 变成「Program Files (x86)」、装错地方。
  ; 用 Sysnative（32 位进程访问原生 System32 的别名）显式调原生 64 位 PowerShell，确保装进 C:\Program Files。
  nsExec::ExecToLog '"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$TEMP\LockCurtainSetup\install.ps1"'
  Pop $0
  SetOutPath "$TEMP"
  RMDir /r "$TEMP\LockCurtainSetup"
  ${If} $0 != 0
    ; 退出码只写进细节日志，不给人看；NSIS 的 MessageBox 不能改标题栏，直接调 MessageBoxW（0x10 = MB_ICONERROR）
    DetailPrint "install.ps1 退出码 $0"
    System::Call 'user32::MessageBoxW(p $HWNDPARENT, w "点「显示细节」，把里面红色的那几行截图，发到 GitHub 上的 Issues。", w "安装没成功", i 0x10) i'
    Abort
  ${EndIf}
SectionEnd
