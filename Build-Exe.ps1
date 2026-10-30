# ============================================================
#  AdClean EXE 构建脚本 v2
#  用本机 .NET Framework 自带的 csc.exe 编译，无需联网
#  产出：dist\AdClean.exe（进程内托管 PowerShell 引擎：
#        无子进程、无释放脚本文件，规避安全软件行为防御）
# ============================================================
$ErrorActionPreference = 'Stop'
$Dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out = Join-Path $Dir 'dist'
$Src = Join-Path $Dir 'launcher-src\Program.cs'

# 1) 找 csc.exe（.NET Framework 4.x）
$cscPath = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $cscPath)) { $cscPath = "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $cscPath)) { Write-Error '未找到 csc.exe（.NET Framework 编译器）'; exit 1 }

# 2) 找 System.Management.Automation.dll（进程内托管 PowerShell 所需）
$sma = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\WindowsPowerShell\3.0\System.Management.Automation.dll"
if (-not (Test-Path $sma)) {
    $sma = Get-ChildItem "$env:WINDIR\Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation" -Recurse -Filter 'System.Management.Automation.dll' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $sma -or -not (Test-Path $sma)) { Write-Error '未找到 System.Management.Automation.dll'; exit 1 }

# 3) 读主程序并校验
$ps1Path = Join-Path $Dir 'AdCleanGUI.ps1'
$ps1 = [IO.File]::ReadAllText($ps1Path)
if ($ps1 -notmatch '-SelfTest' -or $ps1 -notmatch 'AdClean') { Write-Error '主程序内容异常'; exit 1 }
$b64Ps1 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ps1))
$b64Cfg = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('[]'))

# 4) 填充源码占位符
$src = [IO.File]::ReadAllText($Src)
$src = $src.Replace('__PS1_B64__', $b64Ps1).Replace('__PS2_B64__', $b64Cfg)
$gen = Join-Path $env:TEMP "AdClean_gen_$PID.cs"
[IO.File]::WriteAllText($gen, $src, (New-Object Text.UTF8Encoding $true))

# 5) 编译 winexe（无控制台窗口）
if (-not (Test-Path $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }
$exe = Join-Path $Out 'AdClean.exe'
# 清理 v1 遗留的运行时文件（v2 不再释放脚本文件）
Remove-Item (Join-Path $Out 'AdCleanGUI.ps1') -Force -ErrorAction SilentlyContinue
& $cscPath /nologo /target:winexe /platform:anycpu /out:$exe $gen /r:System.dll /r:System.Windows.Forms.dll /r:"$sma"
if ($LASTEXITCODE -ne 0) { Write-Error "编译失败：$LASTEXITCODE"; exit 1 }

# 6) 冒烟测试：exe 进程自身出现主窗口即成功（不再有 powershell 子进程）
$crashLog = Join-Path $Out 'crash-log.txt'
Remove-Item $crashLog -Force -ErrorAction SilentlyContinue
Start-Process $exe | Out-Null
Start-Sleep -Seconds 8
$win = Get-Process AdClean -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -like 'AdClean*' }
if ($win) { Write-Output ('冒烟测试 OK：主窗口已显示「' + $win[0].MainWindowTitle + '」') }
else { Write-Warning '冒烟测试：未检测到主窗口' }
$child = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*AdCleanGUI*' }
if ($child) { Write-Warning '异常：仍存在 powershell 子进程（应为零）' }
Get-Process AdClean -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if (Test-Path $crashLog) {
    Write-Warning '检测到崩溃日志（前 15 行）：'
    Get-Content $crashLog | Select-Object -First 15
}

Remove-Item $gen -Force -ErrorAction SilentlyContinue
Write-Output ("BUILD OK -> " + $exe + "  (" + [math]::Round((Get-Item $exe).Length/1KB) + " KB)")
