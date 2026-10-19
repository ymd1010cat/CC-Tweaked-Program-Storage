--[[- dc.protocol — 消息类型与协议常量

协议要点（详见 docs/PROTOCOL.md）：

  * 两条 rednet 协议：
      "dccomp"  控制与任务（节点 ↔ 主控）
      "dcpush"  代码分发（主控 → 节点，以及 bootstrap 拉取）
  * 所有消息都是 table，字段 t 是消息类型，字段 ver 是协议版本。
  * 拉模型：节点空闲时发 pull，主控回 task 或 idle。这样节点随时可以重启，
    主控不需要维护"推送队列"。
  * 主控只允许有一个 rednet.receive 循环（CC 的 parallel 会把同一个事件
    分发给所有 filter 匹配的协程，两个同协议 receive 循环会重复消费）。
]]

local M = {}

M.VERSION = 1                     -- 协议版本，主控与节点不一致时拒绝连接
M.CTRL    = "dccomp"
M.PUSH    = "dcpush"

-- 节点 → 主控
M.WHO      = "who"                -- 广播找主控
M.HELLO    = "hello"              -- 上线登记
M.PULL     = "pull"               -- 请求任务（同时充当心跳）
M.RESULT   = "result"             -- 任务结果
M.PROGRESS = "progress"           -- 任务进度
M.BYE      = "bye"                -- 主动下线
M.PONG     = "pong"

-- 主控 → 节点
M.IAM      = "iam"                -- 对 who 的应答
M.WELCOME  = "welcome"            -- 对 hello 的应答，带配置
M.TASK     = "task"
M.IDLE     = "idle"
M.CANCEL   = "cancel"
M.HALT     = "halt"
M.PING     = "ping"

-- 主控 ↔ 主控：高可用（谁在岗 / 谁是备用）
M.BEAT     = "beat"               -- 在岗主控的心跳（备用主控靠它判断要不要接管）
M.TAKEOVER = "takeover"           -- 宣布接管主控角色（带电脑 ID，ID 小的胜）
M.REPO     = "repo"               -- 查询对方有哪些作业
M.REPOINFO = "repoinfo"           -- 应答：作业清单

-- 分块传输（dcpush）
M.FETCH    = "fetch"              -- 节点/新机器请求一份代码
M.PUT      = "put"                -- 一个分块
M.PUTACK   = "putack"             -- 收到一个分块
M.PUTDONE  = "putdone"            -- 所有分块发完
M.PUTOK    = "putok"              -- 接收端校验通过
M.PUTMISS  = "putmiss"            -- 接收端报告缺失分块
M.REFERR   = "referr"             -- 主控无法提供所请求的文件

--- 构造消息
function M.msg(t, fields)
    local m = { t = t, ver = M.VERSION }
    for k, v in pairs(fields or {}) do m[k] = v end
    return m
end

--- 是否是本协议的合法消息
function M.valid(m)
    return type(m) == "table" and type(m.t) == "string"
end

--- 版本兼容检查：返回 true / false, err
function M.compatible(m)
    local v = tonumber(m and m.ver) or 0
    if v ~= M.VERSION then
        return false, string.format("协议版本不匹配（对端 %d，本机 %d）", v, M.VERSION)
    end
    return true
end

return M
