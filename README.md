# Artex-red-probe Plugin Pack（高级版）

面向 **ScopeSentry** 的自研插件集。产品定位：**只做高级版** —— 指纹 + 网站专项 PoC + 内置 nuclei，完整评估链路。

## 架构

```
ARTEX (LLM 编排 / MCP)
    │  create_scan_template / create_scan_task / get_asset_detail
    ▼
ScopeSentry (客户自装或你托管，不随产品分发)
    │  加载插件
    ▼
本仓库插件
    ├── AssetHandle/web-fingerprint   # 52 条规则：server/middleware/CMS/framework/WAF/panel
    └── VulnerabilityScan/site-poc    # 网站专项 PoC（templates 订阅下发）
         + 内置 nuclei                # 通用 CVE
```

## 法律

| 组件 | License | 做法 |
|---|---|---|
| ScopeSentry | 无 LICENSE | 只调用，不复制、不分发 |
| 本仓库 | MIT | 可开源 |
| ARTEX 二开 | AGPL-3.0 | 开源卖服务 |
| PoC JSON 数据 | 不进公开仓 | 订阅下发到 `-templates` |

## 目录

```
AssetHandle/web-fingerprint/
  info.json          v0.2.0
  plugin.go          52 rules
VulnerabilityScan/site-poc/
  info.json
  plugin.go
  templates/         示例 only；真 PoC 订阅下发
docs/
  modules.md
  install.md
  fingerprint-rules.md
```

## 高级版扫描模板（唯一模板）

挂载顺序建议：

1. 目标入口 / 子域 / 端口（官方模块）
2. **web-fingerprint**（本仓库）
3. 目录扫描（可选，官方）
4. **site-poc**（本仓库，`-templates` 指向订阅目录）
5. **内置 nuclei**（通用 CVE）

ARTEX skill 侧配合：全量 26 个技能（含 exploit），开源卖服务下不靠代码裁剪分层。

## 订阅价值

- `site-poc/templates/*.json` 云端下发（不进公开仓）
- 指纹规则持续更新（本仓库开源；商业 SLA 可加速推送）
- 托管 ScopeSentry + ARTEX 实例 + 运维

## 参考

- 官方模板：`Autumn-27/ScopeSentry-Plugin-Template`
- 指纹参考：`plugin/AssetHandle/ehole`
- 漏洞参考：`plugin/VulnerabilityScan/AI-Infra-Guard`
- 内置 nuclei：`ScopeSentry-Scan/modules/vulnerabilityscan/nuclei`

## 订阅包（不进公开仓）

```
subscription-packs/
  web-exposure-v1/
    manifest.json
    README.md
    templates/*.json      5 个真实暴露面 PoC
```

验证记录：2026-10-25 lab fixture **5/5 命中**（git high / actuator medium / jenkins medium / swagger low / phpmyadmin low）。

## Matcher DSL

见 `docs/matcher-dsl.md`（v0.2.0：words OR、regex、version 比对、negative、template-level OR）。

