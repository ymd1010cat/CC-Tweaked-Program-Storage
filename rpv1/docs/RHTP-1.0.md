# RHTP/1.0 接口规范（InterTeamNet 应用层）

> 本文件是 **RHTP/1.0** 的唯一规范来源。实现参考：`rpv1/poc/apps/rhtp_server.lua`（服务端）、
> `rpv1/poc/apps/rhtp_client.lua`（客户端）、`rpv1/poc/tests/t_rhtp_server.lua` 与
> `rpv1/poc/tests/t_rhtp_client.lua`（双向验收）。
>
> 规范与实现冲突时：**以本文件为准**，并把实现改成与本文一致；若确实要改协议，先改本文。

## 1. 定位

RHTP 是 ITN 网络上的**单报文请求/响应**文本协议，外形像 HTTP/1.1，但只有：

- 一次请求一个数据报，一次响应一个数据报；
- 无连接、无 keep-alive、无流水线、无分块传输；
- 只有 `GET`；
- 无 TLS、无认证。

它服务的场景是：内网机器用一行命令取到「欢迎页 / DNS 镜像 / 目录」，以及在分发中心把一份
规范文本放在讲台上供人取阅。**它不是 Web 服务器**，不要按 HTTP 的完整语义去理解它。

## 2. 传输与寻址

| 项 | 规定 |
| --- | --- |
| 承载 | IPv4 + UDP，经 rpv1 协议栈（`rpv.udp_send` / `node:bind`） |
| 默认端口 | `8080`（`M.DEFAULT_PORT`） |
| 请求方向 | 客户端从**自己的源端口**发往服务端的监听端口 |
| 响应方向 | 服务端从**监听端口**发回请求方的**源端口**（不是新端口） |
| 报文数量 | 一个请求数据报 → 正好一个响应数据报 |
| 超时 | 由客户端决定；服务端无超时状态、无重传 |
| 顺序 | 无序号；客户端靠「发一收一」配对 |

服务端不回包的情形只有一种：`rpv.udp_send` 本身失败（记 `RHTP_SEND_FAIL`）。此时客户端表现为超时。

### 2.1 报文大小

规范不定义分块。单报文上限由下层决定：UDP 载荷 ≤ 65,507 B；rpv 对超过接口 MTU（部署里通常 256 B）
的报文做分片与重组，实际可用大小取决于双方的 `reasm_bytes` / `reasm_entries` 预算。**协议不提供"续传"**，
一次取不完就换更小的文件。

## 3. 请求格式

```
request      = request-line CRLF [ header CRLF ]* CRLF [ body ]
request-line = METHOD SP request-target [ SP version ] CRLF
```

- `METHOD`：**大写字母**。本版本只定义 `GET`。
- `request-target`：以 `/` 开头的绝对路径，**不允许**空白字符；非 ASCII 不允许。
- `version`：可选，推荐写 `RHTP/1.0`（服务端不校验它）。
- `header`：`Name: value`，`Name` 只允许字母/数字/`-`/`_`；**值里不允许 CR 或 LF**。
- `body`：本版本**不使用**；`GET` 带 body 会被忽略。

最小合法请求（16 字节）：

```
GET / RHTP/1.0\r\n\r\n
```

### 3.1 解析规则（实现即规范）

服务端**只看第一行**，其余一律忽略：

1. 取报文到第一个 CR 或 LF 之前的内容作为请求行；
2. 用 `^%s*(%u+)%s+(%S+)` 提取方法与目标——允许行首空白，方法必须全大写；
3. 目标串里第一个 `?` 或 `#` 之后全部丢弃（查询串与片段不参与路由）；
4. 方法不是 `GET`、或请求行为空、或解析不出目标 ⇒ 走 404，**不是** 405。

因此下面这些都是**合法**的：`  GET /  `、`GET /?probe=1`、`GET /#top`、`GET /\r\nHost: x\r\n`。
下面这些都是 404：`post /`、`PING`、``（空报文）、`nil`。

## 4. 响应格式

```
response      = status-line CRLF [ header CRLF ]* CRLF [ body ]
status-line   = version SP status-code SP reason-phrase CRLF
version       = "RHTP/" 1*DIGIT "." 1*DIGIT
status-code   = 3DIGIT
```

- `version` 固定 `RHTP/1.0`；客户端应接受任何 `RHTP/1.x`。
- 头部块**恰好**以一组空行 `\r\n\r\n` 结束；`body` 是其后**全部**字节（可以再含 CRLF）。
- 头部名大小写不敏感；未识别的头部**必须忽略**，不得报错。

## 5. 状态码与固定正文

| 状态 | 状态行 | 正文 | 触发条件 |
| --- | --- | --- | --- |
| 200 | `RHTP/1.0 200 OK` | 见 §7 | 路由命中 |
| 404 | `RHTP/1.0 404 Not Found` | `Page Not Found` | 未知路径 / 非 GET / 空报文 |
| 404 | `RHTP/1.0 404 Not Found` | `DNS DB Not Found` | `/api/dns_mirror` 但 `dns_db.txt` 不存在或读不出 |
| 500 | `RHTP/1.0 500 Internal Server Error` | `Server Error` | 路由内部抛错（`pcall` 兜底） |

规定：

- `404` 的两个正文**必须**可区分——它们是不同的故障（路径写错 vs 镜像文件没放）。
- `500` 不允许泄漏 Lua 错误串到线上；错误只进服务端日志 `RHTP_ERROR <msg>`。
- 一个请求出错**不能**影响后续请求：socket 保持监听。

## 6. 头部：`X-DNS-Hash`

`/api/dns_mirror` 的 200 响应**必须**带一个头部：

```
X-DNS-Hash: <64 个小写十六进制字符>
```

值 = 正文（即 `dns_db.txt` 的完整内容，不含头部）的 **SHA-256**，编码为小写 hex。

为什么是 hex 而不是原始摘要：32 字节原始摘要里**可能含 CR 或 LF**，那样就会把头部块提前切断，
客户端解析随之错位。hex 编码保证头部行里不可能出现裸 CR/LF。
（`tests/t_rhtp_server.lua` 用一个"摘要里确实含 CR/LF"的正文做了固定用例。）

客户端义务：

1. 若响应带 `X-DNS-Hash`，**必须**用正文重算 SHA-256 并比对，不一致视为响应不可信；
2. 头部存在但正文被替换，等同于哈希不符，**不得**缓存或部分使用；
3. 没有该头部的 200（例如 `/`、`/api/directory`）不做哈希校验。

## 7. 路由表

路由是**精确匹配**（不做前缀、不做尾斜杠归一化）：

| 目标 | 行为 |
| --- | --- |
| `/` | `200`，正文 `Welcome to InterTeamNet` |
| `/api/dns_mirror` | 读文件 `dns_db.txt`：存在 → `200` + `X-DNS-Hash` + 文件原文；不存在 → `404 DNS DB Not Found` |
| `/api/directory` | 读文件 `ip_directory.txt`：存在 → `200` + 文件原文；不存在 → `200` + 内置回落 `root.server 172.16.1.2` |
| 其它一切 | `404 Page Not Found` |

注意 `/api/directory/`（多一个尾斜杠）是 **404**，不是同一条路由。

### 7.1 两个镜像文件

| 文件 | 位置 | 缺失时的行为 | 备注 |
| --- | --- | --- | --- |
| `dns_db.txt` | 服务端工作目录（相对路径） | `404 DNS DB Not Found` | 文本，一行一条记录，内容不被本协议解析 |
| `ip_directory.txt` | 同上 | `200` + 内置回落目录 | 同上 |

服务端**不校验**这两个文件的格式与内容，也不缓存：每个请求都重新读盘，所以改文件即时生效。

## 8. 客户端行为规范

| 项 | 规定 |
| --- | --- |
| 幂等 | `GET` 是幂等的；超时后可安全重发 |
| 重试 | 建议最多 2 次重试，指数退避（100 ms 起，上限 2000 ms）；仍失败则报错给调用方 |
| 状态语义 | **收到合法响应**即算成功（`ok=true`），4xx/5xx 也照样交给调用方看 `status`；只有传输/解析失败才是 `ok=false` |
| 端口 | 客户端应绑定**临时本地端口**（推荐从 40000 起找空位），用完即关 |
| 校验 | 见 §6；`X-DNS-Hash` 不符按失败处理 |
| 缓存 | 本版本不做缓存 |

## 9. 与 HTTP/1.1 的差异（读实现前先看这张表）

| 维度 | HTTP/1.1 | RHTP/1.0 |
| --- | --- | --- |
| 承载 | TCP 流 | UDP 单报文 |
| 版本行 | `HTTP/1.1` | `RHTP/1.0` |
| 方法 | 8 种 | 仅 `GET`（其余一律 404，不是 405） |
| 连接 | keep-alive | 无，一报一回 |
| 分块 | `Transfer-Encoding` | 无 |
| 状态码 | 全套 | 只有 200/404/500 |
| 头部 | 语义丰富 | 只有 `X-DNS-Hash` 有规定，其余忽略 |
| 认证 | 多种 | 无（见 §11） |
| 重定向 | 3xx | 无 |
| 主机名 | `Host` 必需 | 不需要（IPv4 直连） |

## 10. 版本演进

- 版本号形如 `RHTP/<major>.<minor>`；**本规范为 1.0**。
- 客户端必须接受 `RHTP/1.x`；`major` 不同视为不兼容。
- 新增头部 = 不升 major；删除/重命名路由或正文 = 升 major。
- 服务端对未知目标继续返回 404，这是**兼容**行为，不是错误。

## 11. 明确不做的事（别在实现里偷偷加）

- 无认证、无签名：中间人可伪造任何响应，`X-DNS-Hash` 只防**传输截断/错位**，不防伪装。
- 无 TLS / 无 ChaCha20 封装：需要保密时用 `apps/http_secure.lua` 那一套，或换协议。
- 无缓存、无 ETag/Last-Modified。
- 无 POST/PUT/DELETE、无静态目录树、无通配路由、无虚拟主机。
- 无自动重传（服务端侧）。

## 12. 参考实现与验收

| 文件 | 作用 | 验收 |
| --- | --- | --- |
| `rpv1/poc/apps/rhtp_server.lua` | 服务端：`start_rhtp(node, port[, rpv])`、`M.handle_request(data[, log])`、`M.new{...}` | `tests/t_rhtp_server.lua` |
| `rpv1/poc/apps/rhtp_client.lua` | 客户端：`build_request` / `parse_response` / `get` / `call`（异步）/ `rpv_transport`（阻塞，仅测试） | `tests/t_rhtp_client.lua` |
| `rpv1/poc/tests/run.lua` | 把两者都加载进离线套件 | `pwsh -File rpv1/poc/run-offline.ps1` |

离线验收基线（2026-11-01）：`OFFLINE_PASS 2866 / FAIL 0 / GROUPS 31 / LINT_ERRORS 0`。
其中客户端套件用同一个进程内的「桩 node + 桩 rpv」把请求真的走完 client → server → client 一整圈，
不依赖真实网卡，也不需要第二台电脑。
