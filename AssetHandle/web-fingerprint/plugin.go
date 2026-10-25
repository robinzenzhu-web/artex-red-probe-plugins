package plugin

import (
	"fmt"
	"strings"

	"github.com/Autumn-27/ScopeSentry-Scan/internal/options"
	"github.com/Autumn-27/ScopeSentry-Scan/internal/types"
)

func GetName() string  { return "web-fingerprint" }
func Install() error   { return nil }
func Check() error     { return nil }
func Uninstall() error { return nil }

type rule struct {
	tag      string
	category string // server | middleware | lang | framework | cms | panel | waf | cdn
	match    func(h *types.AssetHttp) bool
}

func fold(s string) string { return strings.ToLower(s) }

func hasAny(hay string, needles ...string) bool {
	h := fold(hay)
	for _, n := range needles {
		if strings.Contains(h, fold(n)) {
			return true
		}
	}
	return false
}

// evidence blob: response-side only. Technologies/Tags are deliberately excluded
// because upstream httpx tech-detect false positives (e.g. "java" on an nginx
// welcome page) would otherwise be copied into our tags.
func blob(h *types.AssetHttp) string {
	return strings.Join([]string{
		h.RawHeaders, h.ResponseBody, h.Title, h.WebServer,
	}, "\n")
}

// urlHasExt reports whether the URL path ends with one of exts.
// Substring matching is wrong here: "host.docker.internal" contains ".do".
func urlHasExt(rawURL string, exts ...string) bool {
	u := fold(rawURL)
	if i := strings.IndexAny(u, "?#"); i >= 0 {
		u = u[:i]
	}
	// drop scheme+host, keep path
	if i := strings.Index(u, "://"); i >= 0 {
		rest := u[i+3:]
		if j := strings.IndexByte(rest, '/'); j >= 0 {
			u = rest[j:]
		} else {
			u = ""
		}
	}
	for _, e := range exts {
		if strings.HasSuffix(u, e) || strings.Contains(u, e+"/") {
			return true
		}
	}
	return false
}

var rules = []rule{
	// --- web server ---
	{"nginx", "server", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: nginx") || hasAny(h.WebServer, "nginx")
	}},
	{"apache", "server", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: apache") || hasAny(h.WebServer, "apache")
	}},
	{"iis", "server", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: microsoft-iis") || hasAny(h.WebServer, "iis")
	}},
	{"caddy", "server", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: caddy") || hasAny(h.WebServer, "caddy")
	}},
	{"openresty", "server", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: openresty") || hasAny(h.WebServer, "openresty")
	}},

	// --- middleware ---
	{"tomcat", "middleware", func(h *types.AssetHttp) bool {
		return hasAny(blob(h), "apache tomcat") || hasAny(h.WebServer, "tomcat")
	}},
	{"weblogic", "middleware", func(h *types.AssetHttp) bool {
		return hasAny(blob(h), "weblogic")
	}},
	{"websphere", "middleware", func(h *types.AssetHttp) bool {
		return hasAny(blob(h), "websphere", "ibm http server")
	}},
	{"jboss", "middleware", func(h *types.AssetHttp) bool {
		return hasAny(blob(h), "jboss", "wildfly")
	}},
	{"jetty", "middleware", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: jetty") || hasAny(h.WebServer, "jetty")
	}},

	// --- language / runtime: header or URL evidence only ---
	{"php", "lang", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "x-powered-by: php", "set-cookie: phpsessid") ||
			urlHasExt(h.URL, ".php")
	}},
	{"aspnet", "lang", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "x-powered-by: asp.net", "x-aspnet-version",
			"set-cookie: asp.net_sessionid", "x-aspnetmvc-version")
	}},
	{"java", "lang", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "set-cookie: jsessionid", "x-powered-by: servlet") ||
			urlHasExt(h.URL, ".jsp", ".do", ".action")
	}},
	{"nodejs", "lang", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "x-powered-by: express", "x-powered-by: next.js")
	}},
	{"python", "lang", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: gunicorn", "server: uvicorn", "server: werkzeug")
	}},

	// --- frameworks ---
	{"spring", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "x-application-context") ||
			hasAny(h.ResponseBody, "whitelabel error page")
	}},
	{"thinkphp", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "thinkphp", "think\\") ||
			hasAny(h.RawHeaders, "x-powered-by: thinkphp")
	}},
	{"laravel", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "set-cookie: laravel_session") ||
			hasAny(h.ResponseBody, "laravel")
	}},
	{"django", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "csrftoken") || hasAny(h.ResponseBody, "csrfmiddlewaretoken")
	}},
	{"flask", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "server: werkzeug")
	}},
	{"struts", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "org.apache.struts") ||
			(hasAny(h.URL, ".action", ".do") && hasAny(h.ResponseBody, "struts"))
	}},
	{"shiro", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "set-cookie: rememberme") || hasAny(h.RawHeaders, "deleteme")
	}},
	{"fastjson", "framework", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "fastjson", "com.alibaba.fastjson")
	}},

	// --- CMS ---
	{"wordpress", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "wp-content", "wp-includes")
	}},
	{"discuz", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "discuz", "power by discuz")
	}},
	{"dedecms", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "dedecms", "power by dedecms")
	}},
	{"phpcms", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "phpcms", "power by phpcms")
	}},
	{"empirecms", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "empirecms", "empire cms")
	}},
	{"joomla", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "joomla", "/components/com_")
	}},
	{"drupal", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "sites/default/files") ||
			hasAny(h.RawHeaders, "x-generator: drupal")
	}},
	{"typecho", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "typecho", "powered by typecho")
	}},
	{"zblog", "cms", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "zblog", "zb_system")
	}},

	// --- panels / OA ---
	{"oa-tongda", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "tongda", "通达oa", "office anywhere")
	}},
	{"oa-fanwei", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "ecology", "weaver", "泛微", "wui/")
	}},
	{"oa-seeyon", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "seeyon", "致远")
	}},
	{"oa-yonyou", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "yonyou", "用友")
	}},
	{"oa-kingdee", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "kingdee", "金蝶")
	}},
	{"jenkins", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "x-jenkins") || hasAny(h.ResponseBody, "jenkins")
	}},
	{"grafana", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "grafana")
	}},
	{"nacos", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "nacos")
	}},
	{"apollo", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "apollo-portal", "apollo config")
	}},
	{"swagger", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "swagger-ui", "swagger-ui.html", "openapi")
	}},
	{"phpmyadmin", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "phpmyadmin", "pma_")
	}},
	{"rabbitmq", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "rabbitmq management")
	}},
	{"kibana", "panel", func(h *types.AssetHttp) bool {
		return hasAny(h.ResponseBody, "kibana")
	}},

	// --- WAF / CDN ---
	{"waf-cloudflare", "waf", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "cf-ray", "server: cloudflare") || hasAny(h.CDNName, "cloudflare")
	}},
	{"waf-aliyun", "waf", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "ali-swift-global-savetime", "eagleid") ||
			hasAny(h.CDNName, "aliyun", "alibaba")
	}},
	{"waf-tencent", "waf", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "x-nws-log-uuid") || hasAny(h.CDNName, "tencent")
	}},
	{"waf-huawei", "waf", func(h *types.AssetHttp) bool {
		return hasAny(h.CDNName, "huawei")
	}},
	{"cdn-akamai", "cdn", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "akamai", "x-akamai") || hasAny(h.CDNName, "akamai")
	}},
	{"cdn-fastly", "cdn", func(h *types.AssetHttp) bool {
		return hasAny(h.RawHeaders, "x-served-by", "fastly") || hasAny(h.CDNName, "fastly")
	}},
}

func Execute(input interface{}, op options.PluginOption) (interface{}, error) {
	httpResult, ok := input.(*types.AssetHttp)
	if !ok || httpResult == nil {
		return nil, nil
	}

	found := make([]string, 0, 8)
	cats := make(map[string]int)
	for _, r := range rules {
		if !r.match(httpResult) {
			continue
		}
		if hasTag(httpResult.Tags, r.tag) {
			continue
		}
		httpResult.Tags = append(httpResult.Tags, r.tag)
		found = append(found, r.tag)
		cats[r.category]++
	}

	if len(found) > 0 {
		op.Log(fmt.Sprintf("%s tags=%v cats=%v", httpResult.URL, found, cats))
	}
	return nil, nil
}

func hasTag(tags []string, want string) bool {
	for _, t := range tags {
		if strings.EqualFold(t, want) {
			return true
		}
	}
	return false
}
