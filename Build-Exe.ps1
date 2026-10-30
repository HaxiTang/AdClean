# ============================================================
#  AdClean EXE 构建脚本
#  用本机 .NET Framework 自带的 csc.exe 编译，无需联网
#  产出：dist\AdClean.exe（内嵌主程序，无窗口）
# ============================================================
$ErrorActionPreference = 'Stop'
$Dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out  = Join-Path $Dir 'dist'
$Src  = Join-Path $Dir 'launcher-src\Program.cs'

# 1) 找 csc.exe（.NET Framework 4.x）
$cscPath = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $cscPath)) { $cscPath = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $cscPath)) { Write-Error '未找到 csc.exe（.NET Framework 编译器）'; exit 1 }

# 2) 读主程序并校验
$ps1Path = Join-Path $Dir 'AdCleanGUI.ps1'
$ps1 = [IO.File]::ReadAllText($ps1Path)
if ($ps1 -notmatch '-SelfTest' -or $ps1 -notmatch 'AdClean') { Write-Error '主程序内容异常'; exit 1 }
$b64Ps1 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ps1))
$b64Cfg = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('[]'))

# 3) 填充源码占位符
$src = [IO.File]::ReadAllText($Src)
$src = $src.Replace('__PS1_B64__', $b64Ps1).Replace('__PS2_B64__', $b64Cfg)
$gen = Join-Path $env:TEMP "AdClean_gen_$PID.cs"
[IO.File]::WriteAllText($gen, $src, (New-Object Text.UTF8Encoding $true))

# 4) 编译 winexe（无控制台窗口；MessageBox 需要 Forms 引用）
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }
$exe = Join-Path $Out 'AdClean.exe'
& $cscPath /nologo /target:winexe /platform:anycpu /out:$exe $gen /r:System.dll /r:System.Windows.Forms.dll
if ($LASTEXITCODE -ne 0) { Write-Error "编译失败：$LASTEXITCODE"; exit 1 }

# 5) 冒烟测试：启动 exe，验证 GUI 子进程被拉起、无崩溃日志
$crashLog = Join-Path $Out 'crash-log.txt'
Remove-Item $crashLog -Force -ErrorAction SilentlyContinue
Start-Process $exe | Out-Null
Start-Sleep -Seconds 6
$child = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*AdCleanGUI.ps1*" -Root*' }
if ($child) {
    Write-Output '冒烟测试 OK：GUI 子进程已被 exe 拉起'
    Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
} else {
    Write-Warning '冒烟测试：未检测到 GUI 子进程'
}
Get-Process AdClean -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if (Test-Path $crashLog) {
    Write-Warning '检测到崩溃日志（前 15 行）：'
    Get-Content $crashLog | Select-Object -First 15
}

Remove-Item $gen -Force -ErrorAction SilentlyContinue
Write-Output ("BUILD OK -> " + $exe + "  (" + [math]::Round((Get-Item $exe).Length/1KB) + " KB)")
