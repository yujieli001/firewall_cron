#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
get_dns.py —— 访问 URL 列表, 记录访问全过程中涉及的全部域名 / IP

与"在网页源码里正则搜一遍域名"的做法不同, 本脚本直接在 socket 层挂钩
(socket.getaddrinfo / socket.connect), 凡是访问过程中真实发起过的 DNS
解析、真实建立过的连接, 全部记录:

  * 重定向链上每一跳的域名及其解析到的全部 A / AAAA 地址
  * 页面引用的 JS / CSS / 图片 / iframe / 字体 / preconnect 等资源域名
    —— 对每个引用真实发起连接, DNS 由内核解析器真实发生, 而非文本猜测
  * 外部 CSS 里 url() / @import 引用的域名
  * JS 与内联脚本里的 URL 字面量(第三方 SDK 常内嵌自家服务域名), 以及
    "https://前缀."+变量+".后缀" 拼接模板的区域名候选重建 —— 命中候选
    会真实发起请求, 解析失败的候选不进结果
  * 抓子资源时带 Referer(模拟浏览器), 避免 CDN 防盗链 403

输入格式(脚本顶部 URLS 硬编码), 条目两种写法:
  "https://example.com"                            # 无需登录
  ["https://example.com", "用户名", "密码"]          # 需要登录
带登录凭据的条目:
  * 先用匿名会话完整收集一遍, 再尝试通用表单登录, 成功后用登录会话
    再收集一遍(登录态页面常会多出用户头像 / 推送等专属域名)
  * URLS 中后面的条目命中同一站点域名时, 自动复用该登录会话;
    因此登录条目要写在同站其它条目之前
  * 登录是通用识别: 在首页(或常见登录路径页)找含 <input type=password>
    的表单, 填用户名密码 POST; 需要短信/图形验证码的站无法自动登录

IP 收录规则:
  域名解析得到的 IP 不收录 —— 该域名本身已进列表, 且 IP 随 DNS 漂移,
  按域名放行更可靠; 只收录"直接以 IP 访问"的地址(IP 字面量 URL)。

已知边界(脚本不是浏览器, 不会执行 JavaScript):
  * JS 运行时用变量拼接的域名只能靠模板+区域候选猜测命中一部分,
    拼接逻辑特殊的仍可能漏
  * <a> 超链接不跟踪 —— 浏览器不会自动请求它, 跟踪就把脚本变成了整站爬虫

用法:
  1. 把目标 URL 填进下方 URLS 硬编码列表
  2. python3 get_dns.py

输出: 默认写脚本同目录 dns.txt (IPv4、IPv6、域名三组各自排序去重, 原子替换)。
结果为空时保留旧文件不覆盖, 防止把防火墙白名单输入洗成空。
"""

import argparse
import http.cookiejar
import ipaddress
import os
import re
import socket
import ssl
import sys
import threading
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from urllib.parse import urljoin, urldefrag, urlparse, urlencode, quote
from urllib.request import (HTTPCookieProcessor, HTTPSHandler, ProxyHandler,
                            HTTPError, Request, build_opener)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ====================================================================
# 目标 URL 列表（硬编码，一行一个，按需增删）
#   无需登录:  "URL"
#   需要登录:  ["URL", "用户名", "密码"]
#     —— 该条目先匿名收集一遍, 表单登录成功后再用登录态收集一遍;
#        后面命中同一站点域名的条目会自动使用登录态(登录条目写在前面)
#   不带 scheme 的条目按 https 优先、失败自动退 http 尝试
# ====================================================================

URLS = (
    ["http://www.acwing.com", "yujieli", "nbyg2004"],
    "https://www.acwing.com/activity",
    "https://www.acwing.com/activity/content/32",
    "https://www.acwing.com/file_system/file/content/whole/index/content/1297182",
    ["https://www.luogu.com.cn","yujieli","nbyg2004"],
    "https://www.luogu.com.cn/problem/list",
    "https://www.luogu.com.cn/problem/P1002",
    "https://www.luogu.com.cn/user/mine/training",
    "https://www.luogu.com.cn/user/100928",
    "https://www.luogu.com.cn/discuss?forum=miaomiaowu",
    ["https://vjudge.net","lzh000","nbyg2004"],
    "https://vjudge.net/contest",
    "https://vjudge.net/workbook",
    "https://vjudge.net/article/5268",
    ["https://oj.wlhcode.com","lyj","nbyg2004"],
    "https://www.wlhcode.com",
    ["https://www.mxoj.net/", "lizhenghan", "123456"],
    ["https://www.iai.sh.cn","yujieli","nbyg2004"],
    "https://codeforces.com",
    "https://codeforces.com/problemset",
    "https://codeforces.com/problemset/problem/2276/G",
    ["https://cspsjtest.noi.cn/","yujieli","nbyg2004"],
    ["https://gesp.ccf.org.cn","李玉杰","nbyg2004"],
    "https://www.lanqiaoqingshao.cn",
    "https://www.zhixue.com/login.html",
    ["https://atcoder.jp","yujieli","nbyg2004"],
    "https://atcoder.jp/contests/arc233",
    "https://atcoder.jp/ranking",
)

HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
}

HTML_CTYPES = {"text/html", "application/xhtml+xml"}
CSS_CTYPES = {"text/css"}
JS_CTYPES = {"text/javascript", "application/javascript", "application/x-javascript",
             "text/ecmascript", "application/ecmascript"}
# 服务器没声明类型时嗅探前几个字节, 防止把 HTML 页当二进制漏掉引用
SNIFF_CTYPES = {"", "application/octet-stream"}

# JS 里的完整 URL 字面量(第三方 SDK 常内嵌自己服务的域名)
JS_URL_RE = re.compile(
    r"""https?://([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"""
    r"""(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)(?::\d{1,5})?""")
# JS 字符串里的协议相对 URL("//wx2.sinaimg.cn/large/x.jpg"), 微博系 JS 的
# 标准写法, 不带 scheme 所以 JS_URL_RE 全部漏掉。要求前面紧贴引号/括号且
# 主机后有斜杠, 避开行注释与普通 // 文本; 协议按当前主流按 https 抓取
JS_PROTO_REL_RE = re.compile(
    r"""["'`(](//[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"""
    r"""(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+)(?::\d{1,5})?/""")
# 运行时拼接的 URL 模板, 如 minify 后的 "https://vod."+e.region+".aliyuncs.com/?"
# (后缀引号串允许带路径/查询部分, 装配主机名时取到第一个 /?# 前)
JS_CONCAT_RE = re.compile(
    r"""["'](https?://[A-Za-z0-9.:/_-]*?)["']\s*\+\s*[A-Za-z_$][\w$.]*"""
    r"""\s*\+\s*["'](\.[A-Za-z0-9][A-Za-z0-9.-]*(?:[/?#][^"']*)?)["']""")
# 拼接模板的候选中间段: 云厂商区域名样式(cn-shanghai/ap-southeast-1/us-gov-west-1),
# 不用宽松连字符词 —— 避免把 CSS 类名(tip-text 等)当候选白耗 DNS
REGION_RE = re.compile(
    r"""["']((?:cn|ap|us|eu|me|sa|na|rus|af|co)(?:-[a-z0-9]+){1,3})["']""")
# TLD 必须纯字母才算主机(排除版本号 1.2.3.4 之类); 长度限 2-6,
# 挡掉 cdn.example 这种伪 TLD(真实 TLD 最长 travel/museum=6)
JS_HOST_TLD_RE = re.compile(r"\.[A-Za-z]{2,6}$")
# JS/HTML 源码里的 XML 命名空间、许可协议、规范文档 URI —— 只是标识符,
# 浏览器从不请求它们, 收录只会污染白名单
NON_RESOURCE_HOSTS = ("w3.org", "xml.org", "purl.org", "schema.org",
                      "creativecommons.org", "opensource.org", "iana.org",
                      "example.com", "example.org", "ogp.me", "foo.bar")

# 首页没带登录表单时依次探测的常见登录路径
LOGIN_PATHS = ("/login", "/login/", "/login.html", "/login.php", "/signin",
               "/sign_in", "/users/sign_in", "/account/login", "/user/login/",
               "/member/login", "/member/login.php", "/account/signin")
USER_FIELD_RE = re.compile(r"user|login|acct|account|email|mail|phone|mobile|uname", re.I)
LOGIN_OK_RE = re.compile(r"退出|注销|登出|logout|ログアウト", re.I)
LOGIN_FAIL_RE = re.compile(
    r"密码.{0,6}(错误|不正确)|用户名或密码|验证码|incorrect|invalid\s+(?:login|password|credential)",
    re.I)
# 两段的二级公域后缀, 判断"站点域名"时这些要取三段
TWO_PART_SUFFIXES = {"com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
                     "co.uk", "org.uk", "co.jp", "or.jp", "com.hk", "com.tw",
                     "com.br", "co.kr", "com.au", "com.sg", "com.my", "co.za"}


def site_key(url):
    """URL -> 站点域名(近似注册域), 登录会话按它匹配复用。"""
    host = (urlparse(url).hostname or "").strip(".").lower()
    labels = host.split(".")
    if len(labels) >= 3 and ".".join(labels[-2:]) in TWO_PART_SUFFIXES:
        return ".".join(labels[-3:])
    return ".".join(labels[-2:]) if len(labels) >= 2 else host


# ====================================================================
# socket 层钩子: 记录真实发生的 DNS 解析与连接
# ====================================================================

_lock = threading.Lock()
domains = set()        # 成功解析过的域名
resolved_ips = set()   # 由域名解析得到的 IP —— 按规则输出时剔除
direct_ips = set()     # 直接以 IP 访问的地址 —— 输出只保留这类


def _tracked_getaddrinfo(*args, **kwargs):
    # 先解析、成功才记录: 解析失败的主机没参与本次访问, 对防火墙也无意义
    result = _orig_getaddrinfo(*args, **kwargs)
    host = args[0] if args else kwargs.get("host")
    if isinstance(host, bytes):
        host = host.decode("utf-8", "ignore")
    host = str(host or "").strip().strip(".").lower()
    with _lock:
        literal = None
        if host and not host.startswith("*"):
            try:
                literal = str(ipaddress.ip_address(host))  # IP 字面量 URL
            except ValueError:
                domains.add(host)
        for item in result:
            addr = item[4][0]
            if isinstance(addr, bytes):
                addr = addr.decode("utf-8", "ignore")
            try:
                # 去掉 IPv6 的 %zone 后缀再规范化
                ip = str(ipaddress.ip_address(str(addr).split("%")[0]))
            except ValueError:
                continue
            (direct_ips if literal else resolved_ips).add(ip)
    return result


_orig_connect = socket.socket.connect


def _tracked_connect(self, address):
    # 兜底: 记录实际建立连接的地址(含不走 getaddrinfo 的直连 IP 场景);
    # 由域名解析而来者, 输出时按 resolved_ips 剔除
    if isinstance(address, tuple) and address and isinstance(address[0], (str, bytes)):
        raw = address[0]
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8", "ignore")
        try:
            ip = str(ipaddress.ip_address(str(raw).split("%")[0]))
        except ValueError:
            ip = None
        if ip:
            with _lock:
                direct_ips.add(ip)
    return _orig_connect(self, address)


_orig_getaddrinfo = socket.getaddrinfo


def install_hooks():
    socket.getaddrinfo = _tracked_getaddrinfo
    socket.socket.connect = _tracked_connect


# ====================================================================
# 从 HTML / CSS 中提取浏览器会自动加载的资源引用(仅作抓取清单,
# DNS 与 IP 仍以真实连接时的钩子记录为准)
# ====================================================================

CSS_URL_RE = re.compile(r"""url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s'"]+))\s*\)""", re.I)
CSS_IMPORT_RE = re.compile(r"""@import\s+['"]([^'"]+)['"]""", re.I)
META_REFRESH_RE = re.compile(r"""^\s*\d+\s*;\s*url\s*=\s*['"]?(.+?)['"]?\s*$""", re.I | re.S)

# 浏览器加载页面时会自动发起请求的 标签 → 属性 清单;
# <a>/<form> 不在其中 —— 浏览器不会自动请求, 跟踪等于整站爬虫
AUTOLOAD = {
    "script": ("src", "data-src"),
    "img": ("src", "srcset", "data-src", "data-original"),
    "iframe": ("src", "data-src"),
    "frame": ("src",),
    "link": ("href",),          # stylesheet/preconnect/prefetch/manifest/icon...
    "embed": ("src",),
    "source": ("src", "srcset"),
    "video": ("src", "poster", "data-src"),
    "audio": ("src",),
    "track": ("src",),
    "input": ("src",),
    "object": ("data",),
    "image": ("xlink:href",),   # svg
}
SRCSET_ATTRS = {"srcset", "data-srcset"}
SKIP_PREFIXES = ("data:", "javascript:", "mailto:", "tel:", "blob:",
                 "about:", "file:", "chrome", "{", "@")


def resolve_url(base, raw):
    """把页面里的相对引用解析成绝对 http(s) URL, 非 http(s) 返回 None。"""
    raw = (raw or "").strip().strip("\"'").strip()
    if not raw or raw.startswith(SKIP_PREFIXES):
        return None
    try:
        url = urldefrag(urljoin(base, raw))[0]
        parts = urlparse(url)
    except ValueError:
        return None
    if parts.scheme in ("http", "https") and parts.netloc:
        return url
    return None


def _expand_srcset(value):
    # srcset 形如 "a.png 1x, b.png 2x"; URL 含逗号的极端写法会漏, 可接受
    for entry in value.split(","):
        cand = entry.strip().split()[0] if entry.strip() else ""
        url = resolve_url(None, cand)
        if url:
            yield url


class LinkExtractor(HTMLParser):

    def __init__(self, base_url):
        super().__init__(convert_charrefs=True)
        self.base = base_url
        self.urls = set()
        self._in_style = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "base" and a.get("href"):
            self.base = urljoin(self.base, a["href"])
        if tag == "style":
            self._in_style = True
        for name in AUTOLOAD.get(tag, ()):
            value = a.get(name)
            if not value:
                continue
            if name in SRCSET_ATTRS:
                self.urls.update(_expand_srcset(value))
            else:
                url = resolve_url(self.base, value)
                if url:
                    self.urls.add(url)
        style = a.get("style")
        if style:
            self._add_css(style)
        if tag == "meta" and (a.get("http-equiv") or "").strip().lower() == "refresh":
            m = META_REFRESH_RE.match(a.get("content") or "")
            if m:
                url = resolve_url(self.base, m.group(1))
                if url:
                    self.urls.add(url)

    def handle_endtag(self, tag):
        if tag == "style":
            self._in_style = False

    def handle_data(self, data):
        if self._in_style and data:
            self._add_css(data)

    def _add_css(self, text):
        self.urls.update(extract_from_css(text, self.base))


def extract_from_css(text, base):
    urls = set()
    for m in CSS_URL_RE.finditer(text):
        url = resolve_url(base, m.group(1) or m.group(2) or m.group(3) or "")
        if url:
            urls.add(url)
    for m in CSS_IMPORT_RE.finditer(text):
        url = resolve_url(base, m.group(1))
        if url:
            urls.add(url)
    return urls


def extract_from_html(html_text, base_url):
    parser = LinkExtractor(base_url)
    try:
        parser.feed(html_text)
        parser.close()
    except Exception:
        pass  # 残缺 / 畸形 HTML 尽力而为
    return parser.urls


def _js_host_ok(host):
    """JS 提取出的主机名粗校验: 排除 IP 样串、非资源 URI、异常长度。"""
    if not host or len(host) > 253 or ".." in host:
        return False
    if not JS_HOST_TLD_RE.search(host):
        return False  # TLD 必须纯字母(排除 1.2.3.4 之类版本号)
    return not any(host == s or host.endswith("." + s) for s in NON_RESOURCE_HOSTS)


def extract_from_js(text):
    """从 JS(及 HTML 内联脚本)提取域名, 只请求 scheme://host/ 根路径:

    * 完整 URL 字面量 —— 第三方 SDK 常内嵌自家服务域名(videocloud.cn-hangzhou
      .log.aliyuncs.com 等即来自阿里云播放器/上传 SDK)
    * 拼接模板 "https://前缀." + 变量 + ".后缀" —— 用同文件中出现的区域名样式
      字符串(cn-shanghai 等)猜测中间段重建候选; 猜错的候选 DNS 解析失败,
      不会进入结果, 只多一次查询(阿里云播放器 vod.<region>.aliyuncs.com
      即由此命中)
    """
    hosts = set()
    for m in JS_URL_RE.finditer(text):
        host = m.group(1).lower()
        if _js_host_ok(host):
            hosts.add((m.group(0).split("://")[0], host))
    for m in JS_PROTO_REL_RE.finditer(text):
        host = m.group(1)[2:].lower()          # 去掉开头的 //
        if _js_host_ok(host):
            hosts.add(("https", host))
    templates = JS_CONCAT_RE.findall(text)
    if templates:
        regions = set(REGION_RE.findall(text))
        # locale 之类大写区域在 JS 里常见小写形态, 一并兜进候选
        regions |= {r.lower() for r in regions}
        for r in sorted(regions)[:30]:
            for prefix, suffix in templates[:10]:
                scheme, _, rest = prefix.partition("://")
                # 后缀串可能带路径/查询(".aliyuncs.com/?"), 只取主机名部分
                suffix = re.split(r"[/?#]", suffix, 1)[0]
                host = (rest + r + suffix).strip(".").lower()
                if _js_host_ok(host):
                    hosts.add((scheme, host))
    return {f"{scheme}://{host}/" for scheme, host in hosts}


# ====================================================================
# 会话管理: 匿名一个总会话, 登录过的站每个一份独立 cookie 会话
# ====================================================================

class State:

    def __init__(self, args):
        self.args = args
        self.done = 0
        self.ctx = ssl.create_default_context()
        self.ctx.check_hostname = False
        self.ctx.verify_mode = ssl.CERT_NONE  # 收集白名单用, 证书失败不该阻碍记录
        self.anon = self.make_opener()
        self.logins = {}  # 站点域名 -> 登录后的 opener
        # 完成完整尝试(https+http 兜底)仍连接层失败的主机; 同主机后续 URL
        # 不再浪费超时直接跳过。只由连接层失败(超时/拒绝/DNS 失败/代理不可达)
        # 进入, HTTP 4xx/5xx 与读取中断都不算不可达
        self.dead_hosts = set()

    def make_opener(self):
        # 默认禁用系统代理: 目标域名解析与连接都在本地真实发生, 钩子才记到。
        # 显式传 --proxy 时改用该代理(用于直连被墙的站), 此时目标域名不经本地
        # 解析, 由 fetch_one 里"经代理发起请求"这一事实显式收录(见 proxy_record)
        proxies = {} if not self.args.proxy else {
            "http": self.args.proxy, "https": self.args.proxy}
        return build_opener(
            ProxyHandler(proxies),
            HTTPSHandler(context=self.ctx),
            HTTPCookieProcessor(http.cookiejar.CookieJar()),
        )

    def opener_for(self, url):
        """按 URL 站点域名选会话: 登录过的站用登录会话, 否则匿名。"""
        return self.logins.get(site_key(url)) or self.anon


# ====================================================================
# 通用表单登录
# ====================================================================

class LoginFormFinder(HTMLParser):
    """收集页面中含 <input type=password> 的表单(action/method/inputs)。"""

    def __init__(self, base_url):
        super().__init__(convert_charrefs=True)
        self.base = base_url
        self.forms = []
        self._cur = None

    def handle_starttag(self, tag, attrs):
        if tag == "form" and self._cur is None:
            a = dict(attrs)
            self._cur = {"action": a.get("action") or self.base,
                         "method": (a.get("method") or "GET").lower(),
                         "inputs": []}
        elif tag == "input" and self._cur is not None:
            a = dict(attrs)
            self._cur["inputs"].append(((a.get("name") or "").strip(),
                                        (a.get("type") or "text").strip().lower(),
                                        a.get("value") or ""))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag == "form" and self._cur is not None:
            if any(t == "password" for _, t, _ in self._cur["inputs"]):
                self.forms.append(self._cur)
            self._cur = None


def find_login_form(html, page_url):
    """找页面里可提交用户名密码的表单; 只认同站提交的, 没有返回 None。"""
    finder = LoginFormFinder(page_url)
    try:
        finder.feed(html)
        finder.close()
    except Exception:
        pass
    host = urlparse(page_url).hostname or ""
    same_site = [f for f in finder.forms
                 if (urlparse(urljoin(page_url, f["action"])).hostname or "") == host]
    pool = same_site or finder.forms
    return pool[0] if pool else None


def read_text(resp, max_bytes):
    try:
        body = resp.read(max_bytes)
    except Exception:
        return ""
    enc = resp.headers.get_content_charset() or "utf-8"
    try:
        return body.decode(enc, errors="replace")
    except LookupError:
        return body.decode("utf-8", errors="replace")


def login_site(state, start_url, username, password):
    """通用表单登录。返回 (status, opener, note), status ∈ ok/unknown/fail。

    流程: 首页(及常见登录路径)找含 password 输入框的表单 → 保留 csrf 等
    hidden 字段原值、按字段名识别用户名框 → 带 Referer 提交 → 按页面特征
    判断成败。只支持用户名+密码表单; 短信/图形验证码站无法自动登录。
    """
    opener = state.make_opener()
    login_host = (urlparse(start_url).hostname or "").strip(".").lower()
    with _lock:
        if login_host and login_host in state.dead_hosts:
            # 匿名收集遍已把该主机判死, 登录探测必然同样超时, 直接放弃
            return "fail", None, "站点已判定不可达, 跳过登录"
    page_url, form = None, None
    for cand in [start_url] + [urljoin(start_url, p) for p in LOGIN_PATHS]:
        try:
            resp = opener.open(Request(cand, headers=HEADERS),
                               timeout=state.args.timeout)
        except HTTPError as exc:
            resp = exc
        except Exception:
            # 候选路径全在同一主机上, 连接层失败一次即判死并放弃整个探测
            with _lock:
                if login_host:
                    state.dead_hosts.add(login_host)
            break
        with resp:
            html = read_text(resp, state.args.max_bytes)
        form = find_login_form(html, resp.geturl())
        if form is not None:
            page_url = resp.geturl()
            break
    if form is None:
        return "fail", None, "首页与常见登录路径都没找到含密码框的表单"

    action = urljoin(page_url, form["action"]) or page_url
    fields, filled = {}, False
    for name, typ, val in form["inputs"]:
        if not name or typ in ("submit", "button", "image", "reset", "file"):
            continue
        if typ == "password":
            fields[name] = password
        elif typ == "hidden":
            if val:
                fields[name] = val              # csrf token 等原值必须保留
        elif typ in ("checkbox", "radio"):
            continue
        elif not filled and not val and USER_FIELD_RE.search(name):
            fields[name] = username
            filled = True
        elif val:
            fields[name] = val
    if not filled:
        # 字段名没匹配上时, 取第一个空的文本类输入框当用户名框
        for name, typ, val in form["inputs"]:
            if name and not val and typ in ("text", "email", "tel", "number", "url", ""):
                fields[name] = username
                filled = True
                break
    if not filled:
        return "fail", None, "表单里没能识别出用户名输入框"

    # 像浏览器一样提交: 带表单页 Referer(也过 Django csrf 的 Referer 检查),
    # 前面 GET 收到的会话 cookie(csrf cookie 等)已在 opener 的 cookie jar 里
    headers = dict(HEADERS, Referer=page_url)
    query = urlencode(fields)
    try:
        if form["method"] == "get":
            sep = "&" if "?" in action else "?"
            resp = opener.open(Request(action + sep + query, headers=headers),
                               timeout=state.args.timeout)
        else:
            resp = opener.open(Request(action, data=query.encode("utf-8"),
                                       headers=headers), timeout=state.args.timeout)
    except HTTPError as exc:
        resp = exc
    except Exception as exc:
        return "fail", None, f"登录请求异常 {type(exc).__name__}"
    with resp:
        final_html = read_text(resp, state.args.max_bytes)
    if LOGIN_FAIL_RE.search(final_html):
        return "fail", opener, "页面提示密码错误/需要验证码"
    if LOGIN_OK_RE.search(final_html):
        return "ok", opener, ""
    # POST 落点常是跳转中间页, 登录态特征未必在其中; 用同一会话回首页再验
    try:
        resp2 = opener.open(Request(start_url, headers=HEADERS),
                            timeout=state.args.timeout)
        with resp2:
            home_html = read_text(resp2, state.args.max_bytes)
    except Exception:
        home_html = ""
    if LOGIN_OK_RE.search(home_html):
        return "ok", opener, "POST 落点无特征, 回首页确认已登录"
    if LOGIN_FAIL_RE.search(home_html):
        return "fail", opener, "回首页验证仍是未登录状态"
    return "unknown", opener, "未能从页面特征确认登录成功, 仍按登录态再收集一遍"


# ====================================================================
# 抓取
# ====================================================================

def normalize(raw):
    """无 scheme 的输入按 https 优先尝试; 返回 (url, 是否猜测scheme)。"""
    raw = raw.strip().strip("\"'<>")
    if not raw:
        return None, False
    if "://" not in raw:
        return "https://" + raw.strip("/"), True
    return raw, False


def encode_iri(url):
    """urllib 只接受 ASCII URL, 含中文等资源路径(如 activity/surface/无标题.png)
    会在发出请求前抛 UnicodeEncodeError, 域名白白没访问到。按浏览器做法转成
    UTF-8 百分号编码; safe 里保留 %, 源站已编码的 %xx 不会被二次编码。"""
    try:
        url.encode("ascii")
        return url
    except UnicodeEncodeError:
        return quote(url, safe="!#$%&'()*+,/:;=?@[]~")


def fetch_one(url, level, state, opener, visited, guessed, referer=None):
    """抓取单个 URL, 返回其中需要继续抓取的子资源 URL 集合。"""
    host = (urlparse(url).hostname or "").strip(".").lower()
    dead = False
    with _lock:
        if url in visited:
            return set()
        # 该主机此前已完整尝试且判定不可达 → 直接跳过, 不再耗超时
        if host and host in state.dead_hosts:
            dead = True
        else:
            visited.add(url)
    if dead:
        print(f"[    -] SKIP {url}  (主机 {host} 已判定不可达)")
        return set()

    # 子资源带 Referer(模拟浏览器从页面发起), 否则不少 CDN 防盗链直接 403,
    # 域名虽然仍能记到, 但 CSS 里的 url() 引用会随 403 页面丢失
    headers = dict(HEADERS, Referer=referer) if referer else HEADERS
    try:
        resp = opener.open(Request(encode_iri(url), headers=headers),
                           timeout=state.args.timeout)
    except HTTPError as exc:
        resp = exc  # 4xx/5xx 说明 DNS 与连接已真实发生, 响应体照常解析
    except Exception as exc:
        # 未显式给 scheme 的输入 https 失败时退到 http 再试一次
        if guessed.get(url) and url.startswith("https://"):
            return fetch_one("http://" + url[len("https://"):], level, state,
                             opener, visited, guessed, referer)
        with _lock:
            state.done += 1
            # 连接层彻底失败(非猜测 scheme 的中间态) → 记死主机, 同站后续 URL 跳过
            if host and not guessed.get(url):
                state.dead_hosts.add(host)
                print(f"[{state.done:>4}] FAIL {url}  ({type(exc).__name__})"
                      f"  [主机 {host} 不可达, 同站后续跳过]")
            else:
                print(f"[{state.done:>4}] FAIL {url}  ({type(exc).__name__})")
        return set()

    # 代理模式: HTTPS 经代理是 CONNECT 隧道, 目标域名不在本地解析, socket 钩子
    # 记不到; 拿到响应(含 4xx/5xx)说明隧道真实建成、域名被真实访问, 显式收录。
    # 放在取到响应之后: 代理本身不可达时请求没到目标, 不算真实访问不收录。
    # IP 只有代理知道且随出口漂移, 不记, 交由防火墙装载时按域名重新解析
    if state.args.proxy:
        p_host = (urlparse(url).hostname or "").strip(".").lower()
        if p_host:
            try:
                ipaddress.ip_address(p_host)    # IP 字面量走 direct_ips, 不入 domains
            except ValueError:
                with _lock:
                    domains.add(p_host)

    status, text, parse, final_url, ctype = 0, "", False, url, ""
    try:
        with resp:
            status = getattr(resp, "status", None) or getattr(resp, "code", 0)
            ctype = (resp.headers.get_content_type() or "").lower()
            final_url = resp.geturl()
            parse = (ctype in HTML_CTYPES or ctype in CSS_CTYPES
                     or ctype in JS_CTYPES)
            body = resp.read(state.args.max_bytes) if parse else b""
            if not parse and ctype in SNIFF_CTYPES:
                head = resp.read(4096)
                low = head.lower()
                if b"<html" in low or b"<!doctype html" in low:
                    parse = True
                    body = head + resp.read(state.args.max_bytes - len(head))
            if parse and body:
                text = read_text_body(body, resp)
    except Exception as exc:
        with _lock:
            state.done += 1
            print(f"[{state.done:>4}] {status:>3} {url}  读取失败 ({type(exc).__name__})")
        return set()

    with _lock:
        state.done += 1
        # 有跳转时把最终落点一并展示(geturl 返回百分号编码后的形式, 需同基准比较)
        extra = f"  ->  {final_url}" if (
            final_url.rstrip("/") != encode_iri(url).rstrip("/")) else ""
        print(f"[{state.done:>4}] {status:>3} {url}{extra}")

    if not (parse and level < state.args.depth):
        return set()
    try:
        if ctype in CSS_CTYPES:
            return extract_from_css(text, final_url)
        if ctype in JS_CTYPES:
            return extract_from_js(text)
        # HTML: 标签引用 + 内联脚本里的 URL 字面量(播放器初始化等)
        return extract_from_html(text, final_url) | extract_from_js(text)
    except Exception:
        return set()


def read_text_body(body, resp):
    enc = resp.headers.get_content_charset() or "utf-8"
    try:
        return body.decode(enc, errors="replace")
    except LookupError:
        return body.decode("utf-8", errors="replace")


def crawl_site(start_url, state, opener):
    """从单个 URL 出发, 用给定会话按层抓取子资源。visited 每次调用独立:
    登录前后两遍收集才能把同一批 URL 用不同会话真实重新访问。"""
    url0, is_guess = normalize(start_url)
    if not url0:
        return
    visited, guessed, refer = set(), {url0: is_guess}, {}
    current, level, capped = [url0], 0, False
    while current:
        print(f"[*] 深度 {level}: 抓取 {len(current)} 个 URL")
        results = []
        with ThreadPoolExecutor(max_workers=state.args.concurrency) as pool:
            futures = {pool.submit(fetch_one, u, level, state, opener, visited,
                                   guessed, refer.get(u)): u for u in current}
            for f, u in futures.items():
                try:
                    results.append((u, f.result()))
                except Exception:
                    pass
        pend_set, pending = set(), []
        for parent, res in results:
            for u in res:
                if u in visited or u in pend_set:
                    continue
                if len(visited) + len(pend_set) >= state.args.max_urls:
                    if not capped:
                        print(f"[!] 达到 --max-urls 上限 {state.args.max_urls}, "
                              f"本遍后续资源不再抓取")
                        capped = True
                    break
                refer[u] = parent
                pend_set.add(u)
                pending.append(u)
        current = pending
        level += 1


# ====================================================================
# 输出
# ====================================================================

def write_output(path, doms, ipset):
    """IPv4 → IPv6 → 域名, 各段内部排序; 临时文件 + rename 原子替换。"""
    def vkey(s):
        ip = ipaddress.ip_address(s)
        return (ip.version, ip.packed)

    v4 = sorted((i for i in ipset if ":" not in i), key=vkey)
    v6 = sorted((i for i in ipset if ":" in i), key=vkey)
    lines = v4 + v6 + sorted(doms)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        for line in lines:
            f.write(line + "\n")
    os.replace(tmp, path)


def parse_entries(urls_cfg, parser):
    """URLS 条目 → (url, 用户名, 密码); 登录条目写法为 [url, user, password]。"""
    entries = []
    for item in urls_cfg:
        if isinstance(item, str):
            if item.strip():
                entries.append((item.strip(), None, None))
            continue
        item = list(item)
        if len(item) < 3 or not str(item[0]).strip():
            parser.error(f"URLS 登录条目格式应为 [URL, 用户名, 密码]: {item!r}")
        entries.append((str(item[0]).strip(), str(item[1]), str(item[2])))
    return entries


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="示例:\n"
               "  python3 get_dns.py            # 抓取脚本顶部 URLS 列表\n"
               "  python3 get_dns.py -d 0       # 只抓页面本身, 不抓子资源\n")
    parser.add_argument("-o", "--output",
                        help="输出文件, 默认脚本同目录 dns.txt")
    parser.add_argument("-t", "--timeout", type=float, default=15.0,
                        help="单个请求超时秒数 (默认 15)")
    parser.add_argument("-d", "--depth", type=int, default=2,
                        help="子资源抓取深度: 0=只抓 URL 本身, "
                             "1=再抓页面引用的资源, 2=连同资源里的 HTML/CSS "
                             "引用再深一层 (默认 2)")
    parser.add_argument("-c", "--concurrency", type=int, default=16,
                        help="并发数 (默认 16)")
    parser.add_argument("-m", "--max-urls", type=int, default=5000,
                        help="单遍抓取最多 URL 数, 登录条目前后两遍单独计 (默认 5000)")
    parser.add_argument("--max-bytes", type=int, default=2 * 1024 * 1024,
                        help="单个可解析响应的最大读取字节数 (默认 2MB)")
    parser.add_argument("--proxy", metavar="URL", default="",
                        help="经 HTTP(S) 代理抓取, 用于直连被墙的站(如 vjudge)。"
                             "WSL 内访问 Windows 代理: 用路由网关 IP 且代理需开"
                             "允许局域网, 例 http://<网关IP>:7890")
    args = parser.parse_args(argv)
    out_path = args.output or os.path.join(SCRIPT_DIR, "dns.txt")

    entries = parse_entries(URLS, parser)
    if not entries:
        parser.error("URLS 列表为空, 请在脚本顶部填入目标 URL")

    install_hooks()

    print("=" * 44)
    print(" get_dns: 记录 URL 访问全过程中的域名 / IP")
    print("=" * 44)
    print(f"[+] 输入条目: {len(entries)} 个, 深度: {args.depth}, "
          f"并发: {args.concurrency}")
    state = State(args)
    try:
        for url, user, password in entries:
            key = site_key(normalize(url)[0] or url)
            if user is not None:
                # 登录条目: 匿名先收一遍(登录前), 登录成功后再收一遍(登录后)
                print(f"[*] 登录前(匿名)收集: {url}")
                crawl_site(url, state, state.anon)
                if key not in state.logins:
                    print(f"[*] 尝试登录: {url} (用户: {user})")
                    status, opener, note = login_site(state, normalize(url)[0],
                                                      user, password)
                    if opener is not None and status != "fail":
                        state.logins[key] = opener
                        if status == "ok":
                            print(f"[+] 登录成功: {key}")
                        else:
                            print(f"[!] 登录结果未确认: {note}")
                    else:
                        print(f"[!] 登录失败: {note}, 跳过登录后收集")
                if key in state.logins:
                    print(f"[*] 登录后收集: {url}")
                    crawl_site(url, state, state.logins[key])
            else:
                opener = state.opener_for(url)
                tag = "登录态" if opener is not state.anon else "匿名"
                print(f"[*] 收集({tag}): {url}")
                crawl_site(url, state, opener)
    except KeyboardInterrupt:
        print("\n[!] 已中断, 不写入结果", file=sys.stderr)
        return 130

    print("=" * 44)
    # IP 收录规则: 域名解析而来的 IP 不收录, 只保留直接以 IP 访问的地址
    final_ips = direct_ips - resolved_ips
    hidden = len(direct_ips) - len(final_ips)
    print(f"[+] 域名 {len(domains)} 个, IP {len(final_ips)} 个")
    if hidden:
        print(f"[*] 另有 {hidden} 个 IP 由域名解析而来, 按规则未收录"
              f"(对应域名已在列表中)")
    if not (domains or final_ips):
        # 全失败大概率是网络/DNS 故障, 绝不能把旧列表洗成空
        print(f"[!] 结果为空, 保留原有 {out_path}", file=sys.stderr)
        print("    (所有 URL 都访问失败? 检查网络后重跑)", file=sys.stderr)
        return 1
    write_output(out_path, domains, final_ips)
    print(f"[+] 已写入: {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
