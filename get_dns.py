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

输入格式(同目录 urls.txt 每行一条; 该文件不存在时才用脚本顶部 URLS 硬编码),
条目两种写法:
  "https://example.com"                            # 无需登录
  ["https://example.com", "用户名", "密码"]          # 需要登录
带登录凭据的条目:
  * 先用匿名会话完整收集一遍, 再尝试通用表单登录, 成功后用登录会话
    再收集一遍(登录态页面常会多出用户头像 / 推送等专属域名)
  * URLS 中后面的条目命中同一站点域名时, 自动复用该登录会话;
    因此登录条目要写在同站其它条目之前
  * 登录是通用识别: 在首页(或常见登录路径页)找含 <input type=password>
    的表单, 填用户名密码 POST; 需要短信/图形验证码的站无法自动登录

并行结构:
  URLS 按站点分组, 不同站点各开一个进程全并行(-j 可限并行度); 同站条目
  留在同一进程内串行处理 —— 登录会话是进程内存里的 cookie, 跨进程传不了,
  拆开同站条目会丢掉"同站复用登录态"能力。各进程记录到的域名/IP 结束时
  经各自独立的管道回传父进程合并后统一写出。某站点进程异常终止(崩溃/
  OOM)时拒绝写出并点名。
  相比现有 dns.txt 丢失的条目(上次采到、这次没采到)不再一刀切拒写 ——
  一刀切会让"从 urls.txt 移除某站"之后的每次运行都因同样几条丢失永久
  拒写(cron 死锁)。条目来源(哪个站点组采到)与连续缺席次数记在同目录
  dns.meta.json, 按来源分类处理:
    * 源站点已不在本次 URL 清单: 视为用户移除该站, 随写出直接剪除;
    * 源站点仍在清单 / 无来源记录: 进入缺席宽限, 条目原样保留进新名单
      (一次网络抖动不会把在用域名 DROP 断网), 连续缺席 3 次才判定确已
      消失并剪除;
    * 无法归因于站点移除的丢失超过旧名单一半: 判采集故障(DNS 半瘫/解析
      器退化), 拒写。
  确认接受残缺(站点确已永久移除等)再 --allow-partial: 跳过宽限立即剪除。
  墙外第三方主机不可达 / 登录失败等常态缺失: 只作诊断信息打印。

IP 收录规则:
  域名解析得到的 IP 不收录 —— 该域名本身已进列表, 且 IP 随 DNS 漂移,
  按域名放行更可靠; 只收录"直接以 IP 访问"的地址(IP 字面量 URL)。

娱乐视频黑名单:
  脚本顶部 UNURLS 中的域名(含其子域名)即使被真实访问到也不写进白名单
  —— 娱乐站常经被收录页面的外链 / 内嵌资源混进来, 不该因此获得放行;
  与旧名单对比时这类条目也不记"丢失", 不会因排除它们触发缺席宽限或
  采集故障误判。

已知边界(脚本不是浏览器, 不会执行 JavaScript):
  * JS 运行时用变量拼接的域名只能靠模板+区域候选猜测命中一部分,
    拼接逻辑特殊的仍可能漏
  * <a> 超链接不跟踪 —— 浏览器不会自动请求它, 跟踪就把脚本变成了整站爬虫

用法:
  1. 把目标 URL 填进脚本同目录 urls.txt(每行一条; 无该文件才用 URLS 硬编码)
  2. python3 get_dns.py

输出: 默认写脚本同目录 dns.txt (IPv4、IPv6、域名三组各自排序去重, 原子替换)。
结果为空时保留旧文件不覆盖, 防止把防火墙白名单输入洗成空。
同目录 dns.meta.json 记录条目来源与缺席计数, 供上述丢失分类自用 ——
防火墙不读该文件, 删掉只会让下一次丢失全部走缺席宽限, 无害。
"""

import argparse
import http.cookiejar
import ipaddress
import json
import os
import re
import socket
import ssl
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from multiprocessing import get_context
from html.parser import HTMLParser
from urllib.parse import urljoin, urldefrag, urlparse, urlencode, quote
from urllib.request import (HTTPCookieProcessor, HTTPSHandler, ProxyHandler,
                            HTTPError, Request, build_opener)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ====================================================================
# 目标 URL 列表(后备): 同目录 urls.txt 存在时以文件为准, 本列表不使用;
# urls.txt 也不存在才用这里的硬编码。条目两种写法:
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
    "https://python.microbit.org/v/3",
    "https://python.microbit.org/v/3/ideas",
    "https://python.microbit.org/v/3/api",
    ["https://www.mxoj.net/", "lizhenghan", "123456"],
    ["https://www.iai.sh.cn","yujieli","nbyg2004"],
    "https://codeforces.com",
    "https://codeforces.com/problemset",
    "https://codeforces.com/problemset/problem/2276/G",
    ["https://cspsjtest.noi.cn/","yujieli","nbyg2004"],
    "https://www.noi.cn",
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

# 娱乐视频网站黑名单: 域名等于 UNURLS 条目或是条目子域名的不进白名单
# (采集照常发生, 仅在输出前剔除, 见 main 里"黑名单排除")。条目写法决定
# 粒度: 写注册域(iqiyi.com)整站连全部子域一并屏蔽; 写具体主机
# (www.baidu.com)只屏蔽该主机, 同站其它服务(pan.baidu.com 等)不受牵连。
UNURLS = {
    "www.bilibili.com",                                # B 站主页
    "bilibili.com", "bilivideo.com", "hdslb.com",      # B 站全站与视频/图床
    "www.douyin.com", "douyin.com", "ixigua.com",      # 抖音/西瓜短视频
    "v.qq.com",                                        # 腾讯视频
    "youku.com", "iqiyi.com", "mgtv.com", "acfun.cn",  # 优酷/爱奇艺/芒果TV/A站
    "haokan.baidu.com",                                # 好看视频(百度短视频)
    "douyu.com", "huya.com", "twitch.tv",              # 游戏/秀场直播
    "www.youtube.com", "youtube.com",                  # YouTube
    "googlevideo.com", "ytimg.com",                    # YouTube 视频流/静态资源
    "netflix.com",                                     # Netflix
    "www.baidu.com",                                   # 仅百度主页
}

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


def in_unurls(host):
    """域名是否命中娱乐视频黑名单: 等于条目或是条目的子域名。"""
    host = (host or "").strip(".").lower()
    return host in UNURLS or any(host.endswith("." + s) for s in UNURLS)


# ====================================================================
# socket 层钩子: 记录真实发生的 DNS 解析与连接
# ====================================================================

_lock = threading.Lock()
domains = set()        # 成功解析过的域名
resolved_ips = set()   # 由域名解析得到的 IP —— 按规则输出时剔除
direct_ips = set()     # 直接以 IP 访问的地址 —— 输出只保留这类


# getaddrinfo 是原生阻塞调用, 不受 socket timeout 约束: WSL 的 DNS 中继
# (10.255.255.254) 曾出现"接受 TCP 连接但不回包", 8 个抓取线程永久冻结,
# 整批 URL 停摆。用守护线程给它加硬超时: 超时按解析失败语义抛 gaierror,
# 挂死线程泄漏但不拖累别人(数量有界, 进程退出即回收)。
# 默认硬超时 = 请求超时 + 5s(main/run_group 里折算): 硬超时若低于请求超时,
# 中继只是变慢(未死)也会把好主机误判进 dead_hosts, 静默产出残缺白名单。
# GETDNS_DNS_TIMEOUT: 显式秒数覆盖默认; 0 或负数 = 关闭看门狗(每次解析省下
# 一个线程, 健康网络适用); 非法值告警后按默认。
def _parse_dns_timeout_env():
    raw = os.environ.get("GETDNS_DNS_TIMEOUT", "").strip()
    if not raw:
        return None                              # 未配置: 按请求超时折算
    try:
        val = float(raw)
    except ValueError:
        print(f"[!] GETDNS_DNS_TIMEOUT={raw!r} 无法解析,"
              f" 按默认(请求超时+5s)", file=sys.stderr)
        return None
    return max(val, 0.0)                         # 0 = 显式关闭


# None = 未显式配置(待折算), 0 = 关闭, >0 = 硬超时秒数
DNS_HARD_TIMEOUT = _parse_dns_timeout_env()


def _apply_default_dns_timeout(request_timeout):
    """把"未显式配置"折算成 请求超时+5s; spawn 子进程没走 main, 也各自折算。"""
    global DNS_HARD_TIMEOUT
    if DNS_HARD_TIMEOUT is None:
        DNS_HARD_TIMEOUT = request_timeout + 5.0


def _tracked_getaddrinfo(*args, **kwargs):
    if DNS_HARD_TIMEOUT:
        box = {}

        def _go():
            try:
                box["r"] = _orig_getaddrinfo(*args, **kwargs)
            except BaseException as exc:  # 原样带回, 保留 gaierror 等类型
                box["e"] = exc

        th = threading.Thread(target=_go, daemon=True)
        th.start()
        th.join(DNS_HARD_TIMEOUT)
        if th.is_alive():
            raise socket.gaierror(socket.EAI_FAIL,
                                  f"getaddrinfo 超 {DNS_HARD_TIMEOUT:g}s 未响应,"
                                  f" 按解析失败处理")
        if "e" in box:
            raise box["e"]
        result = box["r"]
    else:
        # 看门狗关闭: 直接内联调用, 省去每次解析一个线程的开销
        result = _orig_getaddrinfo(*args, **kwargs)

    # 先解析、成功才记录: 解析失败的主机没参与本次访问, 对防火墙也无意义
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
        # 本组未采全的因素(max-urls 截断/登录失败在此记录, 不可达主机由
        # run_group 汇总), 随结果回传父进程打印诊断(是否拒写由旧名单对比定)
        self.problems = []

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
                        state.problems.append(
                            f"{url0} 达到 --max-urls 上限, 后续资源未抓取")
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


# 相比旧名单丢失条目的处理参数(分类逻辑见模块 docstring)
MISSING_GRACE = 3       # 无法归因于站点移除的丢失宽限保留的运行周期数
MASS_LOSS_RATIO = 0.5   # 此类丢失超过旧名单该比例判采集故障, 拒写


def _is_ip_literal(s):
    try:
        ipaddress.ip_address(s)
        return True
    except ValueError:
        return False


def meta_path_for(out_path):
    """元数据与输出同名: dns.txt -> dns.meta.json (防火墙只读 dns.txt)。"""
    return os.path.splitext(out_path)[0] + ".meta.json"


def load_meta(path):
    """读条目来源/缺席计数元数据。缺失或损坏一律按空处理: 只影响丢失
    归属精度(全部走缺席宽限), 不该因此挡住采集写出。"""
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
        return {"sources": {str(k): str(v)
                            for k, v in (raw.get("sources") or {}).items()},
                "missing": {str(k): int(v)
                            for k, v in (raw.get("missing") or {}).items()}}
    except (OSError, ValueError, TypeError, AttributeError):
        return {"sources": {}, "missing": {}}


def save_meta(path, sources, missing):
    """与 write_output 同样的临时文件+rename 原子替换; 写失败只告警 ——
    元数据缺失只降级下次丢失归属, 不值得让整个采集以非零退出。"""
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"v": 1, "sources": sources, "missing": missing},
                      f, ensure_ascii=False, sort_keys=True)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as exc:
        print(f"[!] 元数据 {path} 写入失败(不影响本次名单): {exc}", file=sys.stderr)


def load_previous_lines(path):
    """读现有输出文件的条目集合(write_output 的逆: 每行一个 IP/域名)。
    文件不存在/不可读返回空集 —— 首跑无可比, 不判丢失。"""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return {line.strip() for line in f if line.strip()}
    except OSError:
        return set()


def load_urls_file(path, parser):
    """urls.txt 每行一条目: "URL" 或 "URL 用户名 密码"(空白分隔, 密码可带
    空格); # 开头行与空行忽略。返回与硬编码 URLS 同形状的条目元组。"""
    items = []
    try:
        with open(path, encoding="utf-8-sig") as f:   # 容忍记事本 BOM
            for lineno, line in enumerate(f, 1):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                fields = line.split(None, 2)
                if len(fields) == 2:      # 只有 URL+用户名: 多半是漏写了密码
                    parser.error(f"{path} 第 {lineno} 行只有 2 个字段, 登录条目"
                                 f"需 'URL 用户名 密码': {line!r}")
                items.append(fields[0] if len(fields) == 1 else fields)
    except OSError as exc:
        parser.error(f"读取 {path} 失败: {exc}")
    return tuple(items)


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


def collect_entry(url, user, password, state):
    """单个 URLS 条目的收集(登录条目匿名/登录态各收一遍)。"""
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
                if "已判定不可达" not in note:    # 主机判死另有专门汇总
                    state.problems.append(f"登录失败 {key}: {note}")
        if key in state.logins:
            print(f"[*] 登录后收集: {url}")
            crawl_site(url, state, state.logins[key])
    else:
        # 用已规范化的站点键查登录会话 —— 直接拿未规范化的原始条目串去
        # urlparse, 不带 scheme 的条目(合法写法)解析不出 hostname, 会错拿匿名会话
        opener = state.logins.get(key) or state.anon
        tag = "登录态" if opener is not state.anon else "匿名"
        print(f"[*] 收集({tag}): {url}")
        crawl_site(url, state, opener)


def run_group(job):
    """站点分组进程入口(顶层函数, 供 multiprocessing 序列化)。同站条目
    串行以复用登录会话; 子进程里 domains/direct_ips/resolved_ips 是各自
    私有副本(socket 钩子记进本进程), 返回交父进程合并。"""
    args, group = job
    _apply_default_dns_timeout(args.timeout)  # spawn 子进程没走 main, 就地折算
    install_hooks()   # spawn 启动方式不继承父进程钩子; fork 下重复安装幂等
    domains.clear()
    direct_ips.clear()
    resolved_ips.clear()
    try:
        # 多进程共写 stdout: 整行交错(-u 的 write_through 会让 print 分两次
        # write 被别的进程插进来, 必须同时关掉)
        sys.stdout.reconfigure(write_through=False, line_buffering=True)
    except Exception:
        pass
    print(f"[*] ===== 站点组 {group[0][0]} ({len(group)} 条目) =====")
    state = State(args)
    for url, user, password in group:
        collect_entry(url, user, password, state)
    probs = list(dict.fromkeys(state.problems))      # 去重保序
    if state.dead_hosts:
        probs.append(f"不可达主机 {len(state.dead_hosts)} 个, 其上 URL 已跳过: "
                     f"{', '.join(sorted(state.dead_hosts))}")
    return sorted(domains), sorted(direct_ips), sorted(resolved_ips), probs


def _group_worker(job, conn, gkey):
    """站点组进程函数体: 结果经本组专属管道发送后置键退出。任何异常/被外部
    杀死都表现为"该组无结果", 由父进程按缺失处理并点名。"""
    try:
        conn.send((gkey, run_group(job)))
    except BaseException as exc:    # 含 SystemExit: 换成明确日志而非进程无声消失
        print(f"[!] 站点组 {gkey} 工作进程异常: {type(exc).__name__}: {exc}",
              file=sys.stderr)
    finally:
        try:
            conn.close()
        except OSError:
            pass


def _pipe_reader(conn, gkey, results_map, map_lock):
    """父进程侧读线程: 收整帧结果存进 results_map。worker 被杀在发送中途时
    recv 会永久阻塞在半帧上 —— 本线程是守护线程, 主流程只限时 join, 超时即
    按该组缺失处理。各组管道互相独立: 一组半帧不会像共享 Queue 那样把其后
    所有帧都错位吞掉(半帧会让共享管道上后续帧全部解析错乱)。"""
    try:
        got = conn.recv()
    except Exception:               # EOFError(未及发送)/OSError/反序列化失败
        return
    finally:
        try:
            conn.close()
        except OSError:
            pass
    if isinstance(got, tuple) and len(got) == 2 and got[0] == gkey:
        with map_lock:
            results_map[gkey] = got[1]


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
                        help="单站点进程内的线程并发数 (默认 16)")
    parser.add_argument("-j", "--jobs", type=int, default=0,
                        help="并行的站点进程数, 0=每个站点组各开一个进程"
                             " (默认 0, 全并行)")
    parser.add_argument("-m", "--max-urls", type=int, default=5000,
                        help="单遍抓取最多 URL 数, 登录条目前后两遍单独计 (默认 5000)")
    parser.add_argument("--max-bytes", type=int, default=2 * 1024 * 1024,
                        help="单个可解析响应的最大读取字节数 (默认 2MB)")
    parser.add_argument("--urls", metavar="FILE",
                        help="从文件读取 URL 清单, 每行: URL [用户名 密码], "
                             "# 开头为注释行; 未指定时自动探测脚本同目录 "
                             "urls.txt, 该文件也不存在才用脚本内硬编码 URLS")
    parser.add_argument("--allow-partial", action="store_true",
                        help="有站点进程异常终止、或丢失条目超过旧名单一半判"
                             "采集故障时也写出结果; 并放弃缺席宽限, 未采到条"
                             "目立即剪除(默认保留)")
    parser.add_argument("--proxy", metavar="URL", default="",
                        help="经 HTTP(S) 代理抓取, 用于直连被墙的站(如 vjudge)。"
                             "WSL 内访问 Windows 代理: 用路由网关 IP 且代理需开"
                             "允许局域网, 例 http://<网关IP>:7890")
    args = parser.parse_args(argv)
    _apply_default_dns_timeout(args.timeout)
    if DNS_HARD_TIMEOUT and DNS_HARD_TIMEOUT <= args.timeout:
        print(f"[!] DNS 硬超时 {DNS_HARD_TIMEOUT:g}s 不大于请求超时"
              f" {args.timeout:g}s: 中继仅变慢(未死)时好主机也会被误判不可达,"
              f" 结果可能静默残缺", file=sys.stderr)
    out_path = args.output or os.path.join(SCRIPT_DIR, "dns.txt")
    meta_file = meta_path_for(out_path)

    urls_path = args.urls or os.path.join(SCRIPT_DIR, "urls.txt")
    if args.urls or os.path.exists(urls_path):
        print(f"[+] URL 清单: {urls_path}")
        urls_src = load_urls_file(urls_path, parser)
    else:
        urls_src = URLS
    entries = parse_entries(urls_src, parser)
    if not entries:
        parser.error("URL 清单为空, 请写入 urls.txt 或脚本顶部 URLS")

    install_hooks()
    domains.clear()        # 同进程内二次调用 main() 时不残留上次结果
    direct_ips.clear()
    resolved_ips.clear()

    print("=" * 44)
    print(" get_dns: 记录 URL 访问全过程中的域名 / IP")
    print("=" * 44)
    print(f"[+] 输入条目: {len(entries)} 个, 深度: {args.depth}, "
          f"每进程线程: {args.concurrency}")

    # 按站点分组: 不同站点各开一个进程全并行; 同站条目留在同一进程内串行
    # —— 登录会话是进程内存里的 cookie, 跨进程传不了(登录条目写在同站前面,
    # 组内保持 URLS 原顺序即可复用)
    groups, order = {}, []
    for e in entries:
        gkey = site_key(normalize(e[0])[0] or e[0])
        if gkey not in groups:
            groups[gkey] = []
            order.append(gkey)
        groups[gkey].append(e)
    tasks = [(k, (args, groups[k])) for k in order]
    nproc = min(args.jobs, len(tasks)) if args.jobs > 0 else len(tasks)
    print(f"[+] 站点组: {len(tasks)} 个, 并行进程: {nproc}")
    # gkey -> (domains, direct_ips, resolved_ips, problems)
    results_map = {}
    source_of = {}                       # 条目 -> 采到它的站点组键(丢失归属)
    map_lock = threading.Lock()
    if len(tasks) == 1:
        # 与多进程路径同等语义: 中断干净退出 130, 处理异常记作该组失败
        try:
            results_map[order[0]] = run_group(tasks[0][1])
        except KeyboardInterrupt:
            print("\n[!] 已中断, 不写入结果", file=sys.stderr)
            return 130
        except Exception as exc:
            print(f"[!] 站点组 {order[0]} 处理异常: {type(exc).__name__}: {exc}",
                  file=sys.stderr)
    else:
        # 每站点组一个进程 + 专属结果管道, 不用 Pool: Pool 不察觉 worker 被
        # 外部杀死(OOM/段错误), 等待会永久挂起; 这里死亡即可见、可点名。
        # 也不用共享 Queue: worker 写到半帧被杀会让其后所有帧错位成坏帧, 且
        # Queue.get 见半帧可读就进 _recv_bytes 无限阻塞。改为每组一根管道、
        # 一个守护读线程: 半帧只卡住本组读线程, 主流程限时 join 后按该组
        # 缺失处理
        ctx = get_context("fork") if hasattr(os, "fork") else get_context("spawn")
        running, todo = [], list(tasks)
        readers = {}                          # gkey -> 该组读线程
        sys.stdout.flush()  # 先刷父进程缓冲: 防 fork 把未刷出字节复制进子进程重复打印
        try:
            while todo or running:
                while todo and len(running) < nproc:      # 空位即补
                    gkey, job = todo.pop(0)
                    rd, wr = ctx.Pipe(duplex=False)
                    p = ctx.Process(target=_group_worker,
                                    args=(job, wr, gkey), name=gkey)
                    p.start()
                    wr.close()    # 父进程放掉写端副本, 否则子进程退出后读端等不到 EOF
                    th = threading.Thread(target=_pipe_reader,
                                          args=(rd, gkey, results_map, map_lock),
                                          daemon=True, name=f"read-{gkey}")
                    th.start()
                    readers[gkey] = th
                    running.append((p, gkey))
                alive = []
                for p, gkey in running:
                    if p.is_alive():
                        alive.append((p, gkey))
                    else:
                        p.join()              # 回收; 结果帧由其专属读线程自行收取
                running = alive
                if todo or running:
                    time.sleep(0.2)                       # 让出 CPU 的低速轮询
        except KeyboardInterrupt:
            print("\n[!] 已中断, 不写入结果", file=sys.stderr)
            return 130
        finally:
            for p, _ in running:
                if p.is_alive():
                    p.terminate()
        # 正常退出组的帧早已写完入管, 读线程秒回; 限时宽限只等半帧卡住的
        # 读线程, 超时即按该组缺失处理(守护线程随本进程退出回收)
        grace = time.monotonic() + 5.0
        for th in readers.values():
            th.join(timeout=max(0.0, grace - time.monotonic()))

    # 无结果 = 该组进程异常终止(内部打印过日志)或被外部杀死(OOM 等)
    failed = [k for k in order if k not in results_map]
    if failed:
        print(f"[!] {len(failed)} 个站点组未完成: {', '.join(failed)}",
              file=sys.stderr)
    for k in order:
        if k not in results_map:
            continue
        doms, dip, rip, probs = results_map[k]
        domains.update(doms)
        direct_ips.update(dip)
        resolved_ips.update(rip)
        for d in doms:
            source_of[d] = k
        for d in dip:
            source_of[d] = k
        print(f"[+] 站点组 {k}: 域名 {len(doms)} 个")
        # 不可达主机/max-urls 截断/登录失败多为墙外第三方资源与常态问题:
        # 上次采集同样没有的条目, 白名单少它并无损失, 只作诊断信息打印。
        # 真正会挡站在用功能的是"上次采到、这次丢了" —— 由下方与旧 dns.txt
        # 的对比把关, 不在这里一刀切
        for msg in probs:
            print(f"[*] 站点组 {k} 未采全: {msg}")

    # 娱乐视频站黑名单: 真实访问到也不写进白名单(条目粒度见顶部 UNURLS
    # 注释); 先剔除再走与旧名单的丢失对比, 被排除者不算丢失
    blocked = {d for d in domains if in_unurls(d)}
    if blocked:
        # 必须原地删除: domains 是模块级集合, 写成 "domains -= blocked"
        # 会让 Python 把整个 main() 里的 domains 判成局部变量, 前面
        # domains.clear() 直接 UnboundLocalError
        domains.difference_update(blocked)
        more = f" ... 等共 {len(blocked)} 个" if len(blocked) > 20 else ""
        print(f"[i] 娱乐视频黑名单排除 {len(blocked)} 个域名:"
              f" {', '.join(sorted(blocked)[:20])}{more}")

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

    # 残缺判定核心: 与现有 dns.txt 对比, 丢失条目按来源分类(详见模块
    # docstring): 源站点已移出本次清单的随写出剪除; 其余进缺席宽限,
    # 原样保留进新名单(抖动不把在用域名 DROP 断网), 连续缺席满
    # MISSING_GRACE 次才剪除。只有站点进程未完成, 或无法归因的丢失
    # 铺满旧名单一半(疑似 DNS 故障/采集器退化)才拒写。
    old_lines = load_previous_lines(out_path)
    meta = load_meta(meta_file)
    active_keys = set(order)
    lost = old_lines - (domains | final_ips)
    lost -= {e for e in lost if in_unurls(e)}   # 黑名单条目不算丢失, 随写出剪除
    carry, cut_orphan, cut_gone, missing_new = set(), set(), set(), {}
    for e in sorted(lost):
        src = meta["sources"].get(e)
        if src and src not in active_keys:
            cut_orphan.add(e)                    # 源站点已从 urls.txt 移除
            continue
        streak = meta["missing"].get(e, 0) + 1
        if streak >= MISSING_GRACE:
            cut_gone.add(e)                      # 连续缺席, 判定确已消失
        else:
            carry.add(e)                         # 宽限保留
            missing_new[e] = streak

    def _show(msg, items):
        more = f" ... 等共 {len(items)} 个" if len(items) > 20 else ""
        print(f"{msg}: {', '.join(sorted(items)[:20])}{more}")

    if cut_orphan:
        _show(f"[i] {len(cut_orphan)} 个条目的源站点已不在本次 URL 清单"
              f"(视为站点移除, 随写出剪除)", cut_orphan)
    if cut_gone:
        _show(f"[i] {len(cut_gone)} 个条目连续 {MISSING_GRACE} 次未采到"
              f"(判定已消失, 随写出剪除)", cut_gone)
    if carry:
        _show(f"[i] {len(carry)} 个条目本次未采到"
              f"(宽限保留进新名单, 连续缺席 {MISSING_GRACE} 次才剪除)", carry)
    if args.allow_partial:                       # 用户确认接受残缺: 放弃宽限
        carry.clear()
        missing_new.clear()

    unexplained = carry | cut_gone
    mass_loss = bool(old_lines) and len(unexplained) > MASS_LOSS_RATIO * len(old_lines)
    if mass_loss:
        print(f"[!] 相比现有 {out_path} 有 {len(unexplained)} 个条目采不到,"
              f" 超过旧名单 {len(old_lines)} 条的一半: 疑似 DNS 故障或采集器"
              f"退化, 不信任本次结果", file=sys.stderr)
    rc = 2 if failed else 0
    if (failed or mass_loss) and not args.allow_partial:
        print("[!] 拒绝写出白名单(原因见上); 确认接受残缺再 --allow-partial 重跑",
              file=sys.stderr)
        return 2

    out_doms, out_ips = set(domains), set(final_ips)
    for e in carry:                              # 宽限保留: 原样带入新名单
        (out_ips if _is_ip_literal(e) else out_doms).add(e)
    write_output(out_path, out_doms, out_ips)
    # 元数据: 新采到的记本次来源(只记真正写进名单的 —— 直连 IP 里经域名
    # 解析而来者已被剔除, 记了徒增噪声); 宽限保留的沿用上次来源与缺席
    # 计数; 被剪除的与 --allow-partial 放弃保留的不再记录, 采到的条目清零计数
    written = out_doms | out_ips
    sources_new = {e: meta["sources"][e] for e in carry if e in meta["sources"]}
    sources_new.update({e: k for e, k in source_of.items() if e in written})
    save_meta(meta_file, sources_new, missing_new)
    print(f"[+] 已写入: {out_path}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
