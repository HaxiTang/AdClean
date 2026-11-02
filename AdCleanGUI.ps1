# ============================================================
#  AdClean GUI - 通用安卓去广告精简工具 (v1.0)
#  支持：小米/Redmi (MIUI/HyperOS) · OPPO/一加/Realme (ColorOS)
#  原理：ADB 用户级冻结 (pm disable-user) + 系统开关优化
#  特性：完全可还原 · 状态持久化 · 无需 Root/解锁 · 零依赖单文件
#  测试：powershell -File AdCleanGUI.ps1 -SelfTest
# ============================================================
param([switch]$SelfTest, [string]$Root)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }  # 进程内运行（无控制台）时会抛异常，忽略即可

$script:Dir = if ($Root) { $Root } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:StateDir  = Join-Path $script:Dir 'state'
$script:CustomCfg = Join-Path $script:Dir 'custom-list.json'
$script:BrandsCfg = Join-Path $script:Dir 'brands.json'
$script:Adb       = $null
$script:Serial    = $null
$script:Brand     = $null


# ============================================================
#  品牌与禁止清单配置：全部来自 brands.json（必须存在）
# ============================================================
function Import-BrandsConfig {
    if (-not (Test-Path $script:BrandsCfg)) { throw ('配置文件不存在：' + $script:BrandsCfg) }
    $cfg = Get-Content $script:BrandsCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    $lists = [ordered]@{}
    $meta  = [ordered]@{}
    $sets  = @{}
    foreach ($b in @($cfg.brands)) {
        if (-not $b.name) { continue }
        $items = @()
        foreach ($i in @($b.items)) {
            if (-not $i.pkg) { continue }
            $items += @{
                pkg  = [string]$i.pkg
                name = [string]$i.name
                risk = if ($i.risk) { [string]$i.risk } else { 'low' }
                desc = [string]$i.desc
            }
        }
        $lists[$b.name] = $items
        $meta[$b.name]  = @{ props = @($b.props); makers = @($b.manufacturers) }
        $sets[$b.name]  = @($b.settings)
    }
    if ($lists.Keys.Count -eq 0) { throw 'brands.json 中没有有效品牌' }
    $script:Lists = $lists
    $script:BrandMeta = $meta
    $script:SettingsByBrand = $sets
    $script:Forbidden = @($cfg.forbidden)
}
try {
    Import-BrandsConfig
} catch {
    $msg = 'AdClean 配置加载失败：' + $_.Exception.Message + "`r`n请确认程序目录下 brands.json 存在且内容合法。"
    if ($SelfTest) { Write-Output ('SELFTEST FAILED: ' + $msg); exit 1 }
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'AdClean', 'OK', 'Error')
    exit 1
}

# ============================================================
#  引擎层
# ============================================================
function Find-Adb {
    $local = Join-Path $script:Dir 'platform-tools\adb.exe'
    if (Test-Path $local) { return $local }
    # 兼容：脚本在项目根目录直接运行时，复用 dist 下已下载的 platform-tools，避免重复下载
    $dist = Join-Path $script:Dir 'dist\platform-tools\adb.exe'
    if (Test-Path $dist) { return $dist }
    $c = Get-Command adb -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Invoke-Adb {
    param([string[]]$AdbArgs)
    & $script:Adb -s $script:Serial @AdbArgs 2>$null
}

function Get-StateFile([string]$serial) {
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    Join-Path $script:StateDir (($serial -replace '[:.]', '_') + '.json')
}

function Save-State([string]$serial, $items) {
    @{ device = $serial; time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); items = @($items) } |
        ConvertTo-Json -Depth 4 | Set-Content -Path (Get-StateFile $serial) -Encoding UTF8
}

function Load-State([string]$serial) {
    $f = Get-StateFile $serial
    if (Test-Path $f) { Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
}

function Get-PkgState([string]$pkg) {
    $r = [string](Invoke-Adb 'shell' "pm list packages $pkg")
    if ($r -notmatch [regex]::Escape($pkg)) { return 'absent' }
    $d = [string](Invoke-Adb 'shell' "pm list packages -d $pkg")
    if ($d -match [regex]::Escape($pkg)) { return 'disabled' } else { return 'active' }
}

function Freeze-Pkg([string]$pkg) {
    if ($script:Forbidden -contains $pkg) { return 'forbidden' }
    if ((Get-PkgState $pkg) -ne 'active') { return 'skip' }
    [void](Invoke-Adb 'shell' "pm disable-user --user 0 $pkg")
    if ((Get-PkgState $pkg) -eq 'disabled') { return 'ok' } else { return 'fail' }
}

function Restore-Pkg([string]$pkg) {
    [void](Invoke-Adb 'shell' "pm enable $pkg")
    if ((Get-PkgState $pkg) -eq 'active') { return 'ok' } else { return 'fail' }
}

function Detect-Brand {
    # 先按清单顺序探测各品牌的 getprop 属性
    foreach ($name in $script:Lists.Keys) {
        foreach ($p in @($script:BrandMeta[$name].props)) {
            if ([string](Invoke-Adb 'shell' "getprop $p").Trim()) { return $name }
        }
    }
    # 探测不到再按厂商名关键字兜底
    $mk = [string](Invoke-Adb 'shell' 'getprop ro.product.manufacturer')
    foreach ($name in $script:Lists.Keys) {
        foreach ($m in @($script:BrandMeta[$name].makers)) {
            if ($mk -match ('(?i)' + [regex]::Escape($m))) { return $name }
        }
    }
    return 'Unknown'
}

function Get-DeviceConnected {
    if (-not $script:Adb) { return $null }
    $out = & $script:Adb devices 2>$null
    foreach ($line in $out) { if ($line -match '(\S+)\s+device\s*$') { return $Matches[1] } }
    return $null
}

function Get-CustomItems {
    if (-not (Test-Path $script:CustomCfg)) { return @() }
    try { return @(Get-Content $script:CustomCfg -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return @() }
}

function Get-MergedItems([string]$brand) {
    $base = @()
    if ($script:Lists.Contains($brand)) { $base = $script:Lists[$brand] }
    $custom = @(Get-CustomItems)
    $seen = @{}; $result = @()
    foreach ($i in @($base) + $custom) {
        if ($i.pkg -and -not $seen.ContainsKey($i.pkg)) { $seen[$i.pkg] = $true; $result += $i }
    }
    return $result
}

# 后台子进程下载官方 platform-tools（不阻塞 GUI）
function Start-AdbDownload {
    if (-not (Test-Path $script:StateDir)) { New-Item -ItemType Directory -Path $script:StateDir -Force | Out-Null }
    $flag = Join-Path $script:StateDir 'adb-setup.flag'
    Remove-Item $flag -Force -ErrorAction SilentlyContinue
    $worker = @'
$ErrorActionPreference = 'Stop'
$dir  = '__DIR__'
$flag = '__FLAG__'
try {
    $zip = Join-Path $env:TEMP 'platform-tools-latest-windows.zip'
    $urls = @(
        'https://mirrors.cloud.tencent.com/AndroidSDK/platform-tools-latest-windows.zip',
        'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    )
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $ok = $false
    foreach ($u in $urls) {
        if (Test-Path $curl) {
            & $curl -L -sS --max-time 300 --retry 2 -o $zip $u 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path $zip) -and (Get-Item $zip).Length -gt 1MB) { $ok = $true; break }
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'Mozilla/5.0')
            try { $wc.DownloadFile($u, $zip); $ok = $true; break } catch { }
        }
    }
    if (-not $ok) { throw '所有下载源均不可达' }
    $pt = Join-Path $dir 'platform-tools'
    if (Test-Path $pt) { Remove-Item $pt -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Set-Content -Path $flag -Value 'ok' -Encoding ASCII
} catch {
    Set-Content -Path $flag -Value ('fail: ' + $_.Exception.Message) -Encoding UTF8
}
'@
    $worker = $worker.Replace('__DIR__', $script:Dir).Replace('__FLAG__', $flag)
    $wf = Join-Path $script:StateDir 'adb-setup.ps1'
    [IO.File]::WriteAllText($wf, $worker, (New-Object Text.UTF8Encoding $true))
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File', $wf) -WindowStyle Hidden | Out-Null
}

# 无 adb 时：触发下载并轮询结果；返回 $true 表示 adb 已可用
function Update-AdbSetup {
    if ($script:Adb) { return $true }
    $flag = Join-Path $script:StateDir 'adb-setup.flag'
    if (-not $script:AdbDlStarted) {
        Start-AdbDownload
        $script:AdbDlStarted = $true
        Set-StatusPill '设备状态：未找到 adb，正在自动下载 platform-tools（约几十 MB，请耐心等待）…' $script:C.warn
        $lblBrand.Text = ''
        return $false
    }
    $script:Adb = Find-Adb
    if ($script:Adb) {
        Set-StatusPill '设备状态：adb 已就绪，正在检测手机连接…' $script:C.sub
        return $true
    }
    if (Test-Path $flag) {
        $r = ([string](Get-Content $flag -Raw -Encoding UTF8)).Trim()
        if ($r -eq 'ok') { return $false }  # 解压完成但路径未生效，下一轮 Find-Adb 会拿到
        Set-StatusPill '设备状态：adb 自动下载失败，请手动解压 platform-tools 到程序目录后点「刷新设备」' $script:C.bad
        $lblBrand.Text = '原因：' + $r
    }
    return $false
}

# ============================================================
#  自检模式（无 GUI，供自动化测试）
# ============================================================
if ($SelfTest) {
    $fail = @()
    foreach ($brand in $script:Lists.Keys) {
        $pkgs = @()
        foreach ($item in $script:Lists[$brand]) {
            if (-not $item.pkg -or -not $item.name) { $fail += "$brand 存在缺失字段的条目" }
            if (@('low','medium','high') -notcontains $item.risk) { $fail += "$brand/$($item.pkg) risk 非法" }
            if ($script:Forbidden -contains $item.pkg) { $fail += "$brand/$($item.pkg) 与禁止清单冲突" }
            $pkgs += $item.pkg
        }
        $dup = $pkgs | Group-Object | Where-Object Count -gt 1
        if ($dup) { $fail += "$brand 存在重复包名: $($dup.Name -join ',')" }
    }
    if ($script:Lists.Keys.Count -lt 2) { $fail += '品牌清单不足' }
    # 状态持久化往返测试
    $testSerial = 'TEST:123'
    Save-State $testSerial @(@{ pkg='a.b.c'; name='测试'; time='now' })
    $back = Load-State $testSerial
    if (-not $back -or $back.items[0].pkg -ne 'a.b.c') { $fail += '状态保存/读取失败' }
    Remove-Item (Get-StateFile $testSerial) -Force -ErrorAction SilentlyContinue
    # 自定义清单解析测试
    $tmp = Join-Path $env:TEMP "adclean_test_$PID.json"
    '[{"pkg":"x.y.z","name":"临时","risk":"low","desc":"d"}]' | Set-Content $tmp -Encoding UTF8
    $script:CustomCfg = $tmp
    $c = Get-CustomItems
    if ($c.Count -ne 1 -or $c[0].pkg -ne 'x.y.z') { $fail += '自定义清单解析失败' }
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    # brands.json 配置导入测试
    $tmpCfg = Join-Path $env:TEMP "adclean_brands_$PID.json"
    '{"brands":[{"name":"测试品牌","props":["ro.test.brand"],"manufacturers":["testco"],"settings":["settings put test 1"],"items":[{"pkg":"t.e.s.t","name":"测试项","risk":"low","desc":"d"}]}],"forbidden":["t.e.s.t"]}' |
        Set-Content $tmpCfg -Encoding UTF8
    $script:BrandsCfg = $tmpCfg
    Import-BrandsConfig
    if ($script:Lists.Keys -notcontains '测试品牌') { $fail += 'brands.json 品牌导入失败' }
    if ($script:Forbidden -notcontains 't.e.s.t') { $fail += 'brands.json 禁止清单导入失败' }
    Remove-Item $tmpCfg -Force -ErrorAction SilentlyContinue
    # 缺少 brands.json 时必须报错
    $script:BrandsCfg = Join-Path $env:TEMP "no_such_cfg_$PID.json"
    try { Import-BrandsConfig; $fail += '缺少配置文件时未报错' } catch { }
    if ($fail.Count -eq 0) { Write-Output 'SELFTEST OK'; exit 0 }
    else { Write-Output ("SELFTEST FAILED:`n" + ($fail -join "`n")); exit 1 }
}

# ============================================================
#  GUI
# ============================================================
$script:Adb = Find-Adb
$script:AdbDlStarted = $false

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$f = New-Object System.Windows.Forms.Form
$f.Text = 'AdClean · 安卓去广告精简工具'
$f.Size = New-Object System.Drawing.Size(880, 700)
$f.MinimumSize = New-Object System.Drawing.Size(760, 560)
$f.StartPosition = 'CenterScreen'
$f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)

# ============================================================
#  主题色板（浅色）
# ============================================================
$script:C = @{
    bg      = [System.Drawing.Color]::FromArgb(243, 245, 249)
    surface = [System.Drawing.Color]::FromArgb(255, 255, 255)
    line    = [System.Drawing.Color]::FromArgb(229, 232, 240)
    text    = [System.Drawing.Color]::FromArgb(31, 35, 41)
    sub     = [System.Drawing.Color]::FromArgb(107, 114, 128)
    faint   = [System.Drawing.Color]::FromArgb(156, 163, 175)
    accent  = [System.Drawing.Color]::FromArgb(47, 107, 255)
    accentH = [System.Drawing.Color]::FromArgb(84, 132, 255)
    ok      = [System.Drawing.Color]::FromArgb(22, 163, 74)
    warn    = [System.Drawing.Color]::FromArgb(217, 119, 6)
    bad     = [System.Drawing.Color]::FromArgb(220, 38, 38)
    dim     = [System.Drawing.Color]::FromArgb(100, 116, 139)
    ghost   = [System.Drawing.Color]::FromArgb(184, 191, 201)
    btn     = [System.Drawing.Color]::FromArgb(255, 255, 255)
    btnH    = [System.Drawing.Color]::FromArgb(240, 243, 250)
    input   = [System.Drawing.Color]::FromArgb(247, 248, 250)
}

# 圆角：用 GraphicsPath 裁剪控件区域（参考 WinForms Control.Region 标准做法）
function Set-Rounded($ctl, [int]$radius) {
    if ($ctl.Width -le 0 -or $ctl.Height -le 0) { return }
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Min($radius, [Math]::Min($ctl.Width, $ctl.Height) / 2)
    $p.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
    $p.AddArc($ctl.Width - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($ctl.Width - 2 * $r, $ctl.Height - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $p.AddArc(0, $ctl.Height - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure()
    $ctl.Region = New-Object System.Drawing.Region $p
    $p.Dispose()
}

# 颜色混合：前景色按比例混入背景色，用于芯片开关的选中底色
function Get-Blend($fg, $bg, [double]$f) {
    return [System.Drawing.Color]::FromArgb(
        [int]($bg.R * (1 - $f) + $fg.R * $f),
        [int]($bg.G * (1 - $f) + $fg.G * $f),
        [int]($bg.B * (1 - $f) + $fg.B * $f))
}

# 筛选芯片（药丸开关）：状态存 $script:ChipOn，样式统一由 Update-ChipStyle 管理
$script:ChipOn     = @{ low = $true; medium = $true; high = $false }
$script:ChipColors = @{ low = $script:C.ok; medium = $script:C.warn; high = $script:C.bad }
function Update-ChipStyle($b) {
    $on  = [bool]$script:ChipOn[$b.Name]
    $col = $script:ChipColors[$b.Name]
    if ($on) {
        $b.BackColor = Get-Blend $col ([System.Drawing.Color]::White) 0.12
        $b.ForeColor = $col
    } else {
        $b.BackColor = [System.Drawing.Color]::FromArgb(238, 241, 246)
        $b.ForeColor = $script:C.faint
    }
}

# 状态药丸：文字 + 底色随状态联动
function Set-StatusPill([string]$text, $color) {
    $lblDevice.Text = '  ●  ' + $text
    $lblDevice.ForeColor = $color
    $lblDevice.BackColor = Get-Blend $color $script:C.surface 0.14
}

# --- 顶部：Logo + 设备状态 ---
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'; $panelTop.Width = 844; $panelTop.Height = 104
$panelTop.BackColor = $script:C.surface
$panelTop.Padding = New-Object System.Windows.Forms.Padding(18, 12, 14, 10)
$lblLogo = New-Object System.Windows.Forms.Label
$lblLogo.Location = New-Object System.Drawing.Point(18, 10)
$lblLogo.Size = New-Object System.Drawing.Size(126, 34)
$lblLogo.Text = 'AdClean'
$lblLogo.ForeColor = $script:C.accent
$lblLogo.Font = New-Object System.Drawing.Font('Segoe UI', 15.5, [System.Drawing.FontStyle]::Bold)
$lblSubTitle = New-Object System.Windows.Forms.Label
$lblSubTitle.Location = New-Object System.Drawing.Point(136, 22)
$lblSubTitle.Size = New-Object System.Drawing.Size(300, 22)
$lblSubTitle.Text = '安卓去广告精简工具'
$lblSubTitle.ForeColor = $script:C.sub
# 状态药丸：圆角标签，随状态变色（文本留白保证药丸形状）
$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Location = New-Object System.Drawing.Point(18, 52)
$lblDevice.Size = New-Object System.Drawing.Size(560, 28)
$lblDevice.Text = '  ●  设备状态：正在检测 adb 与手机连接…'
$lblDevice.ForeColor = $script:C.sub
$lblDevice.BackColor = $script:C.btn
$lblBrand = New-Object System.Windows.Forms.Label
$lblBrand.Location = New-Object System.Drawing.Point(20, 84)
$lblBrand.Size = New-Object System.Drawing.Size(480, 18)
$lblBrand.Text = ''
$lblBrand.ForeColor = $script:C.ok
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新设备'
$btnRefresh.Location = New-Object System.Drawing.Point(744, 12)
$btnRefresh.Size = New-Object System.Drawing.Size(100, 34)
$panelTop.Controls.AddRange(@($lblLogo, $lblSubTitle, $lblDevice, $lblBrand, $btnRefresh))
$btnRefresh.Anchor = 'Top,Right'

# --- 筛选芯片行（药丸开关，替代复选框） ---
$chipLow  = New-Object System.Windows.Forms.Button
$chipLow.Name = 'low';  $chipLow.Text = '● 低风险';  $chipLow.Location = New-Object System.Drawing.Point(588, 66); $chipLow.Size = New-Object System.Drawing.Size(84, 28)
$chipMed  = New-Object System.Windows.Forms.Button
$chipMed.Name = 'medium'; $chipMed.Text = '● 中风险'; $chipMed.Location = New-Object System.Drawing.Point(676, 66); $chipMed.Size = New-Object System.Drawing.Size(84, 28)
$chipHigh = New-Object System.Windows.Forms.Button
$chipHigh.Name = 'high'; $chipHigh.Text = '● 高风险'; $chipHigh.Location = New-Object System.Drawing.Point(764, 66); $chipHigh.Size = New-Object System.Drawing.Size(84, 28)
foreach ($chip in @($chipLow, $chipMed, $chipHigh)) {
    $chip.FlatStyle = 'Flat'; $chip.Cursor = 'Hand'
    $chip.FlatAppearance.BorderSize = 0
    $chip.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
    $chip.Add_Click({
        $n = $this.Name
        $script:ChipOn[$n] = -not $script:ChipOn[$n]
        Update-ChipStyle $this
        Refresh-List
    })
    $panelTop.Controls.Add($chip)
}
$chipLow.Anchor = 'Top,Right'; $chipMed.Anchor = 'Top,Right'; $chipHigh.Anchor = 'Top,Right'
Update-ChipStyle $chipLow; Update-ChipStyle $chipMed; Update-ChipStyle $chipHigh
Set-Rounded $chipLow 14; Set-Rounded $chipMed 14; Set-Rounded $chipHigh 14
Set-Rounded $btnRefresh 8
$btnRefresh.FlatStyle = 'Flat'; $btnRefresh.Cursor = 'Hand'
$btnRefresh.BackColor = $script:C.btn; $btnRefresh.ForeColor = $script:C.text
$btnRefresh.FlatAppearance.BorderSize = 1
$btnRefresh.FlatAppearance.BorderColor = $script:C.line
$btnRefresh.FlatAppearance.MouseOverBackColor = $script:C.btnH
$sepTop = New-Object System.Windows.Forms.Panel
$sepTop.Dock = 'Bottom'; $sepTop.Height = 1; $sepTop.BackColor = $script:C.line
$panelTop.Controls.Add($sepTop)

# --- 中部：组件列表 ---
$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true
$lv.Dock = 'Fill'
$lv.BackColor = $script:C.surface
$lv.ForeColor = $script:C.text
$lv.BorderStyle = 'None'
$lv.OwnerDraw = $true
$lv.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
[void]$lv.Columns.Add('  组件', 140)
[void]$lv.Columns.Add('包名', 250)
[void]$lv.Columns.Add('风险', 60)
[void]$lv.Columns.Add('状态', 80)
[void]$lv.Columns.Add('说明', 300)
# 自绘深色表头
$lv.add_DrawColumnHeader({
    param($s, $e)
    $b = New-Object System.Drawing.SolidBrush $script:C.surface
    $s.Graphics.FillRectangle($b, $e.Bounds)
    $sf = New-Object System.Drawing.StringFormat
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $tl = $e.Bounds; $tl.Y += 2
    $tb = New-Object System.Drawing.SolidBrush $script:C.dim
    $s.Graphics.DrawString($e.Header.Text, $s.Font, $tb, $tl, $sf)
    $b.Dispose(); $tb.Dispose(); $sf.Dispose()
})
$lv.add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
$lv.add_SizeChanged({ param($s, $e) Set-Rounded $s 12 })

# --- 底部：按钮 + 日志 ---
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = 'Bottom'; $panelBottom.Height = 212
$panelBottom.BackColor = $script:C.bg
$panelBottom.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Top'; $flow.Height = 54
$flow.BackColor = $script:C.bg
$flow.Padding = New-Object System.Windows.Forms.Padding(4, 0, 0, 0)
function New-Btn([string]$text, [bool]$primary = $false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Size = New-Object System.Drawing.Size(136, 36)
    $b.Margin = New-Object System.Windows.Forms.Padding(6, 4, 6, 8)
    $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.25)
    $b.ForeColor = $script:C.text
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $script:C.line
    $b.FlatAppearance.MouseOverBackColor = $script:C.btnH
    $b.FlatAppearance.MouseDownBackColor = $script:C.accentH
    $b.BackColor = $script:C.btn
    $b.Add_SizeChanged({ param($s, $e) Set-Rounded $s 8 })
    if ($primary) {
        $b.BackColor = $script:C.accent
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $script:C.accentH
        $b.FlatAppearance.MouseDownBackColor = $script:C.accentH
    }
    return $b
}
$btnScan    = New-Btn '扫描组件状态'
$btnOneKey  = New-Btn '一键优化(推荐)' $true
$btnFreeze  = New-Btn '冻结选中项'
$btnRestore = New-Btn '还原选中项'
$btnRestoreAll = New-Btn '还原全部(按记录)'
$btnSettings   = New-Btn '应用系统优化'
$flow.Controls.AddRange(@($btnScan, $btnOneKey, $btnFreeze, $btnRestore, $btnRestoreAll, $btnSettings))
$log = New-Object System.Windows.Forms.RichTextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$log.Dock = 'Fill'
$log.BorderStyle = 'None'
$log.BackColor = $script:C.input
$log.ForeColor = $script:C.sub
$log.add_SizeChanged({ param($s, $e) Set-Rounded $s 10 })
$panelBottom.Controls.Add($log)
$panelBottom.Controls.Add($flow)

$f.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$f.BackColor = $script:C.bg
$f.Controls.Add($lv)
$f.Controls.Add($panelTop)
$f.Controls.Add($panelBottom)

function Add-Log([string]$msg) {
    $c = $script:C.text
    if ($msg -match '\[(冻结|还原)')      { $c = $script:C.ok }
    elseif ($msg -match '\[(失败|拒绝|X)\]') { $c = $script:C.bad }
    elseif ($msg -match '\[(跳过|设置)\]')  { $c = $script:C.warn }
    $log.SelectionStart = $log.TextLength; $log.SelectionLength = 0
    $log.SelectionColor = $script:C.faint
    $log.SelectedText = "[$(Get-Date -Format 'HH:mm:ss')] "
    $log.SelectionColor = $c
    $log.SelectedText = $msg + "`r`n"
    $log.ScrollToCaret()
}

function Get-CurrentItems {
    $risks = @()
    if ($script:ChipOn['low'])    { $risks += 'low' }
    if ($script:ChipOn['medium']) { $risks += 'medium' }
    if ($script:ChipOn['high'])   { $risks += 'high' }
    Get-MergedItems $script:Brand | Where-Object { $risks -contains $_.risk }
}

function Refresh-List {
    $lv.BeginUpdate(); $lv.Items.Clear()
    if (-not $script:Serial) { $lv.EndUpdate(); return }
    foreach ($i in (Get-CurrentItems)) {
        $state = Get-PkgState $i.pkg
        $row = New-Object System.Windows.Forms.ListViewItem($i.name)
        $row.UseItemStyleForSubItems = $false
        [void]$row.SubItems.Add($i.pkg)
        [void]$row.SubItems.Add($(switch ($i.risk) { 'low' {'低'} 'medium' {'中'} default {'高'} }))
        [void]$row.SubItems.Add($(switch ($state) { 'active' {'运行中'} 'disabled' {'已冻结'} default {'不存在'} }))
        [void]$row.SubItems.Add($i.desc)
        $row.SubItems[2].ForeColor = $(switch ($i.risk) {
            'low'    { $script:C.ok }
            'medium' { $script:C.warn }
            default  { $script:C.bad }
        })
        $row.SubItems[3].ForeColor = $(switch ($state) {
            'active'   { $script:C.ok }
            'disabled' { $script:C.dim }
            default    { $script:C.ghost }
        })
        if ($state -eq 'disabled') { $row.ForeColor = $script:C.dim }
        if ($state -eq 'absent')   { $row.ForeColor = $script:C.ghost }
        $row.Tag = @{ pkg = $i.pkg; risk = $i.risk }
        $row.Checked = ($i.risk -eq 'low')
        [void]$lv.Items.Add($row)
    }
    $lv.EndUpdate()
}

function Connect-Device {
    if (-not $script:Adb) {
        if (-not (Update-AdbSetup)) { $lv.Items.Clear(); return }
    }
    $serial = Get-DeviceConnected
    if ($serial -eq $script:Serial) { return }
    if (-not $serial) {
        $script:Serial = $null; $script:Brand = $null
        Set-StatusPill '设备状态：adb 已就绪，未检测到手机，请连接 USB 并允许调试' $script:C.bad
        $lblBrand.Text = ''
        $lv.Items.Clear(); return
    }
    $script:Serial = $serial
    $script:Brand  = Detect-Brand
    $model   = [string](Invoke-Adb 'shell' 'getprop ro.product.marketname')
    $device  = [string](Invoke-Adb 'shell' 'getprop ro.product.device')
    $android = [string](Invoke-Adb 'shell' 'getprop ro.build.version.release')
    $shown = if ($model.Trim()) { $model.Trim() } else { $device.Trim() }
    Set-StatusPill "设备状态：已连接 $shown (Android $android) 序列号 $serial" $script:C.ok
    $lblBrand.Text = "识别系统：$script:Brand" + $(if ($script:Brand -eq 'Unknown') { ' —— 未识别品牌，仅显示自定义清单' } else { '' })
    Add-Log "已连接设备：$shown ($serial)，系统识别为 $script:Brand"
    $st = Load-State $serial
    if ($st) { Add-Log "找到历史记录：$($st.time) 曾冻结 $($st.items.Count) 项" }
    Refresh-List
}

# ---------------- 按钮 ----------------
$btnRefresh.Add_Click({ Connect-Device })

$btnScan.Add_Click({
    if (-not $script:Serial) { Add-Log '[X] 未连接设备'; return }
    Add-Log '正在扫描组件状态…'
    $f.Cursor = 'WaitCursor'; Refresh-List; $f.Cursor = 'Default'
    Add-Log '扫描完成'
})

$btnOneKey.Add_Click({
    if (-not $script:Serial) { Add-Log '[X] 未连接设备'; return }
    $done = 0; $skip = 0; $recorded = @()
    $f.Cursor = 'WaitCursor'
    foreach ($row in $lv.Items) {
        $t = $row.Tag; $state = $row.SubItems[3].Text
        if ($t.risk -ne 'low' -or $state -ne '运行中') { continue }
        [System.Windows.Forms.Application]::DoEvents()
        $r = Freeze-Pkg $t.pkg
        if ($r -eq 'ok') { $done++; $recorded += @{ pkg = $t.pkg; name = $row.Text; time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }; Add-Log "  [冻结] $($row.Text) ($($t.pkg))" }
        else { $skip++; Add-Log "  [跳过] $($row.Text)" }
    }
    $f.Cursor = 'Default'
    if ($recorded.Count -gt 0) {
        $old = Load-State $script:Serial
        $merged = @(); if ($old) { $merged = @($old.items) }
        $have = @{}; foreach ($m in $merged) { $have[$m.pkg] = $true }
        foreach ($r in $recorded) { if (-not $have[$r.pkg]) { $merged += $r } }
        Save-State $script:Serial $merged
    }
    Add-Log "一键优化完成：冻结 $done 项，跳过 $skip 项（记录已保存，可随时还原）"
    Refresh-List
})

$btnFreeze.Add_Click({
    if (-not $script:Serial) { Add-Log '[X] 未连接设备'; return }
    $done = 0; $recorded = @(); $f.Cursor = 'WaitCursor'
    foreach ($row in $lv.Items) {
        if (-not $row.Checked) { continue }
        $t = $row.Tag
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:Forbidden -contains $t.pkg) { Add-Log "  [拒绝] $($t.pkg) 是核心组件，禁止操作"; continue }
        $r = Freeze-Pkg $t.pkg
        if ($r -eq 'ok') { $done++; $recorded += @{ pkg = $t.pkg; name = $row.Text; time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }; Add-Log "  [冻结] $($t.pkg)" }
        elseif ($r -eq 'skip') { Add-Log "  [跳过] $($t.pkg)（不在运行状态）" }
        else { Add-Log "  [失败] $($t.pkg)" }
    }
    $f.Cursor = 'Default'
    if ($recorded.Count -gt 0) {
        $old = Load-State $script:Serial
        $merged = @(); if ($old) { $merged = @($old.items) }
        $have = @{}; foreach ($m in $merged) { $have[$m.pkg] = $true }
        foreach ($r in $recorded) { if (-not $have[$r.pkg]) { $merged += $r } }
        Save-State $script:Serial $merged
    }
    Add-Log "冻结完成：$done 项，已写入还原记录"
    Refresh-List
})

$btnRestore.Add_Click({
    if (-not $script:Serial) { Add-Log '[X] 未连接设备'; return }
    $done = 0; $f.Cursor = 'WaitCursor'
    foreach ($row in $lv.Items) {
        if (-not $row.Checked) { continue }
        [System.Windows.Forms.Application]::DoEvents()
        $t = $row.Tag
        if ((Restore-Pkg $t.pkg) -eq 'ok') { $done++; Add-Log "  [还原] $($t.pkg)" } else { Add-Log "  [失败] $($t.pkg)" }
    }
    $f.Cursor = 'Default'
    Add-Log "还原完成：$done 项"
    Refresh-List
})

$btnRestoreAll.Add_Click({
    if (-not $script:Serial) { Add-Log '[X] 未连接设备'; return }
    $st = Load-State $script:Serial
    if (-not $st -or $st.items.Count -eq 0) { Add-Log '本设备没有历史冻结记录'; return }
    $done = 0; $f.Cursor = 'WaitCursor'
    foreach ($item in $st.items) {
        [System.Windows.Forms.Application]::DoEvents()
        if ((Restore-Pkg $item.pkg) -eq 'ok') { $done++; Add-Log "  [还原] $($item.pkg)" } else { Add-Log "  [失败/不存在] $($item.pkg)" }
    }
    $f.Cursor = 'Default'
    if ($done -eq $st.items.Count) { Remove-Item (Get-StateFile $script:Serial) -Force -ErrorAction SilentlyContinue }
    Add-Log "按记录还原完成：$done / $($st.items.Count) 项"
    Refresh-List
})

$btnSettings.Add_Click({
    if (-not $script:Serial) { Add-Log '[X] 未连接设备'; return }
    $cmds = $script:SettingsByBrand[$script:Brand]
    if (-not $cmds) { Add-Log '该品牌暂无系统开关优化项'; return }
    foreach ($c in $cmds) { [void](Invoke-Adb 'shell' $c); Add-Log "  [设置] $c" }
    Add-Log '系统开关优化完成'
})

$f.Add_Shown({ Add-Log 'AdClean 已启动。未检测到 adb 时会自动下载 platform-tools；连接手机后自动识别品牌。' })

# 设备轮询定时器
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Connect-Device })
$timer.Start()

[void]$f.ShowDialog()
$timer.Stop()