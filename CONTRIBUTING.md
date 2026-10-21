# 贡献指南

感谢参与！这个仓库体量很小，规则也简单：

## 欢迎的贡献

- **新版本适配**：PCL2 发布新版本后，按 [docs/adapt-new-version.md](docs/adapt-new-version.md) 流程验证补丁工具可用性，PR 更新 README 支持版本表（版本号 + 原版 SHA-256）。
- **脚本改进**：兼容性（如老版本 PowerShell）、定位鲁棒性、报错信息更友好。
- **文档**：错别字、补充截图、翻译。

## 不接受的贡献

- ❌ **任何修改后的 exe / 二进制文件**（PR 直接关闭）
- ❌ 绕过正版验证、分发 Minecraft 本体相关的功能
- ❌ 与"恢复下载功能"无关的功能性魔改（本仓库保持单一目的）

## PR 要求

- 脚本改动必须附验证输出（`tools/pcl2_analyze.py verify` 或真机截图）；
- 遵守现有代码风格：所有修改必须**等长替换**、特征校验失败必须中止、写入前必须备份。

## Issue

- Bug：附 PowerShell 版本（`$PSVersionTable.PSVersion`）、完整脚本输出、PCL2 版本号；
- 新版本适配请求：用 Adaptation Request 模板。

## 行为准则

尊重 PCL 原作者与其他社区成员；本仓库不评价原项目决定，只做技术研究。
