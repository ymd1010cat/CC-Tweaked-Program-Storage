# ush - 面向 CC:Tweaked 的小型类 UNIX shell

ush 是一个 POSIX 风格的命令行 shell，运行在搭载 CC:Tweaked（ComputerCraft:
Tweaked）的 Minecraft 计算机上，也可以跑在 CraftOS-PC 里。它只用 Lua 5.1 编写，
不依赖任何外部库；把一个目录复制进计算机就算装好，首次启动之后它会用一个登录
界面、一个家目录和一套常规命令替换掉系统自带的 shell 提示符。

## 这是什么

* 一个真正的 shell：引号、管道、重定向、`&&` / `||` 串联、后台任务、history、
  alias、变量和 `$?` 状态；
* 多用户：passwd 与 group 文件、`su` / `sudo`、每个用户独立的主目录，以及首次
  启动时创建的 root 账户；
* 一个小系统：`/etc/rc.d` 里的服务、支持 `@reboot` 的 crontab、软盘挂载点，还
  有日志轮转（logrotate）；
* 联网能力：基于 rednet 的文件传输（`netopen` / `netsend` / `netrecv` / `rget`
  / `rput` / `rexec`），外加 `netd`、`pkgserver` 两个守护进程；
* 自带手册：每个 builtin 都有手册页，用 `man NAME` 或 `help NAME` 查看。

## 运行要求

| 项目 | 内容 |
| --- | --- |
| 运行时 | Lua 5.1（CC:Tweaked、CraftOS-PC，或 PC 侧的 lupa） |
| 目标版本 | CC:Tweaked 1.100+ 或 CraftOS-PC 2.x |
| PC 侧 | Python 3.8+ 与 `lupa`，只有测试运行器需要 |
| 语言 | 源码与配置一律 ASCII，代码里不放本地化字符串 |

本文档 `README.md` 是唯一的中文文档，它不会部署到实机，也不参与源码的 ASCII
门禁检查。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `startup.lua` | 启动入口，把控制权交给 ush |
| `firstboot.lua` | 首次启动向导：root 密码、用户、主机名、网络 |
| `usr/ush.lua` | shell 本体：解析器、builtin、行循环 |
| `usr/cmd/` | 外部程序（`rget`、`rput`、`rexec`） |
| `lib/` | 库：fs、mount、disk、services、cron、users、man 等 |
| `etc/` | 配置样例：network、packages、sudoers、rc.d |
| `tests/` | PC 侧断言套件与运行器 |
| `tools/` | `deploy.py`（差分部署）、`twopart.py` / `fontdisk.py`（两部分安装与字形介质）、`release.py`（发布构建） |

`usr/ush.lua` 在第一次 `require` 之前自己把 `/lib/?.lua` 与 `/usr/?.lua` 装进
`package.path`（幂等，已有则不重复添加），因此它既能被 `startup.lua` 拉起，也能在
CraftOS shell 里直接运行，或在 PC 侧用 `--exec` 启动，不会因为启动器没有预置搜索
路径而报 `module 'perm' not found`。

## 安装与部署

手动安装：把仓库内容复制进计算机目录（Windows 上的 CraftOS-PC 是每台计算机一个
文件夹，路径为 `%APPDATA%\CraftOS-PC\computer\<id>`），然后重启。`startup.lua`
会被自动加载，随后运行首次启动向导。

脚本化部署：`tools/deploy.py` 只复制内容哈希与目标端不同的文件，并把本次写入的
文件记录在目标目录旁的 `deploy-manifest.json` 里：

```
python tools/deploy.py --target "C:\path\to\computer\0"
```

| 选项 | 作用 |
| --- | --- |
| `--target DIR` | 目标计算机目录（必填） |
| `--source DIR` | 源目录，默认是仓库根目录 |
| `--part base\|modules` | 只部署两部分安装中的一半（见下） |
| `--dry-run` | 只打印将要发生的改动，不写任何文件 |
| `--json` | 改为在 stdout 输出机器可读的报告 |
| `--quiet` | 只打印最后的汇总行 |
| `--prune` | 删除本工具早先复制过去、但项目里已经没有的文件（只处理清单里的条目） |

**两部分安装（`--part`）**：CraftOS 电脑的文件系统受 `computer_space_limit` 限制（缺省
1,000,000），而整棵树约 1.40 MB，**装不下**。所以一台 1MB 的电脑这样装：shell 装在电脑上，
它自己的模块装在一块标了 `.pkgsys` 的介质上（见"两种存储器"一节）。

| `--part` | 内容 | 大小（实测） |
| --- | --- | --- |
| `base` | 启动入口 + `lib/` 的**加载期闭包** + `usr/` + `etc/` + 根文件 | **781,380 B（78.1%，装得下）** |
| `modules` | 惰性加载的 `lib/` 模块 + `rpv/` | 614,005 B |
| `all`（缺省） | 整棵树，给空间足够的机器 | 1,395,636 B（约 1.40 MB） |

两半可证不相交，并集正好是整棵树。判定一个模块归哪一半看**加载期闭包**：启动时会被加载期代码
触达的（含 `startup.lua` 的 `pcall(require, ...)`，以及开机时运行的 `firstboot.lua`）留在 `base`，
只在函数被调用时才 require 的可以上介质。

**只装 `base`、完全没有介质**的机器也**能启动到提示符、并完成首启设置**（真机实测：全新机器走完
设置向导、自己写下 setup 标记、进到 `alice@cc-<id>:/$`，全程没有一条 `module '...' not found`）。
因此 `lib/sessionlog.lua`、`lib/policy.lua`、`lib/time.lua` 必须在 `base` 半，gate 5 把三条都钉住：
登录记账模块缺失会让 shell 在**进提示符之前**就崩，首启向导缺了 policy/time 则永远写不出标记。
`lib/boot.lua` 同样钉在 `base`：它只被 `pcall(require, "boot")` 取用，缺失时机器照常跑，只是
`@reboot` 的 crontab 条目永不触发、rc.d 单元在第一次启动后永不再跑（回落分支把它们藏住了）。

```
python tools/deploy.py --target <电脑目录> --part base --with-etc
python tools/deploy.py --target <介质目录> --part modules
```

第 2 部分放到介质上时，每个模块按 `<介质>/usr/pkgs/<包名>/lib/<模块>.lua` 布局（`pkg` 的包布局），
介质根上放一个 `.pkgsys` 标志文件即可。**挂载本身就会把这些 `lib/` 目录接进 `package.path`**
（`mounts.refresh_module_paths()`），所以不需要任何手工配置。
| `--with-etc` | 额外复制 `etc/`（配置样例；实机通常有自己的 /etc，所以默认关闭） |
| `--clean-firstboot` | 删除目标端的首次启动标记，效果等同 shell 里的 resetfirstboot |

开发文件（`tests/`、`tools/`）、清单文件本身，以及本文档 `README.md` 都不会被复制
到实机，命令行里也没有让它们上机的开关。拿不准时先跑 `--dry-run --json`：报告里会
列出 `added`、`updated`、`unchanged`、`pruned`、`markers_removed` 和
`markers_absent`。

## 发布构建

发布资产（五个 zip + 安装说明 + 校验和）由一个受版本管理的脚本从零构建：

```
python unixshell/tools/release.py --out dist/release
```

`--out` 缺省就是仓库根下的 `dist/release`（`dist/` 被 gitignore，产物不入库）。脚本
只用 Python 标准库，先在 `--out` 下的临时目录里跑 `tools/twopart.py` 与
`tools/fontdisk.py`，再打包桌面包和包服务器；整个产物集齐之后才替换上一次的文件，
中途失败不会留下半套产物。

| 文件 | 内容 |
| --- | --- |
| `unixshell-part1-computer.zip` | 电脑本机那一半，解压后是 zip 根 |
| `unixshell-part2-system-modules.zip` | 带 `.pkgsys` 的系统模块介质 |
| `unixshell-fonts-size12-two-disks.zip` | `part1/` + `part2/` 两块 CJK 字形介质 |
| `unixshell-gnome-<version>.zip` | 桌面包 `gnome/`（含 `bin/`、`lib/`、`manifest`） |
| `unixshell-pkgserver.zip` | `pkgserver.lua`、`netd.lua` + 静态 `require()` 闭包 + `rpv/` + `repo/gnome/` |
| `unixshell-INSTALL.txt` | 部署说明：每个包是什么、复制到哪、许可证 |
| `SHA256SUMS.txt` | 五个 zip 的 sha256（`sha256sum -c` 可校验） |

每个 zip 根上都有仓库的 `LICENSE`；font 的每个 `partN/`、`gnome/` 以及
`repo/gnome/` 里都有 `THIRD_PARTY_LICENSES`。包服务器写完之后会重新读成品 zip，断言
其中每个静态 `require()` 都能解析到包内文件，否则构建失败。

## 常用命令

`help` 打印总览，`man NAME` 打印某个命令的手册页，`man -l` 列出全部手册页，
`man -k WORD` 在简短描述里搜索。

| 分组 | 命令 |
| --- | --- |
| 文件 | `ls` `cd` `pwd` `cat` `cp` `mv` `rm` `mkdir` `rmdir` `ln` `touch` `stat` `file` `find` `du` `dirname` `basename` `realpath` `mktemp` `tar` |
| 文本 | `echo` `grep` `egrep` `fgrep` `head` `tail` `sort` `uniq` `wc` `cut` `tr` `sed` `awk` `rev` `tac` `tee` `xargs` `yes` `expr` |
| 摘要与编码 | `sha256sum` `md5sum` `cksum` `base64` |
| shell 内建 | `alias` `unalias` `source` `export` `unset` `env` `printenv` `set` `shift` `return` `break` `continue` `exit` `history` `jobs` `bg` `fg` `disown` `kill` `sleep` `test` `true` `false` |
| 系统 | `uname` `hostname` `uptime` `free` `ps` `top` `date` `clear` `reset` `tput` `tty` `nproc` `id` `groups` `users` `whoami` `which` `audit` `reboot` `bios` `help` `man` |
| 存储 | `mount` `umount` `df` `disk` |
| 服务 | `service` `crontab` `cronlog` `logrotate` |
| 网络 | `netopen` `netclose` `netsend` `netrecv` `netstat` `ping` `path` |
| 账号 | `su` `sudo` `passwd` `useradd` `userdel` `usermod` `groupadd` `groupdel` `gpasswd` |
| 软件包 | `apt` `pkg` |

外部程序放在 `usr/cmd` 下，通过 `PATH` 查找；守护进程 `netd.lua`、`pkgserver.lua`
位于仓库根目录。

**两条命令是刻意不做的，理由写在 `COMMANDS.md` 里**（该文件同时给出与最小 Linux
用户态命令集的对比和覆盖率）：`readlink`（CraftOS 没有符号链接，永远无事可做）与
`timeout`（调度器是协作式的，从不调用 `pullEvent` 的命令无法被抢占——与 Ctrl+C 同一个
局限，见 `lib/interrupt.lua`）。造一个假的比没有更糟。

### 需要外部磁盘的可选包

有些包的数据太大，装不进电脑自己的文件系统（典型例子是中文点阵字库：GB2312 全量在
字号 12 下实测 1,375,263 B（约 1.4 MB），而标准电脑只有约 1 MB；字形由 Noto Sans SC
栅格化，该字体使用 SIL Open Font License 1.1，许可证正文与署名见仓库根目录的
`THIRD_PARTY_LICENSES`），所以它们把数据放在**外部磁盘**上，
只在清单里声明"装我之前必须先插入带标志文件的磁盘"：

| 清单键 | 含义 |
| --- | --- |
| `requires_disk=<标志文件>` | 已挂载的可移动介质根目录里必须有这个文件 |
| `requires_file=<路径>` | 这个文件必须存在（给介质上的字库索引等用） |
| `requires_feature=<名字>` | 本构建要提供这个能力（`disk` / `xfer` / `rexec` / `pkg` / `crypto`） |

`pkg install` 会在**下载任何字节之前**检查这些条件，缺盘时直接报"插入那块磁盘"
（并提示 `disk scan`），而不是先拉一个用不了的包；`pkg requires NAME` 只查询不安装。
磁盘由 `lib/disk.lua` 自动挂载（`/etc/disk.conf`、`.label` 约定），挂载表由
`lib/mounts.lua` 维护，所以换盘符不影响判断。

一台机器有多个驱动器时，用**磁盘号**把介质变成"软件包存储器"；可以有**多个**：

```
pkg store          # 列出当前是存储器的介质、实际安装根目录、每块盘上的包与容量
pkg store --json   # 同样的盘点结果，输出 JSON 供脚本读取
pkg list -s        # 按"在哪块介质上"分组列出已安装的包
pkg store 2        # 把 2 号盘变成普通软件包存储器（在盘上写入标志文件 .pkgstore）
pkg store 2 3      # 两块盘都是
pkg store sys 2    # 把 2 号盘变成"系统模块存储器"（标志文件 .pkgsys）
pkg store sys      # 查看哪块盘装着系统模块
pkg store remove 2 # 从 2 号盘取掉标志（盘上的包不动，两种标志都取）
pkg store auto     # 取掉所有标志，回到装在本机文件系统
pkg store required # 强制：软件包必须装在可移动存储器上
pkg store optional # 取消强制
pkg store sys-required # 强制：本机需要它的系统模块存储器
pkg store sys-optional # 取消该强制
pkg install --store 2 NAME   # 只这一次把 2 号盘当存储器，装完取掉标志
```

**两种存储器，因为有两件事要分。** 一台"分两部分装"的机器（shell 在自己盘上、自己的模块
在介质上）必须把那些模块与普通的额外包区分开，因为一个是安装的组成部分、另一个不是：

| 标志文件 | 是什么 | 丢了会怎样 |
| --- | --- | --- |
| `.pkgsys` | **系统模块存储器**：shell 自己要用的模块（手册页、文件传输、服务等） | 丢功能；机器可以要求它（`sys_required=1`）并在缺失时被告知 |
| `.pkgstore` | 普通**可移动软件包存储器**：额外的包 | 只是少了那些包 |

规则：

- **判断一块盘是不是存储器，看盘上有没有标志文件**——机器**不记录盘号**。盘号属于驱动器插槽、不属于数据，所以盘换插槽、或重启后再插入，仍然凭它自己带的内容被认出来，不会把数据写到此刻恰好插在原插槽里的另一块盘上；如果存储器没插，安装会被拒绝而不是写到别处。
- **一块盘不能同时是两种**：把它认作系统模块存储器会替换掉普通标志；`pkg store remove` 两种标志都取。
- **读取顺序：系统模块存储器排在最前**，所以两块盘带同名模块时，shell 依赖的那个胜出。
- **写入**落在"挂载表里第一个**普通**存储器"上（`<盘>/usr/pkgs`）——系统模块存储器装的是安装自带的模块，新包不会混进去。
- **读取**遍历所有存储器，所以装在任意一块盘上的包都能被找到；**没被指定为存储器的盘不参与搜索**（即使它上面有包）。
- **需求检查**（`requires_disk` / `requires_file`）由**任意一块存储器**满足。
- `store required` 之后，会落到本机文件系统的安装会被拒绝，且不会悄悄回退。
- `sys required` 之后，缺系统模块存储器会**警告**而不是拒绝——它不是"包该放哪"的规则，而是"这台机器不完整"的陈述，所以由 `pkg store`、安装过程与 `pkg.completeness_warning()` 报告，而不阻塞还能做的工作。
- 这两条规则都写在 `/etc/pkgstore.conf`（样例见 `etc/pkgstore.conf`）——那是必须记在机器上的规则，因为它们约束的是机器本身，而不是某块介质。
- `pkg store <N>...` / `remove` / `required` / `optional` / `sys` / `sys-required` / `sys-optional` 需要 root（与安装一致），只读的 `pkg store` 与 `pkg requires` 不需要。

## 开机、运行中与退出时的机器行为

这几项决定**不由 shell 做主**时电脑怎么表现。

### `craftos`（新的 multishell 标签）

```
craftos         # 在 Advanced Computer 上打开一个 CraftOS shell 标签
```

在 multishell 里运行的 ush（dcnet 启动布局就是如此）执行 `craftos` 会
`shell.openTab("/rom/programs/shell.lua")`：**新标签**是 ROM 的 CraftOS shell，
ush 和它的后台作业继续运行，boot guard / noexit 仍然有效。该命令**仅 root 可用**，
拒绝会记审计日志。没有 multishell 的机器会报错，而不是像旧版 `craftos` 那样把整个会话交给 CraftOS。

部署时如果不需要这个命令，用 `python tools/deploy.py --without-craftos ...` 部署：
`usr/cmd/craftos.lua` 不会被复制到机器上，命令直接不存在。

### `reboot`

```
reboot          # 确认后重启电脑
reboot -f       # 不确认
reboot bios     # 直接重启进 BIOS 设置界面
```

**重启是诚实的操作**：机器重新经过 `startup.lua` 起来，前面照样有 BIOS 窗口 —— 和断电重启一样，
而且**回到本项目的控制之下**。

- `reboot bios` 写一个**一次性标记**，`startup.lua` 读掉它并**直接进设置界面**，不用去抢那三秒
  DEL 窗口。标记读一次即删，所以无人值守的机器不会在无关重启后停在设置界面。
- 标记带**机器 ID**，数据目录拷到别的机器不会让那台机器打开设置界面。
- 仅 root 可用，记审计日志。
- `set -o noexit` 同样**拒绝** reboot（重启也是结束会话），`-f` 可越过。
- `reboot shutdown` 被拒绝而不是猜测 —— 关机是另一件事。

### BIOS 设置界面（开机前三秒按 DEL）

`startup.lua` 在启动 shell 前显示三秒 "Press DEL to enter SETUP"，按 **DEL**（或 BACKSPACE）
进入设置界面；错过窗口就照常启动。同一个界面在 shell 里用 `bios` 命令也能打开。

可改的设置：

| 设置 | 作用 |
| --- | --- |
| BIOS 密码 | 设置/清除 BIOS 密码（留空即清除）。**与登录密码分开**，存在 `/etc/bios.conf` |
| 开机前询问密码 | 打开后，不给密码就**根本不启动 shell**（缺省关闭） |
| 保护启动文件 | 同 `set -o bootguard` |
| 允许退出 shell | 同 `set -o noexit` 的反面 |

**BIOS 密码为什么与登录密码分开**：它必须在 shell 启动**之前**就能校验，所以不能依赖 shell 读的
用户数据库——而设置界面恰恰要在机器出问题时可用，那时用户库可能正是坏掉的那部分。

### `set -o noexit`：缺省不允许退出 shell

`exit` / `logout` 在**会话**里被拒绝（`ush -c 'exit 3'` 和脚本里的 `exit 3` **不受影响**——那是
脚本返回状态的方式，看门狗也靠它触发计划任务）。要允许退出：`set +o noexit`（需 root）。

### Ctrl+C 终止当前程序，不退出系统

按 Linux 语义：命令运行中按 Ctrl+C **中断该命令**（状态 130），回到提示符，系统不退出；在提示符上
按 Ctrl+C 仍是丢弃当前半行输入。

CraftOS 是单线程协作式的、没有信号，所以做法是在**协作式程序交还控制权的唯一位置**
（`os.pullEvent`/`os.pullEventRaw`）插一层：有命令在前台时，Ctrl+C 抛出与 ROM 为 Ctrl+T 抛出的
同一个 `"Terminated"` 错误，于是既有的 INT trap 与 130 状态直接复用。

⚠️ **它做不到什么**：一个从不调用 `pullEvent` 的紧凑 CPU 循环**无法被中断**。这是协作式调度器的
性质——解释器就在那个循环里，别的东西跑不了。Linux 能中断是因为内核抢占它，CraftOS 没有内核。

### `set -o bootguard`：启动文件缺省受保护

拒绝写入 `/startup.lua`、`/firstboot.lua`、`/usr/ush.lua` 及 `/lib/` 下任何文件。名单是显式列举
而不是"整个 `/lib`"——包升级是正当操作且装在 `/usr/pkgs`。被拒绝的写入会**失败**（状态 1），
不会报告成功。

要允许覆盖：`set +o bootguard`（需 root）。注意 root **不豁免**——正是要防手滑的 root 命令把机器
刷坏；真要改就用 `set +o`。

### 崩溃兜住

`startup.lua` 用 `xpcall` 跑 shell，崩溃时写入 `/var/log/watchdog.log` 并**附上 traceback**
（指出哪个模块哪一行），而不只是错误消息。

### 启动顺序：ROM 的"从磁盘启动"已关闭

这是**最重要的一条**，因为它是 `bootguard` **挡不住**的。CraftOS 开机时读 `/.settings`，而
`rom/startup.lua` 在跑我们的任何代码**之前**就查两个键：

| ROM 设置 | ROM 缺省 | 本机 | 作用 |
| --- | --- | --- | --- |
| `shell.allow_disk_startup` | **true** | **false** | 驱动器里有带 `startup` 的盘时运行它 |
| `shell.allow_startup` | true | true | 运行本机根目录的 startup |

**危险在哪**：ROM 的代码是 `tUserStartups = startups` —— 磁盘上的 startup **替换**本机的
startup，而不是并行运行。结果是 **shell 根本不启动，本仓库的任何代码都不运行**。所以
`lib/protect.lua`（它住在 `startup.lua` 里面）**根本不在执行路径上**，挡不住这件事。

**防线**：写 ROM 自己读的那个开关，并且**在每次开机时重新施加**：

- `/.settings` **随安装一起部署**，所以**第一次开机**就是安全的
- `bios.enforce_rom_settings()` 每次开机重新施加 → 删掉文件或手改文件都不会把机器留在敞开状态
- BIOS 界面暴露这两个键

⚠️ **文件格式不可商量**：`textutils.unserialize` 会**前置** `"return "`，所以 `/.settings` 必须是
**裸表字面量**。以 `return` 开头、或带注释的文件会解析成 `nil`，每个键静默保持 ROM 缺省值 ——
**一个"看起来对、其实没作用"的文件是最糟的结果，因为机器看起来受保护**。这一点只有在模拟器上
实跑才发现（我第一版就写错了）。测试现在把形状钉住。

### 全部 CraftOS 设置（等价于 shell 里的 `set` 命令）

BIOS 界面的 **"All CraftOS settings"** 一项列出并修改 **ROM 知道的所有设置** —— 就是 shell 里
`set` 命令编辑的那些，走同一个 `settings` API。放在这里是因为：**shell 起不来的时候，正是有人需要
读或改这些设置的时候**。

界面用 `*` 标出**由本机强制执行**的键（记录在 `/etc/bios.conf`，每次开机重新施加，改了会保留）。
**其他设置属于 ROM** —— 本项目既不强制也不记录，`set` 命令才是它们的编辑器。

- 输入空值 = unset，回到 ROM 声明的缺省值（按 `R` 同理）
- 值按声明类型强制转换（`boolean` / `string` / `number`），与 ROM 的 `set` 命令一致
- 非法值被拒绝并说明原因，而不是存进去

实测（真 ROM）：列出 **20 项**，类型/缺省值读取正确，改动生效，非法值被拒，reset 恢复缺省。

### 两个新配置文件

- `etc/boot.conf` —— `boot_guard` 与 `no_exit` 两条机器规则（缺省都是开；只在关闭时写入）
- `etc/bios.conf` —— BIOS 密码哈希与 `ask_password`
- `.settings`（仓库根）—— ROM 自己的启动开关，**格式必须是裸表字面量**

两者都在**机器**上而不是介质上，因为它们约束的是这台电脑；介质可以被换成没带规则的。

## 测试与门禁

PC 侧套件用桩文件系统模拟 CraftOS 环境，因此只要装了 Python 和 lupa，在任何地方
都能跑：

```
python tests/run_all.py
```

| 门禁 | 校验内容 |
| --- | --- |
| gate 1 syntax | 项目的每个 `.lua` 文件都能在已安装的每个 lupa 运行时下编译通过 |
| gate 2 ascii | 会被真正部署到电脑上的文本文件里没有非 ASCII 行。判定"会不会被部署"直接问 `tools/deploy.py`（它是唯一决定机器收到什么的程序），所以 `README.md`、`ROADMAP.zh.md` 以及所有 `.py` / `.json` / `.log` 都在规则之外 |
| gate 3 docs | `README.md` 存在于本树时，写出要求的那些说明（它是 PC 侧文档，机器副本里本来就不带它） |
| gate 4 manual | `usr/ush.lua` 的每个 builtin 都在 `lib/man.lua` 里有手册页 |
| gate 5 deploy | `tools/deploy.py` 的新增 / 空跑 / 恢复 / 清理行为，以及 `--part base\|modules` 两半**互不相交、并集正好是整棵树** |
| gate 6 config | 文档里承诺的配置键（`etc/network.conf`、`etc/pkgstore.conf` 等）确实被对应模块读取——桩文件系统看不到项目源码，这条只能在宿主侧查 |
| gate 7 roadmap | `ROADMAP.md` 与中文版 `ROADMAP.zh.md` 保持同步：标题数量、顺序、层级、小节编号必须一致，且每个英文标题里的词都要出现在对应的中文标题里 |
| gate 8 report | `tools/rpv-verify/log_summary.py`（验收报告）的自测：重复行要带次数与每一次出现的时间戳、判定行无论模式如何都要打印、大小写两种词汇都要匹配、日志缺失/为空/无匹配要分别说明。报告是硬件运行唯一被人看到的东西，一个"悄悄什么都没匹配到"的报告比它取代的 tail 更糟 |
| gate 9 font tools | `tools/fontgen.py` 与 `tools/fontdisk.py` 的自测。这两个程序没有 Lua 部分，产物就是数据，所以它们的 bug 会得到一个"看起来已完成"的介质和一块什么都没有的屏幕——已经有过两个**静默**的真 bug：码点解析器把自己写法里的 `-` 当作分隔符去切 `U+4E2D` 从而画出了字母 D，而占位方框规则被写成"非图形类别"的清单从而把每个**未分配**码点都变成了方框，两者都没有让任何工具报错。检查的是"错误答案的形状"：码点的每种写法都必须指向同一个码点；默认字符集的规模与开头（CJK 文档需要的标点先于第 3000 个表意字）；未分配/控制码点**不**绘制；生成文件是 ASCII（ROM 的 `loadstring` 要能读）；介质上写的标记名就是 `lib/cc_fonts.lua` 读的那个，且 store 标记**绝不能**是系统标记；以及 `tools/deploy.py` 拒绝把 `fontdata/` 放到机器上 |

套件：`batch_check.lua`、`class3_check.lua`、`batch3_check.lua`、`batch4_check.lua`、
`batch5_check.lua`、`batch6_check.lua`、`batch7_check.lua`、`batch8_check.lua`、
`batch9_check.lua`，每个都在独立的全新 Lua 状态里、基于 `tests/cc_env_stub.lua` 运行
（batch3 与 batch8 另外加载 `tests/net_harness.lua`）。常用参数：`--list`、`--suite NAME`、
`--gates`、`--no-deploy`、`--verbose`。

`batch8_check.lua` 专测**丢包**下的数据通道：测试台能按虚拟时钟把某个数据报"扣在线上"
再放行，于是接收端会看到空洞、发送端会等不到确认，`lib/xfer.lua` 的 `missing` 列表、
重传计数与超时预算这些分支才真正被跑到（模拟机上不丢包时它们永远不会执行）。

运行器打印的一切都是 PC 侧模拟结果，不是 CraftOS-PC 的结果：磁盘事件、rednet 时序
和启动流程最终仍以实机为准。

## 内置的 rpv 网络栈

`rpv/` 目录内置了 RPV1 网络栈（来自 rpv1 项目：19 个模块 + `node.lua` + 加载器），
`lib/rpvnet.lua` 是传输层：它保持 rednet 的调用形状（`open` / `close` / `isOpen` /
`send` / `broadcast` / `receive`），但可以改用 rpv 承载流量 —— 于是
`netsend` / `netrecv` / `rget` / `rput` / `rexec` / `apt` 这些命令**不需要改动**就获得
IPv4 风格寻址、路由、DHCP-lite、名字服务、组播域与 AEAD 控制面。

`/etc/network.conf` 里的开关：

| 键 | 作用 |
| --- | --- |
| `transport=auto` | 内置栈能加载且 modem 侧有 modem 时走 rpv，否则 rednet（默认） |
| `transport=rpv` | 强制 rpv；起不来就报错，而不是悄悄回退 |
| `transport=rednet` | 一直用 rednet |
| `rpv_side` / `rpv_channel` / `rpv_mtu` | rpv 接口的 modem 侧、二层频道、MTU（默认 `back` / `4700` / `512`） |
| `rpv_cidr` | 接口地址，默认按电脑 ID 生成 `10.0.4.<id>/24`，一队机器不用逐台配置 |
| `rpv_peer_<id>=<地址>` | 可选的静态 id→地址映射，省掉发现广播 |
| `rpv_reasm_bytes` / `rpv_reasm_entries` | rpv 节点的重组预算（默认 524288 / 128）：分块传输时一个数据报会被切成十几个 IP 分片，栈自带的 16 项 / 64 KB 撑不住一次突发 |

传输与文件协议都已在实机/模拟机上验收：两台 CraftOS-PC 电脑
（`tools/rpv-verify/_ush-rpv-verify3.ps1`）跑通静态映射与发现两条路径，200 KB 文件用
默认 4096 字节分块（49 块、每块约 6 KB = 13 个 IP 分片）`rget` 拉取 + `rput` 推回、
两端 CRC32 一致（`tools/rpv-verify/_ush-rpv-file.ps1`，`verdict=PASS`）。

注意：**rpv 与 rednet 是两套线上协议，不能互通** —— 一次会话的两端必须用同一种传输；
`auto` 下老机器会自然回退到 rednet（PC 侧套件也因此仍跑在 rednet 路径上）。
细节、报文封装与验收命令见 [rpv/MERGE-rpv.md](rpv/MERGE-rpv.md)。

## 内置 dcnet 分布式计算网络（可选包）

`tools/pkgs/dcnet/` 是 dcnet 的 ush 包（由仓库顶层的 `dcnet/` 项目生成：

    python tools/build_dcnet_pkg.py

）。包安装到 `<存储>/usr/pkgs/dcnet` 后，`dcnet` 命令通过包清单进入 `PATH`。把
`tools/pkgs/dcnet/` 放进 `pkgserver` 的 `/repo/dcnet/` 后用 `pkg install dcnet` 安装；也可以
直接把整个目录复制到存储器的 `/usr/pkgs/dcnet/`。

| 命令 | 作用 |
| --- | --- |
| `dcnet master` | 主控控制台（交互界面） |
| `dcnet master --headless` | 无终端主控，日志写 `<root>/logs/master.log` |
| `dcnet worker [ID] [NAME]` | 运算节点控制台 |
| `dcnet worker --headless` | 无终端节点，日志写 `<root>/logs/node-<id>.log` |
| `dcnet status` | 数据根目录、作业数与最近历史 |
| `dcnet jobs` / `dcnet net` / `dcnet config` | 作业、传输、配置 |

配置文件是 `/etc/dcnet.conf`（样例在包的 `etc/dcnet.conf.example`）：`root=` 指定可写数据目录
（root 缺省 `/var/lib/dcnet`，普通用户缺省 `$HOME/.dcnet`），`transport=rednet|rpv|auto`
选择 rednet 或 unixshell 的 RPV1 传输，`key=` 是集群共享的 HMAC 密钥。dcnet 模块从包的
`lib/dcnet/` 直接加载，不依赖 `package.path` 的安装位置；`lib/` 里的模块由构建脚本从
`dcnet/src/lib/` 复制。

**启动入口**：`startup.lua` 在拉起 ush 之前读 `/etc/dcnet.conf`。`boot=master` 或
`boot=worker` 时：

- **Advanced Computer（默认 `multishell=1`）**：startup 把 `/usr/dcnet-tabs.lua` 作为键入
  输入交给 `multishell`，**tab 1 跑 dcnet 角色、tab 2 跑 ush**，焦点在 dcnet。dcnet 先
  加载；ush 只是命令控制台。`multishell=0` 或非 Advanced 机器退回头台作业
  `dcnet ROLE --headless`。
- `forward=1` 时 ush 只把命令行写进 master 的控制队列（`<root>/ctl/*.cmd`），由常驻
  主控执行；`dcnet log` 读它的日志，`dcnet` 前缀的命令（`dcnet log/status/config`）仍在
  本地执行。这样“系统外壳”只是命令通道，逻辑和调度都在 dcnet 里。

`dcnet cmd <命令行>` 也把一行命令放进同一个队列；`dcnet log [N]` 显示最近 N 行主控日志。

**计算端镜像**：`python tools/build_worker.py` 生成 `dist/worker-image/`（15 个文件，
约 123 KB），只包含：

    startup.lua         循环运行 dcnet worker --headless
    usr/pkgs/dcnet/     worker 需要的 9 个模块 + 命令入口 + manifest

它**没有** `usr/ush.lua`、firstboot、BIOS 菜单、man/usr/cmd、`fontdata/`、
`lib/cc_chinese.lua` / `cc_font*` 或桌面包——计算端没有中文字体支持和交互界面。
主控端仍使用完整的 unixshell 安装（multishell tab 1 = dcnet，tab 2 = ush）。

在已经进入会话的机器上，带 `--headless` 的命令仍可用 ush 后台作业跑：

    dcnet worker --headless &
    jobs

验收：`python tools/dcnet_pkg_verify.py` 会在真 CraftOS-PC 上部署 ush、把包放到
`/usr/pkgs/dcnet`，再跑 `dcnet version` 与 `dcnet config`（结果应为 `RESULT dcnet-pkg PASS`）。

## 项目约定

* 只用 Lua 5.1，不用 `goto`、不用 5.2+ 的库、不用 lua 5.5 的特性。
* 源码、配置和注释一律 ASCII；`README.md` 是唯一的中文文档，而且不会部署到实机。
* `lib/` 放可复用逻辑，`usr/cmd/` 与 builtin 只做薄封装。
* 保持套件全绿：弄坏套件的改动必须先修好再提交。
