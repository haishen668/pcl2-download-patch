# ============================================================
#  [Legacy] PCL2 恢复 MC 下载功能补丁 v1 —— 固定特征版
#  仅适配 2.99.0.0 (Build 413)。新版本请使用 src/PCL2-RestoreDownload-v2.ps1。
#  本版特征硬编码该编译产物的元数据编号，作为精确锚点保留，
#  并用于与 v2 做等价性验证（两者产物 SHA-256 相同）。
# ============================================================
#  用法: powershell -ExecutionPolicy Bypass -File .\PCL2-RestoreDownload-v1.ps1 [exe路径]
#  原理: NOP 掉"为遵守相关法律法规"限制块，并把下载页假加载器
#        ("关闭下载") 替换回真正的 DlClientListLoader。共改 60 字节，
#        自动备份 .bak，重复运行安全。
# ============================================================
param(
    [string]$Path = (Join-Path $PSScriptRoot "Plain Craft Launcher 2.exe")
)
$ErrorActionPreference = "Stop"
Write-Host "== PCL2 恢复下载补丁 ==" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "[X] 找不到文件: $Path" -ForegroundColor Red
    Write-Host "    请把脚本放到 PCL 目录运行，或拖动 exe 到本脚本上。" -ForegroundColor Yellow
    exit 1
}

# 版本指纹：限制提示语（UTF-16LE）必须存在于 exe
$bytes  = [IO.File]::ReadAllBytes($Path)
$hex    = [BitConverter]::ToString($bytes) -replace '-', ''
$fpHex  = [BitConverter]::ToString([Text.Encoding]::Unicode.GetBytes("为遵守相关法律法规")) -replace '-', ''
if (-not $hex.Contains($fpHex)) {
    Write-Host "[X] 该 exe 不含 2.99.0.0 的限制标记，可能不是本版本或已被修改，未做任何改动。" -ForegroundColor Red
    exit 1
}

# ---- 三个补丁（十六进制模式 → 替换） ----
$patches = @(
    @{ Name = "补丁1 下载页: 换回真正的版本加载器";
       Pat = "72334701707EFB0900042C077EFB0900042B167EF9090004FE0667140006738D05000A2580FB0900041418738E05000A";
       Rep = "7E0F040004" + ("00" * 43); Min = 1; Max = 1 },
    @{ Name = "补丁2 整合包: 移除安装拦截 throw";
       Pat = "72EB45007073A601000A7A";
       Rep = "00" * 11; Min = 1; Max = 2 },
    @{ Name = "补丁3 组件卡片: Collapsed 改 Visible";
       Pat = "026F71050006186F0E01000A";
       Rep = "026F71050006166F0E01000A"; Min = 1; Max = 1 }
)

$alreadyDone = $true
$changed = 0
foreach ($p in $patches) {
    $pos = 0; $hits = @()
    while (($i = $hex.IndexOf($p.Pat, $pos)) -ge 0) { $hits += $i; $pos = $i + 1 }
    if ($hits.Count -eq 0) {
        if ($hex.Contains($p.Rep)) { Write-Host "[=] $($p.Name): 已打过，跳过" -ForegroundColor DarkGray; continue }
        Write-Host "[X] $($p.Name): 未找到特征(出现0次)，文件结构不符，中止。" -ForegroundColor Red; exit 1
    }
    if ($hits.Count -gt $p.Max) {
        Write-Host "[X] $($p.Name): 特征出现 $($hits.Count) 次(预期 $($p.Min)-$($p.Max))，为安全起见中止。" -ForegroundColor Red; exit 1
    }
    foreach ($h in $hits) {
        $off = $h / 2                       # hex 字符偏移 → 字节偏移
        $repBytes = for ($k = 0; $k -lt $p.Rep.Length; $k += 2) { [Convert]::ToByte($p.Rep.Substring($k, 2), 16) }
        for ($k = 0; $k -lt $repBytes.Count; $k++) { $bytes[$off + $k] = $repBytes[$k] }
        $changed++
    }
    Write-Host "[√] $($p.Name) ($($hits.Count) 处)" -ForegroundColor Green
    $alreadyDone = $false
}

if ($alreadyDone) { Write-Host "所有补丁均已存在，无需修改。" -ForegroundColor Yellow; exit 0 }

# 备份并写回
$bak = "$Path.bak"
if (-not (Test-Path $bak)) { Copy-Item $Path $bak; Write-Host "已备份 → $bak" -ForegroundColor DarkGray }
else { Write-Host "备份已存在，不再覆盖 → $bak" -ForegroundColor DarkGray }
[IO.File]::WriteAllBytes($Path, $bytes)

Write-Host ""
Write-Host "完成！共修改 $changed 处。现在打开 PCL2 的下载页试试。" -ForegroundColor Green
Write-Host "注意: 仅自用，请勿分发修改后的 exe（PCL 为有限分发许可）。" -ForegroundColor DarkGray
