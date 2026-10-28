# psh 路线图（roadmap）

本文件是 `ROADMAP.md` 的中文版，**必须与它同步**。英文版是权威版本；本文件只是同一内容的
中文表达，不新增、不删减条目。

同步由门禁 7 强制：它把两份文件的**标题结构**逐条比对（连续编号、每一个标题、标题行的顺序），
并要求中文标题里保留对应的英文标题文字。只改一份、或改标题数字、或漏掉一节，门禁就会失败。

> 说明：本文件**永远不会被部署到 CC 电脑**（`tools/deploy.py` 跳过所有 `.md`），所以它可以
> 是中文。ASCII 规则针对的是会真正进机器的文件。

门禁：`tests/run_all.py` 运行 8 个门禁（编译、ASCII、文档、手册/内建、部署自测、配置键、
路线图同步、验收报告自测）加 8 个套件，跨 6 个 Lua 运行时。下面每一处改动都要求改动前后都是 `ALL GREEN`。

---

## 1. rpv 真机文件传输（rpv file transfer on real hardware）

传输本身可用，200 KB 文件**双向**都能过：加上请求重试之后的那次真机运行记录到
`PUSHED 200000 bytes crc=6f5477e4 same=true` 与对端的 `PEER_VERDICT PASS`，客户端 trace 显示
`all 49 chunks acknowledged` 与 `result ok=true`。让每次传输都像掷骰子的控制消息可靠性（1.2）
已修；测试脚手架那一半也已收尾（1.3），还有一处网络半在"应答与请求配对"之前一直藏着的缺陷
（1.4）。剩下的是最后一次真机确认。

### 1.1 已修：服务期间到达的请求被丢弃（Fixed: a request that arrives mid-transfer was dropped）

* **状态**：已修并实测。
* **原因**：`xfer.serve` 在**对端的接收循环内部**一直跑到整次传输结束，所以另一次传输期间到达的
  请求**永远不会被读取**。真机上，推送请求正好落进这个窗口，客户端等满了自己的请求超时。
* **修法**：等待循环把"等待别的消息时撞见的请求"入队（`opts.stash`，由 `xfer.serve` 给自己的
  传输设置），`xfer.serve_pending(opts)` 排空该队列；`netd.lua` 与验收对端在每次请求之后调用它。
* **证据**：修复后真机运行显示拉取 17 s 完成、推送请求 17.55 s 发出——**完全不再重叠**，而修复前
  两者是重叠的。
* **比字面更窄**：`wait_message` 原先只接受发送方等于 `opts.peer` 的消息，于是对端在服务客户端 A
  时，客户端 B 的请求会在进入入队分支之前就被过滤掉、照样丢失。这一点也已修（入队现在接受**任何
  发送方**的请求；只有**应答**才限制在正在服务的那个对端），并由 `tests/batch8_check.lua` 覆盖。

### 1.2 已修：推送不再等待一条会丢的 `ready`（Fixed: the push no longer waits for a `ready` that can be lost）

* **状态**：已修，而且现在**不必上真机**就能复现与验证，见 `tests/batch8`。
* **原本是什么**：对端的 `ready` 是一条没有校验和、没有重传的小控制消息。它一丢，推送就要付满一个
  请求超时然后失败——`put request sent (attempt 1/2)`、无应答、`put request sent (attempt 2/2)`、
  仍无应答；而拉取能活下来，只是因为 `rget` 会重跑整条命令。同一种丢失的另一种形态是 `action`
  完好而 `op` 缺失（`unsupported operation: nil`），有一次运行连着出现三条，正好对应三次 `rget`
  尝试。
* **修法是去掉这个往返，而不是给它加重试。** 推送现在把请求与第 1 块**背靠背**发出（`open_push`），
  并以**那一块**的应答作为受理——块本身已经被 chunk 层用 CRC32 加 ack/missing 保护住了。于是
  "丢了也没人知道"的消息，换成了"丢了会被发现并补回来"的消息。空文件没有块可以作为开场，因此
  保留旧的 request/`ready` 形态，对空文件 `ready` 仍然是决定性应答。
* **三件事全部到位**（上一次尝试三件都做错了，所以被回退）：
  1. 队列忽略一切非请求——而且**块也不会被丢掉**：`stash_block` 按发送方把它缓冲起来，
     `xfer.serve` 返回 `"buffered"`，而不是回一句 `unsupported operation: nil`；
  2. 接收方接受早到的块——`stream_receive` 在开始等待之前先装入缓冲，并照常回 ack；
  3. 请求方不把第 1 块发两遍——`stream_send` 把开场的应答当作 `opts.opener`，跳过自己那一次发送。
* **上一次尝试没能走到的一点**：send/wait 之后那个循环**原样未动**，因为上次真正把拉取弄回归的
  正是那个循环的重构（不是缺 `ready`）。循环里唯一的变化，是等待现在只认**本块**的 ack，而不是
  任意 ack——对 hole list 的一串应答会在邮箱里留下过期 ack，发送方把它读成"没有应答"，白白花掉
  重试预算（`tests/batch3_check.lua` 正好抓到了这一点，这也是那一节留在套件里的原因）。
* **证据**：`tests/batch8_check.lua` 的 "a lost ready no longer stops a push"：把对端的 `ready`
  扣住 30 s（远超两次请求尝试），推送依然完成，且第 1 块在线上只出现一次。"an opener that outruns
  its request, against a real netd" 则让两次推送重叠穿过真正的守护进程，断言两次都落地、并且没有
  任何块被回以 `unsupported operation`。两者都是确定性的，不需要 Minecraft。
* **尚未做**：Minecraft 那一轮。下面这次确认是 CraftOS-PC，它的无线链路在同一个进程内模拟；
  Minecraft 才是唯一真正跑真实 modem 链路的地方。脚本是 `tools/rpv-verify/ps1/_psh-mc-file.ps1`
  （需要抬高服务器的 `computer_space_limit` 并重启），它的 trace 会打出同样的开场形态。这次改动
  没有任何一处是模拟器专属的，所以它更像是最后一句确认，而不是一个还开着的风险。
* **已在真实 CraftOS 运行时上确认，而且这次确认的成色格外好。**
  在本棵树上重跑了 `tools/rpv-verify/_psh-rpv-file.sh`（CraftOS-PC 2.8.3、`transport=rpv`、
  200 KB、49 分块、真实 IP 分片），脚本现在会装 `xfer.trace`，所以整段对话可以逐分支阅读。
  两端判定都是 PASS——`CLIENT_VERDICT PASS` / `SERVER_VERDICT PASS`、
  `pushed size=200000 crc=4c790f2d same_as_source=true`——而且**同一次运行正好抓到了本节所讲的
  那次 `ready` 丢失**：

  ```
  拉取   2.68 get request sent (attempt 1/2)
         7.71 get answer: none (attempt 1/2)          <- ready 确实丢了
         8.22 get request sent (attempt 2/2)
         8.42 get answer: ready (attempt 2/2)         <- 靠重试活了下来
        25.64 rget attempts=1 exit=0 in 23.5s
  推送  25.86 put request sent (attempt 1/2) with block 1/49
        26.27 put answer: ack reason=nil (attempt 1/2) <- 块的应答，第一次就拿到
        26.27 chunk 1/49 was sent with the request; answer=ack
        44.39 rput attempts=1 exit=0 in 18.7s
  ```

  也就是说，这个丢失在真实运行时上**依然会发生**——拉取丢了 `ready`，只靠请求重试才救回来；
  而推送因为不再等那条消息，第一次尝试就开场成功。这正是修法按设计生效，而且是量出来的，不是争出来的。
* **向后兼容**：新客户端仍然认得 `ready`（只是不再等它），而对端若先用 `ready` 回应第 1 块也能
  处理——等待会一直继续到那一块自己的应答到达。旧客户端配新对端不受影响，因为对端照旧发 `ready`。

### 1.3 已修：PC 套件够不到网络那一半——现在够得到了（Fixed: the PC suite could not reach the network half -- it can）

* **状态**：已修。当初让这一条一直开着的那两个说法，重新测过，其中一个是错的。
* **说法一，错的**："H.delay/H.drop 匹配的是解码后的消息，而套件里的对端看不到自己发出的那条应答。"
  `rednet.send` 拿到的就是打包好的 blob，所以谓词可以按 `(from, target, 解码后的 t)` 匹配**对端
  自己发出的**应答。`tests/net_harness.lua` 现在把每个数据报连同方向与解码结果记进 `H.wire`，并
  提供 `H.wire_matching`、`H.by_t`、`H.by_msg`，断言因此能指名它扣住的是哪个数据报。
* **说法二，一半对**："`xfer.serve_pending` 无法从测试体里驱动。" 直接从测试体调用确实会死——
  `attempt to yield from outside a coroutine`，因为测试体不是协程——但把它作为 harness 任务
  派生出去就能跑。`H.pump` 给这件事起了个名字，`H.run_until_blocked` 则把请求方推进到"请求已在
  线上、正在等应答"的那一刻。**不需要新的 pump**：`H.spawn` + `H.run` 本来就是。
* **顺带修掉的**：`H.delay(pred)` 的时长**只**认第二个参数，所以既有的每个 `return 1.5`/`2.5`
  调用其实都被静默地按 1 s 默认值扣住了。这些测试两种情况下都过（洞开出来了就是开出来了），
  所以一直没被发现。包装函数现在显式读第二个参数，并写明了这一点。
* **后果**：1.1 的端到端那一半、重试路径、以及 1.2 的回归，现在都在套件里验证。
  `tests/batch8_check.lua` 从 45 条断言涨到 87 条。

### 1.4 已修：一次 rexec 的应答属于提出它的请求（Fixed: a rexec answer belonged to whoever asked last）

* **状态**：已在机器自己的网络层修好；只改了 `lib/rexec.lua` 一个文件，修复由
  `tests/batch3_check.lua` 的 16 条断言钉住。
* **原因**：`rexec.run` 接受来自目标、`action` 为 `rexec` 且 `t` 为 `result` 的**任何**消息，
  于是一个比它自己的请求活得更久的应答（请求方已经放弃并走开了）会被读成**下一次**请求的答案：
  `rexec -t 2 -q echo two` 打印出了早先那次 `echo one` 的输出。这与包管理器那类缺陷同源
  （请求带 id、应答回显、等待方忽略不是自己的答案）；
  `lib/pkg.lua` 用 id 做了。
* **修法**：请求携带 `id = "<computerID>-<seq>"`；`reply()` 在**每一个**应答里回显它——空命令、
  被拒绝的命令、成功——因为拒绝也是一种应答；`rexec.run` 只在 `answers(msg, id)` 为真时接受结果，
  不是本请求的消息会被忽略、等待继续，而整个等待只有一个在第一次接收之前就定好的截止时间。
  走偏的消息**不能**重置预算，否则一个不断产生散件的频道会让这次调用活得和散件一样久
  （专门做这件事的变异就是套件现在杀掉的六个之一）。
* **兼容性**：不认识 id 的旧对端不回显，而无 id 的结果仍然被接受——这正是不弄坏旧守护进程的原因。
  它留下的限制写在 `answers()` 的注释里、并由两条自己的断言钉住：面对无 id 的对端，同时等待的
  两个请求无法区分，因为应答上没有任何东西指出它属于哪个请求。
* **证据**：`tests/batch3_check.lua` 的 "rexec: an answer belongs to the request that asked for it"
  一节（16 条断言：带**上一个**请求 id `5-1` 的迟到结果、带外来 id 的结果、线上真的带 id 且对端
  回显同一个、一个不回显 id 的对端、迟到的**拒绝**、带 id 的拒绝、空命令拒绝、三条分别在 1 秒等待
  的 0.3 / 0.6 / 0.9 秒到达的散件最终以 TIMEOUT 收场、以及"散件没有延长截止时间"实测恰为
  1000 毫秒）。修复前的 RED 记录：`suite batch3 pass 468 fail 11`，第一行就是缺陷本身
  （面对 `echo fresh-answer` 返回了迟到应答 `STALE-ANSWER-FROM-AN-EARLIER-REQUEST`）。
  已做突变测试——6 个变异全部被抓：不看 id 接受第一条结果、不回显 id、遇到第一个不匹配就放弃、
  只在成功路径上校验 id（于是迟到的拒绝能穿过去）、把无 id 的应答当成不匹配（这会弄坏旧对端）、
  每来一个散件就重置截止时间。batch3：447 → 463（第 2 节那次抓取工作）→ 479（本节）。
* **另记、未修**：`tests/net_harness.lua` 让 rexec 客户端和包服务器共用同一个电脑号（5），
  于是同一个信箱服务两边，一个永不结束的 rexec 任务可能吃掉包请求。这是**测试脚手架**的耦合，
  不是产品问题，写在这里而不是糊过去。

---

## 2. 可移动介质上的包管理（Package management on removable media）

* **状态**：完成并验收，且现在有**两种库**。一个介质是"包仓库"**当且仅当**它带有标记文件；
  标记是唯一的记录，任何地方都不存盘符。
* **两个标记，因为有两种库。** 一台分两部分装的机器——shell 在自己盘上、自己的模块在介质上
  ——必须把那些模块与普通的额外包区分开，因为一个是安装的组成部分、另一个不是：
  * `.pkgsys` —— **系统模块库**：shell 自己要用的模块（手册页、文件传输、服务等）。
    丢了它就要丢功能，所以机器可以要求它（`sys_required=1`、`pkg store sys-required`），
    并在它缺失时被告知。
  * `.pkgstore` —— 普通的**可移动包库**：额外的包。丢了它只是少了那些包。
  一个介质不能同时是两者：把它认作系统库会替换掉普通标记。`roots()` **先搜系统库**，所以当两个
  介质带同名模块时，shell 依赖的那个胜出；`root()`（写入目标）是第一个**普通**库，因为系统库装的
  是安装自带的模块，新包不能混进去。
* `pkg store <n>`、`pkg store remove <n>`、`pkg store auto|required|optional`、
  `pkg store sys <n>` / `sys-required` / `sys-optional`、`pkg store --json`、`pkg list -s`、
  `pkg install [--store N] NAME`；`/etc/pkgstore.conf` 里的 `store_required=1` 与
  `sys_required=1` 是仅有的机器侧规则。
* **警告绝不能盖过拒绝。** `check_root()` **先**问必装库：早先一版先问系统库并提前返回，于是一台
  既要求介质、又缺系统库的机器被告知"系统库缺失"，然后安装照常进行。`tests/batch3_check.lua`
  现在把这个优先级钉住了。
* **已修：应答没有和提出它的那个请求配对。** `pkg.update()` 发出 `list`，然后**把频道上的下一条
  消息**当作应答。安装时 FETCH 的应答可能比它的请求活得久（客户端超时了，应答晚到并留在队列里）；
  它被当成索引缓存下来，于是仓库看起来是**空的**——真机实测三次，形如 `server index shape=a
  leftover fetch reply (ok=true)`，`tools/rpv-verify/_psh-desktop.sh` 当时得最多问三次才绕过去。
  现在每个请求都带一个 id，`pkgserver.lua` 把它原样回显；id 不是本请求的应答——或者来自一个还不
  认识 id 的旧仓库、但**形状**是另一个动作的应答——会被忽略并继续等，而且整个等待只用一个截止时间，
  所以跳过不会延长超时。id 在调用方看到应答之前就被剥掉，`pkg.update()` 也会拒绝形状不是索引的应答，
  而不是缓存成 "0 packages"。只有一个收口：四个 `request()` 调用点（`pkg.update`、`pkg.depends`、
  `pkg.requires`、安装器的 `fetch_cached`）都由同一个函数配对。
* **向后兼容**：id 是增量的。此改动之前的客户端不带 id，应答也就不带回显，一切行为与之前完全相同；
  新客户端配旧仓库时退化为用**形状**分辨两种应答（`list` 的应答是条目数组，`fetch` 的应答带 `ok` 字段），
  这已经覆盖了遗留应答那种情形。没有 id 的仓库唯一无法恢复的情形是"两个 list 应答对应两个不同的 list
  请求"；这个限制写在这里，而不是藏起来。
* **为什么不是"发前排空"**：排空会吃掉队列里现成的东西，而同一个频道上也跑着文件数据块——这正是
  `lib/xfer.lua` 在 `stash_block` 周围记下的伤口：队列可以忽略一切非请求的消息，**但不能丢掉块**。
  配对只消费它已经判定"不是本请求应答"的那些消息，一次一条，用的是旧代码读的同一个单一队列；
  `xfer` 自己的缓冲里一个块都没被动过，chunk 循环也没有被改。
* **证据**：`tests/batch3_check.lua` 的 "pkg: an answer belongs to the request that asked for it"
  一节（21 条断言：带 id 和不带 id 的遗留 fetch 应答、带外来 id 的 list 应答、另一个协议形状的
  数据块消息、线上一个请求一个应答且回显 id、fetch 入口遇到遗留应答、不认识 id 的旧仓库、
  以及"频道上不留应答"），已做突变测试——8 个变异全部被抓（接受第一条消息、不校验 id、
  遇到不匹配就放弃、只在 `pkg.update` 里配对、服务端不回显、把 id 留在缓存的索引里、
  没有形状回退、形状规则把任何表都读成 list 应答）。`tools/rpv-verify/_psh-desktop.sh`
  现在断言索引在**第一次**询问时就拿到（`server index attempts=1`），且回来的东西是索引形状。
  探针自己的 `/etc/pkg.conf` 曾把 `timeout` 从机器缺省（5 秒）提到 60 秒：模拟器把 167 KB 的包
  当成**一条**消息发，这份活儿塞不进 5 秒。以前看起来没事，只是因为 `pkg.install` 会问两次文件集
  （一次预检 `fetch`、一次安装自己的），而第二次等待把第一次迟到的应答当成了自己的答案；配对之后
  这个巧合不可能了，所以等待时间必须按真正的那个应答来定。那 60 秒随后成了一笔**真实重复下载**的
  收据——见下一条，它已被修掉，等待也降回了 20 秒。
* **已修：一次安装会把同一个包下载两遍。** `pkg.install` 用 `pkg.requires` 做预检，而一个 `fetch`
  的应答是**整个文件集**（文件、校验和、摘要），不只是清单，所以安装那一遍的 `fetch_cached` 又把
  同一批字节问了一次。它一直不显形，是因为未配对的旧代码会让第二次等待吃掉第一次的迟到应答；
  配对让重复变成真的，60 秒的探针超时就是收据。现在 `pkg.requires(name, cache)` 把预检的缓存交给
  安装那一遍，**每个包一次安装只 fetch 一次**（依赖仍然各自问一次，为它自己）。缓存里的**失败**也
  同样交出去，所以仓库里没有的包仍然以仓库自己的理由失败（`package not found`），而不是被问第二遍。
  证据：`tests/batch3_check.lua` 的 "pkg: one install costs one fetch per package" 一节（16 条
  断言：在线上数 `fetch` 请求——每个包一次、带一个依赖的包总共恰好两次、每个包拿到的是**它自己的**
  文件集、被拒绝的包只花一次请求并报出仓库的理由、单参数 `pkg.requires` 仍能用且只花一次），
  已做突变测试——6 个变异全部被抓：保留第二次下载；共享缓存但丢掉缓存里的失败；只朝一个方向
  缓存；缓存键不是包名（于是依赖拿到父包的文件集）；预检留着、在另一个入口再发一次请求；
  把失败答案缓存成成功。
  `tools/rpv-verify/_psh-desktop.sh` 自己的等待也随之回落：它写 `timeout=20` 而不是 60，这是真机上
  用 `os.epoch("utc")` 量得的最慢一次单次 fetch 的两倍（167 KB 的包：9552 / 9625 / 8133 毫秒，
  一次 `list` 往返 7 毫秒，一次完整安装 12093 毫秒）。
* **证据**：`tests/batch3_check.lua` 的 "pkg: two markers, the system module store and an
  ordinary store" 一节（71 条断言，已做突变测试——9 个变异全部被抓），加上既有的库相关各节；
  `tools/rpv-verify/ps1/_psh-disk-store.ps1`（三次启动，`RESULT psh-disk-store server=PASS`）。
* **未完成**：此功能没有遗留项。分两部分**安装**（哪些模块放哪个介质）是部署问题，记在第 6.7 节。

---

## 3. 可选的 A4 点阵字体（Optional A4 bitmap font）

* **状态**：完成。`cc_chinese.lua` 与 `cc_font_shards.lua` 位于仓库之外，
  在 `~/.dsh/marvis-export/cc_chinese`；没有携带 `cc_fonts.marker` 的介质时，`pkg` 会拒绝安装。
* **为什么在仓库外**：仓库是 ASCII-only 的（门禁 2），而字形数据不是。
* **未完成**：此功能本身没有遗留项。字形生成器（`fontgen.py`）不在导出包里，要重新生成分片就得
  重新写它（详见 6.3）。

---

## 4. 明确不做（Explicitly out of scope）

* **REPL 集成**：用户已明确说明解释器不集成进 shell。
* **Python 解释器**：单独导出在 `~/.dsh/marvis-export/pythonlib`。它不属于本项目；不要把它放进仓库。
* 第 6 节列出了 Marvis 项目遗留的全部未完成项，包含在本仓库范围之外的部分，以免把"没做完"和
  "不做"混为一谈。

---

## 5. 较小的事项，等上面安静下来再做（Smaller items, worth doing when the above are quiet）

* **`tools/rpv-verify/_psh-mc-server.ps1`**：start/stop/restart/status/logs 可用，但 `-Action start`
  的就绪循环有时阻塞过久；而且作为被杀掉的 shell 的子进程启动的服务器会跟着一起死（README 已写明；
  脚本可以改成真正 detach）。
* **`rpv-log.txt` 无界增长** —— **已完成**。先量后做：节点会记录每一个帧事件，所以一对 200 KB 的
  `rget`/`rput` 每台机器要写约 **14.5 KB** 日志（量到的那次是 live 6490 B + 保留世代 8205 B），
  而且只要机器开着就一直涨，涨进一块只有约 1 MB 的盘；经 Minecraft 世界文件系统读回它时还出现过
  超时，而传输本身是好的。现在 vendored 栈会给 live 日志封顶：`rpv/node.lua` 的 `log_write` 自己
  数写入的字节，超过 `log_max_bytes` 就把 `rpv-log.txt` 移成 `rpv-log.txt.1`（只保留一代，每次轮转
  替换），并新开一个文件、用一行 `LOG_ROTATED` 声明发生了轮转。`0` 表示关掉上限；shell 从
  `/etc/network.conf` 读 `rpv_log_max_bytes`（缺省 131072）。每一步都用 `pcall` 包住，因为轮转不了
  的节点也必须继续记日志。**证据**：`tests/batch8_check.lua`（"rpv: the node log is capped..."，
  13 条断言，已做突变测试）；模拟器验收 `tools/rpv-verify/_psh-rpv-file.sh` 现在故意设 8 KB 上限，
  真实运行里能看到轮转（`live 6490 B + .1 8205 B`，传输仍然 `CLIENT_VERDICT PASS` /
  `SERVER_VERDICT PASS`）；门禁 6 覆盖了新键。
* **报告只打尾部** —— **已完成**。MC 验收过去对每台机器的日志只打印最后十条匹配行，这把"连续三次
  失败的请求"变成了单次事件：早先那几次尝试已经滚出窗口。两个验收脚本现在都通过
  `tools/rpv-verify/log_summary.py` 报告：它把相同的行归组并给出次数，**并且列出每一次出现的
  时间戳**（只有次数会丢掉顺序，而正是顺序让原来那次失败读起来像一件事），打印首尾匹配行，且
  无论模式如何都会打印判定行。日志不存在、日志为空、以及有日志但没有一行匹配，是三条不同的消息
  而不是沉默。**做的时候踩到一个坑**：MC 驱动打的是 `REQUEST op=nil`，而模拟器驱动打的是
  `request op=get`，所以按其中一种词汇写的模式在真实日志里只匹配到 **249 行中的 2 行**——现在匹配
  是大小写不敏感的，门禁 8 就是能抓住这件事的自测。`_psh-mc-file.ps1` 在 `-ClientTrace` 下还增加了
  xfer trace 的打印（前 40 行，按顺序）。
* **验收脚本会被自己的等待杀死**：在最终成功的那次运行里，对端报出 `PUSHED ... same=true` 与
  `PEER_VERDICT PASS`，而客户端自己的判定**从未被读到**——客户端要把 200 KB 文件读回并在
  Minecraft 世界文件系统上写标记，需要数分钟，宿主脚本的等待先结束了。传输是完整的，只是判定丢了。
  等待应由两台机器的日志**各自到达判定**来驱动，而不是由一个时钟驱动；客户端回读也应有上界
  （trace 已经证明了传输，回读只是第二重、且很慢的确认）。
* **`tools/deploy.py` 在 Windows 上的退出码** —— **已不成立，这一条是陈旧的。** 直接量过：第一次
  部署与第二次空操作部署都返回 `0`（`python tools/deploy.py --target <dir> --json` 两次都是
  `exit=0`），门禁 5 一路报的都是 `problems 0`。脚本从 `main` 返回 0，从未采纳 POSIX 那套
  "非零表示有差异"的习惯。
* **配置键**：门禁 6 要求每个被文档承诺的键都在某处被读取。新增键必须同时加进文档和一个读取者，
  否则门禁失败。
* **在 Windows 上重写文件不得加 BOM**：Windows PowerShell 的 `Set-Content -Encoding utf8` 会写入
  BOM，门禁 1 随后会报一个指向**无关行号**的 `UnicodeDecodeError`。请用
  `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))`，
  手工重写过 Lua 文件后回头核对前三字节。

---

## 6. Marvis 项目遗留的未完成工作（Unfinished work carried over from the Marvis project）

本项目出自的那个 Marvis 会话，结束时留下了它自己的未完成清单（在归档 dump 里，标题为
"未完成 / 可继续的方向"，约第 89875 行），而本仓库里的 shell 只是那个会话所建东西的一部分。
本节记录那份清单以及每一项后来的下落，以免有任何东西被默默当成已完成。

dump 本身位于
`C:\Users\ymd10\AppData\Roaming\Tencent\Marvis\User\BEE8C8819ED0EAC0E38D844A06450AE8\workspace\conv_c761312b431a4aa8935c6961ce2b1767\output\deepseek-share-t7l9c9g3h0h72ijjy2-dialogue-original.md`
（2.86 MB，89895 行）。从它导出的东西在仓库之外，位于 `~/.dsh/marvis-export`
（`pythonlib`、`cc_chinese`），各自带有 MANIFEST.md。

### 6.1 Python 解释器（仓库外）（Python interpreter (outside this repository)）

已导出到 `~/.dsh/marvis-export/pythonlib`，**不属于**本项目。以下是那个会话自己列出的缺项，
保留在此，因为导出包里没有这份清单：

| 项 | dump 中的状态 |
| --- | --- |
| `try/except` | 未实现（dump 原话"没有异常处理"） |
| `super()` | 未实现 |
| 生成器 / `yield` | 未实现 |
| 循环导入 | 无保护：A 导入 B、B 导入 A 会一直递归到 Lua 栈溢出 |
| `metaclass=` | 未实现（"改动过大，收益低"） |
| 描述符协议（`__get__` / `__set__` / `__delete__`） | 未实现；与属性访问互相纠缠 |
| `async` / `await` | 未实现；在 CC 里协程语义会撞车 |
| 完整 `inspect` | 未实现；需要源码位置信息 |
| 真正的 `re` 模块 | 未实现；需要一个独立的正则引擎 |
| `__prepare__` | 未实现 |
| 性能 | AST 缓存已做、常量折叠已做，**局部变量槽位化未做** |
| 数值 / 字符串边界 | 整数是 Lua double（53 位）、字符串按字节计数、`1e10` 显示为 `1e+10`、`3.0` 显示为 `3`、`dict` 无 `__hash__`、`raise from` 异常链不生效、`finally` 中的 `return` 覆盖语义不精确、闭包赋值会泄漏 |

要怎么处理其中任何一项，都不属于本仓库的范围；列出它们，是为了让后来者知道这个解释器是
**部分实现**，而不是 Python 3 的克隆。

### 6.2 REPL（决定：不做）（REPL (decision: not doing it)）

dump 写着"`pyrepl.lua` 已写好，但还没集成到 `psh` 里作为一个命令"。用户此后已明确表示解释器
**不**集成进 shell，所以这一项是**按决定不做**，不是被遗忘。`pyrepl.lua` 随解释器一起导出了。

### 6.3 CJK 点阵文字：字形放在它们自己的磁盘上（CJK bitmap text, with the glyphs on disks of their own）

**状态：已完成，跨两块介质。** 每个终端单元 2x3 像素，size 12 的字形宽 6 格高 4 格，六个子像素
标志打包成每格一个字节 `string.char(128 + mask)`。**亮格是大于 128 的字节，空白格恰好是 128**
——这正是为什么"到底画出来没有"是关于**字节**的问题，而不是关于"有没有报错"的问题。

**字形既放不进电脑，也放不进一张介质。** 一台 CraftOS 电脑只有 1,000,000 B，而 shell 已用掉约
74%。整个 GB2312 是 6,763 个表意字、实测 **1,375,263 B**，而一张软盘只有 1,228,800 B ——
**超出 146,463 B** —— 所以全量集按**两块介质**构建，由加载器求并集。介质靠根目录下的
`cc_fonts.marker` 找到，**绝不靠盘符**，因为盘符是插槽的属性而不是数据的属性。

**字形从哪来。** 它们由 `tools/fontgen.py` 在字号 12 下从 **Noto Sans SC**
（`C:\Windows\Fonts\NotoSansSC-VF.ttf`，可变字体，栅格化时选用 Regular 实例）生成。该字体使用
**SIL Open Font License 1.1**，许可证正文与署名在仓库根目录的 `THIRD_PARTY_LICENSES`；
生成的 `fontdata/*.lua` 是它的位图衍生作品，同样按该许可证分发。

**一套集是字形的划分，不是复制。** 每一部分的 `fonts/<base>_index.lua` **只**列出与它同处一块
介质的分片，而 `fonts/<base>.set.lua` 是**每一部分都携带**的清单：集名、部分总数、这是第几部分、
它自己的分片，以及**完整的计划**。计划放在每一部分上，是因为只插着第 2 部分的机器读不到第 1 部分
的清单、也就无从知道缺的正是第 1 部分。因此一对介质是按**清单顺序而非盘符顺序**读取的 —— 已用
"故意把两块盘挂反"验证过。没有清单的介质视为单部分集，所以此前构建的介质仍然可用。

* `lib/cc_chinese.lua` 用 `term.blit` 画字符串
* `lib/cc_font_shards.lua` 从该集的每一块介质按需加载一个分片，并报出哪一部分未插入
* `lib/cc_fonts.lua` 找到各介质（`media()`、`bases()`）以及它们共同构成的集（`parts()`、`manifest()`）
* `tools/fontgen.py`（`--font`、`--size`、`--shard-size`、`--chars`、`--full`、`--json`、`--probe`）
* `tools/fontdisk.py`（`--out` 造一块，`--set-out DIR [--disks N]` 造整套，`--capacity B` 指定容量）
* 介质上也带 `.pkgstore`，因为 `requires_disk=cc_fonts.marker` 只在包管理器已当作存储库的介质上才会被检查。它**绝不能**带 `.pkgsys`：那个标记声明的是 shell 启动所必需的模块。

**字形缺失有四种情形、四个理由、没有静默空白。** 字体不在时 `draw()` 返回
`{ok, reason, drawn, missing, absent, missing_parts}` 且什么都不画；`render()` 抛出一条指明介质的
消息。理由互不相同是因为**修法**不同：没有任何介质带标记（插上它）；带标记的介质没有字形集（重建
它）；按名字钉住的集没有索引（检查那个文件）；**该字形在未插入的那一部分上** ——
`shards.stats().status` 会说 `set shs12 part 1 of 2, part 2 not inserted`，而理由会指明是哪一部分、
哪些分片、以及哪段码点范围。最后这种情形**刻意不画**成回退方框：方框等于声称"字体没有这个字"，
而那是假的。

**实测。** `fontgen.py --full --size 12` 是 6,786 个字形、14 个分片 = 1,375,263 B。
`fontdisk.py --set-out DIR --disks 2` 得到 **part 1 713,670 B（软盘的 58.1%，余 515,130 B，
分片 0-6）**与 **part 2 672,264 B（54.7%，余 556,536 B，分片 7-13）**。size 12 下两块介质够用，而
这个数字是**算出来**的：放不下的 `--disks` 会被带着测量结果拒绝而不是硬挤，单块介质超过
`--capacity` 会被拒绝并且**不写入** —— 这是操作者在一张"看起来已完成"的盘上唯一看不出来的失败。
5,400 字形那套仍然放得进一块介质：1,093,371 B = 89.0%。`fontdata/` 是构建输入，被每一次部署排除
（gate 9 检查这一点）：机器是靠挂载介质拿到字形的，永远不是靠被拷进去。

**已在机器上验证**（`tools/rpv-verify/_psh-font-two-disks.sh` 52 项检查；`_psh-font-medium.sh`
26 项，仍然全绿）。探针捕获 `term.blit` 载荷并对**字节**做断言：两块介质都插着、且**故意挂在错的
盘符上**时，两个索引仍按清单顺序读取；U+4E00 渲染出 **22** 个亮点、U+746D 渲染出 **61** 个，两者
都等于 `fontdisk` 从该介质的 shard 文件里量出的墨迹（`byte - 128` 的置位数之和）；而只插 part 1
时，机器答 `set shs12 part 1 of 2, part 2 not inserted`，对住在 part 2 上的字给出它指明 part 2 与
范围的**理由**，并且为它**一个 blit 都不发**。`tests/batch9_check.lua` 有 169 条断言；gate 9 自测那
两个 Python 工具，包括切分是划分、每块的索引只声明自己的分片、每份清单都带完整计划、以及超容量的
介质会被拒绝。

**未验证的，明写**：CraftOS-PC 无法插入软盘镜像，所以"介质"是一个 `--mount-rw` 目录，"放得下"是
对 1,228,800 B 的算术而不是观察到的软盘写入；缺一半的情形是用只挂一块的第二次启动覆盖的，不是物理
弹出；只生成了 size 12；三块介质的构建做了测量但没有启动；而一对互相不匹配的介质只通过
`cc_fonts.parts(...).foreign` / `shards.stats().foreign` 报告 —— 目前还没有把它打印到屏幕上。

### 6.4 包清单：`depends=`（已完成——本条已过时）（Package manifests: `depends=` (done -- this entry was stale)）

dump 写着"`manifest` 里的 `depends=` 未解析"，而本文件过去也照抄成了未完成项。它**并不是**未完成：
**安装路径确实会消费依赖。**

* `lib/pkg.lua` 里的 `install_tree(name, ctx, is_dependency)` 会递归遍历 `manifest.depends`，
  由 `pkg.install`（`lib/pkg.lua`）调用；它把自依赖拒绝为
  `circular dependency: <name> depends on itself`，把第一个父包的约束记进 `ctx.want`/`ctx.wanted_by`，
  跳过已经满足约束的依赖，安装缺失或过旧的依赖，把失败包装成
  `dependency '<spec>' of '<name>' failed: ...`，并用 `pkg.version_satisfies` 校验取回的版本，
  使仓库无法悄悄交付一个依赖方用不了的版本。
* 版本约束的解析与比较由 `pkg.parse_dependency`、`pkg.version_satisfies`、`pkg.describe_dependency`、
  `pkg.dependency_met`、`pkg.dependencies`、`pkg.depends` 完成，底层是 `lib/semver.lua`
  （所以 `1.10` 比 `1.9` 新）。
* `tests/batch3_check.lua` 的 `pkg: dependency constraints in the manifest` 一节端到端断言了这些
  行为：带依赖的包能装好并把它拉进来；报告里会点名；依赖落在仓库版本上；过新的依赖会被替换
  （`base 2.0.0` → `1.5.0`）；无法满足的约束（`base>=9.0`）会被拒绝并点名 `base` 与 `9.0`，同时
  不动那个依赖；仓库没有的依赖（`ghost>=1.0`）会被拒绝并点名 `ghost`，且不安装依赖方。

所以这里没有要决定的事、也没有要写的代码。保留这一条（并改正），是为了让后来者不至于把已有的东西
再实现一遍。

### 6.5 同一清单里属于 shell 的项及其现状（Shell items from the same list, and their state here）

| dump 中的项 | 在本仓库的现状 |
| --- | --- |
| `sudo` 通配符规则（`guest ALL=(ALL) /bin/ls`） | **已完成**，而本文件过去写的是"未核对"。`lib/sudorules.lua` 读取细粒度的 `/etc/sudo.conf` 策略（`<user> <host>=(<runas>) <command>[, <command>...]`），用 `sudorules.pattern_to_lua` 把 `*` 变成模式，并由 `sudorules.check(user, runas, path, name, is_builtin)` 给出三态答案（true / false / nil）。粗粒度一侧也已完成：`lib/perm.lua` 的 `name_pattern` + `perm.is_sudoer` 支持精确名字、`%group` 条目与 `*` 通配，`tests/batch_check.lua` 有断言。**当时发现的缺口已补上**：`lib/sudorules.lua` 现在在 `tests/batch_check.lua` 里有独立一节（31 条断言），覆盖三态契约、runas 字段、命令通配、`.lua` 后缀、内建命令、裸命令名形式、`user:group` 目标以及 `reload`。 |
| `last` / `lastlog` / `w` / `who`（登录历史） | 命令都在（`usr/cmd/last.lua`、`lastlog.lua`、`w.lua`、`who.lua`），背后是 `lib/sessionlog.lua`（`sessionlog.append`、`sessionlog.history`、`sessionlog.archives`，以及 `/var/log/wtmp` 的轮转）。**当时发现的缺口已补上**：`tests/batch4_check.lua` 现在断言了这个模块（44 条断言）——login/logout/switch_user/crash 收尾、`since` 配对与仅出现在 logout 行的 `end`、live `.dat` 记录、存在损坏记录时 `online()` 的排序，以及 wtmp 轮转下 `history(true)` 与 `history(false)` 的差别。 |
| `cd` 应真正切目录 | **已完成**：`cd` 会影响相对路径（`cwd.resolve`，已用 `cat sub/note.txt` 与 `ls sub` 验证）；dump 的说法已过时 |
| `sed` | **已完成**：是 `usr/psh.lua` 里的 shell 内建（`BUILTINS["sed"]`），底层为 `lib/sed.lua` |

### 6.6 同一会话还建过的其他组件（Other components the same session built）

dump 里还有一个 SQL 引擎，带一长串未实现的 SQL（union、子查询、`EXISTS`、`CASE`、递归 CTE、
窗口函数、`ALTER TABLE`、视图、触发器、索引、外键、`CHECK`、级联、`EXPLAIN`、日期时间与 `BLOB`
类型、`CAST`、`||`、`REGEXP`、全文搜索、存储过程、引擎、分区、`GRANT` / `REVOKE`），以及 RSA 和
类 SQLite 数据库的 Lua 实现。这些都不在本仓库、也不在此计划内；记录下来是为了不把
"Marvis 项目"错当成"这个 shell"。

### 6.7 1MB 电脑上的两部分安装（已实测，且已自动化）（The two-part installation on a 1 MB computer (measured, and now automated)）

CraftOS 电脑的文件系统受 `computer_space_limit` 限制（缺省 1,000,000），而完整部署树
（2026-10-17 实测）为 **1,395,636 B（1.40 MB）**——比上限多 395,636 B，装不下。因此预期形态是两部分：shell 在电脑上，它自己的模块在一个标了
`.pkgsys` 的介质上（第 2 节）。`tools/deploy.py --part base|modules` 现在能产出这两半，并且
这个切分已在 CraftOS-PC 上真实启动验证过。

* **切分（实测）**。第 1 部分（`--part base`）= 启动入口 + `lib/` 的加载期闭包 + `usr/` +
  `etc/` + 根文件 = **781,380 B（1 MB 的 78.1%）**，余 218,620 B。第 2 部分
  （`--part modules`）= 惰性加载的 `lib/` 模块 + `rpv/`（其中 244,313 B 可选：`transport=auto`
  会退回 rednet）= **614,005 B**。整棵部署树 1,395,636 B——这个算术就是切分成为必要的原因。两半可证不相交，且并集正好是整棵树（`comm -12` 只显示 manifest，而 manifest 是每一半各自写的）。
* **只装 base 的那一半曾经根本起不来，而且这个缺陷在两个方向上都是致命的。** 这是切分制造出来、而门禁看不见的缺陷：
  * `usr/psh.lua` 打开会话记账时用的是**缩进**在会话启动函数里的 `require("sessionlog")`。按上面
    的规则，缩进的 require 是惰性的，于是 `lib/sessionlog.lua` 被放到介质上——而登录是进提示符
    之前的**最后一步**。真机实测（`--part base` 部署、完全不插介质）：先打印
    `psh 1.0 - type 'help' for commands`，然后 `/usr/psh.lua:8574: module 'sessionlog' not found`，
    会话循环每轮一次，**提示符永远不会出现**。这是发布件里的老缺陷（提交 1515e3e 的 `usr/psh.lua` 8355-8356 行同构），不是某一次提交引入的回归——但切分把它从
    "惰性" 变成了 "致命"。
  * `firstboot.lua` 压根不是 `tools/deploy.py` 的入口（`ENTRY_POINTS` 只有 `startup.lua` 与
    `usr/psh.lua`），所以切分完全忽略了它的 require。`lib/policy.lua` 与 `lib/time.lua` 留在介质
    上，设置向导以 `/firstboot.lua:19: module 'policy' not found` 死掉，**15 秒内 385 次**——marker
    只有在向导走完之后才写，所以这个循环永远不会结束，机器也永远设置不完。
  * 修法是让两处都对规则可见：`usr/psh.lua` 在**列 0** require `sessionlog`（就在 `space` 与
    `danger` 旁边，理由相同），`firstboot.lua` 加入 `ENTRY_POINTS`（它在开机时运行，位置在
    `startup.lua` 之后、shell 之前）。gate 5 把 `lib/sessionlog.lua`、`lib/policy.lua`、
    `lib/time.lua` 钉在 base 半，共用一条验收标准：**不插介质也必须能启动到提示符、并能完成首启设置**。
  * 证据（这也是为什么它是真机结论而不是套件结论）：一台全新的 CraftOS-PC 电脑用
    `--part base --with-etc` 部署、完全没有介质，走完了整个向导（根密码、用户名、主机名、网络、
    时区），自己写下 `/etc/.configured`，进到 `alice@cc-48:/$`，跑了 `echo hi`、`ls /` 与
    `rm -rf /`（被拒，状态 1，`/usr/psh.lua` 仍是 334,485 B），日志里 **0 条** `module ... not
    found`；同一块盘第二次启动直接进提示符、不再走向导。探针在仓库之外
    （`Temp/psh-baseonly2/run.sh`），和其他真机验收一样。
* **`lib/boot.lua` 曾经在介质上，而两处 `pcall` 把后果藏住了。** 启动身份是**恰好**以
  `pcall(require, "boot")` 取得的：`lib/cron.lua:531`（`local first = ok and b and
  b.begin(REBOOT_MARKER)`）与 `lib/services.lua:70`。切分的扫描器只认 `require("x")`，所以这个
  模块落在 modules 半——又因为两个调用点都用 `pcall` 兜住，机器照常运行、只是**丢功能**，而这
  正是没有任何门禁必须发现的那种失败。实测（全新的 CraftOS-PC 电脑，`--part base --with-etc`、
  完全不插介质；修复前）：`BOOT require_ok=false`、`CRON reboot_fired=0 output_file=false`
  （`@reboot` 的 crontab 条目一次都没触发，任务的输出文件从未生成）、
  `SERVICES started= skipped=probe`——一个带着**上一次启动**留下的 `.started` 标记的 rc.d 单元
  被判成「本 boot 已启动」，永远不再跑，因为 `started_same_boot` 的回落分支就是 `return true`。
  把 `"boot"` 加进 `tools/deploy.py` 的 `BOOT_EXTRA` 之后，同一台机器报 `BOOT require_ok=true`、
  `CRON reboot_fired=1`（runner 的输出文件在盘上）、`SERVICES started=probe`。gate 5 把
  `lib/boot.lua` 钉在 base 半。探针在仓库之外（`Temp/psh-two-fixes/run.sh`）。
* **向导自己的缺省用户名被列在自己的黑名单里。** 全新机器**根本设置不完**：管理员名提示写着
  "Leave blank for default name 'admin'"，直接回车取了这个缺省名，而
  `policy.check_username("admin")` 答 `Rejected: 'admin' is a reserved name` 并重新提问，永远循环。
  矛盾在两个文件之间：`firstboot.lua` 提供这个名字，`etc/passwd.policy` 把它列为保留。**错的是策略
  文件那一侧**——在这个系统里 `admin` 不是保留名，它是机器自己的管理员账户、`lib/perm.lua` 播种的
  level 1 账户（`root:2`、`admin:1`、`guest:0`），而 `firstboot.lua` 在操作者选它时**保留**这个账户
  （只有在选了别的名字时才删掉播种的那个）。`admin` 已从黑名单移除，理由写在名单旁边，免得被加
  回去。注意：模拟文件系统里没有 `/etc/passwd.policy`，`lib/policy.lua` 的内置缺省也从来没列过
  `admin`，所以**只在模拟文件系统里**问 `check_username("admin")` 的套件是全绿的，而每一台**部署
  出去**的机器都卡住：新断言读的是仓库里的 `etc/passwd.policy`，把它装进去，然后用一次回车驱动整个
  向导。真机证据（同一台 base-only 机器）：修复前 `SAW RESERVED-NAME-ERROR` 且没有
  `/etc/.configured`；修复后 `SAW admin-password-prompt`、`SAW setup-complete`、
  `SAW prompt text=[...admin@cc-62:/$ ]`，`/etc/.configured` 里写着
  `{computerId = "62", setup = true}`。
* **决定一个模块归哪一半的是「加载期闭包」**。当模块在启动时被加载期代码触达时它属于 `base`
  —— 入口是 `startup.lua`、`usr/psh.lua` 与 `firstboot.lua`，外加 `startup.lua` 里的
  `pcall(require, ...)`（`cron`、`disk`、`services`），它们同样是加载期运行的：`pcall` 只是
  吞掉失败，shell 仍然要这个模块。写在函数体里的 `require` 只在函数被调用时才跑，所以那种模块
  可以住在介质上。
* **对本节早先一处结论的更正。** 本节早先写过 `lib/pkg.lua` 必须留在电脑上、移走会报
  `module 'pkg' not found`。那是**探针的假象**，不是设计的性质：那个探针用手写的 `startup.lua`
  直接起 `psh.lua`，真实启动路径根本没跑，于是 `pkg` 被过早触达。真实路径是
  `startup.lua` -> `lib/marker.lua` 与 `lib/rpvnet.lua`（2026-10-17 随许可证机制移除的
  那个模块已不在这个闭包里），而 `pkg` 只在 `run_pkg`
  里惰性触达。所以 `lib/pkg.lua` **属于 modules 那一半**，应该放在介质上。约束是加载期闭包，
  而 `pkg` 不在其中。
* **这暴露出的真正缺口：包提供的模块根本无法被 require。** 包本来可以发布命令（`manifest
  bin=`），但**没有任何机制**把包的 `lib/` 目录放进 `package.path`，所以挂载介质上的模块对
  `require()` 是不可见的。已修复：在既有的 `mounts.bin_dirs()`（命令的同一思路）旁新增
  `mounts.module_dirs()` / `mounts.refresh_module_paths()`，接进 `mounts.mount()` 与
  `mounts.umount()`，并在启动时由 `startup.lua` 调用。
* **为什么扫描住在 `mounts.lua` 而不是 `pkg.lua`，这是结构性的。** 在两部分机器上 `pkg.lua`
  本身**在介质上**。一个必须先加载包管理器才能找到介质模块的 shell 永远起不来：那段「把介质
  放进 `package.path`」的代码本身就在介质上。`mounts.lua` 在加载期闭包里、永远在电脑上，所以
  由它负责扫描。`pkg.refresh_module_paths()` / `pkg.module_dirs()` 转调它，方便持有 `pkg`
  句柄的调用方。
* **证据**：在 CraftOS-PC 上带着挂载好的介质启动（`--mount-rw "/disk2=<dir>"`；没有它
  `fs.exists("/disk2")` 为 false，而且这个模拟器里 `disk` API 的驱动器永远 `isPresent=false`）。
  第 1 部分在电脑上，第 2 部分在介质上按 `<root>/<name>/lib/<module>.lua` 布局：`mount=true`、
  `module dirs found=18`、**`require mediumonly=true -> loaded from the system module store`**，
  且探针里**没有任何手动改 `package.path` 的地方**——挂载本身就是接线动作——外加
  `require xfer=true`（从介质）、`stores=/disk2`、`roots=/disk2/usr/pkgs,/usr/pkgs`、
  `sys complete=true`、`psh starts=true`，以及八条命令正常执行（`echo pwd cat grep sed sort
  wc ls`）。`tests/batch3_check.lua` 有 "mounts: modules a package contributes to require()"
  一节（21 条断言，已做突变测试——6 个变异抓住 5 个；第 6 个是无法被隔离的守护断言，见该节注释）。
  这是 CraftOS-PC 的测量，不是 Minecraft 的。
* **未完成**：切分本身没有遗留项。下一个自然步骤是写一个 `tools/` 脚本，一条命令同时产出两半
  与启动镜像，而不是像现在 `tools/rpv-verify/probe_part.sh` 那样手工执行两次 `deploy.py` 调用
  并手工摆包布局。


* **已完成：一条命令产出两半，而且结果被真的启动过。**
  `python tools/twopart.py --out DIR` 写出 `DIR/part1`（电脑）、`DIR/part2`（介质）与
  `DIR/README.txt`。它**不重新实现**切分：它 import `tools/deploy.py`，对每一半调用它的
  `main()`，再用 `deploy.collect()` 把 modules 半读回来核对放了什么。介质按 `lib/pkg.lua` 与
  `lib/mounts.lua` 解析的形状摆放——`.pkgsys` 在根，下面是
  `usr/pkgs/<package>/lib/<module>.lua`——模块按关注点分组。`rpv` 在自己的包里保持目录形状，
  因为 `rpv/loader.lua` 按路径加载兄弟模块，把它们平铺发布会让 `rpv/crypto.lua` 和
  `lib/crypto.lua` 同时应答 `require("crypto")`。**没有列进工具 `GROUPS` 表的 `lib/` 模块是
  错误而不是静默遗漏**：构建会停下来并指名它。构建也拒绝自认成功——它检查 part 1 带上了启动路径
  与完整的加载期闭包、两半不共享模块名、且 part 1 仍然放得下。
* **实测值，而且这个数字是有理由地变动的。** part 1 曾是 **808,370 B（1 MB 上限的 80.8%，
  余 191,630 B）**，然后是 **732,919 B（73.3%，余 267,081 B）**；part 2 为 562,632 B。那
  75,451 B 的差额就是 `lib/man.lua`。同一天再测一次，在把 `sessionlog`/`policy`/`time` 钉进电脑
  （让 base 半能自己启动）之后：`python tools/twopart.py --out DIR` 现在报 part 1 **777,712 B
  / 66 个文件（1,000,000 B 的 77.8%，余 222,288 B）**、part 2 **620,572 B / 50 个文件**（7 个包、
  `.pkgsys`、`sys_required` 开）。part 1 多出的 15,216 B 是逐字节算得清的：13,775 B 是那三个
  模块，1,376 B 是解释两处列 0 require 的注释，65 B 是 manifest 条目；part 2 相应少了同样的
  13,775 B。最后再测一次，在 `lib/boot.lua` 搬到电脑上、`admin` 从密码策略黑名单里移除、死代码
  `lib/lineedit.lua` 被删掉之后：part 1 **781,380 B / 67 个文件（1,000,000 B 的 78.1%，余
  218,620 B）**、part 2 **614,005 B / 48 个文件**、整棵树 **1,395,636 B / 107 个文件**。这两次
  之间 part 1 多了 `lib/boot.lua`（2,930 B，从介质搬来）+ 734 B 解释「`admin` 不是保留名」的
  `etc/passwd.policy` 注释 + 19 B manifest 条目，随后又少了 `usr/psh.lua` 里 15 B 的注释；
  part 2 相应少了这 2,930 B，另外少了 `lib/lineedit.lua` 的 3,637 B——那个模块从来没有被任何
  形式 require 过（psh 把编辑规则内联在自己身上），所以它只是压在介质上的死重量。
* **手册页原本待在机器磁盘上，原因是**一句注释**。** 76,549 B 的散文——除 shell 本体外最大的库
  ——之所以在 base 半，只因为 `lib/complete.lua` 在加载期 require 它，而那是为了让 Tab 能补全
  命令的选项。那个 require 现在改成惰性（没有介质的机器只是补不出选项，而不是让行编辑器抛错），
  于是手册页住到介质上——系统模块库本来就一直是被这样记载的归属。
* **一句注释其实一直在决定切分，而门禁看不见。** `tools/deploy.py` 的 `_requires` 扫描**原始
  源码**，并按匹配所在**行的缩进**判定 "top level"，所以只是在**注释里被提到**的 `require()` 也
  算数，列 0 的注释更会被当成加载期。上面这次搬家的第一次尝试——把
  `local man = require("man")` 这句话写进注释——就把那 76 KB 放回了磁盘，而 gate 5 报
  `problems 0`。`usr/psh.lua:5` 与 `startup.lua:8` 同样各有一行列 0 注释提到
  `require("perm")` 与 `require("cwd")`。扫描器现在先清空注释（保持长度，所以字节偏移与列 0 判定
  仍然指向真实文件），且 gate 5 会写一个临时文件，其行注释、块注释与字符串里各有一个不存在的
  require，断言它们都不被报告、而真实的那个仍被报告。**一个把代码当文本读的工具，必须知道什么是
  文本。**
* **构建是被启动过的，不只是被读过的。** `tools/rpv-verify/_psh-twopart-build.sh` 运行该工具，
  把 `part1/` 拷到 CraftOS-PC 电脑，用 `--mount-rw "/disk2=..."` 挂上 `part2/`，并在探针里断言：
  电脑上**没有**它即将 require 的那个模块的任何副本；仅靠挂载就让 `require("xfer")` 与
  `require("pkg")` 成功，且**探针里任何地方都没有改 `package.path`**；六个包都作为模块目录出现；
  shell 从 part 1 启动并跑通九条命令；把挂载表项去掉后机器自报不完整。
  `RESULT psh-twopart-build=PASS server=PASS`。把树检查唯一看不见的东西——标记——改成
  `.pkgstore` 会让同一次运行失败，说明标记的**种类**是承重的而不是装饰。较老的
  `_psh-twopart.sh` 同样通过（`commands: echo=0 pwd=0 cat=0 grep=0 sed=0 sort=0 wc=0 ls=0`），
  它"跑通八条命令"的说法是正确的。
* **未完成**：`sys_required=1` 还没有登录时警告——它的消费者是 `pkg store`、安装预检与
  `pkg.completeness_warning()`，而 `usr/psh.lua` 从不在登录时调用最后一个，所以机器是"自报不完整"
  而不是打印一行。验收启动会把 `startup.lua` 换成探针，所以真实启动路径（`marker`、`bios`、
  bootguard）只被 `shell.run("/usr/psh.lua")` 加九条命令触及到。介质在 CraftOS-PC 2.8.3 里也无法
  真正弹出："介质缺失"是挂载表项被移除，那是 `lib/pkg.lua` 眼中的弹出，不是硬件事件。

### 6.8 命令集：新增了什么，以及那个说谎的桩（The command set: fifteen additions, and the stub that lied）

新增十五条命令，取自与"只有内核自带"的 Linux 命令的对比：`sha256sum`、`md5sum`、`cksum`、
`base64`、`expr`、`egrep`、`fgrep`、`printenv`、`groups`、`users`、`tty`、`nproc`、`tput`、
`realpath`、`mktemp`。

* **有两条是刻意不做、并记录在案而不是造个假的。** `readlink` 无事可做：CraftOS 没有符号链接，
  每次调用都只会退出 1、什么也不打印。`timeout` 无法兑现：调度器是协作式的，从不调用 `pullEvent`
  的命令无法被抢占——与 Ctrl+C 完全相同的局限，`lib/interrupt.lua` 已经写明。一个承诺了自己无法
  执行的截止时间的命令，比它不存在更糟。
* **`cksum` 是 POSIX CRC-32/CKSUM，不是本项目已有的 zlib CRC-32。** 多项式不同、位序不同，且长度
  要喂进同一个循环：`cksum("abc")` 是 `1219131554 3`，`cksum("123456789")` 是 `930766865`，而
  `checksum.crc32("123456789")` 是 `0xCBF43926`。复用现成的助手会得到一个看似合理的错数字。
* **`fgrep` 把转义后的固定串按扩展语法编译。** 在本项目的基础语法里 `\+ \? \( \) \|` 是
  运算符，所以用 `regex.escape()` 转义后再按基础语法编译会匹配错误的文本——`fgrep 'a+b'` 会匹配
  `ab` 和 `aab`。固定串本来就没有语法，读这些转义的语法属于内部细节。两个方向都做了断言。
* **`tput bold`/`smul`/`rmul`/`sgr0` 什么都不写并退出 0。** 这台机器没有粗体或下划线属性，颜色是
  靠调用 `term.setTextColour` 而不是写转义字节来设置的。手册页写明了这一点；输出一段终端根本不
  解释的 ANSI 序列才是安静的谎言。
* **那个说谎的桩，以及它藏住的 bug。** `mktemp -d` 向文件系统要一个目录，并把 `fs.makeDir` 的
  **返回值**当作成功信号。真 ROM 上 `fs.makeDir` **什么都不返回**——实测：新建目录返回 `nil`
  （type nil），已存在的目录也返回 `nil`——于是它那一百次尝试全部看起来失败，命令以 1 退出并打印
  `mktemp: cannot create a name from '/var/tmp/tmp.XXXXXX'`，**却在测试套件里通过了每一条断言**，
  因为测试桩的 `fs.makeDir` 返回 `true`。两边都已修：`mktemp` 改用 `fs.exists` 确认目录，桩也改成
  像 ROM 一样不返回任何东西。回归已被抓住——把 `mktemp` 改回按返回值判断会让套件变红
  （416 通过 / 2 失败）。**这条普遍教训比修复本身更值钱：一个比它所替代之物更宽容的桩，会把硬件
  故障转换成绿色的测试。** 其余调用 `fs.makeDir` 的地方都忽略其返回值，那是正确的。
* **已修：stderr 重定向现在是真的。** 这个 shell 原本**根本没有第二条流**——`emit_diag` 写到和
  `emit` 完全相同的地方——所以 `2>` 既没被遵守也没被拒绝：它被读成**参数 `2`** 加一个普通的 stdout
  重定向。修复前在机器上实测：`echo hi 2> f` 把文本 `hi 2` 写进 `f` 并退出 **0**；
  `echo hi 2> /dev/null` 退出 0，丢掉的是 `hi 2` 而不是诊断信息；`echo hi > f 2>&1` 以 **127** 退出
  并报 "command not found"。**静默的错误输出比报错更糟**，所以这条从"记录待决定"变成了已完成。
  * 只有**数字紧接** `>` 时才识别 `2>`、`2>>` 与 `2>&1`——`echo 2 > f` 仍是参数 `2` 加一个 stdout
    重定向，这与 POSIX 一致。`1>`/`1>>` 作为写全的 stdout 重定向被接受，而 `1>&2` 被拒绝而不是被读成
    参数。
  * **重定向的顺序被遵守**：`> f 2>&1` 把诊断送进 `f`，而 `2>&1 > f` 把它们留在控制台，因为那次复制
    捕获的是**解析到它时**已存在的 stdout。有一处局限写在代码里而不是藏起来：`> a 2>&1 > b` 会给
    `b` 而不是 `a`。
  * 修复后在 CraftOS-PC 上实测：`echo hi 2> f` 让 `f` 为空；`echo hi > f 2>&1` 写入 `hi` 并退出 0；
    `nosuchcmd 2> f` 把诊断放进 `f` 并退出 127；`nosuchcmd 2>&1 > f` 让 `f` 为空而诊断在控制台；
    `2>>` 追加；`echo 2 > f`（带空格）仍然写入 `2`。
  * 证据：`tests/batch_check.lua` 的 "stderr redirection: 2>, 2>> and 2>&1 are real" 一节——12 条断言
    读的是**文件内容**而不是只看状态，因为旧 bug 产生的正是状态 0。已做突变测试：顺序被忽略、诊断永不
    重定向、`2>` 被词法分析成普通 `>`、`2>` 目标被丢弃、`2>>` 变成截断——全部被抓。
* **证据**：`tests/batch_check.lua` 从 358 条断言增到 418 条，全部做过突变测试（试了 41 个变异，
  全部被抓；其中一条断言在那轮里被发现太弱并已加强）。这十五条命令随后在 CraftOS-PC 本机上实跑过，
  不只是跑在 PC 桩上，上面那些数值就是机器打印出来的。



### 6.9 类 GNOME 桌面，作为一个可选软件包（A GNOME-like desktop, as an optional package）

**状态：已完成。** `tools/pkgs/gnome/` 是 `gnome` 包的源（`bin=desktop`，版本 1.7.0）：
文本网格里的 Ubuntu GNOME —— 近黑的一行顶栏（Activities、居中的时钟、状态区）、**沿左边缘常驻
的 dock**（默认三列，`opts.dock_w`；一条灰色分隔线单元，每个图标下有一个运行指示点）、一个位于
工作区内、可点击应用网格的活动概览、紫到橙分带的壁纸，以及带标题栏 / 右侧关闭控件 / 点击聚焦 /
点击置顶 / 拖标题栏的窗口。强调色是**橙色**，只出现在画面上说"就是这个"的地方：打开的 Activity、
选中的卡片、运行指示点，以及焦点窗口标题栏左侧的一格橙色标记（计算器里"刚按下的键"用的是同一个
颜色，但低一层：那是应用自己的反馈，不是桌面的 chrome）。随包带六个应用：**Terminal 把项目
自己的 shell 跑在它自己的窗口里**（`>_` 收藏图标、第一张卡片）、文件浏览器、一个设置面板
（分节、占用条、机器上的实时数字——见 1.7.0）、一个键可点、也能用键盘的计算器、一个
**任务管理器**（它自己的任务会数自己被打断恢复过多少次），以及一个 **Console** ——
它与 Terminal 是**同一个窗口内 shell 的第二个名字**（见下面 1.6.0）。安装与运行：
`sudo pkg install gnome`，然后 `desktop`；加 `--headless --events FILE --dump FILE` 可渲染进缓冲
并打印单元格。

这个包是**真正额外**的：base 安装里没有任何东西提到它，且 `tools/` 在 `tools/deploy.py` 的
`SKIP_DIRS` 里，所以任何部署都不可能把源放到机器上 —— 这也正是主机侧包源该放在 `tools/pkgs/`
的理由。验收断言部署后的树里**没有任何叫 `gnome` 的路径**，并断言该包在 `pkg install` 之前不存在、
之后存在。本包不含任何第三方代码；这里描述的机制都是在本仓库里、针对 CraftOS 自己的 API 实现的。

**1.3.0：Ubuntu 的样子，并且打开不再单例。** `Desktop:open(id)` 现在每次调用都**新建一个窗口**；
它原先会抬起已存在的那一份，这使桌面更像任务切换器，也让"开两个文件浏览器"变得不可能。同一个应用
的窗口标题是 `Files`、`Files 2`、`Files 3` —— 按创建顺序编号，并在某个窗口关闭后重新编号，所以唯一
幸存的那个又叫回 `Files`，而不是留下一个没有 `Files` 的 `Files 2`；dump 的 `WINDOW` 行仍带 `id=` 与
`title=`，两份可以区分。每个窗口的每一点状态都住在窗口上（`win.state`、`win.tasks`，以及 Console
建的那个 ROM 窗口），套件对此的断言是：把一个文件浏览器移动进 `/demo`，再把另一个的路径读回来 ——
应用模块自身不持有可变状态。任务管理器列出的是**窗口**而不是应用，所以两份都会列出。

**工作区**是"窗口可以待在哪"的唯一答案：`desktop.WORK(w, h, dock_w)` 是 dock 分隔线右侧、顶栏之下的
一切（51x19 屏幕上为 x=5 y=2 47x18），`default_geometry`、`move_window`、概览网格与拖动都对着它
度量。于是窗口不可能停在 dock 上或顶栏之下，拖过角点会被夹到 `(5,2)` 而不是 `(1,1)`。旧的底部 dash
**已删除** —— `desktop.dash()` 与 `Desktop:dash_layout()` 被替换成 `desktop.dock()` 与
`Desktop:dock_layout()`，且**没有留别名**，因此不存在两套要同步的面板。dock 属于 chrome：桌面态**和**
概览态都画它（Ubuntu 的概览同样保留 dock）、画在每个窗口之后，并且**先于任何窗口**接收点击。点击图标
就是**新开一个窗口**，只要该应用还有至少一个窗口，图标下的点就亮着。

**1.4.0：桌面可以成为机器启动时直接进入的会话。** 默认仍是 psh：什么都不设的机器进 shell，
在会话里敲 `desktop` 是进入方式，离开桌面又回到 psh。`desktop --autostart on` 让**下一次启动**直接
进桌面，`off` 恢复 psh，`status` 报告下一次启动会做什么。它**仅 root 可用** —— 这决定了机器从哪里
开始，能被普通账号切换的会话就是被夺走的机器 —— 所以控制台账号会被拒绝（状态 1），并提示
`sudo desktop --autostart on`。机制刻意很小：命令只写**一个通用键** `command=desktop` 到
`/etc/session.conf`，基础启动脚本读这个键（base 安装里**不出现包名**，所以"没有任何 base 文件提到
这个包"的断言仍然成立），通过 psh 运行它（于是包命令的解析与会话里完全一致），且**每次启动只运行
一次**，随后照常启动 psh。会话命令抛错或跑不起来会被报告并**回落到 shell**，所以一个被删掉的包不会
让机器停在一块空屏上。真机验收实跑了这个开关：控制台账号被拒绝、root 写入文件、`status` 报告
`desktop`、`off` 又把文件删掉。读侧——机器真的重启并运行文件里写的那条命令——现由
`tools/rpv-verify/_psh-boot.sh` 验收（见下面 1.5.0）。

**1.5.0：多开 Console，一个终端、一个读。** 泵原先是单槽：第二个 Console 的 shell 会被
"a program is already being pumped" 拒绝，桌面同一时刻只能跑一个窗口里的 shell。现在它是
**注册表**（`desktop.pumps`，按注册顺序），机器唯一的那次 `os.pullEvent` 只在**第一个**泵开始时
装一层包装、**最后一个**泵结束时恢复；每次调用由「正在调用的那个协程」找到它自己的泵状态，不属于
任何泵的调用者照旧直达机器。于是 `#desktop.pumps` 就是「此刻有几个程序正在被泵」，每一项是该程序
的状态（协程、任务、窗口、终端目标、请求过滤器、答案、事件数）。

一个事件只投给**一个**泵，规则写在代码里、也由套件钉住：① 焦点窗口的泵（如果它在等这个事件）——
键盘属于操作者正在看的那个窗口，后台窗口的泵**一个 key/char 都拿不到**；② 否则按注册顺序
（先注册者优先）——后台 shell 的 timer 与 rednet 消息正是这样送达的。鼠标点击仍归焦点窗口；
概览打开时完全不泵。

`term.redirect` 也是全局的，所以泵接受一个终端目标（`opts.term`），并在程序的**每一片**之前
重新断言它——终端是每一个协程共享的一份机器状态，只在开头指定一次的目标挡不住中途另一个泵
的重定向。没有它，只要 console 2 最后重定向了 term，console 1
的命令输出就会落进 console 2 的窗口：第二个 console 只是第一个 shell 的一个视图，而不是一个
shell。代码里另有两个后果：Console 的 ROM 窗口建在**桌面自己的**终端（`d.term_target`）之下，
绝不用 `term.current()`（开了一个 console 之后，那正是另一个 console 的窗口）；一个泵结束时把
终端交给「仍在运行、且有终端目标」的**最后注册**的那个泵，一个都不剩时才交回桌面。关闭窗口会丢掉
那个窗口的泵，所以关掉一个 Console 不会把包装器留到会话结束。**Terminal** 应用在 1.5.0 里刻意
**不变**（当时它的语义就是整屏独占交接，那是另一种诚实的形态，而不是第二套实现）；1.6.0 把它换成
了与 Console 相同的窗口内 shell —— 见下面。

有一条操作者会碰到的后果，明写而不是藏着：当 Console 的 shell 拿着焦点时，按键（Escape 或
桌面的 F10）进的是 **shell** 而不是桌面，所以关掉 console 窗口要用它的 `[x]` 控件（点击是
桌面的事件，按键是焦点 shell 的）。真机验收正是这样关掉两个 console 的。

1.5.0 这一轮：`tests/batch10_check.lua` 从 412 条增到 **451** 条（新增一节：在假的 ROM window
API 上开两个真的 Console、把按键投给焦点那个、证明后台那个没被投喂、让一个程序结束而另一个继续
被泵、检查包装器只装了一次且只在最后一个泵结束时恢复、再开三个 Console 验证序号/标题）。**10 个
变异全部被抓**：投递不看焦点、广播给所有泵、回退顺序反过来、按键能到后台泵、第一个泵结束就恢复
包装器、每个泵各装一次包装器、结束的泵留在注册表里、去掉每片之前的终端重断言、console 窗口建在
`term.current()` 之下。真机上 `tools/rpv-verify/_psh-desktop.sh` 从 89 项增到 **106** 项，其中
包括**同时开两个 Console**：两个提示符各自画出，`echo two` 打进焦点那个、`echo one` 打进另一个，
两个 ROM 窗口各自用 `getLine` 读回、各自只包含自己的命令——两个窗口里两个独立的 shell，而面板与
dock 仍在屏幕上。dump 行 `PUMP active=` 变成 `PUMPS n active=.. peak=..` 加每个泵一行
`PUMP <i> ...`（验收 grep 的是 `PUMP 1 active=true`）。

**1.6.0：窗口的边，和一个「本身就是窗口」的 Terminal。** 一个实测报来的 bug，一个设计变更。

*裁剪。* 应用都通过 `api.write/cell/fill` 绘制，而它们原先直接调屏幕。屏幕只在**显示器**边界裁剪，
不在窗口边界裁剪，所以一条比窗口内部更宽的行会画到窗口边框、它后面的窗口和 dock 上 —— 用户报的原话
就是"字溢出了窗口"。Console 之所以没露，只是因为它自己逐格 `:sub` 裁过；别的应用离同一个 bug 只差
一个长字符串。裁剪现在住在 `Desktop:app_api()` 里，也就是**每个应用唯一的绘制入口**，所以新应用
不可能忘：`write` 只保留落在内部列区间里的字符（包括从内部左边之外起头的那一段）、`cell` 丢掉内部
之外的单元格、`fill` 把矩形与内部求交，掉掉的每一格都记进 `stats.clipped` —— dump 里也有，追加在
`term_asserts` 之后，所以 STATS 行的前缀不变。窗口自己的 chrome 也在同一轮查过：底部边框按窗口宽度
截断（所以比三格还窄的窗口不会把右端画到下一格上）、没有格的窗口什么都不画、`paint_error` 只写内部
且每行按宽度截断。

*Terminal。* 直到 1.5.0，Terminal 就是整屏交接：桌面释放屏幕、`psh` 占有它、shell 退出后桌面重绘。
那是诚实的，但它**不是窗口** —— 会话期间面板和 dock 消失，旁边什么都不能用。更好的机制本来就有，
因为它正是 Console 用的那个：在**桌面自己的**终端之下
建一个 ROM 窗口，加上事件泵替 shell 的阻塞读接事件，并在每一片之前重新断言 `term.redirect`
——这台机器只有一个全局终端、由所有泵共享，所以每一片都得为当前这个程序重新夺回。共享实现在 `lib/gnome/apps/shellwin.lua`
（`main(api, win, opts)` 与 `draw(api, win, opts)`，带 `opts.title` / `opts.banner`），
`terminal.lua` 与 `console.lua` 都只是它的薄封装 —— 于是只有一个 shell、一个泵、一处
"the shell left" 要修。Terminal 保留 `>_` 图标、名字与概览第一张卡片；它不再写
"press ENTER to start a session"，也不再调 `handover()`：ENTER 是 shell 自己的键，而当 shell 离开
（在机器允许离开时）窗口会显示 "the shell left"，而不是把桌面让出去。`Desktop:handover` **保留** ——
需要整个终端的程序仍然有这种形态可以要 —— 套件改用**合成应用**来测它，所以这条 API 不需要靠任何
随包应用才能被钉住。

*Terminal 与 Console 是同一机制的两个名字，这一点明写而不是暗示。* 选择保留两者、而不是删掉 Console
把卡片让给 Terminal，理由是：第六张卡片是 1.5.0 已发布的，也是真机验收两个 Console 场景（C2、C3）
驱动的名字 ——「两个 shell、两个窗口、一个事件只投一个」正是靠它在真机上证明的；而 Terminal 是
"机器的 shell" 的传统名字、dock 收藏与第一张卡片。删掉 Console 只改标签、不改行为，却会削弱那组
证据；保留两者的代价是一个名字，而不是一份代码拷贝。

*1.6.0 这一轮。* `tests/batch10_check.lua` 从 453 条增到 **494** 条：17 条专测裁剪（内部最后一列
仍被写入、窗口右侧的格完全没被画、越过右边一格被丢、从内部左侧起头的写入只丢掉外面那段、向右或向下
越界的 fill 停在边界、写在内部下方的一行到不了底部边框也到不了桌面、在屏幕右下角再验一遍、
`stats.clipped` 对越界的应用增长而对恰好画满边界的应用保持 0、计数进 dump），整节交接改为**合成
应用**驱动（原有 15 条保留）并新增 3 条钉住「Terminal 不再交接屏幕」，以及 19 条窗口内 Terminal
（泵属于那个窗口、它的 ROM 窗口建在桌面终端之下、泵被告知自己的终端、并排两个 shell 时按键只进
焦点那个、退格作为 key 事件送进 shell 而不被桌面吃掉、ENTER 让其中一个结束且窗口显示
"the shell left" 而另一个继续被泵、全程没有交接、两个应用
模块是同一个共享模块的封装，两个封装只差在它们交给共享 shell 的标题与横幅）。**10 个变异全部被抓**：
去掉 x 裁剪、去掉 y 裁剪、`cell` 不裁、`fill` 不裁、裁剪计数从不增长、Terminal 退回 `handover()`、
共享模块不经泵直接跑 shell、泵不带终端目标、去掉 "the shell left" 那行、Terminal 戴上 Console 的
名字与横幅。真机上
`tools/rpv-verify/_psh-desktop.sh` 从 106 项增到 **110** 项：旧的交接场景被 C1 取代 —— 在 Terminal
窗口里驱动真的 `psh`（在它的提示符敲的命令跑在那个窗口自己的 ROM 窗口里，用 `getLine` 读回，面板与
dock 仍在屏幕上，`screen handovers=0`），而 C2 与 C3（两个 Console）保持不变。那份验收里**没有任何
一处**调用 `Desktop:handover`；这条 API 在 PC 侧用合成应用测。

**1.7.0：可读的单位、真正的设置面板，以及一个像计算器的计算器。** 这一轮的起点是一句反馈：
"设置和计算器有点抽象了，剩余磁盘空间需要自动调整单位，计算器 UI 需要优化下" —— 说得对：设置窗口
原先是六行字符串加两个可点的行，计算器是一格一格的标签，机器一边说 `2097152 B`、另一边说 `320239B`。

*一条千字节阶梯，只在一个模块里。* `lib/gnome/fmt.lua` 拥有单位算术：1024 进制、B/KB/MB/GB、
**字节不带小数**而更大的单位恰好一位（`0 B`、`1 B`、`1023 B`、`1.0 KB`、`1025 B` → `1.0 KB`、
`732.9 KB`、`1.0 MB`），并且**四舍五入后刚好是 `1024.0` 的值会被进位**而不是原样打出来，所以比一兆
少一个字节读作 `1.0 MB` 而不是 `1024.0 KB`。缺失或不可能的数字是 `?`，绝不是 0 —— 0 是一种断言。
它还带来 `percent`（一位小数、夹在 0..100、没有可除的东西时是 `?`）与两个窗口需要的三个对齐工具
（`fit` 保留头部、丢掉的尾巴用 `>` 标出；`fit_left` 保留尾部、丢掉的头部用 `>` 标出；`pad` 只加宽
不截断）。设置面板的总量/剩余与文件浏览器的尺寸列都走它；没有任何应用再手写 `" B"`。这条阶梯的
第一版**整体落后一格**（它用 1024 的幂去索引标签表，而不是用标签自身的位置），于是 4 MB 打成了
`4.0 KB`；套件的 known answers 在收尾前就抓到了它，现在边界值本身就是断言：0、1、1023、1024、
1025、比一兆少一个字节、一兆、五兆、一吉，另加一条独立的断言"千字节以下的字节数不含小数点"。

*设置窗口是一个面板。* 三个分节 —— `System`（hostname、会话用户、屏幕、时钟）、`Storage`（总量、
剩余、一条占用条、已装包数）、`About`（本包版本、shell 版本）—— 都是键值行，一个标签列加一个值列。
每一项都是实时的、都被 pcall 包住：`os.getComputerLabel`、`perm.get_current_user`、
`fs.getCapacity`/`fs.getFreeSpace`、`pkg.list`，以及从**已安装的 manifest** 读到的包版本（没有就是
`?` 或源码树里的常量）。shell 根本没有版本模块，所以它的版本是从**自己源码尾部**那行横幅里读出来的
（每个窗口一次）；找不到文件就是 `?`。body 宽度至少 36 格时，一节的左右两半并排（十行，正好是默认
窗口的内部高度）；窄 body 则把字段竖排、用方向键与翻页键滚动，于是 12 列的内部仍然可读、每个字段
仍然够得到。占用条画成 `[####----] 50.0%`：**实心格数是从这一行打印出来的百分比数出来的**，所以条与
数字不可能互相矛盾，套件则把两者都从屏幕读回来、再从百分比反推长度。两个动作保留在面板最后一行：
面板颜色（对桌面自身调色板的真实改变）与登出。模块级没有任何可变状态 —— 滚动位置住在窗口的 state
里，两个设置窗口各自滚动是**被断言过的**。

*计算器是一个计算器。* 一行右对齐的显示区，输入过长时**从左侧截断**（最新的数字才重要）并加 `>`
标记；下面一行是 AC 与退格，再下面就是 4x4 网格 —— `7 8 9 /`、`4 5 6 *`、`1 2 3 -`、`0 . = +`。
每个键都是一块两行高的反色单元，所以即使标签看不见键也看得见；指针下的键用调色板的 brown，刚按下的
键穿强调橙并且**自己会熄灭**（熄灭它的是桌面的时钟，所以测试能看着它发生）。几何是 body 尺寸的一个
函数，绘制与命中测试都调用它；窄 body 把键缩到两格，而不是把它们推出窗口。鼠标与键盘是同一批按键：
数字、`.`、四个运算符、ENTER 当 `=`、退格，`c`/`C` 当 AC，而**桌面的返回键 F10 刻意留给桌面**。语义是立即
执行、从左到右：**2 + 3 * 4 是 20，不是 14** —— 不做优先级，这句话写在文件头注释里、这段文字里，
并由一条断言钉住（既查 20，也查 14 不出现）。除零在显示区用错误色打出 `error: divide by zero` 并且
仍然可用（AC 或一个数字重新开始）；`=` 之后再按数字是**开一个新数**，而不是接在答案后面。

*为了这一切，桌面多了一条能力。* 指针移动原先除了拖动之外被完全忽略，所以"悬停"不可能存在。现在
`mouse_move` 会被交给焦点窗口的应用（计入 `stats.moves`，追加在 STATS 行的 `clipped` 之后，所以该行
前缀不变）；它不是拖动、不移动焦点，不关心的应用直接忽略它。

这一轮：`tests/batch10_check.lua` 从 494 增到 **582** 条断言。原有的计算器/设置断言被改到新布局上
（显示的 `10` 从第 6 列移到第 42 列、`7` 键从第 7 行移到第 6 行、`+` 键从 (10,24) 到 (12,33)、设置
标题从第 4 行的 `System settings` 改成第 4 行的 `System` 分节、两个动作从第 8/9 行移到最后一行的左右
两列），新增的三节是单位阶梯（23）、设置面板（35）与计算器（29）。试了十个变异，**十个全被抓**：
千字节边界改成 1000、字节带小数、剩余空间打印成裸字节、占用条永远满、占用条按另一个百分比计数、
除零给出答案而非报错、`=` 把答案留在数字里、去掉悬停高亮、去掉按下高亮、删掉一个分节标题。其中一个
暴露的是**死代码而不是测试漏洞**：第一个 "=" 变异活了下来，因为计算器带着一个**没人能观察到**的
`fresh` 标志 —— 真正决定"开新数"的是数字被清空 —— 于是删掉这个标志，而"把答案留在数字里"的变异
才是咬得住的那个。`tools/rpv-verify/_psh-desktop.sh` 从 111 项增到 **136** 项，而且现在由**机器自己**
驱动这两个窗口：在机器自己的概览里点 Settings 卡片，然后从窗口的单元格上读面板——三个分节标题、
带单位的 `total` 与 `free`、占用条以及它据此打印的百分比、已装包的版本、动作行——再用窗口自己的
`[x]` 关掉；点 Calculator 卡片，在机器的键盘上敲：`2+3=` 得 5、鼠标点 7 键则显示 7、`1/0=` 报出
除零、`=` 之后再按数字开新数。两者都只读窗口**自己的 body**（默认窗口的第 6..43 列），所以紧挨着
的 dock 图标不会被当成答案。这补上了这一段原先承认的缺口：在此之前，设置与计算器的每一个单元格
都只在 PC 套件的缓冲区里被断言过。

**1.7.1：离开桌面一定落在 psh。** 报告很具体：在一台由启动脚本**直接**启动桌面的机器上，离开桌面
（空桌面按 F10，或设置面板里的 log out）会落到 **CraftOS 提示符**——机器自己的系统没了，而这
正是 "log out" 绝不能做的事。`Desktop:quit` 一直是、也仍然是唯一的出口；缺的是**落点**。
`desktop.landing` 用**事实**而不是对调用者的猜测来决定：psh 会给它运行的每个命令 chunk 打上
`__psh_command`（`usr/psh.lua`，就在当初 require 修复引入的那张新的命令环境表里），所以**本身就是
shell 命令**的桌面直接返回那个提示符——在那里再起一个 shell 会套娃；而由启动脚本、或从 CraftOS
提示符启动的桌面，会替它把 `/usr/psh.lua` 起来。起不来的 shell 报 `shell-failed` 且命令以 1 退出，
而不是假装落地；**被中断**的桌面也走同一个落点：Ctrl+T 同样结束一个桌面，操作者不该从这扇门掉出
系统。设置面板保留 log out 动作——它离开桌面（其 `Desktop:quit("settings")` 被钉住），现在落在
psh；并且没有任何窗口能关机或重启（`batch10` 扫描整个包找 `os.shutdown` / `os.reboot` / `os.exit`）。
`tests/batch10_check.lua` 582 → 595：落点的七个答案、命令侧的四条接线事实（它确实询问落点、把
shell 的标记传进去、点名的就是 `/usr/psh.lua`、而且两条退出路径都会问），以及那道扫描。并且在报告来源的那台机器上端到端量过——一个直接启动桌面的
演示启动脚本，开机前就把操作者会按的那下 F10 排进队列：日志先是 "the desktop was left"，随后是
psh 的横幅与 `admin@cc-0:/$`；同样的离开以前打出的是 ROM 提示符。

**1.7.2：logout 结束的是 psh 会话，不是机器。** 设置面板里的 log out 以前和 F10 一样
只是退出桌面——操作者回到同一个 psh 提示符、仍然是登录状态。现在它向 shell 要的是
「手敲 `logout`」的效果：`bin/desktop.lua` 写 `/var/lib/.logout`（**只在桌面由 shell 启动**
时写，别处启动没有会话可结束），`usr/psh.lua` 的交互循环在**会话边界**——正是手敲 `logout`
被判定处理的地方——认可它、删除请求并结束会话，启动脚本的看门狗再起一个全新的 psh。
这就是「任何退出都落在 psh」的含义：从桌面出来的任何一条路，都不会把机器丢在它自己的系统
之外。`tests/batch10_check.lua` 595 → 598 钉住三件事（动作以 `logout` 为理由退出、请求会被
写且带守卫、shell 会去找它）。**1.7.3** 把产品名从壁纸上拿掉：背景只留那一行快捷键
提示（"press o for the overview"），不再写软件叫什么。`tests/batch10_check.lua`
仍是 598（原来的标题断言改成"壁纸上没有产品名"与"提示在自己那一行"），真机验收
改为断言提示的列。

**1.7.4 到 1.7.6：壁纸是真正的渐变。** 用户要求背景更平滑。原色板只有十六色、彼此相距很远，
四条平带已经是它诚实的上限，所以壁纸现在用 `term.setPaletteColour` 把**六个不被任何 chrome
使用的槽位**——purple、magenta、green、pink、lightBlue、brown——重定义为 Ubuntu 紫到橙的六个
真实 RGB 点。在真机上绕一次桌面启动实测：桌面运行期间六个槽位读回
`0.294/0.165/0.388` …… `0.976/0.502/0.114`，离开之后又回到原生颜色
（`0.698/0.400/0.898` ……）。**每行一个槽位、不做抖动**：1.7.4/1.7.5 的 4×2 单格混合在 51×19
的屏上仍然看得出是图案，因为一个单元格就是一个大色块。离开桌面（quit、中断、handover）时槽位
会被放回，而且恢复读的是 `nativePaletteColour` 而不是 `getPaletteColour`：在 CraftOS-PC 2.8.3
上，没人设过的槽位对后者回答 `#191919`（0.098），照它恢复会把 shell 提示符的槽位涂成深灰——一台
离开桌面后看起来坏掉的机器。这一点是**从真实终端读回调色板**才发现的，套件抓不到。
`tests/batch10_check.lua` 599 → 612（六个槽位确实被定义、每次运行只装一次、一行只有一个槽位、
没有调色板的屏幕走回退、退出时恢复、以及按原生色恢复），`_psh-desktop.sh` 137 → 139（顶行与
底行是不同槽位、一行只有一个槽位），`_psh-boot.sh` 仍是 27 项通过。

**1.7.7：终端那个真 bug，和一个文本编辑器。** 用户一轮里提了两件事。先说 bug：图形界面里打开
终端，窗口里出现的是**当前桌面的副本**、打字像什么都没发生。问题不在 shell。自 1.6.0 起，被
泵的程序会把全局 `term` 重定向到它自己的隐形窗口，而 term API 的 blit 跟着重定向走——桌面当
时正是通过 API 画的。于是 shell 被喂过一次事件之后，桌面画的每一帧都进了 shell 的窗口（实测：
窗口的行就是屏幕第 1..10 行——"Activities"、dock、标题栏），shell 的提示符被覆盖。无头套件看
不到它：它渲染进 buffer、根本不碰 term。现在 `desktop.new` 把屏幕建在**终端对象**上
（`screen.term(d.term_target)`），桌面作画不再取决于谁重定向了 API。`tests/batch10_check.lua`
用"破坏全局 term 之后桌面仍须画自己的终端"把它钉住；真机验收新增 C1R：同样的 shell 跑在**真实
终端**上，断言 shell 窗口里有 "echo hi"/"hi" 且**没有**面板。
编辑器：新的 `gnome.apps.editor` 窗口，行缓冲，方向键、Home/End、PageUp/PageDown、Enter、
Backspace、Delete、Tab 与可打印 `char` 输入；Ctrl+S 或 F2 保存（F2 是因为有的构建判不出 Ctrl
是否按住）。窗口显示文件名、行列号、未保存标记，以及保存结果或保存不了的原因。Files 增加了
选中行，Enter 对选中项生效；对文件它只调一个**有文档的接缝**
`api.open("editor", { path = ... })`，而 `Desktop:open(id, opts)` 现在把 opts 交给应用的 open
钩子。真机验收会写一个文件、在 Files 里选中、Enter 打开、输入一个字符、F2 保存，并断言文件
**自己的字节**；`tests/batch10_check.lua` 613 → 629，`_psh-desktop.sh` 141 → 144。

**1.7.9：Files 能滚动，编辑器能自动换行、撤销、查找。** 用户用完 1.7.7 后提的两件事。
Files 原来只显示十行、后面的目录项够不到：现在有一个跟随选中的滚动偏移（方向键、
PageUp/PageDown、Home/End），`files.visible` 是唯一"把选中留在屏幕上"的函数，条目比窗口多时
路径行右侧显示 `sel/total`，点击也走同一个偏移换算（包括 `<..>` 行）。编辑器补上文本窗口的
三件事：**软换行**——`wrap_layout` 把逻辑行推成显示行、不插入任何字符，所以 38 列正文里 100
个字符是三个显示行，而保存写的是你敲的那些字符；方向键按**显示行**移动，长行的手感与眼睛一致。
**撤销**——每次编辑一个快照、上限 200 步，Ctrl+Z 或 F4（F4 是因为有的构建判不出 Ctrl 是否
按住）。**查找**——Ctrl+F 或 F3 打开提示行（字符进查询、不进缓冲区），Enter 找第一处、F3 找
下一处并环绕。`tests/batch10_check.lua` 635 → 656（换行布局与光标映射、F4/Ctrl+Z 撤销与空
栈、查找提示/首处/下一处/环绕，以及 Files 滚动：选中越过窗口、`sel/total`、点击滚动后的行、
end 与 home）；`_psh-desktop.sh` 147 → 152 在真机上驱动：敲 60 个字符占两行 38+22 格且文件里
60 个都在，F4 撤销后 F2 保存，F3 + 查询 + Enter 把光标放到第 2 行第 1 列的 `world` 上且不动
文档内容。

**1.8.0：单击选中，双击打开。** Files 里点一下文件夹以前会立刻进入，于是双击会连进两层、
点文件第二下则什么也不发生——那一行只是留着变成色块。现在按桌面惯例：单击只选中，半秒内
第二次点击**打开**它（文件夹进入、文件进编辑器、`<..>` 回上级），时间源是桌面时钟
（`api.desktop.now`，只在 tick 时前进），所以无头测试可以不等就驱动两次点击。Enter 仍然打开
选中行。`tests/batch10_check.lua` 656 → 665（单击不进入、隔很久的第二下不打开、两下快速点击
进入、点文件一下不打开、两下打开编辑器、`<..>`），真机验收也改成双击文件夹与文件。

**1.8.1：选中效果可读，壁纸提示字看得清。** 两个外观反馈。Files 的选中行原来是橙底黑字，
用户说透过它看不清文件名：现在是灰底白字，并且——这正是第一版改完看起来坏掉的原因——**背景也要
传给文字写入**，因为 `api.write` 不带 bg 时会画默认背景，在每个字符后面把选中条打出黑洞。
壁纸上的快捷键提示原来是色带上的灰字，难以辨认：改用壁纸自己的前景色（白），这是桌面已经
确认在每条色带上都清楚的唯一颜色。`tests/batch10_check.lua` 665 → 666（提示的颜色、以及
选中条：白字灰底且名字仍在行里）。

**1.8.2：双击窗口改为两秒。** 真机上双击打不开了：窗口是**桌面时钟**的半秒，而两次人手点击之间
过去多少 tick 取决于机器——慢的时候凑够数就落到窗口外了。现在窗口是 2 秒，仍不会混淆两次独立
点击（单击只选中，且点到另一行就重置配对）；`tests/batch10_check.lua` 666 → 667，新增“慢一点
（一秒）的双击仍要进入文件夹”的断言。

**1.8.3：配对是“连续两次点击”，不是时间窗。** `<..>` 回上级在真机上仍然失败：2 秒窗口量的是
**桌面时钟**，而一次双击的两下之间过去多少 tick 不是这个应用能知道的（先用 0.5 秒、再改 2 秒，
慢机上第二下仍然落在窗口外）。现在的规则回到它一开始就该有的样子：**同一行连续点击两次**、
中间没有别的动作——点到别的行、按任何键、进入或离开目录都会重置配对，且完全不读时钟。
不同行的两次点击永远配不成对，所以浏览过程中不会误打开东西。`tests/batch10_check.lua` 仍为
667，把窗口时代的两条断言换成了“中间点了别的行就重新开始”和“慢的第二下仍进入文件夹
（不读时钟）”。

**1.8.5：返回键是 F10，因为 Escape 根本到不了机器。** 桌面的那个「返回」键——退出概览、关掉
焦点窗口、离开桌面——原来用的是 ROM 的 Escape 键码（1），编辑器离开查找提示也靠它。在这个包
真正运行的平台上，那个键不存在：Minecraft 把 ESC 留给自己的菜单，从不投递给电脑，所以
`keys.escape` 是 nil，两处分支都是死代码（BIOS 菜单在 `lib/bios.lua` 里学到的是同一课）。
现在的键是 **F10（LWJGL 键码 68）**：它是 ROM 确实会投递的功能键之一，vanilla Minecraft 没有
默认绑定，而且没有字符，所以不会被误打进文本框。编辑器改用 **F9（67；空 query 加 Enter 仍然
能关闭提示）** 离开查找，因为 F10 会被桌面先消费掉、应用根本收不到。`tests/batch10_check.lua`
677 → 689 钉住三级深度、`f10` 退出原因、桌面消费该键而不转发、编辑器的 F9，以及一道源码
扫描：包里不再有任何文件比较 `KEYS.escape` 或 ROM 的 Escape 键码。真机上 `_psh-desktop.sh`
用键码 68 驱动同一条返回阶梯。


**1.7.8：一次只允许一个桌面。** Terminal 与 Console 把 shell 跑在窗口里，于是
在那个提示符敲 `desktop` 会在该窗口里再起一个桌面——它的帧会被画进外层桌面的隐形
窗口，两个泵争一条事件流，而且操作者没有任何看得见的回头路。命令现在在"终端不是机器
自己的屏幕"时拒绝：`desktop.needs_whole_screen(term.current())` 问的是区分窗口与机器屏幕的那一个事实：
CraftOS-PC 2.8.3 实测，机器自己的终端**没有 `getLine`**（`term.native()` 与作为屏幕时的
`term.current()` 都是 nil），而每个 `window.create` 出来的窗口都有——所以能回答 `getLine` 的
终端会被拒绝，给出理由与状态 1。用身份比较会错：同样实测，即使就在机器自己的屏幕上，
`term.current()` 也**不等于** `term.native()`；这个守卫的第一版因此把所有地方都拒绝了（启动
路径当场抓到）。问不出答案的机器放行，因为错误的拒绝会让桌面彻底进不去。`tests/batch10_check.lua` 635 = 629 + 6
钉住决策本身（窗口 / 自己屏幕 / 问不出答案）与命令源码的顺序（守卫在 `run_interactive`
之前）；真机验收会往 Terminal 窗口里敲 `desktop`，断言被拒绝、没有出现第二个桌面窗口、
且该窗口仍只有它那一个 shell（`_psh-desktop.sh` 147 项）。

**1.3.0 那一轮发现的一个缺陷**，它不在这个包的范围里：`lib/pkg.lua` 的 `pkg.update` 把频道上的
**下一条消息**当作它 "list" 请求的应答，于是安装时 FETCH 留在队列里的**一份应答**会被当成索引、
存成 "0 packages"（实测三次，形如 `server index shape=a leftover fetch reply (ok=true)`）。**现在已修**：每个
请求带 id、仓库回显 id，不是本请求的应答会被忽略而等待继续、整个等待只有一个截止时间——真机验收
如今**一次**就拿到索引（`server index attempts=1`），不再最多问三次。机制在第 2 节，配对之后暴露
出来的那次**重复下载**也在那一节里修掉了。

**启动时读取现在是真的验过，而不只是把源码钉住。** `tools/rpv-verify/_psh-boot.sh` 用
`tools/deploy.py --with-etc` 部署项目自己的树，所以机器上的 `/startup.lua` 就是真的那个（逐字节
比较断言）；它启动两次，并通过 CraftOS-PC 的 `--script` 传进一个观察者：该文件在 `/startup.lua`
**之前**、在同一个 Lua 状态里运行，包住 `term.write`/`term.blit`，把每个字符串连同它的行、列、
前景/背景记下来，并在桌面画出来之后入队**一个** F10 按键事件（无头机器的 stdin 不是键盘——
实测；从机器内部入队事件是唯一能「打字进去」的办法）。第一次启动没有 `/etc/session.conf`：落在
psh 的横幅与提示符上，且从未画过面板。第二次启动带着 `--autostart on` 会写的那一个键：面板画在
第 1 行第 1 列、dock 的 `>_` 画在第 2 行第 1 列，随后 F10 离开桌面，启动脚本打印
"the session ended; starting psh"，psh 的横幅与提示符接着出现——共 27 项检查，
`RESULT psh-boot=PASS`。gnome 包是**预置**到 `/usr/pkgs` 的（连同安装器会写的 bins 注册表），
因为无头启动没法跑 `pkg install`；安装路径本身是 `_psh-desktop.sh` 的主题。

**它画的一切都经过一个可注入的屏幕**（`lib/gnome/screen.lua`），因为
**`term.getLine` 在 CraftOS-PC 2.8.3 上不存在**：单元格无法从真实屏幕读回，所以 PC 套件与真机验收
都渲染进一个**保留每格字符、前景与背景**的缓冲。无头路径是一个**有文档的模式**而不是测试钩子，且
`desktop.run(screen, events)` 返回它画入的那个屏幕。`tests/batch10_check.lua` 有 689 条断言，
`tools/rpv-verify/_psh-desktop.sh` 在机器上跑 152 项检查：从包源建一个仓库目录、用 `pkgserver.lua`
把它服务出去、在第二台电脑上用机器自己的 `sudo pkg install` 安装、用**合成鼠标事件**驱动桌面并对
dump 出的单元格做断言，并证明 Terminal 把**真的 `psh` 跑在它自己的窗口里**（在那个窗口的提示符敲的
命令出现在那个窗口自己的 ROM 窗口里，用 `getLine` 读回，而面板与 dock 仍在屏幕上）。1.3.0 这一轮
改了 17 个变异：16 个被抓，活下来的那个是**等价变异而不是缺口** —— 把概览
填满整屏而不是工作区，一个单元格都不会变，因为 dock 与面板画在每一个可能不同的单元格之上 —— 于是它
被换成"移动网格原点"的变异，立刻被抓。早先那轮针对 1.1/1.2 的 43 个变异仍然成立：42 个被抓，唯一
逃逸的那个（tick 会恢复一个正在被泵的任务）是在补上"数恢复次数"的断言之后才被抓的——这正是承认
"守卫先于它的测试存在"的诚实说法。

**它自己调度任务，并且有一层 overlay。** CraftOS 是单线程的，它自己的 `parallel` API 本身就是协程
调度器，所以这台机器上"另一个进程"只能是另一个协程：定义了 `main`（或 `task`）的应用就**作为一个
协程运行**，在窗口打开时启动、由桌面在到期时恢复。任务通过 `api.task` 让出：`sleep(s)` 等时钟、
`wait_event()` 等事件、`yield()` 等下一个 tick、`spawn(fn)` 为同一个窗口再起一个任务。
**时钟之所以可注入，理由和屏幕一样** —— 一个只能靠"真的等"才能观察的 sleep 是不可测试的 ——
所以 `now` 只被 tick 推进：交互循环用 `os.startTimer(step)` 武装自己的定时器，而无头运行收到的是
`tick` 事件（事件文件里写 `tick` 或 `tick 0.5`，正是验收脚本已经在写的格式）。任务里抛错由
`coroutine.resume` 接住并记录（记在任务上、窗口上和计数器里），而不是结束循环；关闭窗口会**停掉它
的任务**，所以被恢复的任务不可能画进一个已经不存在的窗口。只定义 `main` 的 spec 也算应用：注册表
接受 `open` / `draw` / `event` / `main` / `task` 中任意一个作为"这个 spec 就是应用本身"。

**overlay** 是每帧的绘制钩子加一个自己的事件钩子：**画在面板之后** —— 所以模态框能盖住第 1 行，
而这是任何应用都做不到的，因为帧在画完每个窗口之后才画 dock 和面板 —— 并且**在桌面看到事件之前**
先拿到它（最上层优先），只有回答真值时才吃掉事件。overlay 里抛错与应用一样被围住；overlay 属于请求
它的那个窗口，因此关掉那个窗口就会丢掉它。这一层是本项目对帧的一条性质的答案：帧在画完每个窗口
之后才画 dock 和面板，所以任何应用都覆盖不了第 1 行——菜单与模态框若要"在所有东西之上"，就需要
一个在面板之后运行、并且比窗口更早看到事件的钩子。随包带的**任务管理器**正是让调度器可见的东西 —— 它的窗口体打印
`windows`、`tasks` 与它自己的任务被打断恢复的 tick 数 —— 于是"机器多任务了"是**机器屏幕上的一个
单元格**，而不是关于 PC 套件的一句断言。

**阻塞的程序与桌面共享同一次运行（泵），而桌面会把终端夺回来。** 两者都来自这台机器只有一个全局读、一个全局终端这一事实。
**泵**把一个会阻塞的程序作为任务来跑 —— 它用 `os.pullEventRaw` 等一行输入，`psh` 正是这么做的：
包装器只在这次调用期间安装、只回答正在被泵的那个协程，而且**程序本身跑在一个独立协程里**，因为
在 5.1/LuaJIT 上 `pcall` 里 `yield` 就是 "attempt to yield across C-call boundary"；等待由泵循环在
**任务这一层**完成，程序的异常则从 `coroutine.resume` 回来（调度器本来就会兜住它）。被泵的程序**只在
自己的窗口获得焦点时**才被投喂事件，且除非它自己要——**永远不投鼠标事件**，所以 shell 停在提示符时
操作者仍点得到别的窗口；概览打开时键盘归桌面，于是一个窗口无法把整个桌面扣作人质。
`reclaim_terminal()` 是另一个机制：一个把 `term` 重定向走之后就死掉的程序，会让桌面写进一个已经不
存在的窗口，所以桌面在**泵结束后、整屏交接后、以及每次交互循环开头**把自己的目标重定向回来。

有了这两个，窗口里的 shell 是真的：**Console** 在自己内部之下建一个不可见的 ROM 窗口、把 shell 的
`term` 重定向进去，并且每帧用 `window.getLine` 把它的单元格拷出来；1.6.0 起 **Terminal 用的就是
同一个实现**（`lib/gnome/apps/shellwin.lua`），两者只是名字与横幅不同。真机验收端到端证明了它 ——
它先清掉本项目的 `_G.__PSH_TEST` 钩子（该钩子会让 `psh` 只发布测试表然后返回、根本不进会话），然后
把 `echo hi` 打进那个窗口，并断言输出落在**窗口自己的 ROM 窗口里**（C1 是 Terminal，C2/C3 是
Console）**而面板与 dock 仍在屏幕上**：真的 shell、真的命令、在窗口里、桌面还活着。受机器限制的部分
明写不糊过去：泵可以同时跑多个程序，但这台机器只有一个全局读和一个全局终端，所以泵在程序的每一片
之前把终端交给它、按键只到焦点窗口、以及**不读事件就阻塞的命令（`sleep`）仍会让帧停住**，因为这台
机器无法抢占协程。还有一条：`exit` 在交互会话里被 `noexit` 拒绝（默认开），所以真机上验到的是
"shell 在窗口里跑起来、命令在窗口里执行"，而"shell 离开后窗口显示 the shell left"是 PC 套件用会
返回的 runner 钉住的 —— 两者都在，且各自说明覆盖的是哪一半。

 ROM 把 `require`、`package`、`shell` 放在它交给程序的
**环境**里（`rom/programs/shell.lua` 的 `createShellEnv`）而**不在 `_G` 里**，而 `loadfile` 给一个
chunk 的是**默认环境**。所以在 CraftOS-PC 2.8.3 上实测，由 shell 加载的外部命令看到的 `require` 是
**nil**：

```
psh: w: runtime error: /usr/cmd/w.lua:12: attempt to call global 'require' (a nil value)
```

**于是本项目**每一个会加载模块的外部命令在真机上都是坏的** —— `usr/cmd/w.lua`、`who.lua`、
`last.lua`、`lastlog.lua`、`chmod`、`chown`、`chgrp` —— 而 PC 套件**全绿**，因为
`tests/cc_env_stub.lua` 提供了全局 `require`。这与 `fs.makeDir` 在 ROM 上返回空、在桩里返回 `true`
是**同一个陷阱**：**比硬件更宽容的桩，会把机器故障变成绿色的测试。** `usr/psh.lua` 现在让命令文件
在一个**新环境**里运行，其 `__index` 指向 shell 自己的环境
（`setmetatable({}, { __index = getfenv(1) })`）——这正是 ROM 对自己启动的程序所做的，同时也让命令
自己的全局变量不会漏进 shell。已被门禁覆盖：`tests/batch10_check.lua` 钉住那几行，真机验收则同时断言
命令 chunk 能看到 ROM 的 `require`、以及 `w` 能跑。

* **一条值得复述的检查**：CraftOS-PC 2.8.3 报 `_VERSION = Lua 5.2`，而 `setfenv`/`getfenv` 在 5.2 里
  已被**移除** —— 所以在实测之前，这个修复**本该是个空操作**。它们确实存在（作为 5.1 兼容层），而且
  调用本身还有 `pcall` 保护。教训依然成立：**在这个平台上，`_VERSION` 不能告诉你哪些函数存在。**

**未验证的，明写**：交互式桌面从未被真实键鼠驱动过（验收注入合成事件，真机上的 `term_resize` 只被缓冲
测试覆盖）；`pkg install` 是以 root 经**预热的 sudo 缓存**（`lib/sudocache.lua`）执行的，而不是输入
密码，因为无头启动没有键盘 —— 普通账号被拒绝这一点**是**验证过的；安装**第二个**包、升级或移除
`gnome`、以及在 1 MB 机器上安装都没试（验收把 `computerSpaceLimit` 提到 8 MB 以容纳树加包）；另有
一个变异是**等价**而非被杀死（`if ok and type(mod) == "table"`，因为 require 失败返回字符串，两条
路都会设置 `entry.error`），已替换成能咬住的版本。

### 6.10 每次写盘前检查剩余空间（Disk space preflight for every write）

每个写盘的命令在**创建或截断任何东西之前**先问目标文件系统还有多少空间。判据只有一行：
要写的字节数**大于**剩余空间就拒绝，相等则放行。拒绝的消息同时给出两个数字——
`not enough space: need 48000 bytes, 1000 free`——并且命令状态为 1、目标文件未被动过。

* **没有 API 就不拒绝。** `fs.getFreeSpace` 不是每个 CraftOS 构建都有，程序也能把它从表里拿掉。
  回答不了这个问题的机器**不能被变成只读**：所以缺失或异常的答案一律当“放行”，写者行为与
  这个检查不存在时完全相同。模块头部（`lib/space.lua`）就这么写的。
* **实测，不是猜的。** 在 CraftOS-PC 2.8.3 上（2026-10-17，`--headless --script --mount-rw`
  探针脚本）`fs.getFreeSpace` 存在，接受目录、文件、不存在的路径以及 `""`，返回该卷的
  **剩余字节数**：模拟器主机磁盘 224410443776、`/rom` 0。**不是 KiB，也不是按目录**。
  `/rom` 回 0 正是为什么一个从未写过的路径也能得到诚实答案。
* **接啦了哪些写者**：两个 shell 重定向（`>`/`>>` 与 `2>`/`2>>`；流在打开时大小未知，
  所以在这里只能诚实地判“还没满”，即 1 字节）、`cp`（先量全部源，得一个整树总量，放不下就
  一字节不写）、`ln`（在 CraftOS 上就是逐字节复制）、`sed -i` 与 `tee`（新文本大小已知）、
  `tar` 的打包与解包、包解包器（`lib/pkg.lua`，下载的文件集落盘的那一刻）、传输的三个落盘点
  （`rget` 接收端与 `netd`：大小就在 ready/请求里，所以放不下的传输在**第一块之前**就被拒绝，
  落盘前再用**实际到达的字节数**查一次），以及桌面编辑器的保存。
* **两个局限，明写而不隐藏。** 这是**预检**而非预留：CraftOS 没办法把空间拿在手里，所以在答案与写入之间
  别的程序仍可能占掉它，写入仍可能失败。另外，覆盖已有文件的拷贝按**完整大小**计算，
  因此可能拒绝一个“旧字节释放后就够”的拷贝——但拒绝是可恢复的，半棵目录不是。
* **为什么值得这份代码**：磁盘满时 `fs.open(path, "w")` 是**成功**的，它把文件截断成零字节，
  随后的 `write` 才失败。旧内容没了、新内容也没写进去，而且没有一句话告诉你为什么。

* **两处 PC 套件看不见、由真机探针查出的东西。** 这个构建上**字节数不能用 `%d` 打印**：
  `string.format("%d", 224476971009)` 会抛 "bad argument #2 (not a number in proper
  range)"，所以任何超过 2^31 字节的剩余空间（也就是每一块真盘）都会把“拒绝”变成“报错”。
  现在消息用 `%.0f`。另外这个 ROM 上 `fs.copy` 成功时**没有返回值**（桩返回 true），
  目标已存在时**抛错**，于是 `if not fs.copy(...)` 让真机上**每一次成功的复制**都报状态 1；
  cp 现在用 pcall 包住。两者都看不见于模拟文件系统 —— 与 `fs.makeDir` 同一种
  “桩比实物宽容”的形状。

验证：`tests/batch_check.lua`（用可注入的 `fs` 证三态、`cp`/`tee`/重定向拒绝后文件不变）、
`tests/batch10_check.lua`（编辑器状态行）、`tests/batch8_check.lua`（接收方只够半块的传输）、9 个变异、以及一次真机探针。

---
---

## 7. shell 之前与周围的机器行为（Machine behaviour before and around the shell）

一批加入的五项「机器自身」属性。它们的共同点是：决定当**不由 shell 做主**时这台电脑怎么
表现——开机时、命令运行中、以及有人想离开时。

* **启动序列用 `xpcall` 包住，崩溃被兜住并且有解释。** `startup.lua` 原先用 `pcall` 跑
  `shell.run`，只报错误消息。现在处理器会附上 `debug.traceback`（用 `pcall` 保护，因为 ROM
  里 `debug` 是可选的——与 `lib/rpvnet.lua` 同样的保护），于是 `/var/log/watchdog.log` 会指出
  是哪个模块的哪一行抛的，而不只是那条消息。处理器写成**不可能失败**的：它在栈展开时运行，
  它内部若出错就会用一条令人困惑的错误顶替真正的错误。
* **BIOS 式设置界面，开机前三秒内按 DEL 进入。** `lib/bios.lua` 沿用固件的形状：一个短窗口
  （"Press DEL to enter SETUP"），然后照常启动。错过窗口是常态。BACKSPACE 与 DEL 一样能进，
  因为 CraftOS 控制台常常没有完整键盘，拒绝它会让最需要这个界面的硬件反而进不去。同一个界面
  在 shell 里用 `bios` 命令也能打开。
  * 密码与登录密码**分开**，存在 `/etc/bios.conf`，这是**承重**而非整洁：本模块运行在 shell
    **之前**、也运行在用户数据库未必可解析之时，所以依赖 `/etc/passwd` 会让设置界面恰好在
    机器出问题的时候用不了。
  * `ask_password=1` 让机器在给出密码前**根本不启动 shell**。缺省关闭：一台没有密码就不启动的
    机器，是一台无法通过重装 shell 恢复的机器，误开代价严重。
  * 该界面改的就是下面两条规则，通过 `lib/protect.lua` 写入，所以界面与 `set -o` 不可能不一致。
* **`set -o noexit`：缺省不允许退出 shell。** 强制点在**会话**边界（`execute_line`），而不是
  `exit` 内置命令，这个区分是**承重**的：脚本末尾的 `exit 3`、以及 `psh -c 'exit 3'`，都是用
  `exit` 返回**状态**，看门狗也靠这种方式触发计划任务。在内置命令里拒绝 exit 会把这些全部弄坏。
  被拒绝的是**会话结束**；该标志只由交互循环置位，测试钩子让套件说明它模拟的是哪一种。
* **Ctrl+C 终止正在运行的命令，与 Linux 一致。** CraftOS 是单线程协作式的，没有信号可投递；
  能做到的是在协作式程序交还控制权的**唯一位置**——`os.pullEvent`/`os.pullEventRaw`
  （`lib/interrupt.lua`）——插一层。当有命令在前台时，Ctrl+C 按键事件抛出与 ROM 为 Ctrl+T 抛出
  的同一个 `"Terminated"` 错误，而 `is_interrupt_error()` 本来就能匹配它——于是既有的 INT trap
  与 130 状态无需第二条代码路径。在提示符上这层是关闭的，所以 Ctrl+C 保持旧含义（丢弃半行输入）。
  * 过滤器由包装层自己施加、不传给真实函数，这正是关键：`os.pullEvent("char")` 会在调用者看到
    之前丢掉按键事件，否则等待字符的程序将**无法被中断**。测试里有一条断言专门盯这个。
  * **它做不到什么，直说**：一个从不调用 `pullEvent` 的紧凑 CPU 循环无法被中断。这是协作式
    调度器的性质，不是这里的缺口——解释器就在那个循环里，别的东西跑不了。Linux 能中断这种循环
    是因为内核抢占它；CraftOS 没有内核。
* **启动文件缺省受保护（`set -o bootguard`）。** `lib/protect.lua` 拒绝写入 `/startup.lua`、
  `/firstboot.lua`、`/usr/psh.lua` 以及 `/lib/` 下的任何文件，除非操作者关掉该保护。名单是显式
  列举而不是"整个 /lib"，因为包升级是正当操作且装在 `/usr/pkgs`。检查放在 `guard_write`——所有
  写入者都走的**唯一**路径——所以没有哪条命令能忘记它。
  * 被拒绝的写入会**失败**（状态 1），而不是报告成功。这是探针找到的真实 bug：消息打印了，状态
    却仍是 0，于是脚本当写入已完成继续跑。`cp` 里有同样的缺口，它在被拒时什么都不返回。
  * `bootguard` 与 `noexit` 都是 `/etc/boot.conf` 里的机器规则，由仅限 root 的 `set -o`/`set +o`
    修改，并且**跨重启保留**。持久选项刻意**不**在脚本周围保存与恢复：它的权威是那个文件，而以
    root 关掉保护的脚本，不该在脚本结束时被悄悄打开。
* **拒绝就是拒绝：先问再开，崩溃也是一个失败状态。** 在被守卫的机器上实测（fs 表被包住，被拒的
  `fs.open` 返回 nil），有四个内建命令把这个 nil 读错了。`touch` 写的是
  `local f = fs.open(p, "w"); f.close()`，于是整行死于 "attempt to index local 'f'"；`run()`
  把错误打印了却不动状态，于是 `$?` 报的仍是**崩溃前**那行留下的 0；`mkdir` 把 `fs.makeDir`
  的回答丢掉（它即使在成功时也不返回值）并报告成功；`cat` 把它被拒的文件说成 "no such file"。
  现在四个都先问再报：`touch` 与 `mkdir` 先查 `perm.can_write`，给出 "permission denied" 并置
  状态 1；`mkdir` 用 `fs.exists` 判成功；`cat` 把"存在但打不开"与"真的不存在"分开；`run()` 对
  抛出异常的命令置状态 1（中断的 130 与 exit/return 各自的语义不变）。`lib/danger.lua` 现在只对
  **真的**带 `*` 或 `?` 的 token 走通配符分支，于是 `rm -rf /usr` 报的是系统目录，而那个此前
  不可达的分支现在可达。`lib/osguard.lua` 在它包过的 fs 表上打标记，因为 ROM 给每个程序独立的
  package 表：另一个程序里的 `osguard.installed()` 在守卫明明装好的机器上曾返回 false，它的
  `install()` 会再包一层。
  * 证据：`tests/batch_check.lua` 的"a refusal is a refusal"分节加黑名单分节（39 条断言；11 个
    变异全抓——各内建命令的旧行为、缺失的状态、用 `fs.makeDir` 的返回值、剥通配符、以及两处
    osguard 回归）。在 CraftOS-PC 上，探针在真实提示符上逐条敲入：`touch /usr/x` 与
    `mkdir /etc/x` 报 "permission denied" 且状态 1，`cat /etc/shadow` 报 "permission denied"
    （不是 "no such file"），抛出异常的命令之后 `$?` 是 1，`rm -rf /usr` 报"系统目录"。
  * 这个修复也暴露了验收脚本的一个陈旧假设：`usr/psh.lua` 会把留在 root 上的控制台交还给机器的
    level 1 账号（`console.claim`），所以往 `/etc/current_user` 写 `root` **并不能**得到 root
    会话，那两条"root 能创建 ..."的检查之前能过，只是因为 `touch` 从不问权限数据库（被守卫的 fs
    在开机时缓存了 root）。`_psh-perm.sh` 现在为它的第二次启动把那个账号降为 level 0（claim 找的
    是**非** root 的 level 1 账号），于是那次启动真的是 root，提示符以 `#` 结尾。
* **启动顺序：ROM 的"从磁盘的 startup 启动"已关闭。** 这是 `lib/protect.lua` **无法**防住的
  ROM 层隐患，发现它也修正了本节早先的一处说法。CraftOS 开机时读 `/.settings`，而
  `rom/startup.lua` 在跑我们的任何东西**之前**就查两个键：`shell.allow_startup`（跑本机自己的
  startup）与 `shell.allow_disk_startup`（跑接上的磁盘上的 startup）。两者缺省都是 true。第二个
  不是"附加"而是**替换**——ROM 把磁盘上的脚本赋给 `tUserStartups`，覆盖掉它在根目录找到的：
  * shell 永远不会启动，本仓库的任何东西都不会运行，所以 `bootguard`（它住在 `startup.lua`
    里面）根本不在执行路径上；
  * 因此防线是 ROM 自己的开关，写进 `/.settings`，**为下一次开机生效**。`/.settings` 随安装一起
    部署，所以**第一次开机**就是安全的；`bios.enforce_rom_settings()` 每次开机重新施加，所以删掉
    文件或手改文件都不会把机器留在敞开状态。BIOS 界面暴露这两个键。
  * `shell.allow_disk_startup` 的 ROM 真实缺省值是 `commands == nil`（CraftOS-PC 的 `bios.lua`），
    所以命令电脑（Command Computer）缺省是关的。`bios.rom_default` 检查同一个全局变量，并且报告
    ROM **将会**怎么做、而不是文件里写了什么——键缺失意味着"完全敞开"，不是"未设置"。
  * **文件格式不可商量，第一次尝试就错了。** `textutils.unserialize` 会**前置** `"return "`，
    所以 `/.settings` 必须是**裸表字面量**：以 `return` 开头、或带注释的文件会解析成 `nil`，加载
    报失败，每个键都静默保持 ROM 缺省值。一个"看起来对、其实没作用"的文件在这里是最糟的结果，
    因为机器看起来是受保护的。这一点只有在模拟器上跑才发现；断言现在把形状钉住了（首字符 `{`、
    不含 `--`）。
* **整套 CraftOS 设置都能从界面里改。** ROM 自己的 `set` 命令是 `/.settings` 的编辑器，而它需要
  一个能用的 shell —— 这恰恰是坏掉的机器没有的东西。界面的 "All CraftOS settings" 一项列出并修改
  ROM 知道的**每一项**设置，走同一个 API、同样的类型强制转换、同样的"空值 = unset"规则。
  * 它用 `*` 标出自己**强制执行**的键。只有 `ROM_KEYS` 里的键是策略；其余都属于 ROM，本项目既不
    强制也不记录。这个区分必须显示在界面上，因为分不清两者的读者会以为某项设置在开机后依然保留，
    而那次开机根本不会碰它。
  * **策略（POLICY）与选择（CHOICE）是两回事，把它们混为一谈是这一批引入又修掉的一个 bug。**
    第一版用一个 `want` 字段干两件事，于是强制逻辑恢复的是硬编码值，菜单项成了**谎言**：把"从磁盘
    启动"打开看起来成功了，下次开机却被悄悄改回。现在强制逻辑在操作者**做过选择**时写入
    `/etc/bios.conf` 里的**选择**，否则用安装的**策略**。从未动过的键保持策略；改过的键跨重启保留
    改动；删掉 `/.settings` 仍由同一个真相来源修复。该回归已被断言钉住（"the NEXT BOOT does not
    undo the operator's choice"）。
  * `settings.save()` 的缺省路径**相对于当前目录**，所以这里每次写入都传绝对路径 `/.settings`：
    否则当前目录不是 `/` 的调用方会把设置写到 ROM 根本不会读的地方。
* **`reboot` 取代 `craftos`。** 旧命令通过写 `/var/lib/.escape_allowed` 让 `startup.lua` 发现并
  跳出重启循环，从而把机器**丢给 CraftOS shell**。它是唯一的出路，但很糟：机器上跑的是**本项目不
  管理的东西**，于是你在这里设的规则（boot guard、noexit）也随之失效。`reboot` 改为让机器重新经过
  `startup.lua` 起来，于是它**回到本项目的控制之下**，前面照样有 BIOS 窗口——与断电重启完全一样。
  * `reboot bios` 写一个**一次性标记**，`startup.lua` 在显示界面前消费掉它，所以进设置界面不必去抢
    那三秒 DEL 窗口。标记带**机器 ID**，数据目录拷到别的机器不会让那台机器打开设置界面；而且它会被
    消费而不是留下，所以无人值守的机器不会在无关重启后停在设置界面。
  * 仅 root 可用并记审计，与被它取代的命令一致。`set -o noexit` 同样拒绝它——重启也会结束会话，
    所以这条规则必须适用——`-f` 可越过。`reboot shutdown` 被拒绝而不是猜测：关机是另一件事、
    结果也不同。
  * **逃逸机制是被删掉，而不只是不再使用。** `try_escape` 与 `ESCAPE_FLAG` 已从 `startup.lua` 移除，
    `__escape` 已从 shell 移除，没有任何地方再写 `.escape_allowed`。`startup.lua` 仍会删除旧安装
    留下的陈旧标记，所以升级不会留下一个没人能兑现的请求。
  * `os.reboot()` 已在 CraftOS-PC 上确认真能重启：一个调用它的 startup 脚本在同一个数据目录上跑了
    第二次（"boot 1: calling os.reboot()" 然后是 "boot 2: the machine came back up"）。
* **证据**：`tests/batch_check.lua` 的 "the boot guard"、"the shell may not be left"、
  "Ctrl+C stops the running command"、"boot order: the ROM's disk startup is turned off"、
  "the BIOS screen can reach every CraftOS setting" 与 "reboot replaces craftos" 六节
  （123 条断言，已做突变测试——每个变异都被抓住：保护永远放行、目录规则被删、`no_exit` 被忽略、
  `boot_guard` 不被读取、Ctrl+C 永不抛错、包装层透传过滤器、`cp` 在被拒时报成功、
  `enforce_rom_settings` 什么都不做、`want` 被改成允许磁盘启动、`rom_setting` 忽略文件、缺省报成
  false、`set_rom_setting` 不写入、强制逻辑忽略选择、选择未被记录/读取/写入、浏览器把一切都标成策略、
  浏览器什么都不列、布尔被存成字符串、策略键绕过选择路径、reset 不 unset、reboot 允许非 root、
  noexit 不拦 reboot、reboot 从不调用 `os.reboot`、设置请求忽略机器 ID、设置请求未被消费、
  陈旧标记清理被定义却从未被调用）。设置浏览器、ROM 对 `/.settings` 的读取、一次性标记与
  `os.reboot` 本身均已在 CraftOS-PC 上确认。
* **未完成**：BIOS 界面没有 PC 侧的**渲染**测试——断言覆盖的是密码存储、各开关、DEL 窗口的判定、
  ROM 设置与浏览器的数据，不是绘制。跑一次 CraftOS-PC 能确认它长什么样；目前还没有这样的脚本。
* **本项目称为 SHA-256 的那个摘要根本不是 SHA-256。** 在做 `sha256sum` 命令时发现，完整记录是因为
  它正是本项目最容易犯的失败形态：结果看起来合理、什么都不报错、测试也表示同意。
  * `lib/crypto.lua` 向 ROM 要 `cc.crypto`，拿不到时回落到一个 64 位算术折叠
    （`h1 = h1 * 31 + byte`）。**它在 CraftOS-PC 2.8.3 上不存在**——实测 `require "cc.crypto"` 失败
    ——所以那台机器上 `crypto.sha256("abc")` 返回 `0001786200021546`，16 个字符，而真摘要是 64 个。
    建立在它之上的一切都比自称的弱：登录密码哈希、BIOS 密码哈希、包签名校验。
  * **测试正是它活下来的原因。** `crc32` 有标准向量（`0xCBF43926`）；`sha256` 只有
    `digest == checksum.sha256("abc") and #digest > 0`——"稳不稳定"，而折叠满足这一条。已知答案测试
    是唯一能区分摘要与折叠的手段，现在空串与 `abc` 都有。
  * `lib/sha256.lua` 是真的 SHA-256（FIPS 180-4，对四个向量验证，含专门考验额外填充块的 112 字节
    用例）。它是从 `rpv/crypto.lua` **抄过来**而不是 require 过来：`rpv/` 在介质上，base 半不能依赖
    介质。
  * **`bit32` 是可变参数的，而它的三份拷贝都不是。** 压缩函数调用 `bxor(a, b, c)`；两参数的垫片会
    丢掉第三个参数。我的第一版回落有这个 bug，手写的 `bit32` 分支也有，`tests/net_harness.lua` 里的
    垫片**同样**有——这就是测试套件不可能抓到它的原因。三处都已修复，且 `lib/sha256.lua` 与垫片
    现在都在**两条路径**上带已知答案测试。
  * **同一处的第二个独立 bug：存下来的密码随介质移动。** `lib/crypto.lua` 与 `lib/checksum.lua` 在
    modules 半（可移动介质），而 `lib/perm.lua` 在 base 半（电脑），且 `perm.hash_password` 用 pcall
    require crypto、以折叠作回落。实测：插着介质是 `alice:0fbcae8a2053...`，不插是
    `alice:1265856734`，且 `check_password` 返回 **false**。插着介质设的密码在拔掉介质后无法验证
    ——在两部分安装里，Part 2 正是随手拿走的手持电脑，这会把你锁在自己的机器外面。`lib/perm.lua` 与
    `lib/bios.lua` 现在在**列 0** require `lib/sha256.lua`，既固定了哈希，也把 sha256 放进 **base**
    半（gate 5 已钉住）。修复后在**只有 base、完全没有介质**的机器上实测：存的哈希是真的 SHA-256
    且能验证通过。
  * **迁移不是免费的，也不隐瞒**：此前设的密码是基于折叠的，将无法验证。并不存在单一的"旧哈希"可
    保留——旧值取决于当时是否插着介质——所以诚实的回答是：跨越此变更升级的机器需要重设密码。
* **两者的证据**：`tests/batch3_check.lua`（413 条断言）。新增断言均做过突变测试，且**有两个变异
  逃过了测试的第一版、迫使它重写**：只比较"有 crypto 时的哈希"与"没有时的哈希"的断言，对一个恢复
  pcall+折叠的改动会通过，因为在套件里 crypto 总是可加载，两条分支都会算出真摘要。现在测试会在
  **让 `require("crypto")` 失败的同时**设一个密码，并断言存储的字节等于 `sha256.hex("cc-salt:...")`。
  已抓住的变异：bit32 路径上的两参数 `bxor`、回落路径上的两参数 `bxor`、非可变参数的回落 `band`、
  `crypto` 偷偷折叠、填充长度高低位对调、填充边界差一、一个轮常数被改、删掉一个向量、perm 在无介质
  时又折叠、以及盐前缀被改。已在 CraftOS-PC 上确认：`crypto.sha256("abc")` 是 64 字符向量、
  `has bit library` 为 true、自测为空，且只有 base 的机器上设的密码存下并验证的是真摘要。

* **许可证门已移除（2026-10-17）：机器是「已设置」，不是「已授权」。**
  曾经首次启动要向第二台服务器要一张签名许可证：`authserver.lua` 用 512-bit RSA 私钥签
  `computerId:nonce`，`lib/license.lua` 用配套公钥验，`startup.lua` 拿不到就不起 shell。
  用户要求弃用这套机制，理由值得写下来：**私钥和公钥装在同一个安装里**（`authserver.lua` 是
  part1 的一部分，也在发布包里），所以签名从来没有证明任何用户自己造不出来的东西——它只是
  在每次首次启动前面多放了一个守护进程、一个配置文件和一个失败模式；而且它的客户端与服务端
  频道彼此、以及与随附的 `/etc/network.conf` 都不一致，配好的机器也只会白等 30 秒。替代它的
  是一个标记：`lib/marker.lua` 把 `{computerId, setup, at}` 写到原来那四个路径，并绑定本机
  （`marker.done()` 拒绝从别的机器拿来的标记），`startup.lua` 在这个标记存在之前会一直跑
  `firstboot`。`authserver.lua`、`lib/license.lua`、`lib/rsa.lua`、`tools/gen_rsa.py` 是
  **删除**而不是弃置；`/etc/network.conf` 的许可证键（`placeholder_ids`）一并消失，文件现在
  只描述包服务器。证据：`tests/batch4_check.lua`（12 条断言：标记往返、绑定本机、
  `--clean-firstboot` 的 `exists()`、没有签名字段、启动门问 `marker.done()` 且不再 require
  许可证模块）；门禁与套件全绿；门禁 1 编译 117 个 Lua 文件（少了三个），门禁 4 有 145 个
  手册页（`authserver` 那页没了），两部分安装的 part1 少 3 个文件。门禁 3 不再要求 README 提
  "AI"：用户要求删掉生成的 AIGC 标识，所以不再有任何相关要求。

---

## 8. 如何验证一次改动（How to verify a change）

```
python tests/run_all.py                    # 门禁 + 全部套件，期望 ALL GREEN
bash tools/rpv-verify/_psh-perm.sh         # 真机上的权限验收
powershell -File tools/rpv-verify/_psh-mc-server.ps1 -Action status
powershell -File tools/rpv-verify/_psh-mc-file.ps1 -Server <server dir> -RconPort <port> ^
    -ServerAlreadyRunning -ClientTrace
```

真机脚本会给每台机器写出：`mcfile-client.log` / `mcfile-peer.log`（驱动自己的日志）、
`mcfile-trace.log` / `mcfile-peer-trace.log`（rpvnet 数据报与 xfer 状态机）、`rpv-log.txt`
（节点的帧级日志）。请**直接读这些文件**，而不是脚本打印的尾部；并且在相信日志对代码的说法之前，
把每个 `startup.lua` 的 mtime 与该次运行核对一遍。

**不要在未完成的代码树上得出结论。** 1.2 节背后的两次运行，是在代码还在编辑时启动的，它们的失败
（一次拉取卡在 49 块中的第 17 块、一次推送没有开场应答）对改动前和改动后**都不说明问题**。
开真机之前：改完，跑 `tests/run_all.py` 到 `ALL GREEN`，然后再启动。同时保留被改动方向在**上一个
已知良好树**上的基线运行，这样新的失败可以被归因，而不是靠猜。真机一轮要 20 分钟，所以
**一次干净的测量胜过三次抢跑**。
