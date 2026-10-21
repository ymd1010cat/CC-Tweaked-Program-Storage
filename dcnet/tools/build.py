#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 src/ 下的模块化源码打包成 dist/ 下的单文件程序。

    python tools/build.py

产物：
    dist/master.lua     主控（自包含，含全部依赖 + 内置示例作业）
    dist/worker.lua     运算节点（自包含）
    dist/screen.lua     网络屏幕（自包含，只画主控推过来的面板）
    dist/bootstrap.lua  新节点一键拉取脚本（原样拷贝 src/bootstrap.lua）

打包方式：每个模块变成一个 function，注册进 __dc_modules 表，
全局 dc_require("dc.xxx") 负责调用并缓存。这样源码可以正常分文件维护，
部署时又是"一个文件一台机器"，不需要在游戏里摆目录结构。
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import luautil                                            # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
LIB = os.path.join(SRC, "lib")
JOBS = os.path.join(SRC, "jobs")
DIST = os.path.join(ROOT, "dist")

VERSION = "1.2.0"
REQUIRE_RE = re.compile(r'dc_require\(\s*"([^"]+)"\s*\)')

BANNER = """--[[- ==========================================================================
  dcnet v{version} — CC:Tweaked 分布式计算网络（{role}）

  本文件由 tools/build.py 自动生成，请勿直接编辑。
  要改逻辑请改 src/ 下的源码，然后重新运行：
      python tools/build.py

  模块：{modules}
========================================================================== ]]
"""


def read(path):
    with open(path, "r", encoding="utf-8", newline="\n") as f:
        return f.read()


def lua_long_string(s):
    """把一段文本包成 Lua 长字符串，自动选择不会冲突的等号个数。

    只需确认"结束分隔符" ]==] 不出现在正文里；正文里出现 [[ 是无害的。
    """
    level = 0
    while True:
        close = "]" + "=" * level + "]"
        if close not in s:
            return "[" + "=" * level + "[\n" + s + "\n]" + "=" * level + "]"
        level += 1


def load_modules():
    mods = {}
    for name in sorted(os.listdir(LIB)):
        if not name.endswith(".lua"):
            continue
        mod_name = "dc." + name[:-4]
        # 打包时剥掉注释：CC 电脑磁盘只有 1MB，注释随包发出去是纯浪费
        mods[mod_name] = luautil.strip_comments(read(os.path.join(LIB, name)))
    return mods


def closure(entry_src, mods):
    """从入口源码出发，按 dc_require 收集需要的模块（传递闭包）。"""
    needed, queue = [], list(REQUIRE_RE.findall(entry_src))
    while queue:
        name = queue.pop(0)
        if name in needed:
            continue
        if name not in mods:
            raise SystemExit("缺少模块: %s" % name)
        needed.append(name)
        queue.extend(REQUIRE_RE.findall(mods[name]))
    # 保持稳定顺序：util/protocol/net 优先，便于阅读
    priority = ["dc.util", "dc.protocol", "dc.net", "dc.console", "dc.xfer",
                "dc.jobs", "dc.sched", "dc.master", "dc.worker", "dc.screen"]
    needed.sort(key=lambda n: (priority.index(n) if n in priority else 99, n))
    return needed


def emit(role, mods, needed, entry_src, extra_globals=""):
    out = [BANNER.format(version=VERSION, role=role, modules=", ".join(needed))]
    out.append("local __dc_modules, __dc_cache = {}, {}\n")
    out.append("local function __dc_define(name, fn) __dc_modules[name] = fn end\n")
    out.append("""local function __dc_load(name)
    local cached = __dc_cache[name]
    if cached ~= nil then return cached end
    local fn = __dc_modules[name]
    if not fn then error("dcnet: 找不到模块 " .. tostring(name), 0) end
    local mod = fn()
    if mod == nil then mod = true end
    __dc_cache[name] = mod
    return mod
end
_G.dc_require = __dc_load
""")
    for name in needed:
        out.append('\n__dc_define("%s", function()\n' % name)
        out.append(mods[name])
        out.append("\nend)\n")
    if extra_globals:
        out.append(extra_globals)
    out.append("\n-- ── 入口 ────────────────────────────────────────────────────────────\n")
    out.append(entry_src)
    return "".join(out)


def build_jobs_block():
    jobs = {}
    for name in sorted(os.listdir(JOBS)):
        if name.endswith(".lua"):
            # 作业源码也会被释放到磁盘、并发给节点，同样剥掉注释
            jobs[name] = luautil.strip_comments(read(os.path.join(JOBS, name)))
    lines = ["\n_G.DC_DEFAULT_JOBS = {\n"]
    for name, src in jobs.items():
        lines.append('    ["%s"] = %s,\n' % (name, lua_long_string(src)))
    lines.append("}\n")
    return "".join(lines)


INSTALLER_SKELETON = """--[[- ==========================================================================
  dcnet 一键安装器 v{version}（由 tools/build.py 生成，请勿直接编辑）

  把这一个文件拷到任何一台电脑上，就能装好 dcnet：

      install.lua                      装全部（主控 + 节点 + 网络屏幕 + 拉取器 + 作业）
      install.lua master               只装主控
      install.lua worker               只装节点
      install.lua screen               只装网络屏幕
      install.lua jobs                 只装作业
      install.lua all --startup=master 顺便生成开机自启（跑主控）
      install.lua all --startup=worker 顺便生成开机自启（跑节点）
      install.lua all --startup=screen 顺便生成开机自启（跑网络屏幕）
      install.lua all --force          覆盖已存在的文件

  默认不覆盖已有文件，所以重复运行是安全的（作业改过也不会被冲掉）。
========================================================================== ]]

local FILES = {
{files}
}

local JOBS = {
{jobs}
}

local args = { ... }
local what, startup, force, cleanup = "all", nil, false, false
for _, a in ipairs(args) do
    local s = tostring(a)
    if s == "--force" then
        force = true
    elseif s == "--cleanup" then
        cleanup = true
    elseif s:sub(1, 10) == "--startup=" then
        startup = s:sub(11)
    elseif s == "-h" or s == "--help" or s == "?" then
        what = "help"
    elseif s:sub(1, 2) ~= "--" then
        what = s
    end
end

if what == "help" then
    print("用法：install.lua [all|master|worker|screen|jobs] " ..
        "[--startup=master|worker|screen] [--force] [--cleanup]")
    print("  --cleanup  装完把安装器自己删掉（CC 电脑只有 1MB 磁盘，这个文件不小）")
    return
end

local function ensureDir(path)
    if path and path ~= "" and not fs.exists(path) then fs.makeDir(path) end
end

local function put(path, data)
    ensureDir(path:match("^(.*)/[^/]*$"))
    if fs.exists(path) and not force then
        print(string.format("跳过（已存在）  %s", path))
        return false
    end
    local h = fs.open(path, "w")
    if not h then
        print("!! 无法写入 " .. path)
        return false
    end
    h.write(data)
    h.close()
    print(string.format("写入 %-30s %7d 字节", path, #data))
    return true
end

local want = {
    master    = (what == "all" or what == "master"),
    worker    = (what == "all" or what == "worker"),
    screen    = (what == "all" or what == "screen"),
    bootstrap = (what == "all" or what == "bootstrap"),
    jobs      = (what == "all" or what == "jobs"),
}
if not (want.master or want.worker or want.screen or want.bootstrap or want.jobs) then
    print("不认识的选项：" .. tostring(what) ..
        "（all / master / worker / screen / bootstrap / jobs）")
    return
end

local written = 0
for path, data in pairs(FILES) do
    local kind = path:find("master%.lua$") and "master"
        or path:find("worker%.lua$") and "worker"
        or path:find("screen%.lua$") and "screen"
        or path:find("bootstrap%.lua$") and "bootstrap" or "jobs"
    if want[kind] and put(path, data) then written = written + 1 end
end

if want.jobs then
    for name, data in pairs(JOBS) do
        if put("/dccomp/jobs/" .. name, data) then written = written + 1 end
    end
end

if startup == "master" or startup == "worker" or startup == "screen" then
    local target = "/dccomp/" .. startup .. ".lua"
    local body = string.format("-- dcnet 开机自启（install.lua 生成）\\nif fs.exists(%q) then shell.run(%q) end\\n",
        target, target)
    if put("/startup.lua", body) then written = written + 1 end
elseif startup then
    print("--startup 只接受 master、worker 或 screen")
end

ensureDir("/dccomp/jobs")
ensureDir("/dccomp")
print(string.format("完成：写入 %d 个文件。", written))
if want.master then
    print("主控：shell.run(\\"/dccomp/master.lua\\")")
end
if want.worker then
    print("节点：shell.run(\\"/dccomp/worker.lua\\")（不给参数会自动找主控）")
end
if want.screen then
    print("网络屏幕：显示器接上后 shell.run(\\"/dccomp/screen.lua\\")" ..
        "（主控 mon 里能看到它）")
end

-- 安装器自己也不小，装完就没用了：提示删掉（或下次直接 --cleanup）
local self = shell and shell.getRunningProgram and shell.getRunningProgram() or nil
if cleanup then
    if self and fs.exists(self) and fs.delete(self) then
        print("已删除安装器自身：" .. self)
    end
elseif self and fs.exists(self) then
    local size = fs.getSize(self) or 0
    print(string.format("提示：安装器自身 %s，装完可删：delete %s（或用 --cleanup）",
        tostring(math.floor(size / 1024)) .. "KB", self))
end
"""


def build_installer(master_src, worker_src, screen_src, boot_src, jobs):
    """生成 dist/install.lua：把三个产物 + 拉取器 + 全部作业塞进一个安装器。"""
    files = []
    for path, data in (
        ("/dccomp/master.lua", master_src),
        ("/dccomp/worker.lua", worker_src),
        ("/dccomp/screen.lua", screen_src),
        ("/dccomp/bootstrap.lua", boot_src),
    ):
        files.append('    ["%s"] = %s,\n' % (path, lua_long_string(data)))
    job_lines = []
    for name, src in jobs.items():
        job_lines.append('    ["%s"] = %s,\n' % (name, lua_long_string(src)))
    return INSTALLER_SKELETON.replace("{version}", VERSION) \
        .replace("{files}", "".join(files)) \
        .replace("{jobs}", "".join(job_lines))


def main():
    mods = load_modules()
    if not os.path.isdir(DIST):
        os.makedirs(DIST)

    master_entry = luautil.strip_comments(read(os.path.join(SRC, "master.lua")))
    worker_entry = luautil.strip_comments(read(os.path.join(SRC, "worker.lua")))
    screen_entry = luautil.strip_comments(read(os.path.join(SRC, "screen.lua")))
    entries = []
    for entry in (master_entry, worker_entry, screen_entry):
        if not entry.endswith("\n"):
            entry += "\n"
        entries.append(entry)
    master_entry, worker_entry, screen_entry = entries

    master_mods = closure(master_entry, mods)
    worker_mods = closure(worker_entry, mods)
    screen_mods = closure(screen_entry, mods)

    master_src = emit("主控 master", mods, master_mods, master_entry,
                      extra_globals=build_jobs_block())
    worker_src = emit("运算节点 worker", mods, worker_mods, worker_entry)
    screen_src = emit("网络屏幕 screen", mods, screen_mods, screen_entry)

    targets = [
        (os.path.join(DIST, "master.lua"), master_src, master_mods),
        (os.path.join(DIST, "worker.lua"), worker_src, worker_mods),
        (os.path.join(DIST, "screen.lua"), screen_src, screen_mods),
    ]
    for path, data, used in targets:
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(data)
        print("%-28s %7d 字节  %2d 行  模块: %s"
              % (os.path.relpath(path, ROOT), len(data.encode("utf-8")),
                 data.count("\n") + 1, ", ".join(used)))

    boot_src = luautil.strip_comments(read(os.path.join(SRC, "bootstrap.lua")))
    with open(os.path.join(DIST, "bootstrap.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(boot_src)
    print("%-28s %7d 字节  %2d 行"
          % (os.path.relpath(os.path.join(DIST, "bootstrap.lua"), ROOT),
             len(boot_src.encode("utf-8")), boot_src.count("\n") + 1))

    # 一键安装器：把三个产物 + 拉取器 + 全部作业打包成一个文件
    job_sources = {}
    for name in sorted(os.listdir(JOBS)):
        if name.endswith(".lua"):
            job_sources[name] = luautil.strip_comments(read(os.path.join(JOBS, name)))
    inst_src = build_installer(master_src, worker_src, screen_src, boot_src, job_sources)
    with open(os.path.join(DIST, "install.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(inst_src)
    print("%-28s %7d 字节  %2d 行  内含 %d 个作业"
          % (os.path.relpath(os.path.join(DIST, "install.lua"), ROOT),
             len(inst_src.encode("utf-8")), inst_src.count("\n") + 1, len(job_sources)))

    # 安全检查：产物里不应该留下未定义的 dc_require 目标
    for path, data, used in targets:
        for name in set(REQUIRE_RE.findall(data)):
            if name not in used:
                print("!! %s 引用了未打包的模块 %s" % (path, name), file=sys.stderr)
                return 1
    print("打包完成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
