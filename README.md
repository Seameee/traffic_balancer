# Traffic Balance Monitor

跨平台服务器流量监控与自动平衡脚本。基于 **vnstat** 监控月度 RX/TX 流量比例，当比例 <= 2 时自动后台下载文件平衡流量，支持 **Telegram** 远程查询，可安装为 **systemd/OpenRC/SysV** 持久化服务。

---

## 功能特性

- **流量监控**: 基于 vnstat 的月度 RX/TX 比例计算，支持自定义结算日
- **自动平衡**: 比例 <= 2 时自动后台下载文件（从 42 个内置 URL 随机选取）
- **Telegram 机器人**: `/traffic` 命令远程查询当前流量状态
- **跨平台兼容**: Debian/Ubuntu, RHEL/CentOS/Fedora, Alpine, Arch, openSUSE
- **多架构支持**: amd64, arm64, armv7l, i386
- **多虚拟化支持**: KVM, LXC/LXD, VMware, 物理机
- **服务化**: 支持 systemd / OpenRC / SysV init 自动安装
- **自检测试**: `--self-test` 一键诊断环境问题

---

## 一键安装

```bash
curl -sL https://ba.sh/5bPQ -o traffic_balance.sh && chmod +x traffic_balance.sh && sudo ./traffic_balance.sh --install-service
```

或者分步操作：

```bash
# 1. 下载脚本
curl -sL https://ba.sh/5bPQ -o traffic_balance.sh

# 2. 赋予执行权限
chmod +x traffic_balance.sh

# 3. 安装服务
sudo ./traffic_balance.sh --install-service
```

---

## 快速开始

### 1. 前置要求

```bash
# Debian/Ubuntu
sudo apt install vnstat curl jq

# RHEL/CentOS/Fedora
sudo dnf install vnstat curl jq
# 或 sudo yum install vnstat curl jq

# Alpine
sudo apk add vnstat curl jq

# Arch
sudo pacman -S vnstat curl jq
```

确保 **vnstatd** 正在运行：

```bash
sudo systemctl start vnstat   # Debian/Ubuntu
sudo systemctl start vnstatd  # RHEL/CentOS
sudo rc-service vnstatd start # Alpine (OpenRC)
```

### 2. 赋予执行权限

```bash
chmod +x traffic_balance.sh
```

### 3. 自检测试

```bash
./traffic_balance.sh --self-test
```

输出示例：
```
========================================
Traffic Balance 自检测试
========================================

[1/7] Bash 版本检查
  PASS: Bash 5.1.0

[2/7] 必要命令检查
  PASS: curl 已安装
  PASS: vnstat 已安装
  PASS: jq 已安装 (JSON 解析首选)

[3/7] vnstatd 运行状态
  PASS: vnstatd 正在运行

[4/7] 网卡检测
  PASS: 检测到网卡 eth0

[5/7] Telegram Token 格式
  SKIP: Telegram Bot Token 未配置

[6/7] 配置文件加载
  RESET_DAY=1
  INTERFACE='(自动检测)'
  LIMIT_RATE=1M
  CHECK_INTERVAL=60
  TG_POLL_INTERVAL=5
  PASS: 配置加载完成

[7/7] 权限检查
  PASS: 当前为 root 用户，完整功能可用

========================================
自检通过，未发现错误
========================================
```

### 4. 手动前台运行

```bash
# 使用默认配置运行
sudo ./traffic_balance.sh

# 指定结算日为每月 15 日，下载限速 2MB/s
sudo ./traffic_balance.sh -d 15 -l 2M

# 手动指定网卡
sudo ./traffic_balance.sh -i eth0
```

### 5. 安装为系统服务

```bash
# 安装服务
sudo ./traffic_balance.sh --install-service

# 安装并设置结算日为每月 15 日
sudo ./traffic_balance.sh --install-service -d 15

# 脚本将自动完成：
#   1. 安装依赖 (vnstat, curl, jq)
#   2. 启动 vnstatd
#   3. 初始化网卡监控 (如需要)
#   4. 复制脚本到 /usr/local/bin/
#   5. 创建并启用服务
#   6. 启动服务
```

### 6. 卸载服务

```bash
sudo ./traffic_balance.sh --uninstall-service
```

---

## Telegram 机器人配置（可选）

### 1. 创建机器人

1. 在 Telegram 搜索 **@BotFather**
2. 发送 `/newbot`，按提示设置机器人名称和用户名
3. 记录获得的 **Bot Token**，格式如：`1234567890:ABCdefGHIjklMNOpqrsTUVwxyz`

### 2. 获取用户 ID

1. 搜索你的机器人，发送任意消息
2. 访问 `https://api.telegram.org/bot<TOKEN>/getUpdates`
3. 在 JSON 响应中找到 `message.from.id`，这就是你的用户 ID

### 3. 创建配置文件

```bash
mkdir -p ~/.config/traffic_balance
cat > ~/.config/traffic_balance/config << 'EOF'
TELEGRAM_BOT_TOKEN="1234567890:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_ALLOWED_USER_ID="123456789"
RESET_DAY=15
LIMIT_RATE="1M"
# 使用 Cloudflare Worker 反代 Telegram Bot API 时填写，不包含 /bot<TOKEN>
# TG_API_BASE_URL="https://tg-api.example.workers.dev"
# TG_API_PROXY_SECRET="your-long-random-secret"
# TG_PROXY="socks5://user:pass@host:port"
EOF
```

### 4. 使用 Cloudflare Worker 反代 Telegram API

如果 VPS 部署在中国大陆地区，不建议长期直接使用 SOCKS5 访问 Telegram Bot API。可以把 `api.telegram.org` 反代到 Cloudflare Worker，再让脚本访问 Worker 域名。

1. 在 Cloudflare Workers 新建 Worker，代码使用本仓库的 [`cloudflare-workers/telegram-api-proxy.js`](./cloudflare-workers/telegram-api-proxy.js)
2. 在 Worker 环境变量/Secret 中配置：

```text
BOT_TOKENS=1234567890:ABCdefGHIjklMNOpqrsTUVwxyz123456789,9876543210:OtherBotToken123456789012345678901
PROXY_SECRET=your-long-random-secret
ALLOWED_METHODS=getUpdates,sendMessage
RATE_LIMIT_PER_IP=60
RATE_LIMIT_PER_BOT=240
MAX_GETUPDATES_TIMEOUT=10
```

3. 推荐绑定一个 KV 命名空间到 `RATE_KV`，用于跨 Worker 实例限流；不绑定时脚本会退化为单实例内存限流，仍会校验 token 白名单和密钥头，但抗刷能力弱一些。
4. 在本脚本配置文件中设置 Worker 根地址和同一个密钥：

```bash
TELEGRAM_BOT_TOKEN="1234567890:ABCdefGHIjklMNOpqrsTUVwxyz"
TELEGRAM_ALLOWED_USER_ID="123456789"
TG_API_BASE_URL="https://tg-api.example.workers.dev"
TG_API_PROXY_SECRET="your-long-random-secret"
TG_PROXY=""
```

`TG_API_BASE_URL` 也可以填写裸域名，例如 `tg-api.example.com`，脚本会自动补全为 `https://tg-api.example.com`。

Worker 防刷策略：

- 只接受 `BOT_TOKENS` 白名单内的 bot token，支持多个 bot token。
- 要求请求头 `X-TG-Proxy-Secret` 匹配 `PROXY_SECRET` 或 `PROXY_SECRETS`。
- 默认只允许 `getUpdates` 和 `sendMessage`，可通过 `ALLOWED_METHODS` 扩展。
- 限制请求体大小，默认 `MAX_BODY_BYTES=1048576`。
- 按来源 IP 和 bot token 分别限流，默认每分钟 `RATE_LIMIT_PER_IP=60`、`RATE_LIMIT_PER_BOT=240`。

### 5. 重启服务

```bash
sudo systemctl restart traffic-balance  # systemd
sudo rc-service traffic-balance restart   # OpenRC
```

### 6. 使用

在 Telegram 向机器人发送 `/traffic`，机器人将返回：

```
[流量报告] my-server
时间: 2026-04-28 10:24:21
网卡: eth0
结算周期: 2026-04-01 ~ 2026-04-28
----------------------------
下载(RX): 150.41 GiB
上传(TX): 13.02 GiB
RX/TX比例: 11.56
----------------------------
状态: 监控中
脚本PID: 16038
curl下载: 空闲
上次检查: 2026-04-28 10:24:21
```

---

## 命令行参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-d, --reset-day DAY` | 月度流量结算日 (1-31) | `1` |
| `-i, --interface IFACE` | 手动指定外网网卡 | 自动检测 |
| `-l, --limit-rate SPEED` | curl 下载限速 | `1M` |
| `-c, --config FILE` | 指定配置文件路径 | 见下文 |
| `--install-service` | 安装为系统服务（需 root） | — |
| `--uninstall-service` | 卸载系统服务（需 root） | — |
| `--self-test` | 执行自检测试 | — |
| `-h, --help` | 显示帮助信息 | — |

### 配置文件查找顺序

1. `-c` 命令行指定的路径
2. `~/.config/traffic_balance/config`（用户级，推荐）
3. `/etc/traffic_balance.conf`（系统级）

### 配置文件示例

```bash
# ============================================
# Traffic Balance 配置文件
# ============================================

# --- Telegram (可选) ---
TELEGRAM_BOT_TOKEN="1234567890:ABCdef..."
TELEGRAM_ALLOWED_USER_ID="123456789"
# Telegram Bot API 根地址，不包含 /bot<TOKEN> (留空则使用 https://api.telegram.org)
# TG_API_BASE_URL="https://tg-api.example.workers.dev"
# Telegram API 反代密钥头，配合 Cloudflare Worker 使用
# TG_API_PROXY_SECRET="your-long-random-secret"
# Telegram 代理 (留空则直连，支持 socks5:// 或 http://)
# TG_PROXY="socks5://user:pass@host:port"

# --- 结算日 (1-31) ---
RESET_DAY=1

# --- 网卡 (留空则自动检测) ---
INTERFACE=""

# --- curl 限速 ---
LIMIT_RATE="1M"

# --- curl 超时 (秒) ---
CONNECT_TIMEOUT=30
MAX_DOWNLOAD_TIME=7200

# --- 流量检查间隔 (秒) ---
CHECK_INTERVAL=60

# --- Telegram 轮询间隔 (秒, 建议 3-10) ---
TG_POLL_INTERVAL=5
```

---

## 工作原理

### 流量比例计算

1. 根据结算日计算当前结算周期（起始日期 ~ 今天）
2. 通过 `vnstat --json` 获取流量数据
3. 累加结算周期内的日数据得到 RX/TX 总量
4. 计算比例 `ratio = RX / TX`

### 流量平衡触发条件

- `ratio <= 2.0` 且 `ratio != -1`（有效数据）
- 当前没有 curl 下载进程在运行

### 平衡下载

从 42 个内置 URL 中随机选取一个，后台启动 curl 下载。支持全球多个测速服务器，覆盖亚洲、欧洲、北美等地区。

---

## 日志

日志文件位置：

| 运行方式 | 日志路径 |
|----------|----------|
| root 用户 | `/var/log/traffic_balance.log` |
| 非 root 用户 | `~/.local/state/traffic_balance.log` |

日志示例：

```
[2026-04-28 10:24:21] [INFO] 主循环启动 - 网卡: eth0, 结算日: 1, 检查间隔: 60s
[2026-04-28 10:24:21] [INFO] 流量比例 1.11 <= 2.0，触发流量平衡
[2026-04-28 10:24:21] [INFO] 开始流量平衡下载: http://speedtest.tokyo2.linode.com/100MB-tokyo2.bin
[2026-04-28 10:24:52] [ERROR] 下载失败 - HTTP 0, 退出码未知
```

日志超过 10MB 时自动轮转，旧日志保存为 `.old` 文件。

---

## 故障排除

### 自检失败的常见原因

| 问题 | 解决方案 |
|------|----------|
| `env: 'bash\r': No such file or directory` | 转换行尾：`dos2unix traffic_balance.sh` 或 `sed -i 's/\r$//' traffic_balance.sh` |
| `vnstat: Permission denied` | 确保 vnstatd 已启动：`sudo systemctl start vnstat` |
| `无法检测到外网网卡` | 手动指定：`sudo ./traffic_balance.sh -i eth0` |
| `依赖安装失败` | 手动安装：`sudo apt install vnstat curl jq` |
| `非 root 运行，服务安装等功能受限` | 使用 sudo 或切换到 root 用户 |

### 查看服务状态

```bash
# systemd
sudo systemctl status traffic-balance

# OpenRC
sudo rc-service traffic-balance status

# SysV
sudo service traffic-balance status
```

### 查看实时日志

```bash
# systemd
sudo journalctl -u traffic-balance -f

# 日志文件
sudo tail -f /var/log/traffic_balance.log
```

---

## 卸载

```bash
# 停止并卸载服务
sudo ./traffic_balance.sh --uninstall-service
```

---

## 常见问题

**Q: 为什么比例 <= 2 时要平衡流量？**
A: 许多云服务商以 RX（入站）流量计费，TX（出站）流量免费或低价。当 TX 相对较小时，增加 RX 可优化成本。

**Q: 下载会消耗多少流量？**
A: 取决于你的限速（默认 1MB/s）和 `MAX_DOWNLOAD_TIME`（默认 7200 秒 = 2 小时）。最大约 26GB。

**Q: 可以同时运行多个实例吗？**
A: 不可以，脚本使用 PID 文件锁确保单实例运行。

**Q: 如何修改下载 URL？**
A: 直接编辑脚本中的 `DOWNLOAD_URLS` 数组。URL 顺序不可改变。

**Q: Ctrl+C 无法终止 curl 下载？**
A: 已修复，使用 `nohup curl &` 确保子进程可被正确终止。

---

## 开源许可

MIT License
