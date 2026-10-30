# AdClean

通用安卓去广告 / 系统精简工具。**小米 / 红米（MIUI · HyperOS）**、**OPPO / 一加 / Realme（ColorOS）** 通用。

免 Root、免解锁 Bootloader，通过 ADB 以用户级方式冻结系统广告组件，全程可一键还原。

![界面](https://img.shields.io/badge/UI-WinForms-blue) ![依赖](https://img.shields.io/badge/依赖-零-green) ![平台](https://img.shields.io/badge/平台-Windows_10%2F11-lightgrey)

## 功能

- **图形界面**：组件勾选操作，风险分级（低 / 中 / 高），实时显示每个包的运行状态
- **品牌自动识别**：通过系统属性检测 MIUI/HyperOS 或 ColorOS，加载对应组件清单（42 项内置）
- **一键优化**：自动冻结全部低风险广告组件（系统广告、快应用、埋点、营销推送等）
- **三层还原**：还原选中项 / 按本机记录还原全部（`state\序列号.json`）/ 任意 `pm enable`
- **核心保护**：桌面、SystemUI、手机管家、查找设备等 16 类关键包硬编码禁止操作
- **系统开关优化**：按品牌执行 `settings` 级广告开关关闭
- **自定义扩展**：`custom-list.json` 添加任意包名；`$script:Lists` 增补新品牌清单
- **零依赖**：Windows 自带 PowerShell 运行；exe 为自包含单文件

## 使用

1. 下载 [Android platform-tools](https://developer.android.google.cn/tools/releases/platform-tools)，把 `platform-tools` 文件夹放进本目录
2. 手机开启 USB 调试并连接（首次授权弹窗点允许）
3. 双击 `dist\AdClean.exe` → 点「一键优化(推荐)」

| 品牌 | 开启 USB 调试 |
|---|---|
| 小米/红米 | 设置 → 我的设备 → 全部参数 → 连点「OS版本」×7 → 开发者选项 → USB调试 |
| OPPO/一加 | 设置 → 关于手机 → 版本信息 → 连点「版本号」×7 → 开发者选项 → USB调试 |

## 构建

```powershell
powershell -ExecutionPolicy Bypass -File Build-Exe.ps1
```

用 Windows 自带的 .NET Framework 编译器（csc.exe）把 C# 启动器与内嵌的 PowerShell 主程序编译成 `dist\AdClean.exe`，无需联网、无需安装任何 SDK。

## 目录结构

```
├─ dist/AdClean.exe        ← 成品（自包含，可单独分发）
├─ launcher-src/Program.cs ← exe 启动器 C# 源码
├─ AdCleanGUI.ps1          ← 主程序（WinForms 界面 + ADB 引擎）
└─ Build-Exe.ps1           ← 一键重新打包
```

## 安全边界

只调用 `pm disable-user / pm enable`（用户级，可逆）与 `settings put`（可逆开关）；不触碰系统分区、不解锁、不 Root。冻结系统组件在极少数机型上可能引起个别功能异常，请按风险分级谨慎操作，所有操作均可还原。仅供设备所有者优化自己的设备使用。
