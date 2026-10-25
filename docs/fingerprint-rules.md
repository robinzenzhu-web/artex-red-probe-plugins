# 指纹规则清单（v0.2.0）

来源：自研规则表（dsh `web-fingerprint.md` 仅有方法论无规则表，规则在本仓库落地）。

| category | tags |
|---|---|
| server | nginx, apache, iis, caddy, openresty |
| middleware | tomcat, weblogic, websphere, jboss, jetty |
| lang | php, aspnet, java, nodejs, python |
| framework | spring, thinkphp, laravel, django, flask, struts, shiro, fastjson |
| cms | wordpress, discuz, dedecms, phpcms, empirecms, joomla, drupal, typecho, zblog |
| panel | oa-tongda, oa-fanwei, oa-seeyon, oa-yonyou, oa-kingdee, jenkins, grafana, nacos, apollo, swagger, phpmyadmin, rabbitmq, kibana, apollo-admin |
| waf / cdn | waf-cloudflare, waf-aliyun, waf-tencent, waf-huawei, cdn-akamai, cdn-fastly |

合计 **52** 条。命中后写入 `Tags` + `Technologies`，供 ScopeSentry UI / ARTEX `get_asset_detail` 同步。

## 与 PoC 的衔接

指纹 tag 是 site-poc / nuclei 的前置特征。例如命中 `thinkphp` 后，agent 或扫描模板应优先跑 thinkphp 相关 PoC。
