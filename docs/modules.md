# 模块映射（高级版）

## ScopeSentry 流水线

| module | 作用 | 本产品 |
|---|---|---|
| TargetHandler / SubdomainScan / PortScan | 入口与存活 | 官方模块 |
| AssetHandle | 指纹 | **web-fingerprint**（52 rules） |
| DirScan | 目录 | 官方（可选） |
| VulnerabilityScan | 漏洞 | **site-poc** + **内置 nuclei** |

## 产品文案对照（高级版）

| 文案 | 实现 |
|---|---|
| 指纹识别 / 存活验证 | web-fingerprint + 官方存活/端口 |
| 网站专项 PoC | site-poc（订阅 templates） |
| 通用 CVE | 内置 nuclei |
| 命中后输出验证结果 | VulnResult → get_asset_detail → ARTEX finding |
| 全套技能包 | ARTEX skills/ 26 个（编排层） |

## 两层不要混

1. ARTEX skills（markdown）—— 教 LLM 何时调工具 / 写报告
2. ScopeSentry plugins（Go）—— 真正跑指纹 / PoC

PoC 库放第 2 层；skills 里的 `nuclei-scan.md` / `web-fingerprint.md` 只做编排说明。
