# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目用途

家长控制: 用白名单限制孩子电脑只能访问信奥学习类网站。同一套数据管道部署到三端 —— Windows 11 本机防火墙、Ubuntu/WSL (iptables)、OpenWrt 路由器 (firewall4 ipset)。

## 数据管道 (核心架构, 改任何一环前先读这里)

```
urls.txt ──> get_dns.py ──> dns.txt ──┬── allow_dns.ps1 (Windows: 解析→防火墙规则)
 (种子URL,   (socket层挂钩  (域名白名单 ├── ubuntu/firewall.sh (WSL: 解析→iptables DNSFILTER链)
  可带账密)   实地采集)      唯一事实源) └── openwrt/allow_dns.sh (路由器: 解析→ipv4/ipv6.txt→ipset)
                  │
                  └── dns.meta.json (get_dns.py 自用状态: 条目来源站点 + 连续缺席计数)
```

- **dns.txt 是三端共享的唯一输入**。三个下游脚本各自独立把域名解析成 IP 并落地, 格式(每行一个域名/IP、LF、UTF-8)变更会同时影响三端。三端还各自硬编码放行公共 DNS 服务器与 DoH 入口(防白名单掐断自己的 DNS/DoH 通道)。
- `get_dns.py` 不用正则搜网页, 而是在 socket 层挂钩, 凡真实发生的 DNS/连接全部记录; 按站点分组多进程并行, 同站条目串行复用登录会话(登录条目写在同站其它条目之前)。
- **丢条目保护**(改写出逻辑前必读 get_dns.py 顶部 docstring): 相比旧 dns.txt 丢失的条目按 `dns.meta.json` 记录的来源分类 —— 来源站点已从 urls.txt 移除则剪除; 否则进缺席宽限(连续缺席 `MISSING_GRACE=3` 次才剪, 防一次 DNS 抖动把在用域名 DROP 断网); 无法归因的丢失超过旧名单一半判采集故障、拒绝写出, 人工确认后才用 `--allow-partial` 强制。结果为空绝不覆盖旧 dns.txt。
- IP 只收录"URL 直接写 IP"的地址; 域名解析出的 IP 不进 dns.txt(IP 随 DNS 漂移, 按域名放行更可靠)。顶部 `UNURLS` 娱乐黑名单域名即使被访问到也不写入。

## 常用命令

```bash
# 采集(无需管理员, 输出 dns.txt): get_dns.bat 是包装器(py -3 优先)
py -3 get_dns.py                      # 或 ./get_dns.bat; WSL 内: python3 get_dns.py
py -3 get_dns.py -d 0                 # 只抓页面本身
py -3 get_dns.py --proxy http://<网关IP>:7890   # 被墙站点(如 vjudge)走 Windows 代理
py -3 get_dns.py --allow-partial      # 确认接受残缺名单时强制写出

# Windows 端应用/恢复(两个 .bat 会自动提权到管理员)
allow_dns.bat        # 解析 dns.txt → 历史∪本轮累积 → 分块(500/条)建出站放行规则 → 默认出站 Block
clear_ips.bat        # 恢复默认出站 Allow 并删规则

# Ubuntu/WSL 端(需 root)
sudo ./ubuntu/firewall.sh [dns.txt]  # 解析 dns.txt, 原子装载 iptables DNSFILTER/DNSFILTER6 链
sudo ./ubuntu/clear.sh               # 清空全部规则恢复 ACCEPT (firewall.sh 的逆操作)

# OpenWrt (BusyBox ash)
cp openwrt/allow_dns.sh /root && /root/allow_dns.sh
# 退出码 10 = 生成的 ipv4/ipv6.txt 有变化, cron 里据此触发 service firewall reload
```

没有测试套件、没有构建步骤。`node_modules/`(iconv-lite 等)是历史遗留, 无 package.json。

## 重要陷阱

- **Readme.md 与 cron.xml 已过时**: 它们引用的 `dns2ips.ps1` / `allow_ips.ps1` / `auto_sub_lookup.sh` 已删除(被 `get_dns.py` + `allow_dns.ps1` 和 `openwrt/allow_dns.sh` 取代), cron.xml 里的路径仍指向 `d:\firewall_cron` 旧脚本名。以实际脚本与本文件为准。
- **文件编码混杂, 不要转换**: `clear_ips.bat` / `clear_ips.ps1` 是 GBK 编码(Read/Write 会拒绝, 改动须用保留编码的 shell 命令); `cron.xml` 是 UTF-16; `.editorconfig` 缺省, VSCode 全局按 gb18030 打开(.vscode/settings.json)。新文件一律 UTF-8 + LF。
- **urls.txt 存在时完全取代 get_dns.py 内硬编码 URLS**, 增删站点只改 urls.txt; 里面是明文账密(家庭内网仓库, 属预期)。
- **防火墙端白名单只增不减(Windows 与 ubuntu 两端同构)**: 历次解析的 IP 累积在状态目录 `STATE_DIR` 环境变量可改写(便于测试隔离), 每轮装载 历史∪本轮, 空解析绝不覆盖历史 —— CDN 轮询地址池靠累积覆盖全。ubuntu 端默认 `/var/lib/firewall_cron/whitelist{4,6}.txt`, Windows 端默认 `%ProgramData%\firewall_cron\whitelist{4,6}.txt`(allow_dns.ps1 同时把本轮快照写到 ipv4.txt/ipv6.txt, 仅作诊断)。想收敛放行面就删状态文件重跑。
- **iptables 装载顺序不可反**: 先 `-P ... ACCEPT` 再 `-F`(旧策略是 DROP 时先清规则会瞬间锁死整机); 链用 `<链名>_new` + iptables-restore 原子换入。`firewall.sh` 从清空旧规则起若中途失败, 机器处于裸奔态, 需立即重跑。
- **OpenWrt BusyBox 的 `tr` 有 ctype bug**(`tr [:upper:]` 会损坏输出): 一律用显式字符类如 `[A-Z]`, 禁用 `[:upper:]` / `[:space:]` 之类 POSIX 类。
- **WSL 联网调试前必须先清防火墙**: `sudo ubuntu/clear.sh`。白名单 DROP 表现为静默超时, 极易误诊为"被墙"。
- **Git Bash 调 WSL**: `wsl bash -c '...'` 里任何 `$变量` 都会被 MSYS 预展开, 带变量的命令要写成脚本文件执行; `/mnt/...` 路径需 `MSYS_NO_PATHCONV=1`。
- Windows 出站规则里还硬编码了几个固定放行 IP(DNS 服务器 + `allow_dns.ps1` 里的 `142.171.157.43` / `2607:f130:...`), 改动防火墙行为时一并核对。
