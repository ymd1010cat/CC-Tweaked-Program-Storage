--[[- dc.lang — 运行时界面语言（en / zh）

  设计：英文串是唯一事实来源（源码里全是英文），中文词典从历史版本
  （git 9f44af3）恢复。M.tr(text) 在输出边界（Console:log / 调度器日志）
  做翻译，调用点一律不用改。monitor 大屏面板（dc.panel）保持英文：面板是
  定宽的 6x9 像素字符网格，中文一个字要 6x4 格，应该迁就原来的布局。

  - en 模式：原样返回，且不构建 pattern 索引（启动零开销）。
  - zh 模式：先精确查表；带 printf 占位符的英文模板会被编译成锚定的 Lua
    pattern（逐个捕获占位符），命中后把捕获值塞回中文模板。
  - zh 模式但 _G.DCNET_CJK_READY 不是 true（没有 CJK 字形介质）：原样返回
    英文。原版 CC 终端字体没有汉字，输出中文只会是乱码。
  - 词典没收录的文本原样返回，绝不抛错。
]]

local M = {}

local unpack = table.unpack or unpack

local AVAILABLE = { "en", "zh" }
M.LABELS = { en = "English", zh = "Chinese" }

local function norm(code)
    if code == "en" or code == "zh" then return code end
    return "en"
end

-- settings 可能不存在（裸 CraftOS 测试桩），所有调用都先做类型检查
if type(settings) == "table" and type(settings.define) == "function" then
    pcall(settings.define, "dcnet.lang", {
        default = "en", type = "string",
        description = "dcnet UI language (en/zh)",
    })
end

local function stored()
    local raw = rawget(_G, "DCNET_LANG")
    if raw == nil and type(settings) == "table" and type(settings.get) == "function" then
        local ok, v = pcall(settings.get, "dcnet.lang")
        if ok then raw = v end
    end
    return raw
end

M.lang = norm(stored())

function M.get() return M.lang end

function M.set(code)
    code = tostring(code or "")
    if code ~= "en" and code ~= "zh" then
        return nil, "unknown language: " .. code .. " (" .. table.concat(AVAILABLE, ", ") .. ")"
    end
    M.lang = code
    _G.DCNET_LANG = code
    if type(settings) == "table" then
        if type(settings.set) == "function" then pcall(settings.set, "dcnet.lang", code) end
        if type(settings.save) == "function" then pcall(settings.save) end
    end
    return true
end

-- ── 词典：英文 → 中文 ───────────────────────────────────────────────────
local ZH = {
    ["                          Submit a job, e.g. run primes to=2000000 pri=5"] = "                          提交作业，例如 run primes to=2000000 pri=5",
    ["              params: %s"] = "              参数：%s",
    ["    %d/%d done  failed %d  elapsed %s"] = "    %d/%d 完成  失败 %d  用时 %s",
    ["  #%-3d %-12s %-4s ok%d fail%d  %s  %s"] = "  #%-3d %-12s %-4s 成功%d 失败%d  %s  %s",
    ["  #%-3d %-16s %3dx%-3d  %7s ago  %d frames"] = "  #%-3d %-16s %3dx%-3d  %7s前  已发 %d 帧",
    ["  %-10s %-34s slots %d inflight %d ok %d failed %d %s"] = "  %-10s %-34s 槽位 %d 在飞 %d 成功 %d 失败 %d %s",
    ["  %s  %-10s %s ago"] = "  %s  %-10s %s前",
    ["  (job has not finished yet)"] = "  （作业还没有结束）",
    ["  (run screen.lua on the screen computer to connect)"] = "  （屏幕电脑上运行 screen.lua 就会自动连上）",
    ["  -> task %d.%d dispatched to #%d (try %d%s)"] = "  → 任务 %d.%d 派发给 #%d（第 %d 次%s）",
    ["  <- task %d.%d done on #%d (%s)"] = "  <- 任务 %d.%d 完成于 #%d（%s）",
    ["  Dropped "] = "  本机总计丢弃 ",
    ["  Failed to open modem: "] = "  打开 modem 失败：",
    ["  Heartbeat %ss, takeover after %ss (set beatInterval / takeoverAfter)"] = "  心跳间隔 %ss，接管阈值 %ss（set beatInterval / takeoverAfter 可调）",
    ["  Monitors: "] = "  可用显示器：",
    ["  No monitor peripheral (attach to master, or use screen.lua)"] = "  没有检测到 monitor 外设（贴到主控侧面，或用 screen.lua 当网络屏幕）",
    ["  Note: workers need /startup.lua autorun to rejoin the cluster."] = "  注意：节点电脑必须有 /startup.lua 之类的开机自启，才能自动回到集群。",
    ["  Other machines need the same key (master setkey / worker set dcnet.key),"] = "  其它机器要用同一个密钥（主控 setkey / 节点 set dcnet.key），",
    ["  Silent for %.1f s"] = "  已静默 %.1f 秒",
    ["  This master took over (original went offline)"] = "  本机是接管上来的（原主控掉线）",
    ["  Use setkey <shared key> to enable; optional on one machine"] = "  用 setkey <共享密钥> 打开；自己单机玩可以不开",
    ["  Worker still runs old code; reboot #"] = "  节点仍在跑旧代码，需要 reboot #",
    ["  [have]"] = "  [已有]",
    ["  [paused]"] = "  [已暂停]",
    ["  cache [clear]           Result cache list / clear"] = "  cache [clear]           结果缓存列表 / 清空",
    ["  cache clear wipes / run! skips cache / set cache false off"] = "  cache clear 清空 / run! 跳过缓存 / set cache false 关闭",
    ["  cancel <job id>         Cancel a job"] = "  cancel <作业号>          取消作业",
    ["  cannot restore "] = "  无法恢复 ",
    ["  cfg                     Show all active config"] = "  cfg                     显示当前生效的全部配置",
    ["  clear                   Redraw the UI"] = "  clear                   重绘界面",
    ["  cloud                   Cloud endpoint list and status"] = "  cloud                   云端端点列表与状态",
    ["  cloud add <name> <url> [parallel] Register an HTTP compute service (persisted)"] = "  cloud add <名字> <url> [并发]   注册一个 HTTP 计算服务（持久化）",
    ["  cloud add <name> <url> [slots] to register an HTTP service"] = "  用 cloud add <名字> <url> [并发] 注册一个 HTTP 计算服务",
    ["  cloud del <name>        Delete endpoint"] = "  cloud del <名字>        删除端点",
    ["  cloud request %s exceeds %d bytes, uploading in %d chunks"] = "  云端请求 %s 超过 %d 字节，切成 %d 块上传",
    ["  cloud test <name>       Probe (one GET)"] = "  cloud test <名字>       探活（GET 一次）",
    ["  halt                    Make all workers exit"] = "  halt                    让所有节点退出",
    ["  help                    Show this help"] = "  help                    显示本帮助",
    ["  history [N]             Recent job run history"] = "  history [N]             最近的作业运行历史",
    ["  jobs                    List jobs under /dccomp/jobs"] = "  jobs                    列出 /dccomp/jobs 下的作业",
    ["  key                     Show signing state, key fingerprint, drop stats"] = "  key                     查看签名状态、密钥指纹与丢弃统计",
    ["  kick <worker id>        Make one worker exit"] = "  kick <节点ID>            让某个节点退出",
    ["  last rejection: "] = "  最近一次拒绝：",
    ["  limit [N]               Max jobs in parallel"] = "  limit [N]               同时执行几个作业（并发上限）",
    ["  mon <name> attach local / mon off close local / mon net net screens"] = "  mon <名字> 挂本地显示器 / mon off 关本地 / mon net 网络屏幕",
    ["  mon [name|off]          Attach/close local monitor panel (persisted)"] = "  mon [名字|off]          挂载/关闭本地 monitor 大屏面板（持久化）",
    ["  mon net [on|off|kick ID] Net screen: another computer + monitor as panel"] = "  mon net [on|off|kick ID] 网络屏幕：另一台电脑 + 显示器当大屏",
    ["  mon net on|off toggles / mon net kick <ID> drops one"] = "  mon net on|off 开关 / mon net kick <ID> 断开一台",
    ["  net                     Show modem / network status"] = "  net                     显示 modem / 网络情况",
    ["  note: job source %s is large; sent with every task, consider splitting"] = "  注意：作业源码 %s 偏大，每个任务下发时会附带源码，建议拆小",
    ["  pause [job id]          Pause dispatch (no id=all)"] = "  pause [作业号]           暂停派发（不带作业号=全部）",
    ["  pri <job id> <priority> Set priority (higher grabs tasks first)"] = "  pri <作业号> <优先级>    调整优先级（高者先抢任务）",
    ["  pull <master id> <job names...> / pullall <master id> missing only"] = "  pull <主控ID> <作业名…> 拉取 / pullall <主控ID> 只拉本地没有的",
    ["  pull <master id> <job names...> Pull jobs from it (adds .lua)"] = "  pull <主控ID> <作业名…> 从它那里拉作业（自动补 .lua）",
    ["  pullall <master id>     Pull only missing ones (repo first)"] = "  pullall <主控ID>        只拉本地没有的（先 repo 看清单）",
    ["  push [worker id..]      Push "] = "  push [节点ID..]          把 ",
    ["  queue                   Show job queue"] = "  queue                   查看作业队列",
    ["  quit                    Close master (workers stay, reconnect on restart)"] = "  quit                    关闭主控（节点会保留，重启主控后自动重连）",
    ["  reboot [worker id..]    Reboot workers (load new code after push)"] = "  reboot [节点ID..]        让节点重启电脑（配合 push 加载新代码）",
    ["  redun [N]               Redundant tail threshold (0=off, tames slow tails)"] = "  redun [N]               抢尾冗余派发阈值（0=关，抑制慢节点拖尾）",
    ["  repo <master id>        Query another master's job repo"] = "  repo <主控ID>           查询另一台主控的作业仓库",
    ["  result [job id]         Show a job result (default=latest done)"] = "  result [作业号]          查看某个作业的结果（缺省=最近完成的）",
    ["  resume [job id]         Resume dispatch"] = "  resume [作业号]          恢复派发",
    ["  run <job> [params..] [pri=N]"] = "  run <作业> [参数..] [pri=N]",
    ["  run! <job> ...          Same but skip result cache (force)"] = "  run! <作业> ...         同上但跳过结果缓存（强制重算）",
    ["  save <job id> [path]    Save result to a file"] = "  save <作业号> [路径]     结果另存为文件",
    ["  set <key> <value>       Change config and persist (cfg lists all)"] = "  set <配置项> <值>        改配置并持久化（cfg 看全部）",
    ["  setkey <key>            Enable signing (anti-spoof/replay, same everywhere)"] = "  setkey <密钥>           启用消息签名（防冒充/防重放，各机器设成一样）",
    ["  setkey off disables signing; on workers use set dcnet.key <key>"] = "  setkey off 关闭签名；节点上用 CC 自带的 set dcnet.key <密钥>",
    ["  standby [on|off]        Standby master: take over and resume if active dies"] = "  standby [on|off]        待命主控：在岗主控掉线时自动接管并接续作业",
    ["  standby on|off: start in standby by default (persisted)"] = "  standby on|off：本机默认以待命模式启动（会持久化）",
    ["  state [save|clear]      Snapshot state / write now / clear"] = "  state [save|clear]      断点续算快照的状态 / 立即写 / 清除",
    ["  state save writes now / state clear wipes / set snapshot false off"] = "  state save 立即写 / state clear 清除 / set snapshot false 关闭",
    ["  status                  Job overview + worker list"] = "  status                  作业总览 + 节点列表",
    ["  task %d failed: %s"] = "  任务 %d 失败：%s",
    ["  task %d.%d payload %s via file channel (%s)"] = "  任务 %d.%d 负载 %s，改走文件通道（%s）",
    ["  top [N]                 Worker total contribution ranking"] = "  top [N]                 节点累计贡献排行（跨会话）",
    ["  unsigned %d  bad signature %d  duplicate %d  stale %d"] = "  未签名 %d　签名错误 %d　重复 %d　时间戳无效 %d",
    ["  upgrade this worker to the master version (run push on the master, or copy worker.lua again)"] = "  请把该节点升级到与主控同一版本（主控执行 push，或重新拷贝 worker.lua）",
    ["  workers                 Worker list only"] = "  workers                 只看节点列表",
    ["  x task %d.%d failed: %s"] = "  x 任务 %d.%d 失败：%s",
    ["  x task %d.%d failed: %s (dispatched %d times)"] = "  x 任务 %d.%d 失败：%s（已派发 %d 次）",
    ["  ~ task %d.%d requeued: %s"] = "  ~ 任务 %d.%d 重新入队：%s",
    ["  ~ task %d.%d retry: %s"] = "  ~ 任务 %d.%d 重试：%s",
    [" ("] = "（",
    [" (%dx%d)"] = "（%dx%d）",
    [" (attach: mon "] = "（mon ",
    [" (mon off to disable)"] = "（mon off 可关闭）",
    [" (tried: "] = "（已尝试: ",
    [" (type help)"] = "（输入 help 查看帮助）",
    [" (wired network)"] = "（有线网络）",
    [" ago"] = "前",
    [" bytes"] = " 字节",
    [" duplicated"] = " 出现重复",
    [" failed "] = " 失败",
    [" kicked (reconnects on next heartbeat)"] = "（它下次心跳会再连上来）",
    [" messages in total"] = " 条消息",
    [" mismatches"] = " 个不一致",
    [" missing, cannot distribute"] = " 不存在，无法分发",
    [" s"] = " 秒",
    [" s+adaptive"] = " 秒+自适应",
    [" to exit."] = " 退出。",
    [" to load the new version"] = " 才会加载新版本",
    [" to workers (upgrade)"] = " 推给节点（升级用）",
    ["# job %d  %s"] = "# 作业 %d  %s",
    ["# params: %s"] = "# 参数: %s",
    ["# state: %s  tasks %d ok / %d failed  elapsed %s"] = "# 状态: %s  任务 %d 成功 / %d 失败  用时 %s",
    ["#%-3d %-12s %-6s pri%-3d %s %3d%%  tasks %d/%d failed %d  elapsed %s%s"] = "#%-3d %-12s %-6s pri%-3d %s %3d%%  任务 %d/%d 失败 %d  用时 %s%s",
    ["#%d %s (cannot load source: %s)"] = "#%d %s（源码无法装载：%s）",
    ["#%d announced takeover (lower ID), going standby"] = "#%d 宣布接管（ID 更小），本机退回待命",
    ["#%d queried job repo, replied %d jobs"] = "#%d 查询了作业仓库，已回复 %d 个作业",
    ["#%d refused the pull: %s"] = "#%d 拒绝了拉取请求：%s",
    ["#%d:idle"] = "#%d:闲",
    ["#%d:offline"] = "#%d:离线",
    ["#%s bad message signature (type=%s)"] = "#%s 的消息签名不对（type=%s）",
    ["#%s duplicate/regressed message dropped (seq %s <= %s)"] = "#%s 重复/回退的消息被丢弃（seq %s ≤ %s）",
    ["#%s message timestamp skew too large"] = "#%s 的消息时间戳偏差过大",
    ["#%s sent unsigned message (type=%s)"] = "#%s 发来未签名的消息（type=%s）",
    ["%d jobs not resumed (job file missing)"] = "有 %d 个作业无法接续（缺少作业文件）",
    ["%d wired / %d wireless"] = "%d 有线 / %d 无线",
    ["%dx%d matrix product: element sum %.6f, trace %.6f, max abs %.4f (%d elements)"] = "%d×%d 矩阵乘积：元素和 %.6f，迹 %.6f，最大绝对值 %.4f（共 %d 个元素）",
    ["%s -> #%d failed: %s"] = "%s → #%d 失败：%s",
    ["%s -> #%d transferring %d/%d"] = "%s → #%d 传输中 %d/%d",
    ["%s = %s (persisted)"] = "%s = %s（已持久化）",
    ["%s = %s (persisted, survives reboot)"] = "%s = %s（已持久化，重启后仍生效）",
    ["%s delivered to #%d (%d chunks, %s)"] = "%s 已送达 #%d（%d 块，%s）",
    ["%s:%d run"] = "%s:%d飞",
    ["(/startup.lua starts the new worker.lua on reboot)"] = "（重启后由 /startup.lua 自动拉起新版本的 worker.lua）",
    ["(no job files under "] = "（",
    ["(no jobs)"] = "（还没有作业）",
    ["(no worker contribution records)"] = "（还没有节点贡献记录）",
    ["(no workers connected)"] = "（还没有节点连接）",
    [")"] = "）",
    ["), unsigned/replay messages dropped"] = "），未签名/重复消息会被丢弃",
    ["* Took over as master (%s): node #%d is active"] = "★ 接管主控（%s）：本机 #%d 现在在岗",
    [", last saw active master #"] = "，最近看到在岗主控 #",
    [", re-registering..."] = "，重新登记…",
    [", redundant"] = "，冗余",
    ["..."] = " 查询作业仓库…",
    [": "] = " 失败: ",
    [":idle"] = ":闲",
    [":offline"] = ":离线",
    ["; available: "] = "；可用：",
    ["Add failed: "] = "添加失败：",
    ["All its jobs already exist locally."] = "对方的作业本地都有了。",
    ["Attach failed: "] = "挂载失败：",
    ["Attached monitor "] = "已挂载显示器 ",
    ["Auto-attached monitor: "] = "已自动挂载显示器：",
    ["Available jobs %d: %s"] = "可用作业 %d 个：%s",
    ["Begin push to %d workers: %s..."] = "开始向 %d 个节点推送 %s…",
    ["Big payload channel: %d/%d tasks, total payload %s (about %s each), anomalies %d"] = "大负载通道：%d/%d 个任务，负载合计 %s（每个约 %s），异常 %d",
    ["Big payload channel: payloads/results above the threshold switch to file transfer"] = "大负载通道：负载/结果超过阈值时自动改走文件传输",
    ["Cancel failed: "] = "取消失败：",
    ["Check that: 1) master runs on the same wired network; 2) cables are connected."] = "请确认：① 主控程序已在同一条有线网络上运行；② 网络线缆接好。",
    ["Cleared %d result cache entries."] = "已清除 %d 条结果缓存。",
    ["Cloud %d endpoints, %d in flight, ok %d / failed %d"] = "云端 %d 端点，在飞 %d，成功 %d / 失败 %d",
    ["Cloud endpoint %s unavailable (%s), no retry for %d s"] = "云端端点 %s 不可用（%s），%d 秒内不再尝试",
    ["Cloud endpoints %d: %s (cloud for details)"] = "云端端点 %d 个：%s（cloud 查看详情）",
    ["Cloud offload is off (set cloud true to enable)"] = "云端卸载已关闭（set cloud true 打开）",
    ["Cloud offload unavailable: "] = "云端卸载不可用：",
    ["Cluster self-check: known answer + optional fault injection (validates dispatch/reduce/retry)"] = "集群自检：已知答案 + 可选故障注入（验证调度/汇总/重派）",
    ["Command error: "] = "指令出错：",
    ["Config: parallel %d, redundant %d, task timeout %s%s (set / cfg)"] = "配置：并发 %d，抢尾冗余 %d，任务超时 %s%s（set 改配置 / cfg 看全部）",
    ["Connected to master #%d"] = "已连接主控 #%d",
    ["Control command failed: "] = "控制命令失败：",
    ["Count primes in [from,to] (verifiable benchmark)"] = "统计 [from,to] 区间内的素数个数（可对答案的基准测试）",
    ["Delete failed: "] = "删除失败：",
    ["Deleted endpoint "] = "已删除端点 ",
    ["Disconnected by master"] = "已被主控断开",
    ["Dispatch resumed."] = "已恢复派发。",
    ["Dropped #%s message: %s"] = "丢弃 #%s 的消息：%s",
    ["Dropped message from #%s: %s"] = "丢弃 #%s 的消息：%s",
    ["Dropped transfer from #%s: %s"] = "丢弃 #%s 的传输消息：%s",
    ["Endpoint %s probe failed: %s"] = "端点 %s 探活失败：%s",
    ["Endpoint %s probe ok: %s"] = "端点 %s 探活成功：%s",
    ["Estimate pi by Monte Carlo (random simulation job demo)"] = "用蒙特卡洛方法估算 π（演示随机模拟类作业）",
    ["FAIL - see details above and main log"] = "FAIL —— 看上面的明细与主控日志",
    ["Failed to attach monitor: "] = "挂载显示器失败：",
    ["Failed to enable message signing: "] = "启用消息签名失败：",
    ["Failed to enable signing: "] = "启用消息签名失败：",
    ["Found master #"] = "已找到主控 #",
    ["Got big result from #%d: %s (%s)"] = "已从 #%d 收到大结果 %s（%s）",
    ["HA: node #%d is in %s mode%s"] = "高可用：本机 #%d 当前是 %s 模式%s",
    ["HTTP event error: "] = "处理 HTTP 事件出错：",
    ["Halt command from master, worker exiting."] = "收到主控的 halt 指令，节点退出。",
    ["Installed sample jobs to "] = "已释放示例作业到 ",
    ["JSON decode failed: "] = "JSON 解码失败: ",
    ["JSON encode failed: "] = "JSON 编码失败: ",
    ["JSON support missing"] = "本机缺少 JSON 支持",
    ["Job #%d %s"] = "作业 #%d %s",
    ["Job #%d %s (%s) params: %s"] = "作业 #%d %s（%s）参数：%s",
    ["Job #%d %s cancelled"] = "作业 #%d %s 已取消",
    ["Job #%d %s finished: done %d / failed %d, elapsed %s"] = "作业 #%d %s 结束：成功 %d / 失败 %d，用时 %s",
    ["Job #%d %s result cache hit (computed %s ago), returning result"] = "作业 #%d %s 命中结果缓存（%s 前算过），直接出结果",
    ["Job #%d %s started (%d tasks, priority %d)"] = "作业 #%d %s 开始执行（%d 个任务，优先级 %d）",
    ["Job #%d %s submitted: %d tasks  %s"] = "作业 #%d %s 已提交：%d 个任务  %s",
    ["Job #%d priority set to %d"] = "作业 #%d 优先级改为 %d",
    ["Job #%d two-level reduce: %d results split into %d groups"] = "作业 #%d 进入两级汇总：%d 条结果分成 %d 组并行 reduce",
    ["Job repo of #%d (%d):"] = "#%d 的作业仓库（%d 个）：",
    ["LU solve: %dx%d, solved %d RHS, residual max|Ax-b| = %.3e (should be ~0), sum x = %.6f"] = "LU 求解：%d×%d，解了 %d 个右端项，残差 max|Ax-b| = %.3e（应≈0），Σx = %.6f",
    ["Load job failed: "] = "加载作业失败：",
    ["Local panel closed"] = "已关闭本地大屏面板",
    ["Looking for master..."] = "正在寻找主控…",
    ["Lost master, searching again..."] = "与主控失联，重新搜索…",
    ["Master #%d active (lower ID), this node goes standby"] = "主控 #%d 在岗（ID 更小），本机退回待命模式",
    ["Master #%d took over, staying standby"] = "主控 #%d 已接管，本机继续待命",
    ["Master disabled network screen push"] = "主控已关闭网络屏幕推送",
    ["Master exiting. Workers keep waiting and reconnect on restart."] = "主控退出。节点会继续等待，重新运行 master.lua 后会自动重连。",
    ["Master found again #"] = "重新找到主控 #",
    ["Master protocol version incompatible: "] = "主控协议版本不兼容：",
    ["Master starting..."] = "主控启动中…",
    ["Master's network screen slots are full"] = "主控的网络屏幕数量已满",
    ["Matrix multiply (row blocks; matrices regenerated from seed per node, verifiable)"] = "矩阵乘法（按行分块；矩阵按种子在各节点再生，可对答案）",
    ["Message error: "] = "处理消息出错：",
    ["Message signing enabled (key fingerprint "] = "消息签名已启用（密钥指纹 ",
    ["Message signing: enabled, key fingerprint "] = "消息签名：已启用，密钥指纹 ",
    ["Message signing: off (setkey <key> enables)"] = "消息签名：未启用（setkey <密钥> 可以打开）",
    ["Monitor %s  %dx%d"] = "显示器 %s  %dx%d",
    ["N-body gravity: forces per body block (net force should be ~0, self-check)"] = "N 体引力：按天体分块算受力（净外力应≈0，可自检）",
    ["N-body: %d bodies, sum|F| = %.6f, net force = %.3e (should be ~0), pairwise terms %d (expected %d)"] = "N 体引力：%d 个天体，Σ|F| = %.6f，净外力 = %.3e（应≈0），两两作用 %d 次（应为 %d）",
    ["Net screen #"] = "已断开网络屏幕 #",
    ["Net screen #%d connected: %s (%dx%d)"] = "网络屏幕 #%d 已连接：%s（%dx%d）",
    ["Net screen #%d left: %s"] = "网络屏幕 #%d 已退出：%s",
    ["Net screen #%d offline (no msg for %.0f s)"] = "网络屏幕 #%d 已离线（%.0f 秒没有消息）",
    ["Net screen #%d size changed: %dx%d -> %dx%d"] = "网络屏幕 #%d 尺寸变化：%dx%d → %dx%d",
    ["Net screen #%s protocol incompatible: %s"] = "网络屏幕 #%s 协议版本不兼容：%s",
    ["Net screen push off (screens show 'master closed')"] = "已关闭网络屏幕推送（屏幕端会显示「主控已关闭」）",
    ["Net screen push on (run screen.lua on the screen computer)"] = "已开启网络屏幕推送（屏幕电脑上运行 screen.lua 即可）",
    ["Net screens %d (mon net to list / toggle)"] = "网络屏幕 %d 台（mon net 查看 / 开关）",
    ["Net screens: %s (%d/%d)"] = "网络屏幕：%s（%d/%d 台）",
    ["Network: opened %s (%s)"] = "网络：已打开 %s（%s）",
    ["Network: opened %s (%s)  ID #%d"] = "网络：已打开 %s（%s）  本机 ID #%d",
    ["New version received (%s); reboot to apply"] = "已收到新版本（%s），用主控的 reboot 指令重启后生效",
    ["No finished job yet."] = "还没有完成的作业。",
    ["No jobs to resume."] = "没有需要接续的作业。",
    ["No local monitor attached."] = "当前没有挂载本地显示器。",
    ["No master for %d s, rebooting per watchdog..."] = "已经 %d 秒找不到主控，按看门狗设置重启电脑…",
    ["No master found."] = "没有找到主控。",
    ["No result to save."] = "没有可保存的结果。",
    ["No such net screen: #"] = "没有这块网络屏幕：#",
    ["No workers to push to."] = "没有可推送的节点。",
    ["No workers to reboot."] = "没有可重启的节点。",
    ["Note: no worker online; job queues until one connects."] = "提示：当前没有节点在线，作业会排队等待节点接入。",
    ["Online workers %d / registered %d"] = "在线节点 %d / 登记 %d",
    ["Opened modems: %s"] = "已打开 modem：%s",
    ["PASS - link OK"] = "PASS —— 链路正常",
    ["Panel draw failed: "] = "面板绘制失败：",
    ["Panel write to monitor failed (size "] = "面板写入显示器失败（尺寸 ",
    ["Panel: %s (%dx%d, scale %.2f)"] = "大屏：%s（%dx%d，缩放 %.2f）",
    ["Parallel Mandelbrot render (data-block job demo)"] = "并行渲染曼德博集合（演示数据块型作业）",
    ["Parallel brute-force search (early-termination job demo)"] = "并行暴力搜索（演示提前终止型作业）",
    ["Pause failed: "] = "暂停失败：",
    ["Paused all dispatch (running tasks unaffected)."] = "已暂停全部派发（正在执行的任务不受影响）。",
    ["Payload write failed: "] = "负载写入失败：",
    ["Press Ctrl+T to stop the worker."] = "按 Ctrl+T 可以终止节点。",
    ["Prime count (cloud endpoints preferred, falls back to local on failure)"] = "素数统计（有云端端点时优先卸载到云端，失败自动回落本机）",
    ["Probe not sent: "] = "探活没发出去：",
    ["Protocol version incompatible"] = "协议版本不兼容",
    ["Pulled job from #%d: %s (%s)"] = "已从 #%d 拉取作业 %s（%s）",
    ["Push %s -> #%d unacked (chunk %d/%d)"] = "推送 %s → #%d 迟迟没有确认（第 %d/%d 块）",
    ["Push %s to #%d failed: %s"] = "推送 %s 到 #%d 失败：%s",
    ["Push failed: "] = "推送失败：",
    ["Push to net screen #%d failed: %s"] = "给网络屏幕 #%d 推送失败：%s",
    ["Pushed %s to #%d (%s)"] = "已把 %s 推给 #%d（%s）",
    ["Pushed %s to worker #%d (%s)"] = "已推送 %s 给节点 #%d（%s）",
    ["Pushing %s -> #%d (%s)"] = "开始推送 %s → #%d（%s）",
    ["Querying job repo of #"] = "已向 #",
    ["RHS %d/%d"] = "右端项 %d/%d",
    ["Reboot command from master, rebooting..."] = "收到主控的重启指令，正在重启电脑…",
    ["Received %d panel frames"] = "已收到 %d 帧面板",
    ["Received job source %s (%s)"] = "已接收作业源码 %s（%s）",
    ["Receiving from #%d: chunked %s (%s chunks)"] = "开始接收 #%d 的分块传输 %s（%s 块）",
    ["Refused invalid job name: "] = "拒绝分发非法作业名：",
    ["Refused unknown file: "] = "拒绝保存未知文件：",
    ["Refusing unknown file: "] = "拒绝写入未知文件：",
    ["Registered cloud endpoint %s -> %s (%d parallel, persisted)"] = "已注册云端端点 %s → %s（%d 并发，已持久化）",
    ["Registered with master, waiting for tasks."] = "已在主控登记，等待任务。",
    ["Requesting job "] = "请求拉取作业 ",
    ["Restart %d after error: %s"] = "第 %d 次异常：%s",
    ["Restored %d unfinished jobs from snapshot"] = "已从快照恢复 %d 个未完成作业（断点续算）",
    ["Result cache %d entries (%s):"] = "结果缓存 %d 条（%s）：",
    ["Result push failed, using inline: "] = "结果推送失败，改回内联：",
    ["Result saved: "] = "结果已保存：",
    ["Result: "] = "结论：",
    ["Resume failed: "] = "恢复失败：",
    ["Resumed %d jobs (completed task results reused)"] = "已接续 %d 个作业（完成的任务结果直接沿用）",
    ["Run history (latest %d / total %d):"] = "运行历史（最近 %d / 共 %d 条）：",
    ["Run mon net at master to list or kick screens"] = "在主控上 mon net 看列表 / 踢掉不用的屏幕",
    ["Run mon net on at the master to re-enable"] = "在主控上执行 mon net on 重新开启",
    ["Save failed"] = "保存失败",
    ["Saved: "] = "已保存：",
    ["Set as standby master (next start): watch heartbeat, take over if active dies"] = "已设为待命主控（下次启动生效）：只盯心跳，在岗主控掉线就接管",
    ["Set failed: "] = "设置失败：",
    ["Signing enabled, key fingerprint "] = "已启用消息签名，密钥指纹 ",
    ["Signing off (any program on the subnet can impersonate)"] = "消息签名：未启用（同网段任何程序都能冒充主控或节点）",
    ["Signing off (anyone on the subnet can impersonate master/worker)"] = "已关闭消息签名（同网段任何人都能冒充主控/节点）",
    ["Snapshot cleared (no resume on next start)."] = "已清除快照（下次启动不再续算）。",
    ["Snapshot failed: "] = "快照失败：",
    ["Snapshot not restored: "] = "快照未恢复：",
    ["Snapshot written."] = "快照已写入。",
    ["Snapshot: %s (%s)"] = "快照：%s（%s）",
    ["Solve A*x=b by LU factorization (parallel over RHS; residual max|Ax-b| self-check)"] = "LU 分解解线性方程组（按右端项并行；残差 max|Ax-b| 自检）",
    ["Standby cleared (next start runs as active master)"] = "已取消待命设置（下次启动直接当在岗主控）",
    ["Standby: ignoring #%s %s"] = "待命模式：忽略 #%s 的 %s",
    ["Starting standby: #%d watches heartbeat, takes over after %.0f s"] = "以待命主控模式启动：#%d 只盯心跳，%.0f 秒收不到就接管",
    ["Submit failed: "] = "提交失败：",
    ["Sum-of-squares closed-form check: %s"] = "平方和闭式解校验：%s",
    ["TSP brute force (split by second city, optimal tour verifiable)"] = "旅行商暴力搜索（按第二个城市切分，可对最优解）",
    ["TSP: %d cities, shortest tour %.4f, path %s->1 (%d enumerations, %d branch tasks)"] = "TSP：%d 个城市，最短回路 %.4f，路线 %s→1（枚举 %d 次，%d 个分支任务）",
    ["Task %d.%d cancelled (%.1fs)"] = "任务 %d.%d 已取消（%.1fs）",
    ["Task %d.%d done (%s)"] = "任务 %d.%d 完成（%s）",
    ["Task %d.%d failed: %s"] = "任务 %d.%d 失败：%s",
    ["Task %d.%d hash mismatch, refusing to run"] = "任务 %d.%d 的源码哈希不符，拒绝执行",
    ["Task %d.%d missing job source"] = "任务 %d.%d 缺少作业源码",
    ["Task %d.%d payload fetch failed: %s"] = "任务 %d.%d 取负载失败：%s",
    ["Task %d.%d result %s, sent via file channel"] = "任务 %d.%d 结果 %s，走文件通道推给主控",
    ["Task ids: %s"] = "任务号完整性：%s",
    ["Tasks %d ok / %d failed, elapsed %s"] = "任务 %d 成功 / %d 失败，用时 %s",
    ["Told %d workers to exit."] = "已通知 %d 个节点退出。",
    ["Told %d workers to reboot."] = "已通知 %d 个节点重启。",
    ["Told worker #"] = "已通知节点 #",
    ["Total tasks %d failed %d retries %d redundant %d"] = "累计任务 %d 失败 %d 重试 %d 冗余 %d",
    ["Type help for commands."] = "输入 help 查看指令。",
    ["Type mon at the master to view network screens"] = "在主控上输入 mon 查看网络屏幕",
    ["URL must start with http:// or https://"] = "URL 必须以 http:// 或 https:// 开头",
    ["Unfinished jobs %d; auto-write every >=3s on change, fallback %ds"] = "未完成作业 %d 个；有变化时每 ≥3s 自动写一次，兜底 %ds",
    ["Unknown command: "] = "未知指令：",
    ["Update screen.lua to match the master version"] = "请把 screen.lua 更新到与主控相同的版本",
    ["Upgrade worker and master to the same version."] = "请把本节点与主控升级到同一版本后重试。",
    ["Usage: cancel <job id>"] = "用法：cancel <作业号>",
    ["Usage: cloud add <name> <url> [parallel]"] = "用法：cloud add <名字> <url> [并发数]",
    ["Usage: cloud test <name>"] = "用法：cloud test <名字>",
    ["Usage: kick <worker id>"] = "用法：kick <节点ID>",
    ["Usage: mon net kick <screen id> (mon net lists them)"] = "用法：mon net kick <屏幕ID>（mon net 看列表）",
    ["Usage: pri <job id> <priority>"] = "用法：pri <作业号> <优先级>",
    ["Usage: pull <master id> <job names...> (adds .lua)"] = "用法：pull <主控ID> <作业名…>（自动补 .lua）",
    ["Usage: repo <master id> (lists its jobs)"] = "用法：repo <主控ID>（列出对方有哪些作业）",
    ["Usage: repo <master id> first, then pullall <master id>"] = "用法：先 repo <主控ID> 看清单，再 pullall <主控ID>",
    ["Usage: run <job> [params..] [pri=N] (jobs lists available)"] = "用法：run <作业名> [参数..] [pri=N]（用 jobs 查看可用作业）",
    ["Usage: set <key> <value> (cfg lists all keys)"] = "用法：set <配置项> <值>（用 cfg 看全部配置项）",
    ["Usage: setkey <shared key> (min 8 chars; same key on all)"] = "用法：setkey <共享密钥>（至少 8 位；各机器设成同一个才会互相接受）",
    ["Will reconnect on next heartbeat"] = "下次心跳会自动重连",
    ["Worker #%d %s | Master #%s | %s%s | done %d failed %d"] = "节点 #%d %s | 主控 #%s | %s%s | 完成 %d 失败 %d",
    ["Worker #%d %s: %s (%s)"] = "节点 #%d 已%s：%s（%s）",
    ["Worker #%d lost contact (>%ds)"] = "节点 #%d 失去联系（>%ds）",
    ["Worker #%d protocol version incompatible: %s"] = "节点 #%d 协议版本不兼容：%s",
    ["Worker #%d requests %s..."] = "节点 #%d 请求拉取 %s…",
    ["Worker #%d requests job %s..."] = "节点 #%d 请求拉取作业 %s…",
    ["Worker #%d went offline: %s"] = "节点 #%d 主动下线：%s",
    ["Worker name: %s (use label set <name> to rename)"] = "节点名：%s（用 label set <名字> 可以改名）",
    ["Worker starting v"] = "节点启动 v",
    ["Workers %d/%d jobs %d"] = "节点 %d/%d 作业 %d",
    ["Workers %d/%d online   parallel %d/%d   queue %d%s"] = "节点 %d/%d 在线   并发 %d/%d   队列 %d%s",
    ["Write failed: "] = "写入失败：",
    ["You can also pass worker <masterID> explicitly."] = "也可以用 worker <主控ID> 直接指定。",
    ["[%d, %d] no hash divisible by %d found"] = "[%d, %d] 内没有找到能被 %d 整除的哈希",
    ["[bootstrap] found master #"] = "[bootstrap] 找到主控 #",
    ["[bootstrap] master cannot distribute code: "] = "[bootstrap] 主控无法分发代码：",
    ["[bootstrap] missing %d chunks, requesting retransmit"] = "[bootstrap] 缺 %d 块，请求重传",
    ["[bootstrap] receiving worker.lua ..."] = "[bootstrap] 正在接收 worker.lua …",
    ["[bootstrap] using %s (%s), computer ID #%d"] = "[bootstrap] 使用 %s（%s），本机 ID #%d",
    ["[bootstrap] wrote %s (%d bytes), starting worker..."] = "[bootstrap] 已写入 %s（%d 字节），启动节点…",
    ["[dcnet] Attach a monitor to this computer, or pass screen.lua <name>."] = "[dcnet] 把显示器贴在电脑侧面，或用 screen.lua <外设名> 指定。",
    ["[dcnet] Attach a network cable to a wired modem and check peripheral.getNames()."] = "[dcnet] 请在有线调制解调器上接好网络线缆，并用 peripheral.getNames() 确认。",
    ["[dcnet] Master crashed: "] = "[dcnet] 主控异常终止：",
    ["[dcnet] Master stopped."] = "[dcnet] 主控已停止。",
    ["[dcnet] Network screen %s started: monitor %s (%dx%d), waiting for master..."] = "[dcnet] 网络屏幕 %s 已启动：显示器 %s（%dx%d），等待主控…",
    ["[dcnet] Network screen: cannot open monitor "] = "[dcnet] 网络屏幕：无法打开显示器 ",
    ["[dcnet] Network screen: dropped a message ("] = "[dcnet] 网络屏幕：丢弃一条消息（",
    ["[dcnet] Network screen: failed to enable message signing: "] = "[dcnet] 网络屏幕：启用消息签名失败：",
    ["[dcnet] Network screen: failed to open modem: "] = "[dcnet] 网络屏幕：打开 modem 失败：",
    ["[dcnet] Network screen: message signing enabled (fingerprint "] = "[dcnet] 网络屏幕：消息签名已启用（指纹 ",
    ["[dcnet] Network screen: monitor not found "] = "[dcnet] 网络屏幕：找不到显示器 ",
    ["[dcnet] Network screen: no modem detected"] = "[dcnet] 网络屏幕：没有检测到调制解调器（modem）",
    ["[dcnet] Network screen: no monitor on this computer"] = "[dcnet] 网络屏幕：这台电脑上没有显示器（monitor）",
    ["[dcnet] No modem detected"] = "[dcnet] 没有检测到调制解调器（modem）",
    ["[dcnet] Screen computer must be on the wired (or same wireless) network."] = "[dcnet] 屏幕电脑也要接在有线网络（或同一无线网络）里。",
    ["[dcnet] Wired setup: put a wired modem beside the computer, cable into the modem,"] = "[dcnet] 有线网络接法：电脑旁放有线调制解调器，调制解调器上接网络线缆，",
    ["[dcnet] Worker crashed: "] = "[dcnet] 节点异常终止: ",
    ["[dcnet] Worker error (%s), auto-restart in %d s (%d/%d)"] = "[dcnet] 节点异常（%s），%d 秒后自动重启（第 %d/%d 次）",
    ["[dcnet] Worker failed %d times in a row, no auto-restart: %s"] = "[dcnet] 节点连续异常 %d 次，停止自动重启：%s",
    ["[dcnet] Worker stopped."] = "[dcnet] 节点已停止。",
    ["[dcnet] chain all machines on one cable; add more modems to bridge more networks."] = "[dcnet] 所有机器串到同一段线缆上即可；要多网段就给主控挂多个 modem。",
    ["[dcnet] master failed to start."] = "[dcnet] 主控启动失败。",
    ["[dcnet] screen failed to start."] = "[dcnet] 网络屏幕启动失败。",
    ["[dcnet] unknown argument: "] = "[dcnet] 未知参数: ",
    ["[dcnet] worker failed to start."] = "[dcnet] 节点启动失败。",
    ["active"] = "在岗",
    ["adaptive timeout from task history"] = "按历史耗时自适应超时",
    ["adaptive timeout max (s)"] = "自适应超时上限（秒）",
    ["adaptive timeout min (s)"] = "自适应超时下限（秒）",
    ["all match"] = "全部一致",
    ["all tasks failed"] = "所有任务都失败了",
    ["auto restart interval (s)"] = "自动重启间隔（秒）",
    ["auto resume unfinished jobs on start"] = "启动时自动接上未完成作业",
    ["avg/s"] = "均速",
    ["bad reduce task payload (missing __reduce)"] = "reduce 任务负载格式不对（缺少 __reduce）",
    ["bad signature"] = "签名错误",
    ["bodies per task"] = "每个任务算几个天体",
    ["body %d/%d"] = "天体 %d/%d",
    ["body count"] = "天体数量",
    ["busy"] = "忙碌",
    ["cancelled"] = "取消",
    ["cannot open any modem"] = "无法打开任何调制解调器",
    ["cannot open monitor: "] = "无法打开显示器: ",
    ["cannot open: "] = "无法打开: ",
    ["cannot parse pool file: "] = "池子文件解析失败: ",
    ["cannot write: "] = "无法写入: ",
    ["chunk ack timeout"] = "分块确认超时",
    ["city count (9 -> 8! tours, split into 8 parts by second city)"] = "城市数量（9 → 8! 条回路，按第二城切成 8 份）",
    ["cloud"] = "云端",
    ["cloud chunk encode failed: "] = "云端分块编码失败: ",
    ["cloud chunk upload failed: "] = "云端分块上传失败: ",
    ["cloud must be a table"] = "cloud 必须是 table",
    ["cloud rejected chunk: "] = "云端拒绝分块: ",
    ["cloud request build failed: "] = "云端请求打包失败: ",
    ["cloud request chunk size (bytes)"] = "云端请求超过多少字节就分块上传",
    ["cloud request encode failed: "] = "云端请求编码失败: ",
    ["cloud request failed: "] = "云端请求失败: ",
    ["cloud response has no count field"] = "云端响应里没有 count 字段",
    ["cloud response is not valid JSON: "] = "云端响应不是合法 JSON: ",
    ["cloud response parse failed: "] = "云端响应解析失败: ",
    ["cloud returned failure"] = "云端返回失败",
    ["cloud unreachable: "] = "云端不可达: ",
    ["cloud.build must be a function"] = "cloud.build 必须是函数",
    ["cloud.build returned nil"] = "cloud.build 返回了 nil",
    ["cloud.endpoint must be a string"] = "cloud.endpoint 必须是字符串",
    ["cloud.parse must be a function"] = "cloud.parse 必须是函数",
    ["cloud.parse returned nil"] = "cloud.parse 返回了 nil",
    ["compile failed: "] = "编译失败: ",
    ["complete, no duplicates"] = "齐全且无重复",
    ["computing"] = "运算",
    ["connected"] = "连接",
    ["cooling %ds (%s)"] = "冷却中 %ds（%s）",
    ["current"] = "当前",
    ["dcnet master #%d   %s"] = "dcnet 主控 #%d   %s",
    ["dcnet master v%s   local ID #%d"] = "dcnet 主控 v%s   本机 ID #%d",
    ["dcnet network screen #%d"] = "dcnet 网络屏幕 #%d",
    ["dcnet worker v%s"] = "dcnet 运算节点 v%s",
    ["dcnet: transport=rpv but lib/rpvnet.lua unavailable: "] = "dcnet: transport=rpv 但 lib/rpvnet.lua 不可用: ",
    ["deliberately failed tasks"] = "故意失败的任务数",
    ["dispatch paused"] = "已暂停派发",
    ["dispatch resumed"] = "已恢复派发",
    ["done"] = "完成",
    ["duplicate message"] = "重复消息",
    ["elapsed"] = "累计耗时",
    ["empty content"] = "内容为空",
    ["enable cloud offload (HTTP compute)"] = "启用云端卸载（HTTP 计算服务）",
    ["end"] = "终点",
    ["endpoint name already exists: "] = "端点名已存在: ",
    ["endpoint name cannot be empty"] = "端点名不能为空",
    ["endpoints %d, inflight %d, total ok %d / failed %d"] = "端点 %d 个，在飞请求 %d，累计成功 %d / 失败 %d",
    ["expected true/false"] = "需要 true/false",
    ["failed"] = "失败",
    ["failed to load module "] = "加载模块 ",
    ["failed to read result file: "] = "结果文件读取失败: ",
    ["fallback snapshot interval (s)"] = "兜底快照间隔（秒）",
    ["file channel threshold (bytes)"] = "超过多少字节改走文件通道",
    ["file not found: "] = "文件不存在: ",
    ["final ack timeout"] = "结束确认超时",
    ["format failed: "] = "format 执行失败: ",
    ["format must be a function"] = "format 必须是函数",
    ["handshake"] = "握手",
    ["http unavailable (http_enable may be off)"] = "本机 http 不可用（服务器可能关了 http_enable）",
    ["idle"] = "空闲",
    ["idle worker poll interval (s)"] = "节点空闲轮询间隔（秒）",
    ["image height"] = "图像高度",
    ["image width"] = "图像宽度",
    ["initial task timeout (s)"] = "任务初始超时（秒）",
    ["inner hash failed"] = "内部哈希失败",
    ["integers per task"] = "每个任务的整数个数",
    ["invalid argument %s: %s"] = "参数 %s 无效: %s",
    ["invalid job name"] = "非法作业名",
    ["invalid message format"] = "消息格式非法",
    ["invalid module name: "] = "模块名非法: ",
    ["invalid payload name"] = "非法负载名",
    ["invalid pool file name"] = "非法池子文件名",
    ["invalid target ID"] = "目标 ID 非法",
    ["invalid timestamp"] = "时间戳无效",
    ["job already finished"] = "作业已经结束",
    ["job does not define cloud.build"] = "作业没有定义 cloud.build",
    ["job does not define cloud.parse"] = "作业没有定义 cloud.parse",
    ["job has no local map (cloud only)"] = "该作业没有本地 map（只能交给云端执行）",
    ["job has no reduce, cannot do two-level reduce"] = "该作业没有 reduce，不能做两级汇总",
    ["job init failed: "] = "作业初始化失败: ",
    ["job must return a table"] = "作业必须 return 一个 table",
    ["job name may only contain letters, digits, underscore and dash"] = "作业名只能包含字母、数字、下划线和短横线",
    ["job source compile failed: "] = "作业源码编译失败: ",
    ["job source not found locally (hash "] = "本地没有该作业源码（哈希 ",
    ["job source verification failed (hash mismatch)"] = "作业源码校验失败（哈希不符）",
    ["just match the fingerprint"] = "核对指纹一致即可",
    ["key hash failed"] = "密钥哈希失败",
    ["key too short (at least 8 characters)"] = "密钥太短（至少 8 个字符）",
    ["large payloads via file channel"] = "大负载走文件通道",
    ["last seen"] = "最近在线",
    ["load failed: "] = "加载失败: ",
    ["log every task dispatch"] = "打印每次任务派发",
    ["malformed result received"] = "收到结构异常的结果",
    ["map must be a function"] = "map 必须是函数",
    ["map result is not serializable (may contain functions or coroutines)"] = "map 返回值无法序列化（可能包含函数或协程）",
    ["map returned nil (return an explicit structure for \"not found\", e.g. { hit = false })"] = "map 返回了 nil（要表达\"没找到\"请返回显式结构，例如 { hit = false }）",
    ["master #%d"] = "主控 #%d",
    ["master has no "] = "主控上没有 ",
    ["master not found"] = "找不到主控",
    ["matrix order"] = "矩阵阶数",
    ["max auto restarts after error"] = "异常后最多自动重启次数",
    ["max dispatches per task"] = "单任务最多派发次数",
    ["max iterations"] = "最大迭代次数",
    ["min hit n = %d (hash(\"dc%d\") %% %d == 0), scanned %d values"] = "最小命中 n = %d（hash(\"dc%d\") %% %d == 0），共扫描 %d 个数",
    ["missing "] = "缺少 ",
    ["missing map function (or cloud definition for cloud offload)"] = "缺少 map 函数（或用于云端卸载的 cloud 定义）",
    ["missing name field"] = "缺少 name 字段",
    ["module not found: "] = "找不到模块 ",
    ["monitor name (empty=auto)"] = "大屏显示器名（空=自动找）",
    ["monitor text scale"] = "大屏字号缩放",
    ["name"] = "名称",
    ["network not open ("] = "网络未打开（",
    ["no bit32, cannot compute HMAC"] = "本机没有 bit32，无法计算 HMAC",
    ["no bit32, cannot compute hash"] = "本机没有 bit32，无法计算哈希",
    ["no bit32, cannot enable message signing"] = "本机没有 bit32，无法启用消息签名",
    ["no master found: make sure master.lua is running on the same wired network."] = "没有找到主控：请确认主控已在同一条有线网络上运行（master.lua）。",
    ["no master heartbeat for %.0f s"] = "已 %.0f 秒没有主控心跳",
    ["no modem detected"] = "没有检测到调制解调器",
    ["no modem found: connect the network cable to a wired modem."] = "没有找到调制解调器：请在有线调制解调器上接好网络线缆。",
    ["no monitor detected"] = "没有检测到显示器",
    ["no monitor specified"] = "没有指定显示器",
    ["no progress for %.0fs"] = "超过 %.0fs 无进展",
    ["no snapshot"] = "没有快照",
    ["no such endpoint: "] = "没有这个端点: ",
    ["no such job"] = "没有这个作业",
    ["none"] = "无",
    ["not a boolean"] = "不是布尔值",
    ["not a monitor peripheral: "] = "不是显示器外设: ",
    ["not a number"] = "不是数字",
    ["not in pool: "] = "池子里没有 ",
    ["number required"] = "需要数字",
    ["off"] = "已关闭",
    ["offline"] = "离线",
    ["offline "] = "离线 ",
    ["padding bytes added to cloud requests (chunked upload test)"] = "给云端请求塞多少字节填充（测分块上传用）",
    ["parallel %d/%d"] = "并发 %d/%d",
    ["parallel jobs"] = "同时执行的作业数",
    ["parallel reduce when many results"] = "结果多时并行 reduce（两级汇总）",
    ["params must be an array"] = "params 必须是数组",
    ["paused"] = "已暂停",
    ["payload bytes per task"] = "每个任务的负载字节数",
    ["payload not found"] = "负载不存在",
    ["payload write failed, inline fallback: "] = "负载落盘失败，退回内联：",
    ["pi ~ %.6f (samples %d, inside %d, relative error %.4f%%)"] = "π ≈ %.6f（样本 %d，圆内 %d，相对误差 %.4f%%）",
    ["prefer cloud (off=only when busy)"] = "优先用云端（关闭=本机空闲时不用云端）",
    ["primes in [%d, %d] = %d (max %s); %d tasks, cloud %d / local %d"] = "[%d, %d] 内素数个数 = %d（最大 %s）；%d 个任务，其中云端 %d / 本机 %d",
    ["primes in [%d, %d] = %d (max prime %s), reduced from %d tasks"] = "[%d, %d] 内素数个数 = %d（最大素数 %s），由 %d 个任务汇总",
    ["protocol version mismatch (peer %d, local %d)"] = "协议版本不匹配（对端 %d，本机 %d）",
    ["push panel to network screens"] = "向网络屏幕推送面板（屏幕节点）",
    ["pushing"] = "推送中",
    ["queue "] = "队列 ",
    ["queued"] = "排队",
    ["random seed"] = "随机种子",
    ["random seed (determines city coordinates)"] = "随机种子（决定城市坐标）",
    ["random seed (determines initial layout)"] = "随机种子（决定初始分布）",
    ["random seed (determines matrix)"] = "随机种子（决定矩阵内容）",
    ["random seed (reproducible)"] = "随机种子（保证可复现）",
    ["ready"] = "就绪",
    ["reboot after master lost (s, 0=off)"] = "失联多久重启电脑（0=关）",
    ["reconnected"] = "重新连接",
    ["reduce failed: "] = "reduce 执行失败: ",
    ["reduce must be a function"] = "reduce 必须是函数",
    ["reduce result is not serializable"] = "reduce 返回值无法序列化",
    ["reduce returned nil"] = "reduce 返回了 nil",
    ["redundant "] = "抢尾 ",
    ["request could not be sent"] = "请求未能发出",
    ["result bytes per task"] = "每个任务的返回字节数",
    ["results needed for two-level reduce"] = "超过多少条结果启用两级汇总",
    ["results per reduce task"] = "每个 reduce 任务处理多少条结果",
    ["right-hand sides per task"] = "每个任务解几个右端项",
    ["row %d"] = "行 %d",
    ["row %d/%d"] = "行 %d/%d",
    ["rows per task"] = "每个任务算几行",
    ["rows rendered per task"] = "每个任务渲染的行数",
    ["run failed: "] = "运行失败: ",
    ["running"] = "执行中",
    ["samples per task"] = "每个任务的样本数",
    ["scan range per task"] = "每个任务扫描范围",
    ["selftest deliberate failure (task "] = "selftest 故意失败（任务 ",
    ["serialization failed: "] = "序列化失败: ",
    ["serving master heartbeat (s)"] = "在岗主控心跳间隔（秒）",
    ["settings API not available"] = "本机没有 settings API",
    ["sha256(long string)"] = "sha256(长串)",
    ["signature: signed %d  accepted %d  dropped %d"] = "签名：已签 %d　放行 %d　丢弃 %d",
    ["snapshot disabled"] = "快照已关闭",
    ["snapshot unfinished jobs"] = "把未完成作业写快照（断点续算）",
    ["snapshot write failed: "] = "快照写入失败：",
    ["softening length to avoid divide-by-zero"] = "软化长度，避免除零",
    ["split failed: "] = "split 执行失败: ",
    ["split must be a function"] = "split 必须是函数",
    ["split must return a non-empty task array"] = "split 必须返回非空的任务数组",
    ["standby"] = "待命",
    ["start"] = "起点",
    ["start (>=2)"] = "起点（>=2）",
    ["start as standby master"] = "本机作为待命主控启动",
    ["state"] = "状态",
    ["straggler redundancy threshold (0=off)"] = "抢尾冗余派发阈值（0=关）",
    ["takeover after missed heartbeats (s)"] = "收不到心跳多久后接管（秒）",
    ["target divisor"] = "目标整除因子",
    ["target is not a network node"] = "目标不是网络节点",
    ["task "] = "任务 ",
    ["task %d check mismatch: %s != %s"] = "任务 %d 校验不符：%s ≠ %s",
    ["task count"] = "任务数",
    ["task payload fetch failed: "] = "取任务负载失败: ",
    ["tasks %d: expected success %d, actual success %d; expected failures %d (check main log)"] = "任务 %d 个：预期成功 %d，实际成功 %d；预期失败 %d（与主控日志核对）",
    ["terms per task"] = "每任务平方和项数",
    ["textutils.serializeJSON is missing (CC too old)"] = "本机没有 textutils.serializeJSON（CC 版本过旧）",
    ["textutils.unserializeJSON is missing (CC too old)"] = "本机没有 textutils.unserializeJSON（CC 版本过旧）",
    ["timed out waiting for payload"] = "等待负载超时",
    ["total samples"] = "总样本数",
    ["transfer failed"] = "传输失败",
    ["transfer timeout"] = "传输超时",
    ["unknown"] = "未知",
    ["unknown argument: "] = "未知参数: ",
    ["unknown config: "] = "未知配置项: ",
    ["unrecognized snapshot format (version mismatch or corrupt file)"] = "快照格式不认识（版本不符或文件损坏）",
    ["unsigned"] = "未签名",
    ["use result cache"] = "使用结果缓存",
    ["watchdog: master unreachable, rebooting"] = "看门狗：联系不上主控，重启电脑",
    ["wired"] = "有线",
    ["wireless"] = "无线",
    ["worker"] = "节点",
    ["worker crashed: "] = "节点异常终止：",
    ["worker error: "] = "节点报错: ",
    ["worker offline"] = "节点离线",
    ["worker offline timeout (s)"] = "节点失联判定（秒）",
    ["worker re-hello silence (s)"] = "节点重发 hello 的静默阈值（秒）",
    ["worker rediscover silence (s)"] = "节点重新搜索主控的静默阈值（秒）",
    ["worker stopped normally"] = "节点正常停止",
    ["workers %d/%d"] = "节点 %d/%d",
}

-- ── printf 模板 → 锚定 pattern（首次中文翻译时才构建） ──────────────────
local MAGIC = "^$()%.[]*+-?"

local function escapeMagic(ch)
    if ch ~= "" and MAGIC:find(ch, 1, true) then return "%" .. ch end
    return ch
end

local CAPTURE = {
    d = "(%-?%d+)", i = "(%-?%d+)", u = "(%-?%d+)", o = "(%-?%d+)", c = "(%-?%d+)",
    x = "(%-?[%x]+)", X = "(%-?[%x]+)",
    e = "(%-?%d+%.?%d*)", E = "(%-?%d+%.?%d*)", f = "(%-?%d+%.?%d*)",
    g = "(%-?%d+%.?%d*)", G = "(%-?%d+%.?%d*)",
    s = "(.-)", q = "(.-)",
}

-- 把英文模板编译成锚定 pattern，返回 pattern 与占位符个数；不支持则返回 nil
local function compile(tpl)
    local out, n, i, len = {}, 0, 1, #tpl
    while i <= len do
        local ch = tpl:sub(i, i)
        if ch == "%" then
            if tpl:sub(i + 1, i + 1) == "%" then
                out[#out + 1] = "%%"
                i = i + 2
            else
                local j = i + 1
                while j <= len and tpl:sub(j, j):match("^[-+ #0]$") do j = j + 1 end
                while j <= len and tpl:sub(j, j):match("^%d$") do j = j + 1 end
                if tpl:sub(j, j) == "." then
                    j = j + 1
                    while j <= len and tpl:sub(j, j):match("^%d$") do j = j + 1 end
                end
                local cap = CAPTURE[tpl:sub(j, j)]
                if not cap then return nil end
                out[#out + 1] = cap
                n = n + 1
                i = j + 1
            end
        else
            out[#out + 1] = escapeMagic(ch)
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$", n
end

local built = false
local buckets, generic = {}, {}

local function byLength(a, b) return a.len > b.len end

local function buildPatterns()
    built = true
    for en, zh in pairs(ZH) do
        if en:find("%", 1, true) then
            local pat, n = compile(en)
            if pat and n > 0 then
                local item = { pat = pat, zh = zh, n = n, len = #en }
                local head = en:sub(1, 6)
                if not head:find("%", 1, true) then
                    buckets[head] = buckets[head] or {}
                    buckets[head][#buckets[head] + 1] = item
                else
                    generic[#generic + 1] = item
                end
            end
        end
    end
    for _, list in pairs(buckets) do table.sort(list, byLength) end
    table.sort(generic, byLength)
end

local function tryList(list, text)
    for i = 1, #list do
        local item = list[i]
        local caps = { text:match(item.pat) }
        if caps[1] ~= nil then
            local args = {}
            for k = 1, item.n do
                args[k] = (caps[k] or ""):match("^%s*(.-)%s*$")
            end
            local ok, res = pcall(string.format, item.zh, unpack(args, 1, item.n))
            if ok then return res end
        end
    end
end

function M.tr(text)
    if M.lang ~= "zh" then return text end
    -- 没有 CJK 字形介质（字体盘 + 客户端资源包）时，原版 CC 终端画不出汉字，
    -- 打印出去只会是乱码。所以这里回退英文：主控启动时 dc.cjk 探测成功才会
    -- 把 _G.DCNET_CJK_READY 设为 true（见 master.lua）。
    if rawget(_G, "DCNET_CJK_READY") ~= true then return text end
    if type(text) ~= "string" then return text end
    local hit = ZH[text]
    if hit ~= nil then return hit end
    if not built then buildPatterns() end
    local list = buckets[text:sub(1, 6)]
    if list then
        local res = tryList(list, text)
        if res ~= nil then return res end
    end
    if #generic > 0 then
        return tryList(generic, text) or text
    end
    return text
end

return M
