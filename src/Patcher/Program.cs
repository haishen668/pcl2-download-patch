using System.Reflection.PortableExecutable;
using System.Reflection.Metadata;
using System.Text;

// ============================================================
//  PCL2 下载恢复补丁器 —— 双击即用
//  用法: 放到 PCL 目录双击运行（或命令行传入 exe 路径）
//  仅修改 60 个字节，自动备份 .bak，重复运行安全。
// ============================================================

Console.OutputEncoding = Encoding.UTF8;
var title = "PCL2 下载恢复补丁 v1.0";
Console.WriteLine($"== {title} ==\n");

// ---------- 定目标文件 ----------
string path = args.Length > 0 ? args[0] : Path.Combine(AppContext.BaseDirectory, "Plain Craft Launcher 2.exe");
if (!File.Exists(path))
{
    var alt = Path.Combine(Directory.GetCurrentDirectory(), "Plain Craft Launcher 2.exe");
    if (File.Exists(alt)) path = Path.Combine(Path.GetFullPath(alt));
}
if (!File.Exists(path))
{
    Fail<object>("找不到 Plain Craft Launcher 2.exe。\n请把本工具放到 PCL 文件夹里再运行，\n或直接把 PCL 的 exe 拖到本程序上。");
}

byte[] bytes;
try { bytes = File.ReadAllBytes(path); }
catch (Exception ex) { Fail<object>($"无法读取文件: {ex.Message}"); return; }

// ---------- 解析 .NET 元数据 ----------
var fs = new FileStream(path, FileMode.Open, FileAccess.Read);
var pe = new PEReader(fs);
var md = pe.GetMetadataReader();

int usFileOff = LocateUserStringHeap(pe, bytes)
                ?? Fail<int?>("无法定位 .NET 元数据（这个 exe 可能不是标准 .NET 程序）").Value;

// ---------- 在 #US 堆中定位两个关键字符串的 ldstr token ----------
uint tokRestrict = FindStringToken(bytes, usFileOff, md, "为遵守相关法律法规")
                   ?? Fail<uint?>("这个 PCL 版本里没有找到下载限制标记。\n可能尚未受限、已经打过补丁、或版本结构有变化。\n可到 GitHub 仓库提 Issue 附上 PCL 版本号。").Value;
uint tokClose = FindStringToken(bytes, usFileOff, md, "关闭下载") ?? 0;
uint fldLoader = FindFieldToken(md, "DlClientListLoader") ?? 0;
uint mGetCard = FindMethodToken(md, "get_CardMinecraft") ?? 0;

int changed = 0, alreadyAll = 0;

// ---------- 补丁 A: NOP 掉"为遵守…"throw 块 ----------
{
    var pat = PrefixTokenBytes(0x72, tokRestrict);
    int[] starts = { 0 };
    var positions = FindAll(bytes, pat);
    int thrown = 0;
    foreach (var r in positions)
    {
        bool isNop = true;
        for (int k = 0; k < 11; k++) if (bytes[r + k] != 0) { isNop = false; break; }
        if (isNop) continue;
        // 形态: ldstr(5) + newobj(5) + throw(1)
        if (bytes[r + 5] == 0x73 && (bytes[r + 9] == 0x0A || bytes[r + 9] == 0x06) && bytes[r + 10] == 0x7A)
        {
            for (int k = 0; k < 11; k++) bytes[r + k] = 0;
            thrown++; changed++;
        }
    }
    if (thrown > 0) { Ok($"移除下载拦截 ({thrown} 处)"); }
    else if (positions.Count > 0) { Info("拦截块已处理过"); alreadyAll++; }
}

// ---------- 补丁 B: 下载页假加载器 → 真加载器 ----------
if (tokClose != 0 && fldLoader != 0)
{
    var positions = FindAll(bytes, PrefixTokenBytes(0x72, tokClose));
    if (positions.Count >= 1)
    {
        int r = positions[0];
        int end = -1;
        for (int q = r; q < Math.Min(r + 128, bytes.Length - 3); q++)
            if (bytes[q] == 0x02 && bytes[q + 1] == 0xFE && bytes[q + 2] == 0x06) { end = q; break; }
        if (end > r)
        {
            bool hasNewobj = false;
            for (int q = r; q < end - 4; q++)
                if (bytes[q] == 0x73 && (bytes[q + 4] == 0x0A || bytes[q + 4] == 0x06)) hasNewobj = true;
            if (hasNewobj)
            {
                int len = end - r;
                bytes[r] = 0x7E;                                   // ldsfld DlClientListLoader
                WriteU32(bytes, r + 1, fldLoader);
                for (int k = 5; k < len; k++) bytes[r + k] = 0;
                Ok($"恢复下载页版本列表 (区间 {len} 字节)"); changed++;
                goto doneB;
            }
        }
        Warn("假加载器结构有变化，跳过下载页补丁");
    }
    else if (FindAll(bytes, PrefixTokenBytes(0x7E, fldLoader)).Count >= 1) { Info("下载页已处理过"); alreadyAll++; }
    else Warn("未找到假加载器特征（版本结构可能已变化）");
}
doneB:

// ---------- 补丁 C: 组件卡片恢复显示 ----------
if (mGetCard != 0)
{
    var pat = new byte[8];
    pat[0] = 0x02; pat[1] = 0x6F;
    WriteU32(pat, 2, mGetCard);
    pat[6] = 0x18; pat[7] = 0x6F;
    var positions = FindAll(bytes, pat);
    if (positions.Count == 1) { bytes[positions[0] + 6] = 0x16; Ok("恢复版本设置中的原版组件卡片"); changed++; }
    else if (positions.Count == 0)
    {
        pat[6] = 0x16;
        if (FindAll(bytes, pat).Count >= 1) { Info("组件卡片已处理过"); alreadyAll++; }
        else Warn("未找到组件卡片隐藏点，跳过");
    }
    else Warn($"组件卡片模式出现 {positions.Count} 次，跳过（保守起见）");
}

if (changed == 0 && alreadyAll >= 3)
{
    Console.WriteLine("\n所有补丁都已存在，无需修改。当前 exe 已是恢复过的版本。");
    PauseIfDoubleClicked(args); return;
}
if (changed == 0)
{
    Fail<object>("未能应用任何补丁，文件未做修改。\n请到 GitHub 仓库提 Issue，附上 PCL 版本号。"); return;
}

// ---------- 备份并写回 ----------
string bak = path + ".bak";
try
{
    if (!File.Exists(bak)) { File.Copy(path, bak); Console.WriteLine($"已备份原文件 → {Path.GetFileName(bak)}"); }
    else Console.WriteLine("备份已存在，不覆盖。");
    File.WriteAllBytes(path, bytes);
}
catch (Exception ex) { Fail<object>($"写入失败（PCL 可能正在运行？请先关闭 PCL）: {ex.Message}"); return; }

Console.WriteLine($"""
已恢复共 {changed} 项。
现在打开 PCL2 的下载页试试吧！

· 想还原: 删掉 exe，把 .bak 改回原名即可
· PCL 更新后: 重新双击本工具一次
""");
PauseIfDoubleClicked(args);

// ================= 工具函数 =================

static void Ok(string s)   => Console.WriteLine($"[√] {s}");
static void Info(string s) => Console.WriteLine($"[=] {s}");
static void Warn(string s) => Console.WriteLine($"[?] {s}");

static T Fail<T>(string msg)
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine($"[X] {msg}");
    Console.ResetColor();
    Console.WriteLine("\n按任意键退出…");
    try { Console.ReadKey(true); } catch { }
    Environment.Exit(1);
    return default;
}

static void PauseIfDoubleClicked(string[] args)
{
    if (args.Length == 0) { Console.WriteLine("\n按任意键退出…"); try { Console.ReadKey(true); } catch { } }
}

static void WriteU32(byte[] b, int off, uint v)
{
    b[off] = (byte)v; b[off + 1] = (byte)(v >> 8); b[off + 2] = (byte)(v >> 16); b[off + 3] = (byte)(v >> 24);
}

static byte[] PrefixTokenBytes(byte op, uint token)
{
    var b = new byte[5];
    b[0] = op;
    WriteU32(b, 1, token);
    return b;
}

static List<int> FindAll(byte[] hay, byte[] needle)
{
    var res = new List<int>();
    for (int i = 0; i <= hay.Length - needle.Length; i++)
    {
        int j = 0;
        while (j < needle.Length && hay[i + j] == needle[j]) j++;
        if (j == needle.Length) { res.Add(i); i++; }
    }
    return res;
}

// 定位 #US 用户字符串堆在文件中的偏移
static int? LocateUserStringHeap(PEReader pe, byte[] bytes)
{
    var dir = pe.PEHeaders.CorHeader.MetadataDirectory;
    int mdOff = 0;
    foreach (var s in pe.PEHeaders.SectionHeaders)
        if (dir.RelativeVirtualAddress >= s.VirtualAddress &&
           dir.RelativeVirtualAddress < s.VirtualAddress + Math.Max(s.SizeOfRawData, s.VirtualSize))
        { mdOff = (int)(dir.RelativeVirtualAddress - s.VirtualAddress + s.PointerToRawData); break; }
    if (mdOff == 0) return null;

    int p = mdOff + 12;                                  // sig(4)+ver(2+2)+reserved(4)
    uint verLen = ReadU32(bytes, p); p += 4;
    p += (int)Math.Ceiling(verLen / 4.0) * 4;            // 版本串按 4 对齐
    p += 2;                                              // Flags
    int streamCount = ReadU16(bytes, p); p += 2;
    for (int k = 0; k < streamCount; k++)
    {
        uint off = ReadU32(bytes, p); p += 8;            // offset+size
        var name = new StringBuilder();
        int q = p;
        while (bytes[q] != 0) { name.Append((char)bytes[q]); q++; }
        int nameLen = (int)Math.Ceiling((q - p + 1) / 4.0) * 4;
        p += nameLen;
        if (name.ToString() == "#US") return mdOff + (int)off;
    }
    return null;
}

// 在 #US 堆中找字符串 → 计算 ldstr token（回退 1~4 字节压缩前缀并用 MetadataReader 验证）
static uint? FindStringToken(byte[] bytes, int usOff, System.Reflection.Metadata.MetadataReader md, string text)
{
    var needle = Encoding.Unicode.GetBytes(text);
    for (int h = usOff; h <= bytes.Length - needle.Length; h++)
    {
        int j = 0;
        while (j < needle.Length && bytes[h + j] == needle[j]) j++;
        if (j != needle.Length) continue;
        for (int pre = 1; pre <= 4; pre++)
        {
            int usIdx = h - usOff - pre;
            if (usIdx < 1) continue;
            uint tok = 0x70000000u | (uint)usIdx;
            try
            {
                var handle = System.Reflection.Metadata.Ecma335.MetadataTokens.UserStringHandle((int)tok);
                string s = md.GetUserString(handle);
                if (s != null && s.Contains(text)) return tok;
            }
            catch { }
        }
    }
    return null;
}

static uint? FindFieldToken(System.Reflection.Metadata.MetadataReader md, string name)
{
    int row = 0;
    foreach (var h in md.FieldDefinitions)
    {
        row++;
        if (md.GetString(md.GetFieldDefinition(h).Name) == name)
            return 0x04000000u | (uint)row;
    }
    return null;
}

static uint? FindMethodToken(System.Reflection.Metadata.MetadataReader md, string name)
{
    int row = 0;
    foreach (var h in md.MethodDefinitions)
    {
        row++;
        if (md.GetString(md.GetMethodDefinition(h).Name) == name)
            return 0x06000000u | (uint)row;
    }
    return null;
}

static uint ReadU32(byte[] b, int o) => (uint)(b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24);
static ushort ReadU16(byte[] b, int o) => (ushort)(b[o] | b[o + 1] << 8);
