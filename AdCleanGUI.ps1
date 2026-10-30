# ============================================================
#  AdClean GUI - 通用安卓去广告精简工具 (v1.0)
#  支持：小米/Redmi (MIUI/HyperOS) · OPPO/一加/Realme (ColorOS)
#  原理：ADB 用户级冻结 (pm disable-user) + 系统开关优化
#  特性：完全可还原 · 状态持久化 · 无需 Root/解锁 · 零依赖单文件
#  测试：powershell -File AdCleanGUI.ps1 -SelfTest
# ============================================================
param([switch]$SelfTest, [string]$Root)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$script:Dir = if ($Root) { $Root } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:StateDir  = Join-Path $script:Dir 'state'
$script:CustomCfg = Join-Path $script:Dir 'custom-list.json'
$script:Adb       = $null
$script:Serial    = $null
$script:Brand     = $null

# ============================================================
#  组件清单  risk: low=放心禁 medium=按需 high=有副作用需了解
# ============================================================
$script:Lists = [ordered]@{
    '小米/红米 (MIUI/HyperOS)' = @(
        @{ pkg='com.miui.systemAdSolution';       name='系统广告组件';   risk='low';    desc='国内版广告核心，禁用后大部分系统广告消失' }
        @{ pkg='com.miui.analytics';              name='分析埋点上报';   risk='low';    desc='用户行为数据上报' }
        @{ pkg='com.miui.msa.global';             name='海外广告组件';   risk='low';    desc='国际版广告SDK，国行机通常不存在' }
        @{ pkg='com.miui.hybrid';                 name='快应用服务';     risk='low';    desc='信息流广告与秒开弹窗源头' }
        @{ pkg='com.miui.hybrid.accessory';       name='快应用组件';     risk='low';    desc='快应用辅助进程' }
        @{ pkg='com.miui.phrase';                 name='小米画报';       risk='low';    desc='锁屏壁纸信息流' }
        @{ pkg='com.xiaomi.joyose';               name='云控策略';       risk='low';    desc='广告下发通道' }
        @{ pkg='com.miui.cleanmaster';            name='清理推广';       risk='low';    desc='垃圾清理推广组件' }
        @{ pkg='com.miui.yellowpage';             name='黄页';           risk='low';    desc='生活黄页广告' }
        @{ pkg='com.xiaomi.gamecenter';           name='游戏中心';       risk='low';    desc='游戏推广与通知' }
        @{ pkg='com.xiaomi.gamecenter.sdk.service'; name='游戏SDK服务';  risk='low';    desc='游戏推广组件' }
        @{ pkg='com.micredit.in';                 name='小米信贷';       risk='low';    desc='贷款推广' }
        @{ pkg='com.miui.bugreport';              name='用户反馈';       risk='low';    desc='反馈通道' }
        @{ pkg='com.xiaomi.shop';                 name='小米商城';       risk='medium'; desc='商城推广通知' }
        @{ pkg='com.miui.player';                 name='小米音乐';       risk='medium'; desc='含推广，不用可禁' }
        @{ pkg='com.miui.videoplayer';            name='小米视频';       risk='medium'; desc='含信息流' }
        @{ pkg='com.miui.gamebooster';            name='游戏加速';       risk='medium'; desc='含推广' }
        @{ pkg='com.miui.contentextension';       name='传送门';         risk='medium'; desc='长按取词推送，禁后取词失效' }
        @{ pkg='com.miui.personalassistant';      name='负一屏';         risk='medium'; desc='信息流广告，禁后负一屏消失' }
        @{ pkg='com.xiaomi.midrop';               name='小米分享';       risk='medium'; desc='文件互传，不用可禁' }
        @{ pkg='com.miui.guardprovider';          name='应用扫描';       risk='high';   desc='AVG扫描引擎，禁后装应用不再安全扫描' }
        @{ pkg='com.android.thememanager';        name='主题壁纸';       risk='high';   desc='禁后无法更换主题' }
        @{ pkg='com.miui.weather2';               name='天气';           risk='high';   desc='禁后系统天气不可用' }
        @{ pkg='com.xiaomi.mipicks';              name='应用商店';       risk='high';   desc='禁后无法安装/更新应用' }
    )
    'OPPO/一加/Realme (ColorOS)' = @(
        @{ pkg='com.oplus.motor';                 name='付费主题推广';   risk='low';    desc='主题字体付费推广组件' }
        @{ pkg='com.oplus.wifibackup';            name='WiFi备份';       risk='low';    desc='云端备份推广' }
        @{ pkg='info.mnotify';                    name='营销通知';       risk='low';    desc='OPPO营销推送' }
        @{ pkg='com.nearme.statistics.rom';       name='统计上报';       risk='low';    desc='用户数据上报' }
        @{ pkg='com.ted.number';                  name='号码助手';       risk='low';    desc='黄页识别类' }
        @{ pkg='com.oplus.crashbox';              name='崩溃收集';       risk='low';    desc='崩溃上报，禁后反馈失效' }
        @{ pkg='com.oplus.postmanservice';        name='推送服务';       risk='low';    desc='系统级推送（含营销）' }
        @{ pkg='com.coloros.phrase';              name='画报资讯';       risk='low';    desc='锁屏画报信息流' }
        @{ pkg='com.oplus.pay';                   name='OPPO钱包';       risk='medium'; desc='NFC支付，不用可禁' }
        @{ pkg='com.oplus.ovoicemanager';         name='语音助手管理';   risk='medium'; desc='小布助手相关' }
        @{ pkg='com.oplus.logkit';                name='日志工具';       risk='medium'; desc='日志采集' }
        @{ pkg='com.oplus.battery';               name='电池实验室';     risk='medium'; desc='实验性电池功能' }
        @{ pkg='com.heytap.themestore';           name='主题商店';       risk='medium'; desc='付费主题推广' }
        @{ pkg='com.heytap.browser';              name='OPPO浏览器';     risk='medium'; desc='含资讯流' }
        @{ pkg='com.heytap.openmarket';           name='开放市场';       risk='medium'; desc='预装推广' }
        @{ pkg='com.oplus.games';                 name='游戏中心';       risk='medium'; desc='游戏推广' }
        @{ pkg='com.heytap.market';               name='软件商店';       risk='high';   desc='禁后无法安装/更新应用' }
        @{ pkg='com.coloros.weather.service';     name='天气服务';       risk='high';   desc='禁后天气不可用' }
    )
}

# 各品牌的系统开关优化（可逆）
$script:SettingsByBrand = @{
    '小米/红米 (MIUI/HyperOS)'   = @('settings put secure ads_enabled 0', 'settings put global ad_enabled 0', 'settings put secure personalad_engine_status 0')
    'OPPO/一加/Realme (ColorOS)' = @('settings put secure oplus_plPAY_recommand_close 1', 'settings put secure oppo_market_referrer 0')
}

# 绝对禁止操作的核心包
$script:Forbidden = @('com.android.launcher','com.miui.home','com.oppo.launcher','com.android.systemui',
    'com.android.settings','com.miui.securitycenter','com.coloros.safecenter','com.oplus.securitycenter',
    'com.xiaomi.xmsf','com.xiaomi.finddevice','com.miui.cloudservice','com.miui.powerkeeper',
    'com.android.updater','com.miui.securitycore','com.oplus.ocpa','com.android.providers.telephony')

# ============================================================
#  引擎层
# ============================================================
function Find-Adb {
    $local = Join-Path $script:Dir 'platform-tools\adb.exe'
    if (Test-Path $local) { return $local }
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
    $mi  = [string](Invoke-Adb 'shell' 'getprop ro.mi.os.version.name')
    $opl = [string](Invoke-Adb 'shell' 'getprop ro.build.version.oplusROM')
    if ($mi.Trim())  { return '小米/红米 (MIUI/HyperOS)' }
    if ($opl.Trim()) { return 'OPPO/一加/Realme (ColorOS)' }
    $b = [string](Invoke-Adb 'shell' 'getprop ro.product.manufacturer')
    if ($b -match '(?i)xiaomi|redmi')    { return '小米/红米 (MIUI/HyperOS)' }
    if ($b -match '(?i)oppo|oneplus|realme') { return 'OPPO/一加/Realme (ColorOS)' }
    return 'Unknown'
}

function Get-DeviceConnected {
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
    if ($fail.Count -eq 0) { Write-Output 'SELFTEST OK'; exit 0 }
    else { Write-Output ("SELFTEST FAILED:`n" + ($fail -join "`n")); exit 1 }
}

# ============================================================
#  GUI
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$f = New-Object System.Windows.Forms.Form
$f.Text = 'AdClean · 安卓去广告精简工具'
$f.Size = New-Object System.Drawing.Size(880, 700)
$f.MinimumSize = New-Object System.Drawing.Size(760, 560)
$f.StartPosition = 'CenterScreen'
$f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# --- 顶部：设备信息 ---
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'; $panelTop.Height = 64
$lblDevice = New-Object System.Windows.Forms.Label
$lblDevice.Location = New-Object System.Drawing.Point(12, 8)
$lblDevice.Size = New-Object System.Drawing.Size(640, 22)
$lblDevice.Text = '设备状态：正在检测 adb 与手机连接…'
$lblDevice.ForeColor = 'DimGray'
$lblBrand = New-Object System.Windows.Forms.Label
$lblBrand.Location = New-Object System.Drawing.Point(12, 36)
$lblBrand.Size = New-Object System.Drawing.Size(640, 20)
$lblBrand.Text = ''
$lblBrand.ForeColor = 'DarkGreen'
$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = '刷新设备'
$btnRefresh.Location = New-Object System.Drawing.Point(750, 8)
$btnRefresh.Size = New-Object System.Drawing.Size(96, 28)
$panelTop.Controls.AddRange(@($lblDevice, $lblBrand, $btnRefresh))

# --- 过滤行 ---
$chkLow = New-Object System.Windows.Forms.CheckBox
$chkLow.Text = '低风险'; $chkLow.Checked = $true;  $chkLow.Location = New-Object System.Drawing.Point(740, 40); $chkLow.Size = New-Object System.Drawing.Size(70, 20)
$chkMed = New-Object System.Windows.Forms.CheckBox
$chkMed.Text = '中风险'; $chkMed.Checked = $true;  $chkMed.Location = New-Object System.Drawing.Point(806, 40); $chkMed.Size = New-Object System.Drawing.Size(70, 20)
$chkHigh = New-Object System.Windows.Forms.CheckBox
$chkHigh.Text = '高风险'; $chkHigh.Checked = $false; $chkHigh.Location = New-Object System.Drawing.Point(740, 60); $chkHigh.Size = New-Object System.Drawing.Size(70, 20)
$panelTop.Controls.AddRange(@($chkLow, $chkMed, $chkHigh))

# --- 中部：组件列表 ---
$lv = New-Object System.Windows.Forms.ListView
$lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
$lv.Dock = 'Fill'
[void]$lv.Columns.Add('组件', 130)
[void]$lv.Columns.Add('包名', 240)
[void]$lv.Columns.Add('风险', 50)
[void]$lv.Columns.Add('状态', 70)
[void]$lv.Columns.Add('说明', 300)

# --- 底部：按钮 + 日志 ---
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock = 'Bottom'; $panelBottom.Height = 205
$flow = New-Object System.Windows.Forms.FlowLayoutPanel
$flow.Dock = 'Top'; $flow.Height = 40
function New-Btn([string]$text) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Size = New-Object System.Drawing.Size(128, 30)
    $b.Margin = New-Object System.Windows.Forms.Padding(4)
    return $b
}
$btnScan    = New-Btn '扫描组件状态'
$btnOneKey  = New-Btn '一键优化(推荐)'
$btnFreeze  = New-Btn '冻结选中项'
$btnRestore = New-Btn '还原选中项'
$btnRestoreAll = New-Btn '还原全部(按记录)'
$btnSettings   = New-Btn '应用系统优化'
$flow.Controls.AddRange(@($btnScan, $btnOneKey, $btnFreeze, $btnRestore, $btnRestoreAll, $btnSettings))
$log = New-Object System.Windows.Forms.TextBox
$log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
$log.Dock = 'Fill'; $log.BackColor = [System.Drawing.Color]::White
$panelBottom.Controls.Add($log)
$panelBottom.Controls.Add($flow)

$f.Controls.Add($lv)
$f.Controls.Add($panelTop)
$f.Controls.Add($panelBottom)

function Add-Log([string]$msg) {
    $log.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $msg`r`n")
    $log.SelectionStart = $log.TextLength; $log.ScrollToCaret()
}

function Get-CurrentItems {
    $risks = @(); if ($chkLow.Checked) { $risks += 'low' }
    if ($chkMed.Checked) { $risks += 'medium' }; if ($chkHigh.Checked) { $risks += 'high' }
    Get-MergedItems $script:Brand | Where-Object { $risks -contains $_.risk }
}

function Refresh-List {
    $lv.BeginUpdate(); $lv.Items.Clear()
    if (-not $script:Serial) { $lv.EndUpdate(); return }
    foreach ($i in (Get-CurrentItems)) {
        $state = Get-PkgState $i.pkg
        $row = New-Object System.Windows.Forms.ListViewItem($i.name)
        [void]$row.SubItems.Add($i.pkg)
        [void]$row.SubItems.Add($(switch ($i.risk) { 'low' {'低'} 'medium' {'中'} default {'高'} }))
        [void]$row.SubItems.Add($(switch ($state) { 'active' {'运行中'} 'disabled' {'已冻结'} default {'不存在'} }))
        [void]$row.SubItems.Add($i.desc)
        $row.Tag = @{ pkg = $i.pkg; risk = $i.risk }
        $row.Checked = ($i.risk -eq 'low')
        if ($state -eq 'disabled') { $row.ForeColor = [System.Drawing.Color]::Gray }
        if ($state -eq 'absent')   { $row.ForeColor = [System.Drawing.Color]::LightGray }
        [void]$lv.Items.Add($row)
    }
    $lv.EndUpdate()
}

function Connect-Device {
    $serial = Get-DeviceConnected
    if ($serial -eq $script:Serial) { return }
    if (-not $serial) {
        $script:Serial = $null; $script:Brand = $null
        $lblDevice.Text = '设备状态：未检测到手机，请连接 USB 并允许调试'
        $lblDevice.ForeColor = 'Firebrick'; $lblBrand.Text = ''
        $lv.Items.Clear(); return
    }
    $script:Serial = $serial
    $script:Brand  = Detect-Brand
    $model   = [string](Invoke-Adb 'shell' 'getprop ro.product.marketname')
    $device  = [string](Invoke-Adb 'shell' 'getprop ro.product.device')
    $android = [string](Invoke-Adb 'shell' 'getprop ro.build.version.release')
    $shown = if ($model.Trim()) { $model.Trim() } else { $device.Trim() }
    $lblDevice.Text = "设备状态：已连接 $shown (Android $android) 序列号 $serial"
    $lblDevice.ForeColor = 'DarkGreen'
    $lblBrand.Text = "识别系统：$script:Brand" + $(if ($script:Brand -eq 'Unknown') { ' —— 未识别品牌，仅显示自定义清单' } else { '' })
    Add-Log "已连接设备：$shown ($serial)，系统识别为 $script:Brand"
    $st = Load-State $serial
    if ($st) { Add-Log "找到历史记录：$($st.time) 曾冻结 $($st.items.Count) 项" }
    Refresh-List
}

# ---------------- 按钮 ----------------
$btnRefresh.Add_Click({ Connect-Device })
$chkLow.Add_Click({ Refresh-List }); $chkMed.Add_Click({ Refresh-List }); $chkHigh.Add_Click({ Refresh-List })

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

$f.Add_Shown({ Add-Log 'AdClean 已启动。连接手机后点击「刷新设备」即可开始。' })

# 设备轮询定时器
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Connect-Device })
$timer.Start()

[void]$f.ShowDialog()
$timer.Stop()
