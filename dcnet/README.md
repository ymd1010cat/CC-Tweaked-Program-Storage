# dcnet — CC:Tweaked 分布式计算网络

重要提示：本项目涉及分布式算力调度，请在部署前务必阅读 DISCLAIMER.md。严禁用于任何恶意卡服行为！

用**有线局域网**把多台 CC:Tweaked 电脑连成一个小集群：**一台主控**负责拆任务、
派任务、收结果、容错重派，**其余电脑**只负责算。

```
              ┌──────────────┐
              │  主控 master │  #2   作业拆分 / 调度 / 汇总 / 容错
              └──────┬───────┘
                     │ 有线调制解调器 + 网络线缆（同一段网络 = 一个广播域）
     ┌───────────────┼───────────────┬───────────────┐
┌────┴────┐     ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
│ 节点 #3 │     │ 节点 #4 │     │ 节点 #5 │     │ 节点 #6 │  只跑 map
└─────────┘     └─────────┘     └─────────┘     └─────────┘
```

- 纯 Lua，无第三方依赖，兼容 Cobalt(Lua 5.1) 与 Lua 5.2+。
- 作业定义（做什么计算）是**独立的小文件**，主控在派任务时把**源码**通过网线
  发给节点，节点不需要预装任何作业 —— 改一行作业代码，整网立刻生效。
- 节点掉线/卡死不会拖垮作业：任务会自动重派给别的节点（可配置重试次数）。
- 部署只要两个文件：`dist/master.lua`（主控）与 `dist/worker.lua`（节点）；
  要在大屏上显示，再按需加 `dist/screen.lua`（网络屏幕，见 §4.3）。

---

## 1. 游戏内准备（有线局域网）

每台电脑需要：

| 物品 | 数量 | 说明 |
| --- | --- | --- |
| 电脑（Computer / Advanced Computer） | 1 | 高级电脑有彩色屏，界面更好看 |
| **有线调制解调器**（Wired Modem） | 1 | **不要用无线调制解调器** |
| **网络线缆**（Networking Cable） | 若干 | 把所有调制解调器串起来 |

接法：

```
[电脑]──[有线调制解调器]══[网络线缆]══[有线调制解调器]──[电脑]
                              │
                        [有线调制解调器]
                              │
                           [电脑]
```

要点：

1. 有线调制解调器**贴在电脑侧面**（贴上去后电脑会多出一个 `modem` 外设）。
2. 网络线缆接在调制解调器上，一段线缆可以拐弯、可以很长（有线没有距离限制）。
3. **同一段线缆上的所有调制解调器属于同一个有线网络**，网内广播可达全部机器；
   两段互不相连的线缆之间消息不会串（天然的隔离）。
4. 在主控上执行 `peripheral.getNames()`，应能看到 `left`/`top` 之类的 modem：

```lua
peripheral.getNames()          -- 例如 { "left", "top" }，"left" 就是那个 modem
```
   程序会自动优先选择**有线**调制解调器；只有无线时也能跑（方便先在单机上调试）。

> ⚠️ 有线调制解调器贴在电脑上之后，需要**右键/使用**它才会生效（或直接接上线缆）。
> 若 `peripheral.getType("left")` 返回的不是 `"modem"`，说明没贴好。

---

## 2. 安装

程序会被打包成两个自包含的单文件，**不需要在游戏里建目录结构**。

### 方式 A：软盘（不需要联网，推荐）

1. 在电脑上放一个磁盘驱动器，插入软盘（Floppy Disk）。
2. 在游戏外把 `dist/master.lua` / `dist/worker.lua` 写进软盘存档目录：
   `saves/<存档>/computer/<ID>/disk/`，或直接在游戏里用 `edit` 粘贴。
3. 拷贝到目标电脑（建议放到 `/dccomp/` 下）：

```
mkdir /dccomp
copy disk/master.lua /dccomp/master.lua      # 主控
copy disk/worker.lua /dccomp/worker.lua      # 每个节点
```

### 方式 B：pastebin（需要该电脑开启 http）

```
pastebin put /dccomp/master.lua   -- 得到 id
pastebin get <id> master.lua
```

### 方式 C：让主控通过网线分发（新机器只要一行）

主控上准备好 `/dccomp/worker.lua` 后，在新电脑上运行 `dist/bootstrap.lua`
（或把它的内容直接 `Ctrl+V` 粘进终端回车）。它会广播找主控、把 `worker.lua`
拉下来、写盘并直接启动：

```lua
-- 懒得传文件？在主控所在网络上任意新电脑里粘这一行也行：
local m=peripheral.find("modem",function(_,d)return not d.isWireless()end) rednet.open(peripheral.getName(m)) shell.run("/dccomp/bootstrap.lua")
```

> `bootstrap.lua` 本身只有 100 行左右，粘一次以后所有节点都不用再传文件。
> 之后也可以用主控的 `push` 指令把新版 `worker.lua` 推给全部在线节点（升级用）。

### 方式 D：一键安装器（最省事）

`dist/install.lua` 是**一个自包含的安装器**（把主控、节点、拉取器、全部作业都塞在
里面，约 457KB）：拷到任意一台电脑上运行即可。

```
install.lua                       装全部（主控 + 节点 + 网络屏幕 + 拉取器 + 作业）
install.lua master                只装主控
install.lua worker                只装节点
install.lua screen                只装网络屏幕（屏幕节点）
install.lua jobs                  只装作业
install.lua all --startup=master  顺便生成开机自启（跑主控）
install.lua all --startup=worker  顺便生成开机自启（跑节点）
install.lua all --startup=screen  顺便生成开机自启（跑网络屏幕）
install.lua all --force           覆盖已存在的文件
install.lua all --cleanup         装完把安装器自己删掉（省 ~457KB 磁盘）
```

默认**不覆盖**已存在的文件，所以重复运行很安全（你改过的作业不会被冲掉）。
安装器自身有 200 多 KB，装完就没用了——它会提示你删掉，或者直接用 `--cleanup`。

### 方式 E：开机自启（强烈建议，升级全靠它）

在每台**节点**的根目录建一个 `/startup.lua`：

```lua
-- /startup.lua
if fs.exists("/dccomp/worker.lua") then
    shell.run("/dccomp/worker.lua")
end
```

这样节点电脑一开机就自动入网；更重要的是，主控的
`push`（推新代码）+ `reboot`（让节点重启）就能**一键全网升级**，不用跑去每台机器前面。
主控机同理可以写 `shell.run("/dccomp/master.lua")`。

---

## 3. 五分钟跑通

**主控机：**

```
/dccomp/master.lua
```

看到状态栏 + 命令提示符 `dcnet> ` 就成功了。首次运行会自动把 5 个示例作业
写到 `/dccomp/jobs/`（含集群自检 `selftest`）。

> **界面语言**：dcnet 的游戏内界面、日志与作业结果默认是**英文**（ASCII），
> 原版 CC 字体即可正常显示，不需要中文字体资源包；需要中文时用 §4.7 的 `lang zh` 切换
> （需要 unixshell 字体盘 + 自建的 `ush-cjk-font.zip` 资源包）。本文档为了说明方便仍用
> 中文，部分示例输出可能是旧版界面。

**每台运算机：**

```
/dccomp/worker.lua
```

主机名、ID、状态都会显示在屏幕上；不用给参数，它会自动广播寻找主控。

**回主控机：**

```
jobs                     列出可用作业
workers                  看节点列表
run selftest             集群自检，先看到 PASS 再干活
run primes to=2000000    跑一个作业
status                   随时看进度
result                   看结果
```

输出示例：

```
[12:03:41] Worker #3 connected: node-3 (wired)
[12:03:44] Worker #4 connected: node-4 (wired)
dcnet> run primes to=2000000
Job #1 primes submitted: 80 tasks  from=2 to=2000000 chunk=25000
Job #1 primes started (80 tasks, priority 0)
dcnet> status
#1   primes       running pri0   ############  57%  tasks 46/80 failed 0  elapsed 12.4s
worker  name         state  done  failed  elapsed   avg/s  current
#3      node-3       busy     24       0     5.1s    4.7/s  #1.47 88%
#4      node-4       busy     22       0     4.9s    4.5/s  #1.48 12%
[12:04:02] Job #1 primes finished: done 80 / failed 0, elapsed 18.3s
  primes in [2, 2000000] = 148933 (max prime 1999993), reduced from 80 tasks
```

对答案：π(1e6)=78498、π(2e6)=148933、π(1e7)=664579。

---

## 4. 主控指令

| 指令 | 说明 |
| --- | --- |
| `help` | 帮助 |
| `status` | 作业总览 + 节点表格 |
| `workers` | 只看节点列表（状态/完成数/平均速度/当前任务） |
| `jobs` | 列出 `/dccomp/jobs/` 下的作业及其参数默认值 |
| `run <作业> [参数..] [pri=N]` | 提交作业，例如 `run primes to=5000000 chunk=10000 pri=5` |
| `run! <作业> ...` | 同上但**跳过结果缓存**，强制重算 |
| `queue` | 作业队列（受 `limit` 控制的并发上限，其余排队） |
| `result [作业号]` | 查看结果（缺省=最近完成的作业） |
| `cancel <作业号>` | 取消作业 |
| `pause [作业号]` / `resume [作业号]` | 暂停 / 恢复派发（不带作业号=全局） |
| `pri <作业号> <优先级>` | 改优先级：同时有活时高优先级的作业先抢到任务 |
| `limit [N]` | 同时执行几个作业（并发上限，缺省 1） |
| `redun [N]` | 抢尾冗余阈值：剩余任务 ≤ N 时把任务复制给空闲节点抢尾 |
| `set <配置项> <值>` | 改配置并**持久化**（`cfg` 看全部配置项） |
| `lang [en\|zh]` | 查看 / 切换界面语言（缺省 `en`，持久化到本机 settings） |
| `cfg` | 显示当前生效的全部配置 |
| `net` | 显示 modem / 网络情况（支持多网段桥接） |
| `state [save\|clear]` | 断点续算快照的状态 / 立即写 / 清除 |
| `cache [clear]` | 结果缓存列表 / 清空 |
| `history [N]` | 最近的作业运行历史 |
| `top [N]` | 节点累计贡献排行（跨会话） |
| `cloud` | 云端端点列表与状态 |
| `cloud add <名字> <url> [并发]` | 注册一个 HTTP 计算服务（持久化） |
| `cloud del <名字>` / `cloud test <名字>` | 删除端点 / 探活（GET 一次） |
| `setkey <密钥>` | 启用消息签名（防冒充/防重放，各机器设成一样） |
| `key` | 查看签名状态、密钥指纹与丢弃统计 |
| `standby [on\|off]` | 待命主控：在岗主控掉线时自动接管并接续作业 |
| `mon [名字\|off]` | 挂载 / 关闭**本地** monitor 大屏面板（持久化；网络上的显示器也能挂） |
| `mon net [on\|off\|kick ID\|unblock ID]` | 网络屏幕：查看 / 开关 / 永久屏蔽（`kick`，持久化）/ 解除屏蔽「另一台电脑 + 显示器」的屏幕节点 |
| `repo <主控ID>` | 查询另一台主控有哪些作业 |
| `pull <主控ID> <作业名…>` | 从它那里拉作业（自动补 `.lua`） |
| `pullall <主控ID>` | 只拉本地没有的（先 `repo` 看清单） |
| `push [节点ID..]` | 把 `/dccomp/worker.lua` 推给节点（缺省=全部在线节点） |
| `reboot [节点ID..]` | 让节点重启电脑；配合 `push` 完成升级（需节点有开机自启） |
| `kick <节点ID>` | 让某个节点退出 |
| `halt` | 让所有节点退出（回到 shell，电脑不关） |
| `shutdown [节点ID..]` | 一键关闭节点电脑（不带参数=全部在线节点） |
| `save <作业号> [路径]` | 结果另存为文件（作业结束时也会自动存到 `/dccomp/out/`） |
| `clear` | 重绘界面（终端被别的东西刷乱时用） |
| `quit` | 关闭主控；节点会继续等待，重开主控后自动重连 |

参数写法：`名字=值`，也可以按作业声明顺序位置传参（`run primes 2 2000000`）；
`pri=N` 是调度器选项（不属于作业参数），控制同一时刻多个作业之间谁先抢到任务。

### 4.1 并发、优先级与抢尾

- **并发**：`limit 2` 可以同时跑两个作业，主控按"优先级降序、提交顺序"给节点派活；
  配置会持久化，重启后仍生效。
- **优先级**：`run ... pri=5` 或事后 `pri <作业号> 5`。优先级只影响**抢任务**的先后，
  不会打断已经在算的任务。
- **抢尾冗余**：`redun 2` 打开后，当某个作业只剩 ≤2 个任务没完成时，主控会把这些
  任务**再复制一份**给空闲节点，谁先回来算谁的（慢节点拖尾时特别有用）。
  重复计算不会影响结果统计：任务一旦完成，第二份结果会被丢弃。

### 4.2 断点续算与结果缓存

- **断点续算**：未完成的作业（连同**已完成任务的结果**）会写进 `/dccomp/state/jobs.dat`，
  主控重启后自动接上，长作业不用从头再算。`state` 看状态、`state save` 立即写、
  `state clear` 清除、`set snapshot false` 关闭。
- **结果缓存**：同一份作业源码 + 同一组参数 → 直接命中缓存出结果，不占集群算力。
  `cache` 看列表、`cache clear` 清空、`run!` 跳过缓存、`set cache false` 关闭。

### 4.3 大屏面板与作业仓库

**monitor 大屏**：把显示器贴到主控侧面就能当集群仪表盘（启动时自动找，也可以
`mon right` 指定、`mon off` 关掉，都会持久化）。面板内容随尺寸自适应：

```
dcnet master #2   12:03:41
Workers 3/3 online   parallel 1/2   queue 1
#1 primes    ############-------  57%
    46/80 done  failed 0  elapsed 12.4s
#3:42% #4:idle #5:63%  cloud:1 run
Total tasks 128 failed 1 retries 2 redundant 4
```

**网络上的显示器**：有线网络会把「贴着有线调制解调器的显示器」暴露成外设
（名字是 `monitor_0` 这种）。这种屏幕主控本来就能用：

```
mon                    # 列表里会标出「（有线网络）」
mon monitor_0          # 直接挂上
```

**网络屏幕（屏幕节点）**：如果显示器是**贴在另一台电脑侧面**的，主控看不到那个
外设——这时让那台电脑当「屏幕节点」：它不参与计算，只接收主控推过来的面板并绘制。

```lua
-- 1) 屏幕电脑：把显示器接上，然后运行 screen.lua
screen.lua                     -- 自动找显示器（缩放 0.5）
screen.lua right --scale=0.4   -- 指定外设名 / 字号
screen.lua --name=机房大屏      -- 主控 mon net 里看到的名字
```

```lua
-- 2) 主控：什么都不用配（netScreen 默认开），screen 会自动登记
mon net                # 网络屏幕：推送中（1/16 台）  #12 screen-12 ...
                       #   被屏蔽时多一行：blocked: #9 #12
mon net off            # 暂停推送（屏幕显示「主控已关闭」）
mon net on             # 恢复
mon net kick 12        # 永久屏蔽某一台（写进 settings，主控重启后依然拒绝）
mon net unblock 12     # 解除屏蔽（下一次心跳就自动重连；also 接受 allow）
```

`kick` 是**持久**操作：主控把被踢的 ID 记进 CC 的 `settings`（`dcnet.screenBlock`，
逗号分隔的 ID 串），此后该屏幕每次心跳都只会收到 `screenoff {why="blocked"}`，
屏幕端显示「Blocked by the master」和该敲的 `mon net unblock <ID>`；主控重启
（断电/重做）后黑名单仍然生效。`mon net` 列表里的 `blocked:` 行就是当前黑名单。
只想让屏幕暂时断开、还要它自己回来时，用 `mon net off` 再 `on`，不要用 `kick`。

屏幕文件的来源：`install.lua screen`（或 `install.lua all`）会写到
`/dccomp/screen.lua`；也可以把 `dist/screen.lua` 直接拷到屏幕电脑；unixshell 下用
`dcnet screen`。屏幕端和主控之间同样有消息签名：集群设了 `setkey` 时，屏幕电脑也要
`set dcnet.key <同一个密钥>`（或 `screen.lua --key=<密钥>`），否则会被丢弃。

限制与取舍：

- 一个主控最多同时接 16 块网络屏幕，面板每秒推一帧（内容是文字行 + 颜色）。
- 屏幕**不参与调度**，不出现在 `workers` 里；它只是显示器，不消耗算力也不能算任务。
- 待命主控（`standby`）不会回应屏幕；在岗主控掉线/接管后，屏幕会在下一次心跳
  （缺省 3 秒）自动连上新主控。
- 任何设了同一个密钥的机器都能当屏幕（它只会收到面板内容，收不到作业/结果）。

**作业仓库**：主控之间可以直接同步作业文件（走分块传输，和 `push` 同一套机制）：

```
repo 42                  # 看 #42 有哪些作业、哪些本地已有
pull 42 cloudprimes      # 拉一个（自动补 .lua，非法文件名会被拒绝）
pullall 42               # 只拉本地没有的
```

> 拉过来的是**可执行代码**——只从你信任的主控拉作业。

### 4.5 消息签名（防冒充 / 防重放）

同一段有线网络里，**任何一台电脑上的任何程序**都能往 dcnet 的频道上发消息——冒充主控
派任务、冒充节点报假结果、或者把抓到的消息原样重放一遍。给集群设一个共享密钥就能挡住：

```
setkey my-super-secret     # 主控上执行一次（会持久化到 settings）
set dcnet.key my-super-secret   # 节点上用 CC 自带的 set 写进 settings，然后重启节点
key                        # 查看状态与「密钥指纹」，核对各机器指纹一致即可
```

打开后：

| 行为 | 说明 |
| --- | --- |
| 每条消息带 `sid`/`seq`/`ts`/`sig` | HMAC-SHA256（纯 Lua 实现，不依赖任何库） |
| 未签名 / 签名不对 | 直接丢弃并记一行日志 |
| 重复或序号回退 | 丢弃（每个会话号只认严格递增的序号） |
| 时间戳偏差 > 120 秒 | 丢弃（防抓到旧消息延后重放） |

**代价与边界**（都是刻意的取舍）：

- 大块内容（分块传输的数据块、下发的作业源码）不直接参与哈希——游戏内电脑算 4KB 的
  SHA-256 要一秒，所以签名里放的是它们的**校验和**；文件本身另有哈希校验。
- 密钥是明文存在 `settings` 里的，能读到 settings 的人就能伪造。它挡的是"局域网里别的
  脚本乱发消息"，**不是**能读到本机文件的攻击者。
- 需要 `bit32`（CC:Tweaked 与 CraftOS-PC 都有）；没有就会明确提示"本机不支持签名"。
- 不设密钥时行为与以前完全一样（不签名、全部放行），单机玩可以不开。

### 4.6 主控高可用（待命主控接管）

主控是单点：它一挂整个集群就停。所以可以再准备一台**待命主控**：

```
master.lua standby          # 或者先 set standby true，之后直接跑 master.lua
```

待命主控**不接活**（不回应节点、不派任务），只盯在岗主控的心跳：

| 情况 | 行为 |
| --- | --- |
| 每 `beatInterval`（默认 3s）收到心跳 | 继续待命 |
| 连续 `takeoverAfter`（默认 15s）没有心跳 | **接管**：广播 takeover、从快照接续作业、开始派任务 |
| 发现另一台在岗主控（ID 更小） | 自动退回待命，避免"双主控"打架 |

**状态接续**靠断点续算快照：已算完的任务带着结果回来（不重算），没算完的重新排队。接管时会打印
`* Took over as master (no master heartbeat for N s)` 和 `Resumed N jobs`。节点侧无需配置——它们发现主控静默超过
`rediscoverAfter`（默认 25s，由主控下发）就重新广播 `who` 找主控，谁应答就跟谁走。

```
standby              # 看当前是"在岗"还是"待命"、已静默多久
standby on / off     # 本机是否默认以待命模式启动（持久化）
```

> **这一段需要两台真机验证**（单机测试桩里两台"主控"是同一个 CraftOS 实例、电脑 ID 相同，
> 节点重连的目标 ID 无法区分，所以只覆盖到"接管 + 状态接续"）：
> 1. 两台电脑跑 `master.lua`，第三台跑 `master.lua standby`，再加 1~2 台 `worker.lua`；
> 2. 主控上 `run selftest tasks=32 size=3000`，等它跑到一半；
> 3. 把在岗主控**退出/断电**；
> 4. 15 秒内待命机应打印 `* Took over as master` + `Resumed 1 jobs`；
> 5. 再过 ≤25 秒，各节点应打印 "found master #N"，作业在新主控上继续跑完（总数不变）。

### 4.7 界面语言（lang）

界面默认是**英文**（ASCII，原版 CC 字体即可正常显示）。需要中文时可以切回：

```
lang            # language: en (available: en, zh)
lang zh         # 切换为中文并持久化
lang en         # 切回英文
```

中文显示复用了 unixshell 的 CJK 模块（`cjk.lua` / `cjk_fonts.lua` / `cjk_shards.lua`，
原名 `cc_chinese.lua` / `cc_fonts.lua` / `cc_font_shards.lua`）。需要准备两样东西：

1. **字形介质**：把 unixshell 的字体盘（release 资产
   `unixshell-fonts-size12-two-disks.zip` 里的两张盘）插到主控电脑的磁盘驱动器上；
   模块按 `cc_fonts.marker` 自动找盘，大小 8/12/16 按优先级自动选。
2. **客户端字体资源包**：直接下载 dcnet release 里的 `ush-cjk-font.zip`（pack_format 15，
   适用于 1.20.1；其他 Minecraft 版本可用 `--pack-format` 重新生成），或按
   [unixshell/tools/respack/README.md](../unixshell/tools/respack/README.md) 自己生成
   （standalone 模式不再需要 CC:Tweaked 的贴图）。放进 `<minecraft>/resourcepacks/` 并启用。

- 缺任一项时：`lang zh` 仍可切换并持久化，但**文字保持英文**（不会乱码），`lang` 命令会
  提示缺字体介质；插好盘后重进主控（或重新 `lang zh`）即生效。
- 中文渲染是**位图**的：一个汉字占 **6×4 个终端格**（size 12），所以含中文的日志行会占
  4 行，日志区一次能显示的行数会变少；纯英文行仍是正常一行。
- 翻译覆盖主控的控制台、日志与内置作业的结果行。**monitor 大屏面板固定英文**（面板是
  6×9 定宽字体布局，混排中文放不下）；节点/网络屏幕自己的控制台也保持英文。
  自己写的作业和协议数据保持原样。
- 语言是**主控本机**的设置（CC settings 的 `dcnet.lang`，持久化）；也可以在启动时用
  `master.lua --lang=zh` 指定。
- 没有字体介质/资源包时请保持 `en`（默认值）。

### 4.4 节点侧（worker 自己的 settings）

节点的这几项配置写在**节点**的 `.settings` 里（用 `set` 指令改不了，它是节点本的）：

| 配置 | 默认 | 说明 |
| --- | --- | --- |
| `dcnet.maxRestarts` | 5 | 异常后最多自动重启几次（自愈） |
| `dcnet.restartDelay` | 5 | 自动重启间隔（秒） |
| `dcnet.rebootAfter` | 0 | 失联多久就重启电脑（秒，0=关；需要开机自启） |

节点异常会写进 `/dccomp/logs/node-<ID>.log`，主控的 `top` 则能看到跨会话的累计贡献。

---

## 5. 内置作业

| 作业 | 说明 | 典型参数 |
| --- | --- | --- |
| `selftest` | **集群自检**：已知答案 + 故障注入，一趟验证链路 | `tasks=24 size=2000` |
| `primes` | 统计区间内素数个数（可对答案） | `to=2000000 chunk=25000` |
| `pi` | 蒙特卡洛估算 π | `samples=2000000 chunk=50000` |
| `mandelbrot` | 并行渲染曼德博集合（ASCII） | `width=48 height=14 rows=2` |
| `hashsearch` | 并行暴力搜索（提前终止型） | `to=4000000 modulus=65536` |
| `cloudprimes` | 素数统计，**优先卸载到云端**，失败自动回落本机 | `to=200000` |
| `bigdata` | **大负载通道**演示：负载/结果超过阈值自动走文件传输 | `tasks=6 size=24000 res=12000` |
| `matmul` | 矩阵乘法（按行分块；矩阵按种子在各节点再生，可对答案） | `n=64 rows=8 seed=7` |
| `nbody` | N 体引力受力分析（净外力应≈0，可自检） | `bodies=256 step=16 seed=3` |
| `tsp` | 旅行商暴力搜索（按第二个城市切分，可对最优解） | `cities=10 seed=5` |
| `ludecomp` | LU 分解解线性方程组（按右端项并行；残差自检） | `n=32 cols=4 seed=11` |

```
run selftest tasks=64 size=5000     # 先跑这个，看到 PASS 再干活
run mandelbrot width=50 height=16
run pi samples=8000000
run hashsearch to=8000000 modulus=1048576
```

### 5.1 装好之后先做自检

`selftest` 用**闭式解**给每个任务对答案（`1²+2²+…+n² = n(n+1)(2n+1)/6`），
同时检查任务号是否齐全、有没有重复，最后打印 `PASS / FAIL`：

```
dcnet> run selftest tasks=48 size=5000
Job #1 selftest submitted: 48 tasks  tasks=48 size=5000 fail=0
...
  tasks 48: expected success 48, actual success 48; expected failures 0 (check main log)
  Sum-of-squares closed-form check: all match
  Task ids: complete, no duplicates
  Result: PASS - link OK
```

再跑一次**故障注入**，验证重派逻辑（前 3 个任务故意报错，会被重派 3 次后记为失败，
但作业仍然汇总成功、其余任务不受影响）：

```
dcnet> run selftest tasks=24 fail=3
  ~ task 1.1 retry: worker error: selftest deliberate failure (task 1)
  ...（每个失败任务出现 3 次）
  x task 1.1 failed: worker error: selftest deliberate failure (task 1) (dispatched 3 times)
Job #1 selftest finished: done 21 / failed 3, elapsed 1.8s
  tasks 24: expected success 21, actual success 21; expected failures 3 (check main log)
  Result: PASS - link OK
```

这两步能过，说明「注册 → 派发 → 计算 → 回传 → 汇总 → 超时重派 → 失败统计」
整条链路都是好的。

---

## 6. 云端卸载（把任务发给互联网上的计算服务）

dcnet 的算力不限于自己的电脑：**任何会 HTTP + JSON 的服务**都能当 worker 用
（云函数、自己的服务器、NAS、同一台机器上的脚本都行）。云端端点在 `workers`
表里显示成 `cloud:<名字>`，和真节点一起参与调度、统计、排行。

```
python cloud/server.py                                   # 在能跑 Python 的机器上
# 然后在主控里：
cloud add local http://192.168.1.20:8080/dcnet 2         # 名字 / URL / 并发
cloud test local
run cloudprimes to=200000
# → [2, 200000] 内素数个数 = 17984；8 个任务，其中云端 6 / 本机 2
```

- **自动回落**：云端慢/挂了 → 任务超时或请求失败 → 回到队列 → 本机节点接手，
  作业里不用写任何容错代码；端点连续失败会进入冷却退避，不再反复撞墙。
- **两种模式**：`set cloudFirst true`（默认，优先云端）／`false`（本机忙不过来才用云端）。
- **协议极简**：`POST <url>` 带 JSON，回 `{ok:true,data:{...}}`；怎么打包/解析由作业的
  `cloud.build` / `cloud.parse` 决定（都在主控上跑，云端不需要懂 dcnet）。

完整协议、写自己服务的方法、安全提醒见 **[docs/CLOUD.md](docs/CLOUD.md)**；
参考服务端在 [cloud/server.py](cloud/server.py)（标准库实现，支持 primes/pi/hashsearch/sleep/echo）。

> 前提：本机 `http` 可用（单人游戏默认开；服务器可能被管理员关掉）。
> CC 默认还会拦 `localhost`/`127.0.0.1`，用**内网 IP**即可。

---

## 7. 写自己的作业

在**主控**上新建 `/dccomp/jobs/myjob.lua`，内容是一段返回 table 的 Lua 代码：

```lua
return {
    name    = "myjob",                  -- 必须与文件名一致
    summary = "一句话说明",
    params  = {                         -- 可选，声明了就能自动解析参数
        { name = "to", type = "number", default = 100000 },
    },

    -- ① 主控运行：把作业拆成任务数组（每个元素会被序列化后发给节点）
    split = function(a)
        local tasks = {}
        for lo = 1, a.to, 1000 do
            tasks[#tasks + 1] = { lo = lo, hi = math.min(lo + 999, a.to) }
        end
        return tasks
    end,

    -- ② 节点运行：算一个任务（严禁长时间不让出，见下）
    map = function(task, ctx)
        local sum = 0
        for i = task.lo, task.hi do
            sum = sum + i
            if i % 256 == 0 then
                ctx.progress((i - task.lo) / (task.hi - task.lo))  -- 0..1，内部节流
                ctx.tick()          -- ★ 必须调用：让出执行权 + 上报心跳
            end
        end
        return { sum = sum }
    end,

    -- ③ 主控运行：汇总所有成功结果
    reduce = function(results)
        local total = 0
        for _, r in ipairs(results) do total = total + r.sum end
        return { total = total }
    end,

    -- ④ 主控运行：把最终结果格式化成给人看的字符串
    format = function(res)
        return "总和 = " .. res.total
    end,
}
```

保存后在主控输入 `jobs` 就能看到 `myjob`，`run myjob to=100000` 即可执行。
**节点无需做任何事** —— 源码会随任务下发。

### ⚠️ 三条硬性规则

1. **热循环里必须周期性调用 `ctx.tick()`。**
   CC:Tweaked 允许一次连续执行 7 秒（`TimeoutState.TIMEOUT`），超时就抛
   `Too long without yielding`，再拖 1.5 秒直接硬中止关掉电脑。
   `ctx.tick()` 用 `os.queueEvent + os.pullEvent` 投递一个事件——在 CC 内部这算
   "收到新事件"，会把 7 秒预算**重置**，所以只要周期性调用就永远不会撞上超时。
   内部按 50ms 节流，顺带上报进度、接收取消指令、维持心跳。
   经验值：让两次 `ctx.tick()` 之间的真实耗时落在几百毫秒内即可
   （重活每 256 次迭代一次，轻活每 4096 次一次）。
2. **`map` 的返回值必须可序列化**：number / string / boolean / table，
   不能包含函数、协程、元表。返回 `nil` 视为任务失败。
3. **作业源码不要太大**（建议 < 8KB）。源码随任务下发，作业文件过大时主控会提示。

作业运行在沙箱环境里（有标准库 `math`/`string`/`table`/`os.clock` 等），
但**不能 `require` 其他文件**，也不能依赖节点上的任何本地文件。

### ctx（节点侧上下文）

| 成员 | 说明 |
| --- | --- |
| `ctx.payload` | 本任务的数据（`split` 返回的那个元素） |
| `ctx.job` / `ctx.task` | 作业号 / 任务号 |
| `ctx.progress(pct, note)` | 上报进度（0..1），内部节流，高频调用无副作用 |
| `ctx.tick()` | **让出 + 心跳**，热循环里必须周期性调用 |
| `ctx.canceled()` | 主控是否已取消本任务（取消后应尽快 `return`） |
| `ctx.log(text)` | 在节点屏幕上打一行日志（排错用） |
| `ctx.now()` / `ctx.mono()` | 墙钟毫秒 / 单调秒 |

---

## 8. 它是怎么工作的

### 大负载走文件通道

任务负载和结果默认内联在消息里（简单、快）。一旦超过 `inlineLimit`（默认 8KB），
就自动改成文件传输——**几十 KB 塞进一条 modem 消息会拖慢游戏，分块传反而更快**：

```
负载下行（节点主动取）              结果上行（节点主动推）
主控: 写 /dccomp/pool/task-1-7.dat   节点: 写 /dccomp/pool/res-1-7.dat
      TASK 里只带 payloadRef ──▶           分块推给主控 ──▶
                                    TASK 里只带 dataRef（读完即删）
```

- 两条路都复用已有的 `dcpush` 分块传输（停等 + 重传 + 收齐校验）。
- 池子文件名有白名单（`task-*.dat` / `res-*.dat`），接收端**按名字决定落盘位置**，
  越界名字（`../x.dat`、`worker.lua`）一律拒绝。
- 传输出问题时结果会退回内联（不会因为通道故障丢任务）；池子里超过 15 分钟没动的
  残file会被自动清理。
- 想关掉：`set fileChannel false`（全部内联），或 `set inlineLimit 999999`。

### 拉模型（pull）

节点空闲时主动发 `pull`，主控从当前作业的待办队列里取一个任务回给它。
好处：

- 节点随时可以重启、上线、下线，主控不需要维护"推送目标"。
- `pull` 同时充当心跳，主控据此判断节点是否还活着。
- 快节点自然多拿任务，**自动负载均衡**，不需要打分排序。

### 容错

| 情况 | 处理 |
| --- | --- |
| 节点 12 秒没有任何消息 | 标记离线，它手上的任务**重新入队** |
| 任务 90 秒没有进度上报 | 任务**重新入队**（有进度就自动顺延） |
| 单个任务重派超过 3 次 | 标记失败，日志打印原因，作业继续跑其余任务 |
| 迟到的结果 | 任务已完成/已失败则忽略，不会重复计数 |
| 作业结束 | 只要有 1 个任务成功就 reduce 汇总，并统计失败数 |

### 事件模型（CC 特有，容易踩坑）

- `rednet.run` 在后台自动把 `modem_message` 转成 `rednet_message`，
  所以程序里用 `rednet.receive` / `os.pullEvent("rednet_message")` 即可。
- 主控跑 4 个协作协程（网络 / 代码推送 / 定时器 / 命令行），节点也跑 4 个
  （网络 / 算任务 / 心跳 / 接收推送）。
- **同一个协议只能有一个 `rednet.receive` 循环**：CC 的 `parallel` 会把同一个
  事件分发给所有 filter 匹配的协程，开两个循环会导致同一条消息被处理两次。
  这也是主控的文件推送用状态机（由定时器驱动）而不是另开接收循环的原因。

### 协议一览

见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。两条 rednet 协议：

- `dccomp` —— 控制与任务（hello/welcome/pull/task/result/progress/cancel/halt…）
- `dcpush` —— 代码分发（fetch/put/putack/putdone/putok/putmiss）

---

## 9. 调参与排错

主控启动参数（可选，`--<配置项>=<值>` 对所有 `cfg` 里的项都适用；命令行 > settings > 默认值）：

```
/dccomp/master.lua --taskTimeout=180 --workerTimeout=20 --maxTries=5 --maxParallel=2 --redundancy=2 -v
```

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `workerTimeout` | 12 秒 | 多久没有节点消息就判离线 |
| `taskTimeout` | 90 秒 | 任务初始超时（自适应开启时会被历史耗时收紧/放宽） |
| `adaptiveTimeout` | true | 按任务耗时 EWMA 自动定每个任务的截止时间 |
| `maxTries` | 3 | 单任务最多派发次数 |
| `pollInterval` | 1.5 秒 | 节点空闲轮询间隔（改小更灵敏、更吵） |
| `maxParallel` | 1 | 同时执行几个作业 |
| `redundancy` | 0 | 抢尾冗余阈值（0=关） |
| `snapshot` / `autoResume` | true | 断点续算快照 / 启动自动续算 |
| `cache` | true | 结果缓存 |
| `twoLevelReduce` | true | 结果多时把 reduce 也拆成并行任务（两级汇总） |
| `reduceThreshold` | 300 | 结果数超过它才启用两级汇总 |
| `cloud` / `cloudFirst` | true | 云端卸载开关 / 优先用云端 |
| `monitor` / `monitorScale` | 空 / 0.5 | 本地 monitor 大屏（空=自动找，`off`=不用）/ 字号缩放 |
| `netScreen` | true | 把面板推给网络屏幕（屏幕节点运行 `screen.lua`） |
| `fileChannel` / `inlineLimit` | true / 8192 | 负载与结果超过多少字节就改走文件通道 |
| `standby` | 本机默认以待命主控启动（在岗主控掉线就接管） |
| `beatInterval` / `takeoverAfter` | 3 / 15 | 心跳间隔 / 多久没心跳就接管（秒） |
| `reHelloAfter` / `rediscoverAfter` | 8 / 25 | 节点重发 hello / 重新搜索主控的静默阈值（秒） |
| `-v` | 关 | 详细日志：打印每一次任务派发 |

改完想持久化就直接用 `set <配置项> <值>`（写进该电脑的 `.settings`），
`cfg` 可随时查看当前生效值。

**常见问题**

| 现象 | 原因 / 处理 |
| --- | --- |
| `没有检测到调制解调器` | 调制解调器没贴到电脑侧面，或贴的是无线调制解调器且没生效 |
| 节点一直"正在寻找主控" | 不在同一段网络线缆上；或主控没启动 |
| 节点报 `Too long without yielding` | 你的作业 `map` 连续 7 秒没调用 `ctx.tick()` |
| 主控/节点报"协议版本不兼容" | 两侧的 `master.lua`/`worker.lua` 版本不一致，用 `push` 或重拷统一 |
| 任务总是失败重派 | 看主控日志的失败原因；节点机器可能算太慢（调大 `taskTimeout`） |
| `push` 报 `worker.lua 不存在` | 主控机上也必须有 `/dccomp/worker.lua`（用来分发给节点） |
| 屏幕被刷乱 | 主控输入 `clear` 重绘 |

**性能提示**

- 任务粒度别太细：每任务几十毫秒到几秒最合适。太细的话网络往返（每任务约
  2 条 rednet 消息）会成为瓶颈；太粗则负载不均、重算代价大。
- 想让结果可复现，作业里自己实现固定种子的随机数（见 `pi` 作业）。
- 主控机也可以很闲 —— 它只做拆分和汇总。反过来，如果作业的 `reduce` 很重，
  瓶颈会落到主控上。

---

## 10. 测试（CraftOS-PC 真机跑）

不用开 Minecraft 也能验证整套东西：用 **CraftOS-PC**（CraftOS 的独立实现）把项目
目录挂载进真机，跑真实源码 + 真实 ROM API。

```bash
python tests/run_craftos.py            # 需要在 PATH 或默认位置有 CraftOS-PC
python tests/run_craftos.py --keep     # 保留真机数据目录，方便自己进机器看
python tests/run_craftos.py --data D   # 换数据目录（缺省 tests/.ccdata，跑完自动删）
```

它做的事：`--mount-rw /project=<项目目录>` 把源码挂进真机，`--script` 跑
[tests/craftos_test.lua](tests/craftos_test.lua)，最后按 "ALL PASS / FAILED" 判定。

真机数据目录默认建在工作区里的 `tests/.ccdata`，跑完自动清理——**不往系统临时目录
写东西**，所以在受限的沙箱环境（只允许写工作区）下也能直接跑；唯一需要工作区外
权限的动作是"执行"CraftOS-PC 本体，那不需要写权限。

覆盖范围（当前 289 项检查）：

| 分组 | 验证内容 |
| --- | --- |
| 环境 | 真 `loadstring`/`setfenv` 分支（`util.loadChunk` 的 5.1 路径）、`parallel`/`window` |
| util | 哈希、时长格式化、带引号分词、参数解析与拒绝未知参数 |
| 作业计算 | `primes` 对答案 π(100000)=9592、`pi` 蒙特卡洛、`mandelbrot` 行宽、`hashsearch` 独立复核、`selftest` 闭式解 |
| 执行预算 | 重活循环里周期性 `ctx.tick()` **不会**触发 `Too long without yielding` |
| 分块传输 | `xfer` 发送/接收状态机往返，16800 字节 5 块重组逐字节一致 |
| 场景 1 | 真 `master.run` + 两个真 `worker.run`：注册 → 派发 → 回收 → 汇总（成功 6/失败 0）→ `push` 分发并落盘 |
| 场景 2 | 故障注入：2 个任务故意报错 → 重试 → 统计 成功 4 / 失败 2，reduce 仍正确 |
| 场景 3 | 节点掉线：把 #4 隔离在总线外 → 主控判离线 → 任务重派 → 10/10 全部成功 |
| 场景 4/5 | 云端卸载：真 HTTP 打到参考服务端（有任务由云端完成）/ 云端不可达 → 冷却并回落本机 |
| 场景 6 | 作业仓库：两台主控之间 `repo`/`pull`，非法作业名被拒 |
| 场景 7 | 打包产物冒烟：真 `shell.run(dist/master.lua)`，假 modem + 注入 `help`/`state`/`quit` |
| 场景 8 | 消息签名：签名集群照常跑完；未签名伪造被丢弃；原样重放被拒 |
| 场景 9 | 大负载通道：24KB 负载经文件通道下发、14KB 结果经文件通道上传 |
| 场景 10 | 主控高可用：待命机按心跳接管 + 从快照接续作业（"节点换主"需两台真机，见 §4.6） |
| 场景 11 | **混沌**：确定性丢包 1/7 + 杀节点 + 重复上报，作业结果仍须完全正确 |
| 场景 12 | 网络屏幕：屏幕节点登记 → 收 disp 帧画出面板 → `mon net off/on/kick`（`kick` 持久化、屏幕被拒且显示 blocked）→ `mon net unblock` 后重连 |

> 混沌测试用的是**确定性丢包**（每 7 条丢 1 条，不用真随机），所以失败可复现。
> 游戏里对应的是：拔网线 / Ctrl+T 干掉节点 / 让别的脚本乱发消息（后者配 `setkey` 直接拒掉）。

测试里主控与节点各跑**一份独立的模块副本**（各自的 `dc_require` 缓存），只把
`dc.net` 的收发换成本进程总线；其它代码路径（`console` 界面、`read()` 输入、
`parallel` 协程、`sched` 调度、`jobs` 沙箱）都是真机原件。

---

## 11. 目录结构与二次开发

```
dcnet/
├── README.md              本文档
├── docs/
│   ├── PROTOCOL.md        通信协议规格
│   ├── CLOUD.md           云端卸载协议与自建服务指南
│   └── JOBS.md            作业开发指南（含调试技巧）
├── cloud/
│   └── server.py         云端参考服务端（Python 标准库，可直接部署）
├── src/                   源码（模块化，开发时用）
│   ├── master.lua         主控入口
│   ├── worker.lua         节点入口
│   ├── screen.lua         网络屏幕入口
│   ├── bootstrap.lua      新节点一键拉取
│   ├── lib/
│   │   ├── util.lua       工具：时间/字符串/哈希/文件/源码装载
│   │   ├── protocol.lua   消息类型与协议常量
│   │   ├── net.lua        有线 modem 发现 + rednet 封装
│   │   ├── console.lua    三区终端界面（状态行/日志/输入）
│   │   ├── xfer.lua       分块可靠传输（停等+重传+校验）
│   │   ├── jobs.lua       作业装载/校验/沙箱执行
│   │   ├── sched.lua      主控调度器（派发/超时/重派/汇总）
│   │   ├── master.lua     主控主逻辑（协程 + 指令）
│   │   ├── worker.lua     节点主逻辑（协程 + 任务执行）
│   │   ├── panel.lua      monitor 大屏面板（本地 + 网络屏幕共用行生成）
│   │   ├── screen.lua     网络屏幕：接收 disp 帧并绘制
│   │   ├── state.lua      持久化：作业快照 / 结果缓存 / 历史 / 贡献统计
│   │   └── cloud.lua      云端卸载：HTTP 端点当虚拟 worker
│   └── jobs/              内置示例作业（会随主控首次运行释放）
├── dist/                  打包产物（部署用 master/worker/screen 三个文件）
│   ├── master.lua
│   ├── worker.lua
│   ├── screen.lua         网络屏幕（可选）
│   ├── bootstrap.lua
│   └── install.lua        一键安装器（自带全部内容）
├── tests/
│   ├── craftos_test.lua   CraftOS-PC 里跑的真机测试
│   └── run_craftos.py     启动真机 / 判定结果
└── tools/
    ├── build.py           打包：src/ → dist/ 单文件
    └── check.py           一致性检查（模块引用/协议常量/作业结构）
```

开发流程：

```bash
python tools/build.py         # 生成 dist/master.lua、worker.lua、screen.lua（自动剥注释）
python tools/check.py         # 一致性检查
python tools/size_report.py   # 体积构成：代码 / 注释 / 字符串 / 中文各占多少
python tests/run_craftos.py   # 真机回归（改完代码跑一遍，绿了再进游戏）
```

改完源码必须重新 `build.py`，游戏里用的是 `dist/` 下的单文件。
`src/` 下的源码也可以直接在游戏里跑（入口自带开发模式加载器，会从 `lib/` 读模块），
方便一边改一边试。

### 体积与注释

CC 电脑默认磁盘上限只有 **1MB**，所以打包时会**剥掉注释与多余空行**（源码保留完整注释，
产物不带）。实测：

| 产物 | 剥注释后 | 说明 |
| --- | --- | --- |
| `dist/master.lua` | **292 KB** | 主控常驻的就是这个（含中文语言包 + CJK 渲染模块） |
| `dist/worker.lua` | **80 KB** | 每台运算节点一份 |
| `dist/install.lua` | **457 KB** | 只在安装时用，装完可删 |

界面文案全部是英文（ASCII），不再依赖中文字体：原版 CC 客户端与 CraftOS-PC 都能直接
正常显示，不需要中文字体资源包。字库本身也不在电脑磁盘上（CC 的终端字体是客户端资源包、
CraftOS-PC 是宿主配置），所以界面文字不占电脑空间。

---

## 12. 在 unixshell 下运行（可选）

dcnet 也可以作为 [unixshell](../unixshell/) 的一个包运行。包源在
`unixshell/tools/pkgs/dcnet/`，由本项目的源码生成：

```bash
cd unixshell
python tools/build_dcnet_pkg.py
```

构建脚本会复制 `dcnet/src/lib/*.lua`、`dcnet/src/jobs/*.lua` 和
`dcnet/dist/worker.lua`，并重建 `dist/`，所以包内容与源码始终一致。

安装到一台 ush 机器（包存储器的 `usr/pkgs/dcnet`，或通过 `pkg install dcnet`）后：

| 命令 | 作用 |
| --- | --- |
| `dcnet master` | 主控控制台 |
| `dcnet master --headless` | 无终端主控，日志 `$DCNET_ROOT/logs/master.log` |
| `dcnet worker [主控ID] [节点名]` | 节点控制台 |
| `dcnet worker --headless` | 无终端节点（可 `&` 到后台） |
| `dcnet screen [显示器名]` | 网络屏幕：把主控面板画到本机显示器上 |
| `dcnet status` / `jobs` / `net` / `config` | 状态、作业、传输与配置 |

配置在 `/etc/dcnet.conf`（样例见包内 `etc/dcnet.conf.example`）：

- `root=`：可写数据目录；root 缺省 `/var/lib/dcnet`，普通用户缺省 `$HOME/.dcnet`
- `transport=rednet|rpv|auto`：`rpv` 走 unixshell 的 RPV1，所有节点必须一致
- `key=`：集群共享的 HMAC 密钥
- 其余键按 `sched.lua` / `worker.lua` 的默认配置项覆盖

包入口用 `dc_require` 风格的直连加载器从包自己的 `lib/dcnet/` 读模块，不依赖
`package.path`；所以包放在哪个存储器的 `usr/pkgs/dcnet` 都能启动。

**启动与多线程**：`/etc/dcnet.conf` 的 `boot=master|worker` 让 `unixshell/startup.lua`
在第一次提示符前启动角色。Advanced Computer 默认走 **multishell**：`/usr/dcnet-tabs.lua`
把 dcnet 放进 tab 1、ush 放进 tab 2，dcnet 先加载，ush 只作为命令控制台；`forward=1`
时 ush 的每一行写入 `<root>/ctl`，由常驻主控执行，`dcnet log` 看输出。非 Advanced
机器或 `multishell=0` 退回 `dcnet ROLE --headless` 后台作业。

**计算端精简镜像**：在 unixshell 仓库运行

```bash
python tools/build_worker.py
```

得到 `unixshell/dist/worker-image/`（15 文件，约 127 KB）：只有 `startup.lua` 和 dcnet
包的 worker 所需模块，循环执行 `dcnet worker --headless`。镜像里**没有** ush、firstboot、
BIOS、man/usr/cmd、`fontdata/`、`lib/cc_chinese.lua`/`cc_font*` 或桌面包——计算端没有
中文字体支持和交互界面。主控端保留完整 unixshell + multishell。

unixshell 仓库里的 `python tools/dcnet_pkg_verify.py` 会在真 CraftOS-PC 上部署 ush +
dcnet 包，并跑 `dcnet version` / `dcnet config` 做端到端验收。

版本：1.3.2 · 协议版本：1 · 适用 CC:Tweaked 1.16+（含 1.20/1.21 系列）
