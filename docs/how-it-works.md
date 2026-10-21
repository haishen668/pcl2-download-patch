# 逆向分析：2.99.0.0 的下载限制是如何实现的，以及补丁如何定位

本文记录对 PCL2 正式版 2.99.0.0（Build 413，SHA-256 `6b6e1260…e7386`）的完整分析过程。
所有结论均可通过 [`tools/pcl2_analyze.py`](../tools/pcl2_analyze.py) 复现。

## 1. 限制的来源：一个编译期常量

PCL2 官方开源仓库（每次发布时同步正式版代码）中，`Modules/ModSecret.vb:18`：

```vb
Public Const RestrictMcDownload As Boolean = True
```

错误提示语与调用点分布在（开源代码可见处）：

- `PageDownloadInstall.xaml.vb:17` —— 下载页版本列表加载
- `ModModpack.vb:11 / 88` —— 整合包安装入口与安装器
- `PageDownloadModify.vb:315` —— 原版组件卡片 `Visibility`
- `PageDownloadCompDetail.xaml.vb:275` —— 资源页整合包下载按钮
- `FormMain.xaml.vb:1079` —— 拖拽安装整合包的拦截分支

由于是 `Const`，**没有任何运行时开关**：设置、注册表、联网配置、hosts、代理都不起作用。

## 2. 关键事实：Roslyn 的常量折叠改变了补丁思路

朴素的思路是"把 true 改成 false"，但实际反汇编后发现**行不通**：

`RestrictMcDownload` 是编译期常量，VB 编译器（Roslyn）在编译时做了两件事：

1. **分支折叠**：`If RestrictMcDownload Then A Else B` 中 Else 分支被**整体删除**，A 变成无条件执行；
2. **不可达代码消除**：`If RestrictMcDownload Then …Return` 之后的正常逻辑被**整体删除**。

实际后果（以 `PageDownloadInstall::LoaderInit` 为例，源码是 If/Else 二选一）：

```il
IL_0025: ldnull
IL_0026: ldstr       "关闭下载"                       ;; 假加载器名称
IL_002B: ldsfld      0x040009FB                       ;; 缓存的 lambda
IL_0030: brfalse.s   …                                ;; lambda 缓存判空
IL_0039: ldftn       0x06001467                       ;; Sub() Throw New Exception("为遵守…")
IL_0044: newobj      Action ctor
IL_004F: ldnull
IL_0050: ldc.i4.2
IL_0051: newobj      LoaderTask ctor                  ;; New LoaderTask("关闭下载", …)
IL_0056: ldarg.0
IL_0057: ldftn       0x0600061C                       ;; LoadMinecraft_OnFinish
IL_005D: newobj      Action ctor
IL_0062: ldnull / ldc.i4.1
IL_0064: call        PageLoaderInit(…)                ;; Else 分支已不存在
```

"正确的 Else 分支"（`PageLoaderInit(…, DlClientListLoader, …)`）在 exe 里已不存在，但它的替代品一直在那：`ModDownload` 模块的静态字段 `DlClientListLoader`（真实加载器）**本身没有被删**——限制代码只是不再引用它。

## 3. 补丁构造

### 补丁 A：移除 throw（2 处，各 NOP 11 字节）

`ModModpack::ModpackInstall(File)` 中：

```il
IL_02DA: ldstr    "为遵守相关法律法规，PCL 暂时不再提供 MC 下载功能，非常抱歉 qwq……"
IL_02DF: newobj   Exception ctor
IL_02E4: throw
```

字节形态 `72 <US-token> 73 <ctor-token> 7A`，NOP 成 `00 × 11` 后执行流直接落到后续的 `Select Case PackType` 正常安装逻辑。同一形态还出现在给假加载器用的 `_Closure$__::_Lambda$__3-0`（`Sub() Throw …`）中，一并 NOP（对补丁 B 起双保险作用）。

### 补丁 B：假加载器 → 真加载器（48 字节区间）

在 `LoaderInit` 中，把从 `ldstr "关闭下载"` 到 OnFinish 委托构造锚（`02 FE 06` = `ldarg.0; ldftn`）之前的 **48 字节**整体替换：

```il
替换前：ldstr"关闭下载"; …newobj Action; newobj LoaderTask   (48 字节)
替换后：ldsfld <ModDownload.DlClientListLoader> ; nop × 43   (5 + 43 字节)
```

栈语义完全等价：原文在该位置向栈上压入 1 个 `LoaderTask` 引用作为 `PageLoaderInit` 的第 5 参；替换后压入 1 个真实的 `DlClientListLoader` 引用（同类型，同为模块级已初始化的加载器字段）。`ldsfld` 的 token 需要从目标 exe 的 `Field` 元数据表现算——这就是 补丁工具"语义定位"的核心之一。

### 补丁 C：Visible 枚举 1 字节

`PageDownloadModify` 中 `CardMinecraft.Visibility = If(RestrictMcDownload, Visibility.Collapsed, Visibility.Visible)` 折叠为：

```il
ldarg.0; callvirt get_CardMinecraft; ldc.i4.2; callvirt set_Visibility
```

`Visibility.Collapsed == 2`、`Visibility.Visible == 0`，把 `ldc.i4.2 (0x18)` 改为 `ldc.i4.0 (0x16)` 即恢复显示。

### 刻意不动的两处

- `ModpackInstall()`（无参入口）的 `Hint + Return`：其后的文件选择逻辑已被编译器删除，NOP 掉 Hint 也无法恢复功能，保留提示反而能明确告知用户该入口已失效；拖拽安装走的是 `ModpackInstall(File)`，不受影响。
- `FormMain` 拖拽 Catch 中的 `ex.Message = "为遵守…"` 比较：补丁 A 移除上游 throw 后该比较恒为 `false`，自然回落到正常错误处理路径，无需改动。

## 4. 定位方法：为什么补丁能跨版本

.NET 每次重编译都会重新分配元数据 token（字段/方法/字符串的 4 字节编号）与堆偏移，硬编码字节特征只对单一编译产物有效（固定特征版即此设计）。

补丁工具改为**运行时现算**，步骤：

1. 解析 PE → CLI Header → Metadata Root → 定位 `#US`（用户字符串堆）；
2. 在 `#US` 中搜 UTF-16LE 关键串（"为遵守相关法律法规"/"关闭下载"），回退 1~4 字节压缩长度前缀得到 blob 偏移 → 拼出 `ldstr` token（`0x70000000 | offset`），并用 `MetadataReader.GetUserString` 验证回读；
3. 遍历 `Field` / `MethodDef` 表按**名字**取 `DlClientListLoader`、`get_CardMinecraft` 的真实 token；
4. 用这些 token 在文件中搜索并按**指令形态**校验（如 `ldstr` 后必须紧跟 `73 ?? ?? ?? 0A/06 7A` 的 throw 形态），形态不符即拒绝修改——这同时防住了把操作数字节巧合误判为指令的误报（分析中实际遇到过一例：`MONITORINFO::.ctor` 内恰好出现 `72 EB 45 00 70` 字节序列）。

因此对常规重编译（token/偏移全变、代码结构不变）补丁直接可用；只有作者更换话术或限制机制时才需要重新分析。

## 5. 验证方法

- **IL 层**：补丁前后用 `tools/pcl2_analyze.py dump` 反汇编目标方法逐指令比对（栈平衡、跳转目标不变）；
- **字节层**：`verify` 子命令对比补丁前后差异，应恰好 60 字节、分布 4 个区间；
- **等价性**：PowerShell 脚本版与 C# exe 版两套独立实现产出 SHA-256 完全一致的文件；
- **幂等**：对已打补丁文件重跑，脚本应全部报告"已打过"且零写入；
- **签名**：确认 exe 无强名称签名（`CLR_STRONGNAMESIGNED=False`），字节修改不会触发运行时校验。

## 6. 安全边界

- 补丁**必须**等长替换（不改变任何 RVA/偏移）；
- 特征命中数超出预期**必须**中止；
- 写入前**必须**保留 `.bak` 备份；
- 分发的只有脚本，没有二进制。
