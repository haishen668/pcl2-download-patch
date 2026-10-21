# 新版本适配指南

PCL2 发布新版本后，按本流程适配补丁脚本。整个过程通常 15~30 分钟。

## 0. 前置

```bash
pip install dnfile dncil          # 纯 Python 的 .NET 元数据 / IL 解析库
python tools/pcl2_analyze.py info "Plain Craft Launcher 2.exe"   # 版本指纹与限制点总览
```

## 1. 先直接跑 v2 脚本

新版本大概率只是常规重编译（token 与堆偏移变化，代码结构不变），**v2 的语义定位对此免疫**：

```powershell
powershell -ExecutionPolicy Bypass -File .\src\PCL2-RestoreDownload-v2.ps1
```

- 三项补丁全部 `[√]`：适配完成，请顺手在 [支持版本表](../README.md#支持版本) 提 PR 补一行（版本号 + 原版 SHA-256）。
- 脚本报 `[X] 未找到 …`：作者改了限制的实现方式，继续第 2 步。

## 2. 重新分析（限制实现变化时）

1. **对照开源代码**：官方仓库随发布同步源码，diff 上次版本，重点看 `ModSecret.vb`、`PageDownloadInstall.xaml.vb`、`ModModpack.vb`、`PageDownloadModify.vb`：
   ```bash
   python tools/pcl2_analyze.py dump --str "为遵守相关法律法规" "Plain Craft Launcher 2.exe"
   ```
2. **定位新的限制点**：`dump` 会列出所有引用限制字符串的方法及其 IL。区分三种形态：
   - `ldstr + newobj Exception + throw`（throw 拦截）→ NOP 整段（含 newobj 的 5 字节）；
   - `ldstr + ldc.i4 + call Hint`（提示折叠）→ 检查其后正常逻辑是否仍存在（看方法是否还有后续指令），存在才可绕过；
   - 其他形态 → 需要具体分析，参考 [how-it-works.md](how-it-works.md) 的思路。
3. **确认目标字段/方法仍存在**：
   ```bash
   python tools/pcl2_analyze.py tokens "Plain Craft Launcher 2.exe"
   ```
   语义版依赖 `DlClientListLoader`（Field）与 `get_CardMinecraft`（MethodDef）这两个名字。
4. **更新脚本**：修改 `src/PCL2-RestoreDownload-v2.ps1` 中的关键词/形态/锚点，并把旧的字节特征追加到 v1 的历史表（供考古）。
5. **验证**（必做，缺一不可）：
   ```bash
   python tools/pcl2_analyze.py dump …            # IL 逐指令核对（栈平衡、跳转不变）
   python tools/pcl2_analyze.py verify orig.exe patched.exe   # 差异应等长且区间最小
   ```
   再在真机上测试：下载页加载版本列表 → 下载一个原版 → 拖拽安装一个 zip 整合包。

## 3. 提交适配

- PR：更新 README 支持版本表 + 脚本（如有修改）+ 在 PR 描述附 `dump`/`verify` 输出。
- Issue（不想动手的话）：用 **Adaptation Request** 模板，附新版本号、原版 SHA-256、`info` 输出。

## 分析工具速查

| 命令 | 用途 |
|---|---|
| `info <exe>` | 指纹/强名称/限制字符串引用统计 |
| `dump <exe> [--str 关键词 \| --method 名字]` | 反汇编相关方法 IL |
| `tokens <exe>` | 打印 v2 依赖的关键元数据 token |
| `verify <orig> <patched>` | 对比两份 exe，输出差异区间 |
