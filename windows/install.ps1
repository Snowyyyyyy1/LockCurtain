# install.ps1 —— 把 LockCurtain 装成「登录时以最高权限运行」
#
# 为什么：普通权限的低级钩子看不到发给管理员窗口的按键（UIPI），管理员窗口在前台时，
# 真人的按键会直接打进那个窗口。LockCurtain 以管理员身份运行，钩子就能看到并吞掉。
#
# 做两件事：
#   1. 程序文件（exe、它们的 .config 和依赖的 dll、x64\ 和 arm64\ 里自动更新用的 WinSparkle.dll）复制到
#      C:\Program Files\LockCurtain。普通权限写不了这里，别的程序（包括 agent）没法替换它们、借下次登录拿到管理员权限
#   2. 注册计划任务 LockCurtain：当前用户登录时以最高权限启动，不弹 UAC。
#      「LockCurtain.exe away」在 App 没运行时也通过这个任务拉起它
#
# 要求当前账户是管理员。普通账户用不了这种方式，直接运行 LockCurtain.exe 即可。
#
#   install.ps1              安装或更新（用同目录下的全部程序文件）并立即启动
#   install.ps1 -Uninstall   删除计划任务和安装目录
param([switch]$Uninstall, [string]$ForUser)
$ErrorActionPreference = 'Stop'

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# 提权后的进程看不到映射盘（比如 Parallels 共享的 Y:，实测 2026-10-27），
# 所以先把脚本和 exe 复制到本机的临时目录，从那里提权运行，用完删掉
$stage = Join-Path $env:TEMP 'LockCurtainInstall'

# 要装的文件：脚本旁边的全部文件（含 x64\、arm64\ 子目录），除了脚本自己和根目录的两个占位文件
#（WinSparkle.dll、LockCurtainCtl.exe 只是给旧版更新器查名字的，见 build.sh）
function Get-Payload([string]$root) {
    Get-ChildItem $root -Recurse -File | Where-Object {
        $_.Name -ne 'install.ps1' -and -not ($_.DirectoryName -eq $root -and $_.Name -in 'WinSparkle.dll', 'LockCurtainCtl.exe')
    }
}
# 按相对路径复制，子目录跟着建
function Copy-Payload([string]$from, [string]$to) {
    foreach ($f in Get-Payload $from) {
        $target = Join-Path $to $f.FullName.Substring($from.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $f.FullName $target -Force
    }
}

if (-not $admin) {
    # 以管理员身份重新运行（弹 UAC），带上当前账户，提权后核对没换人
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item $PSCommandPath (Join-Path $stage 'install.ps1') -Force
    if (-not $Uninstall) { Copy-Payload $PSScriptRoot $stage }
    $a = "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$(Join-Path $stage 'install.ps1')`" -ForUser $($me.User.Value)"
    if ($Uninstall) { $a += ' -Uninstall' }
    Start-Process powershell -Verb RunAs -ArgumentList $a
    exit
}
if ($ForUser -and $ForUser -ne $me.User.Value) {
    throw '提权后换成了另一个账户：当前账户不是管理员，用不了以最高权限运行。直接运行 LockCurtain.exe 即可'
}

$task = 'LockCurtain'
$dir = Join-Path $env:ProgramFiles 'LockCurtain'
$exe = Join-Path $dir 'LockCurtainApp.exe'
# 本机自签代码签名证书的 subject：安装时建、卸载时删，两处必须一致才不会漏删
$subject = 'CN=LockCurtain Self-Signed Code Signing'

Get-Process LockCurtain, LockCurtainApp -ErrorAction SilentlyContinue | ForEach-Object { $_.Kill(); $_.WaitForExit(5000) | Out-Null }

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    # 安装时在本机生成的自签证书也一并删掉
    foreach ($store in 'Cert:\LocalMachine\My','Cert:\LocalMachine\Root','Cert:\LocalMachine\TrustedPublisher') {
        Get-ChildItem $store -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $subject } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if ($PSScriptRoot -eq $stage) { Remove-Item $stage -Recurse -Force }
    '已卸载'
    return
}

New-Item -ItemType Directory -Force $dir | Out-Null
# 先清掉上一版的全部程序文件：.NET 10 版的大 exe、根目录的 WinSparkle.dll、占位文件、
# 旧版就地换文件留下的 .old/.new、以后不再用的 dll。只留 updates：自动更新时本脚本就是从它里面跑的
Get-ChildItem $dir -Force | Where-Object { $_.Name -ne 'updates' } | Remove-Item -Recurse -Force
Copy-Payload $PSScriptRoot $dir
# 从网上下载、用资源管理器解压出来的文件带「来自网络」标记，复制时跟着过来，
# 以后在安装目录里双击 exe 会弹 SmartScreen。这里去掉
Get-ChildItem $dir -Recurse -File | Unblock-File
$ctl = Join-Path $dir 'LockCurtain.exe'
# uiAccess 要求 exe 被本机信任的证书签名。这里在本机生成一张自签代码签名证书（私钥只留本机、不可导出），
# 装进本机受信任根和受信任发布者，再签主程序。每台机器用自己的证书，不用买、不分发私钥。
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
        -CertStoreLocation Cert:\LocalMachine\My -KeyUsage DigitalSignature `
        -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(30)
}
$cer = Join-Path $env:TEMP 'lockcurtain-signing.cer'
Export-Certificate -Cert $cert -FilePath $cer -Force | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Remove-Item $cer -Force -ErrorAction SilentlyContinue
$sig = Set-AuthenticodeSignature -FilePath $exe -Certificate $cert
if ($sig.Status -ne 'Valid') { throw "给 $exe 签名失败：$($sig.Status) $($sig.StatusMessage)" }
# 设置里开过「登录时打开」的话删掉，不然登录时 Run 键和计划任务各起一个
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name LockCurtain -ErrorAction SilentlyContinue
if ($PSScriptRoot -eq $stage) { Remove-Item $stage -Recurse -Force }

# uiAccess 的 exe 不能被普通 CreateProcess 启动（0x800702E4），只能 ShellExecute：
# 任务跑不带 uiAccess 的启动器 LockCurtain.exe --launch，由它 ShellExecute 起主程序 LockCurtainApp.exe
$action = New-ScheduledTaskAction -Execute $ctl -Argument '--launch'
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me.Name
$principal = New-ScheduledTaskPrincipal -UserId $me.Name -LogonType Interactive -RunLevel Highest
# 计划任务默认 72 小时后结束、用电池时不启动、优先级低于正常（7），都改掉：
# 优先级低时钩子回调容易超时，被系统摘掉
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -Priority 4
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $task

"已安装到 $ctl；已设为登录时启动；现在正在运行。"
"给 agent 用的命令：& `"$ctl`" away"
