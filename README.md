# PCL2 Download Patch

> 恢复 [PCL2（Plain Craft Launcher 2）](https://github.com/Meloong-Git/PCL) 2.99.0.0 中被移除的 Minecraft 下载功能的**用户侧补丁工具**。
> 单文件 PowerShell 脚本 · 零依赖 · 自动备份 · 幂等可重跑

**English TL;DR:** A single-file PowerShell patcher that restores the Minecraft download feature removed in PCL2 2.99.0.0 ("为遵守相关法律法规…"). It byte-patches the IL of your **own** copy of the official exe — this repo distributes **no modified binaries**, only the patch script. See [docs/how-it-works.md](docs/how-it-works.md) for the full reverse-engineering write-up.

---

## ⚠️ 免责声明（请先读）

- 本项目仅用于**技术研究与学习目的**（.NET IL 补丁方法论的完整实例），并供用户对**自己设备上已合法获取的软件副本**自行处置。
- 本项目**不分发** PCL 本体、修改后的 exe 或任何 Minecraft 游戏文件；不绕过任何正版验证；脚本产生的修改仅保存在用户本机。
- PCL 原项目采用[《PCL 分发有限许可》](https://github.com/Meloong-Git/PCL)，其许可不允许随意再分发——因此**请勿把补丁后的 exe 发给别人**，让对方自行打补丁。
- 使用本工具恢复的功能由使用者自行承担合规责任；如果所在地区法规不允许，请勿使用。
- 请尊重 PCL 作者的决定。作者在 2.99.0.0 中移除下载功能是主动合规行为，本工具与 PCL 作者及其项目**无任何关联**。

## 背景

2026-10-20，PCL2 发布 2.99.0.0（Build 413），更新日志第一条：

> 删除：为遵守相关法律法规，PCL 暂时不再提供 MC 下载功能，非常抱歉 qwq……

同日 [HMCL](https://github.com/HMCL-dev/HMCL)（3.17.0.362 预览版）与 [PCL-CE](https://github.com/PCL-Community/PCL-CE)（2.15.1）也相继禁用了中国大陆地区的游戏下载/安装功能（[事件报道](https://www.nexusmc.cn/forum/post/pcl-hmcl-pcl-ce)）。

限制在代码中是一个编译期常量 `RestrictMcDownload = True`（`Modules/ModSecret.vb`），并**没有**设置开关或配置项，因此换下载源、换网络、改 hosts 均无效。受影响范围：

| 功能 | 状态 |
|---|---|
| 下载页安装原版 MC | ❌ 版本列表直接抛异常 |
| 拖拽 zip 安装整合包 | ❌ 被拦截 |
| 资源页下载整合包 | ❌ 按钮隐藏 |
| 版本设置中添加/升级原版组件 | ❌ 卡片隐藏 |
| 启动已安装版本 / Mod、资源包下载 | ✅ 未受影响 |

## 使用方法

### 前置

- Windows 10 1803+（自带 PowerShell 5.1 / .NET 4.7.2+）或 PowerShell 7
- PCL2 **正式版 2.99.0.0**（别的版本见下方"支持版本"）

### 打补丁

1. 下载 [`src/PCL2-RestoreDownload-v2.ps1`](src/PCL2-RestoreDownload-v2.ps1)（或从 [Releases](../../releases) 获取）
2. 把脚本复制到 PCL 目录（与 `Plain Craft Launcher 2.exe` 同级）
3. **关闭 PCL**，然后右键脚本 → **"使用 PowerShell 运行"**，或：

```powershell
powershell -ExecutionPolicy Bypass -File .\PCL2-RestoreDownload-v2.ps1
```

4. 看到 `完成！` 即可。原文件自动备份为 `.bak`。

脚本输出示例：

```
== PCL2 恢复下载补丁 v2 (语义版) ==
正在解析元数据……
  DlClientListLoader = 0x0400040F, get_CardMinecraft = 0x06000571
[√] 补丁A: 移除 throw/拦截 块 (2 处)
[√] 补丁B: 下载页假加载器已替换为 DlClientListLoader (区间 48 字节)
[√] 补丁C: 组件卡片 Collapsed → Visible
已备份 → ...\.bak
```

### 还原

删除 exe，把 `.bak` 改回原名即可。

## 补丁做了什么

共修改 **60 个字节**，文件大小不变。全程只改用户自己的 exe 副本，详见 [docs/how-it-works.md](docs/how-it-works.md)。

| 补丁 | 位置 | 改法 |
|---|---|---|
| A | `ModModpack::ModpackInstall(File)` 及其 lambda | NOP 掉无条件的 `throw New Exception("为遵守…")` 块（各 11 字节） |
| B | `PageDownloadInstall::LoaderInit` | 把假加载器 `New LoaderTask("关闭下载", Sub() Throw …)` 的构造区间（48 字节）替换为 `ldsfld DlClientListLoader`（真正的版本列表加载器） |
| C | `PageDownloadModify` | `CardMinecraft.Visibility` 的 `Collapsed(2)` 改 `Visible(0)`（1 字节） |

由于 `RestrictMcDownload` 是编译期常量，Roslyn 在编译时已把受影响方法的正常分支**整体删除**（例如 `ModpackInstall()` 无参入口的文件选择逻辑在正式版 exe 中已不存在），因此以下两处**无法**通过补丁恢复，属已知限制：

- 启动器内的"选择文件安装整合包"按钮入口（但**拖拽 zip 到窗口安装不受影响**）
- 资源页整合包条目的"下载"按钮（"保存"按钮仍在，保存后可拖拽安装）

## 支持版本

| PCL2 版本 | v2（语义版） | v1（固定特征版） |
|---|---|---|
| 2.99.0.0 (Build 413) | ✅ 已验证 | ✅ 已验证 |
| 更新版本 | 🔄 通常直接可用¹ | ❌ |
| 旧版本（≤2.14） | 无需补丁（无此限制） | 无需补丁 |

¹ v2 不硬编码任何元数据编号，运行时解析 .NET 元数据动态定位补丁点，对常规重编译免疫。若作者更换限制话术或实现方式，脚本会安全退出并提示"未找到标记"，此时请[提交适配请求](../../issues/new?template=adaptation_request.md)。

**文件校验（2.99.0.0 正式版）**

| 文件 | SHA-256 |
|---|---|
| 原版 `Plain Craft Launcher 2.exe` (5,980,160 B) | `6b6e1260cb5a1d6a303855f1c60cab3d0bc1aebba7e40a964180188b271e7386` |
| 补丁后（v1 与 v2 产物一致） | `0b7034b1c94f47dd794592c305e567f04e08e2fd21756052c26123013feccf2e` |

## 为什么不直接发布改好的 exe？

1. PCL 的[分发许可](https://github.com/Meloong-Git/PCL)不允许再分发其程序；
2. 分发"现成恢复版"是最近[已出现的中毒重灾区](https://www.nexusmc.cn/forum/post/pcl-hmcl-pcl-ce)——本仓库只发布**可审计的短脚本**，几十行就能读完，没有二进制黑箱。

## FAQ

**Q: 杀毒软件报毒？**
脚本只对 exe 做等长字节替换且自动备份；写 exe 的行为本身可能触发启发式告警，属误报。不放心可先通读脚本（v2 约 200 行）。

**Q: PCL 更新后又失效了？**
更新会覆盖 exe，重跑一次 v2 脚本即可（幂等，重复运行安全）。

**Q: 我不想打补丁，有别的办法吗？**
有：① 用 [HMCL](https://hmcl.huangyuhui.net/) / 官方启动器等装好游戏，再用 PCL2 启动（启动功能未受限）；② 回退 PCL 2.14.0.0 等旧版；③ 参考 [官方开源代码](https://github.com/Meloong-Git/PCL) 自行编译（`ModSecret.vb` 中 `RestrictMcDownload` 改为 `False`）。

**Q: patch 后 PCL 还能自动更新吗？**
可以，但更新会覆盖补丁，需要重跑脚本。

## 文档

- [逆向分析：限制是如何实现的、补丁如何定位（how-it-works.md）](docs/how-it-works.md)
- [新版本适配指南（adapt-new-version.md）](docs/adapt-new-version.md)
- [分析工具 `tools/pcl2_analyze.py` 用法](tools/)

## 贡献

欢迎通过 PR / Issue 改进脚本与文档、提交新版本适配。**不接受**任何形式的修改后二进制。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可

本仓库的脚本与文档以 [MIT License](LICENSE) 发布。PCL2 为其原作者所有，与本仓库无关联。

## 致谢与相关项目

- [Meloong-Git/PCL](https://github.com/Meloong-Git/PCL) —— PCL2 官方开源代码（本项目的逆向基础）
- [PCL-Community/PCL-CE](https://github.com/PCL-Community/PCL-CE) —— 社区版
- [HMCL](https://github.com/HMCL-dev/HMCL) —— 同事件中同样调整的启动器
- [NexusMC 事件报道](https://www.nexusmc.cn/forum/post/pcl-hmcl-pcl-ce)
