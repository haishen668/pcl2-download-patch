# ============================================================
#  PCL2 恢复 MC 下载功能补丁 v2 —— 语义版（适配多个版本）
#  相比 v1 不再硬编码元数据编号，运行时解析 .NET 元数据动态定位，
#  PCL 小版本更新后通常无需改脚本，直接重跑即可。
#  用法: powershell -ExecutionPolicy Bypass -File .\PCL2-RestoreDownload-v2.ps1 [exe路径]
#  要求: Windows 10 1803+ (PowerShell 5.1 自带 .NET 4.7.2+) 或 PowerShell 7
# ============================================================
param(
    [string]$Path = (Join-Path $PSScriptRoot "Plain Craft Launcher 2.exe")
)
$ErrorActionPreference = "Stop"
Write-Host "== PCL2 恢复下载补丁 v2 (语义版) ==" -ForegroundColor Cyan

if (-not (Test-Path $Path)) {
    Write-Host "[X] 找不到文件: $Path （把脚本放到 PCL 目录运行，或把 exe 拖到脚本上）" -ForegroundColor Red
    exit 1
}

try { Add-Type -AssemblyName System.Reflection.Metadata } catch {}
try {
    $null = [System.Reflection.PortableExecutable.PEReader]
} catch {
    Write-Host "[X] 当前系统缺少 System.Reflection.Metadata（需要 Win10 1803+ / .NET 4.7.2+）。" -ForegroundColor Red
    exit 1
}

$bytes = [IO.File]::ReadAllBytes($Path)
$fs    = [IO.File]::OpenRead($Path)
$pe    = New-Object System.Reflection.PortableExecutable.PEReader($fs)
$md    = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)

# ---------- 工具：在字节数组中搜索 pattern 的全部出现 ----------
function Find-Bytes([byte[]]$hay, [byte[]]$needle, [int]$from) {
    $res = @(); $i = $from; $n = $needle.Length; $last = $hay.Length - $n
    while ($i -le $last) {
        $j = 0
        while ($j -lt $n -and $hay[$i + $j] -eq $needle[$j]) { $j++ }
        if ($j -eq $n) { $res += $i; $i++ } else { $i++ }
    }
    return $res
}
function Hex2Bytes([string]$h) {
    $b = New-Object byte[] ($h.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
    return ,[byte[]]$b
}

# ---------- 定位 #US 用户字符串堆的文件偏移 ----------
$corMeta = $pe.PEHeaders.CorHeader.MetadataDirectory
$sections = $pe.PEHeaders.SectionHeaders
$mdFileOff = 0
$metaRva = $corMeta.RelativeVirtualAddress
foreach ($s in $sections) {
    if ($metaRva -ge $s.VirtualAddress -and $metaRva -lt ($s.VirtualAddress + [Math]::Max($s.SizeOfRawData, $s.VirtualSize))) {
        $mdFileOff = $metaRva - $s.VirtualAddress + $s.PointerToRawData; break
    }
}
if ($mdFileOff -eq 0) { Write-Host "[X] 无法定位元数据目录"; exit 1 }
# 解析 metadata root: BSJB签名(4)+版本(2+2)+保留(4)+版本串长度(4)+版本串(4对齐)+Flags(2)+Streams数(2)
$p = $mdFileOff + 12
$verLen = [BitConverter]::ToUInt32($bytes, $p); $p += 4
$verLenAligned = [Math]::Ceiling($verLen / 4) * 4
if ($verLenAligned -lt $verLen) { $verLenAligned = $verLen }
$p += $verLenAligned
$p += 2   # Flags
$streamCount = [BitConverter]::ToUInt16($bytes, $p); $p += 2
$usFileOff = 0
for ($k = 0; $k -lt $streamCount; $k++) {
    $off = [BitConverter]::ToUInt32($bytes, $p); $size = [BitConverter]::ToUInt32($bytes, $p + 4); $p += 8
    $name = ""; $q = $p
    while ($bytes[$q] -ne 0) { $name += [char]$bytes[$q]; $q++ }
    $nameLen = $q - $p + 1; $nameLen = [Math]::Ceiling($nameLen / 4) * 4
    $p += $nameLen
    if ($name -eq "#US") { $usFileOff = $mdFileOff + $off }
}
if ($usFileOff -eq 0) { Write-Host "[X] 无法定位 #US 字符串堆"; exit 1 }

# ---------- 在 #US 堆中找字符串 → 生成 ldstr token（处理 1~4 字节压缩前缀回退） ----------
function Get-StringToken([string]$text, [string]$label) {
    $needle = [Text.Encoding]::Unicode.GetBytes($text)
    $hits = Find-Bytes $bytes $needle $usFileOff
    foreach ($h in $hits) {
        # ldstr token 指向 blob 前缀，前缀长度 1~4，逐一验证
        foreach ($pre in 1..4) {
            $usOff = $h - $usFileOff - $pre
            if ($usOff -lt 1) { continue }
            $tok = 0x70000000 -bor $usOff
            try {
                $h2 = [System.Reflection.Metadata.Ecma335.MetadataTokens]::UserStringHandle($tok)
                $s = $md.GetUserString($h2)
                if ($s -ne $null -and $s.Contains($text)) { return @{Tok = $tok; FileOff = $h} }
            } catch {}
        }
    }
    Write-Host "[X] 在 #US 堆中未找到 `$text`（$label）——限制代码结构可能已变化，未做任何修改。" -ForegroundColor Red
    exit 1
}

# ---------- 元数据表：按名字查字段/方法 token（token = 表号<<24 | 行号） ----------
function Get-FieldToken([string]$fname) {
    $row = 0
    foreach ($h in $md.FieldDefinitions) {
        $row++
        $fd = $md.GetFieldDefinition($h)
        if ($md.GetString($fd.Name) -eq $fname) { return (0x04 -shl 24) -bor $row }
    }
    return 0
}
function Get-MethodToken([string]$mname) {
    $row = 0
    foreach ($h in $md.MethodDefinitions) {
        $row++
        $mf = $md.GetMethodDefinition($h)
        if ($md.GetString($mf.Name) -eq $mname) { return (0x06 -shl 24) -bor $row }
    }
    return 0
}

Write-Host "正在解析元数据……"
$tRestrict = Get-StringToken "为遵守相关法律法规" "限制提示语"
$tClose    = Get-StringToken "关闭下载" "假加载器名称"
$fLoader   = Get-FieldToken  "DlClientListLoader"
$mGetCard  = Get-MethodToken "get_CardMinecraft"
if ($fLoader -eq 0) { Write-Host "[X] 找不到字段 DlClientListLoader（结构已变化）"; exit 1 }
if ($mGetCard -eq 0) { Write-Host "[X] 找不到方法 get_CardMinecraft（结构已变化）"; exit 1 }
Write-Host ("  DlClientListLoader = 0x{0:X8}, get_CardMinecraft = 0x{1:X8}" -f $fLoader, $mGetCard)

$changed = 0
$alreadyAll = $true

# ---------- 补丁 1+2：所有 ldstr"为遵守"引用点 ----------
$patLd = New-Object byte[] 5
$patLd[0] = 0x72
[BitConverter]::GetBytes([int]$tRestrict.Tok).CopyTo($patLd, 1)
$refs = Find-Bytes $bytes $patLd 0
$throwPatched = 0
foreach ($r in $refs) {
    # 已打过的痕迹：从 ldstr 起整段已是 NOP
    $isNop = $true
    for ($k = 0; $k -lt 11; $k++) { if ($bytes[$r + $k] -ne 0x00) { $isNop = $false; break } }
    if ($isNop) { continue }
    # 形态 A: ldstr(5) + newobj(5) + throw(1) → NOP 11 字节
    if ($bytes[$r + 5] -eq 0x73 -and ($bytes[$r + 9] -eq 0x0A -or $bytes[$r + 9] -eq 0x06) -and $bytes[$r + 10] -eq 0x7A) {
        for ($k = 0; $k -lt 11; $k++) { $bytes[$r + $k] = 0x00 }
        $throwPatched++; $changed++
    }
    # 形态 B: 无参 ModpackInstall() 的 Hint+Return（恒真折叠，后续正常代码已被编译器删除）
    elseif ($bytes[$r + 5] -eq 0x18 -and $bytes[$r + 6] -eq 0x17 -and $bytes[$r + 7] -eq 0x28) {
        Write-Host "[-] 无参整合包入口已折叠（其文件选择逻辑在编译时已被删除，无法恢复，跳过）" -ForegroundColor DarkGray
    }
}
if ($throwPatched -gt 0) { Write-Host "[√] 补丁A: 移除 throw/拦截 块 ($throwPatched 处)" -ForegroundColor Green; $alreadyAll = $false }
elseif ($refs.Count -gt 0) { Write-Host "[i] 其余 $($refs.Count) 处字符串引用已核对为无害残留（比较条件/已折叠入口），未修改" -ForegroundColor DarkGray }

# ---------- 补丁 1：LoaderInit 假加载器 → 真 DlClientListLoader ----------
$patC = New-Object byte[] 5
$patC[0] = 0x72
[BitConverter]::GetBytes([int]$tClose.Tok).CopyTo($patC, 1)
$cRefs = Find-Bytes $bytes $patC 0
if ($cRefs.Count -ge 1) {
    $r = $cRefs[0]
    # 区间 = ldstr("关闭下载") 起，到 OnFinish 委托构造锚 02 FE 06 之前
    $end = -1
    for ($q = $r; $q -lt [Math]::Min($r + 128, $bytes.Length - 3); $q++) {
        if ($bytes[$q] -eq 0x02 -and $bytes[$q + 1] -eq 0xFE -and $bytes[$q + 2] -eq 0x06) { $end = $q; break }
    }
    if ($end -gt $r) {
        # 校验区间内确实在构造 LoaderTask（存在 newobj，即 73 .. .. .. 0A/06）
        $okNew = $false
        for ($q = $r; $q -lt $end - 4; $q++) {
            if ($bytes[$q] -eq 0x73 -and ($bytes[$q + 4] -eq 0x0A -or $bytes[$q + 4] -eq 0x06)) { $okNew = $true }
        }
        if ($okNew) {
            $len = $end - $r
            $bytes[$r] = 0x7E                                  # ldsfld
            [BitConverter]::GetBytes([int]$fLoader).CopyTo($bytes, $r + 1)
            for ($k = 5; $k -lt $len; $k++) { $bytes[$r + $k] = 0x00 }
            Write-Host "[√] 补丁B: 下载页假加载器已替换为 DlClientListLoader (区间 $len 字节)" -ForegroundColor Green
            $changed++; $alreadyAll = $false
        } else { Write-Host "[?] 未在假加载器区间识别到 LoaderTask 构造，跳过补丁B" -ForegroundColor Yellow }
    } else { Write-Host "[?] 未找到假加载器区间终点锚，跳过补丁B" -ForegroundColor Yellow }
} else {
    # 已打过：ldstr 已被 ldsfld 替换，检查标志
    $probe = New-Object byte[] 5
    $probe[0] = 0x7E
    [BitConverter]::GetBytes([int]$fLoader).CopyTo($probe, 1)
    if ((Find-Bytes $bytes $probe 0).Count -ge 1) { Write-Host "[=] 补丁B: 已打过" -ForegroundColor DarkGray }
    else { Write-Host "[X] 未找到『关闭下载』ldstr，且无已打补丁标志——结构不符，中止补丁B" -ForegroundColor Yellow }
}

# ---------- 补丁 3：CardMinecraft.Visibility Collapsed → Visible ----------
$patV = New-Object byte[] 8
$patV[0] = 0x02; $patV[1] = 0x6F
[BitConverter]::GetBytes([int]$mGetCard).CopyTo($patV, 2)
$patV[6] = 0x18; $patV[7] = 0x6F
$vRefs = Find-Bytes $bytes $patV 0
if ($vRefs.Count -eq 1) {
    $bytes[$vRefs[0] + 6] = 0x16
    Write-Host "[√] 补丁C: 组件卡片 Collapsed → Visible" -ForegroundColor Green
    $changed++; $alreadyAll = $false
} elseif ($vRefs.Count -eq 0) {
    $patV2 = $patV.Clone(); $patV2[6] = 0x16
    if ((Find-Bytes $bytes $patV2 0).Count -ge 1) { Write-Host "[=] 补丁C: 已打过" -ForegroundColor DarkGray }
    else { Write-Host "[?] 未找到 Visibility 赋值点，跳过补丁C" -ForegroundColor Yellow }
} else {
    Write-Host "[?] Visibility 模式出现 $($vRefs.Count) 次，为安全跳过补丁C" -ForegroundColor Yellow
}

if ($alreadyAll) { Write-Host "所有补丁均已存在，无需修改。" -ForegroundColor Yellow; exit 0 }
if ($changed -eq 0) { Write-Host "[X] 未能应用任何补丁，文件未修改。" -ForegroundColor Red; exit 1 }

# ---------- 备份写回 ----------
$bak = "$Path.bak"
if (-not (Test-Path $bak)) { Copy-Item $Path $bak; Write-Host "已备份 → $bak" -ForegroundColor DarkGray }
else { Write-Host "备份已存在，不覆盖 → $bak" -ForegroundColor DarkGray }
[IO.File]::WriteAllBytes($Path, $bytes)
$fs.Close()
Write-Host ""
Write-Host "完成！共 $changed 处修改。打开 PCL2 下载页试试。" -ForegroundColor Green
Write-Host "仅自用勿分发 · 下次 PCL 更新后如再受限，重跑本脚本即可（语义定位，自动适应新编号）。" -ForegroundColor DarkGray
