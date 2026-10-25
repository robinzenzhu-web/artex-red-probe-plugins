# site-poc Matcher DSL（v0.2.0）

## 能力

| 能力 | 用法 |
|---|---|
| 关键词 AND/OR | `words` + matcher.`condition`=`and`\|`or` |
| 正则 | `type=regex` 或任意类型带 `regex` |
| 作用面 | `part`=`header`\|`body`\|`title`\|`url`\|`tech`\|`server`\|`all` |
| 模板级 OR | template.`condition`=`or`（任一 matcher 命中即报） |
| 取反 | `negative: true` |
| 版本比对 | `type=version` + `op` + `version`；用 `regex` 第 1 捕获组或 `words[0]` 旁自动抽版本 |

## 版本比对

```json
{
  "type": "version",
  "part": "all",
  "words": ["thinkphp"],
  "op": "lt",
  "version": "5.0.24"
}
```

抽取顺序：

1. 若有 `regex` → 用 capture group 1
2. 否则用 `words[0]` 生成 `(?i)word[^\d]{0,24}(\d+(?:\.\d+){0,3})`
3. 再不行 → 全文第一个 dotted version

`op`: `lt|lte|gt|gte|eq|neq`

## 与指纹插件衔接

先跑 `web-fingerprint` 写入 `Technologies`/`Tags`，再用 `type=tech` 或 `version` 做精准 PoC 过滤，减少误报。

## 注意

- 这是**验证器**，不是完整 nuclei DSL（无 HTTP 发包、无 OOB、无 flow）
- 需要主动请求的利用链：用内置 nuclei 或 ARTEX skill 编排
- 真 PoC JSON **不要**进公开仓
