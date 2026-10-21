#!/usr/bin/env python3
"""pcl2_analyze —— PCL2 下载限制逆向分析工具

子命令:
  info    <exe>                        版本指纹 / 强名称 / 限制字符串引用统计
  dump    <exe> [--str 关键词 | --method 名字]   反汇编相关方法的 IL（含原始字节）
  tokens  <exe>                        打印补丁脚本依赖的关键元数据 token
  verify  <orig> <patched>             对比补丁前后差异（应等长、区间最小）

依赖: pip install dnfile dncil
"""
import argparse
import hashlib
import sys

try:
    import dnfile
    from dncil.cil.body import CilMethodBody
    from dncil.cil.body.reader import CilMethodBodyReaderBase
except ImportError:
    sys.exit("缺少依赖: pip install dnfile dncil")

RESTRICT_STR = "为遵守相关法律法规"
KEY_FIELDS = ["DlClientListLoader"]
KEY_METHODS = ["get_CardMinecraft", "LoaderInit", "ModpackInstall"]


class Analyzer:
    def __init__(self, path):
        self.path = path
        self.raw = open(path, "rb").read()
        self.pe = dnfile.dnPE(path)
        self.owner = {}
        for t in self.pe.net.mdtables.TypeDef.rows:
            tn = ((t.TypeNamespace.value or "") + "." + (t.TypeName.value or "")).strip(".")
            for m in t.MethodList:
                if m.row is not None:
                    self.owner[id(m.row)] = tn

    # ---------- 基础 ----------
    def methods(self):
        """yield (type_name, method_name, row, file_offset or None)"""
        for row in self.pe.net.mdtables.MethodDef.rows:
            if not row.Rva:
                continue
            try:
                fo = self.pe.get_offset_from_rva(row.Rva)
            except Exception:
                continue
            yield (self.owner.get(id(row), "?"), row.Name.value or "?", row, fo)

    def body(self, fo):
        class R(CilMethodBodyReaderBase):
            def __init__(s, d, o):
                s.data, s.base, s.pos = d, o, 0
            def read(s, n):
                b = s.data[s.base + s.pos:s.base + s.pos + n]
                s.pos += n
                return b
            def tell(s):
                return s.base + s.pos
            def seek(s, off):
                if off >= s.base:
                    s.pos = off - s.base
                else:
                    s.base, s.pos = off, 0
        return CilMethodBody(R(self.raw, fo))

    def us(self, token):
        try:
            u = self.pe.net.user_strings.get(token.rid)
            return str(u.value) if u and u.value else ""
        except Exception:
            return ""

    def fmt(self, insn, fo):
        rel = insn.offset - fo
        op = str(insn.opcode)
        extra = ""
        if insn.operand is not None:
            if op == "ldstr":
                extra = f'"{self.us(insn.operand)[:36]}"'
            elif hasattr(insn.operand, "value"):
                extra = f"0x{insn.operand.value:08X}"
        return f"  IL_{rel:04X}: {op} {extra}".rstrip()

    # ---------- 子命令 ----------
    def cmd_info(self):
        print(f"文件: {self.path}")
        print(f"大小: {len(self.raw):,}  SHA-256: {hashlib.sha256(self.raw).hexdigest()}")
        print(f"强名称签名: {'有 ⚠' if int(self.pe.net.Flags) & 8 else '无 (可安全字节补丁)'}")
        print(f"限制字符串明文存在: {'是' if RESTRICT_STR.encode('utf-16-le') in self.raw else '否 (可能被加密/未受限)'}")
        needle = RESTRICT_STR[:6].encode("utf-16-le")
        refs = []
        i = 0
        while True:
            i = self.raw.find(needle, i)
            if i < 0:
                break
            refs.append(i)
            i += 1
        print(f"#US 堆内匹配: {len(refs)} 处 ({[hex(x) for x in refs]})")
        # ldstr 引用统计（按已解析方法扫描）
        cnt = 0
        for tn, mn, row, fo in self.methods():
            try:
                b = self.body(fo)
            except Exception:
                continue
            for insn in b.instructions:
                if str(insn.opcode) == "ldstr" and insn.operand is not None:
                    if RESTRICT_STR in self.us(insn.operand):
                        cnt += 1
                        print(f"  ldstr 引用: {tn}::{mn} (方法体 0x{fo:X})")
        print(f"解析到 ldstr 引用共 {cnt} 处")

    def cmd_dump(self, str_filter=None, method_filter=None):
        for tn, mn, row, fo in self.methods():
            try:
                b = self.body(fo)
            except Exception:
                continue
            insns = list(b.instructions)
            hit = False
            if method_filter and method_filter.lower() in mn.lower():
                hit = True
            if str_filter:
                for insn in insns:
                    if str(insn.opcode) == "ldstr" and insn.operand is not None \
                            and str_filter in self.us(insn.operand):
                        hit = True
                        break
            if not hit:
                continue
            print(f"\n==== {tn}::{mn}  方法体 0x{fo:X}  code_size={b.code_size} ====")
            code = self.raw[fo + b.header_size: fo + b.header_size + b.code_size]
            for i in range(0, len(code), 16):
                print("  +" + f"{i:04X}: " + " ".join(f"{x:02X}" for x in code[i:i + 16]))
            for insn in insns:
                print(self.fmt(insn, fo))

    def cmd_tokens(self):
        print("== Field 表（按名字） ==")
        for name in KEY_FIELDS:
            found = 0
            for i, r in enumerate(self.pe.net.mdtables.Field.rows):
                if r.Name.value == name:
                    print(f"  {name} -> 0x04{i + 1:06X}")
                    found += 1
            if not found:
                print(f"  {name} -> 未找到 ⚠")
        print("== MethodDef 表（按名字） ==")
        for name in KEY_METHODS:
            hits = []
            for i, r in enumerate(self.pe.net.mdtables.MethodDef.rows):
                if r.Name.value == name:
                    hits.append(f"0x06{i + 1:06X}")
            print(f"  {name} -> {', '.join(hits) if hits else '未找到 ⚠'}")

    @staticmethod
    def cmd_verify(orig_path, patched_path):
        a = open(orig_path, "rb").read()
        b = open(patched_path, "rb").read()
        if len(a) != len(b):
            print(f"!! 大小不一致: {len(a):,} vs {len(b):,} —— 违反等长补丁原则")
            return 1
        diffs = [i for i in range(len(a)) if a[i] != b[i]]
        print(f"差异字节: {len(diffs)} 个")
        groups = []
        for i in diffs:
            if groups and i - groups[-1][-1] <= 2:
                groups[-1].append(i)
            else:
                groups.append([i])
        for g in groups:
            s, e = g[0], g[-1]
            print(f"  0x{s:X}..0x{e:X}  ({e - s + 1} B): {a[s:e+1].hex(' ')} -> {b[s:e+1].hex(' ')}")
        print(f"补丁后 SHA-256: {hashlib.sha256(b).hexdigest()}")
        return 0


def main():
    ap = argparse.ArgumentParser(description="PCL2 下载限制分析工具")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("info").add_argument("exe")
    d = sub.add_parser("dump")
    d.add_argument("exe")
    d.add_argument("--str", dest="s")
    d.add_argument("--method", dest="m")
    sub.add_parser("tokens").add_argument("exe")
    v = sub.add_parser("verify")
    v.add_argument("orig")
    v.add_argument("patched")
    args = ap.parse_args()

    if args.cmd == "verify":
        sys.exit(Analyzer.cmd_verify(args.orig, args.patched))
    a = Analyzer(args.exe)
    if args.cmd == "info":
        a.cmd_info()
    elif args.cmd == "dump":
        a.cmd_dump(args.s, args.m)
    elif args.cmd == "tokens":
        a.cmd_tokens()


if __name__ == "__main__":
    main()
