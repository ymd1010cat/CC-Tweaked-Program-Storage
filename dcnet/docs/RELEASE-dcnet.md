## dcnet

面向 CC:Tweaked 的分布式计算网络：一台主控把作业拆成任务，节点拉取并计算，主控汇总、
缓存、超时重派；纯 Lua，无第三方依赖。支持两级 reduce、云端卸载、文件通道、HMAC 签名，
并可作为 unixshell 的包在 multishell 里运行（dcnet 一个 tab、ush 一个 tab）。

本 tag 指向 `main` 的 `{{COMMIT}}`，资产由 `python tools/release_dcnet.py` 生成。

## 这一版的重点

- **版本 1.3.1**：屏幕关闭/踢屏持久化（`mon off`、`mon net off`、`mon net kick` 重启后仍生效，
  `mon net unblock` 解除）；界面英文化 + `lang en|zh` 切换（中文复用 unixshell 的 CJK
  位图渲染）；网络屏幕。协议版本仍为 1，只加了新消息类型，旧节点/旧主控可以继续
  混跑（未知类型按协议约定忽略）。
- **界面英文（默认）/中文**：游戏内控制台、日志与内置作业输出默认英文（ASCII），
  原版 CC 字体不再乱码；主控上 `lang zh` 可切回中文，控制台复用 unixshell 的 CJK
  位图渲染模块（需要 unixshell 字体盘 + 自建的 `ush-cjk-font` 资源包；缺字体介质时
  文字保持英文）。`lang en` 切回英文；monitor 面板固定英文。
- **独立运行**：`dist/master.lua` + `dist/worker.lua` 两个文件即可组网，保持原来的
  rednet 有线网络用法；节点源码随任务下发，无需预装作业。
- **unixshell 包**：`tools/pkgs/dcnet/` 提供 `dcnet` 命令（master / worker / screen /
  status / cmd / log / jobs / net / config），配置在 `/etc/dcnet.conf`；支持 rednet 或
  unixshell 的 RPV1 传输。
- **multishell 启动**：`boot=master|worker` 时，Advanced Computer 用 multishell
  开两个 tab：tab 1 dcnet 角色，tab 2 ush；dcnet 先加载。`forward=1` 让 ush 只做命令
  通道（命令行写入 `<root>/ctl`，由常驻主控执行，`dcnet log` 查看）。
- **计算端精简镜像**：worker 镜像只含 `startup.lua` + dcnet worker 所需模块，循环运行
  `dcnet worker --headless`；没有 ush、firstboot、BIOS、man、中文字体数据和交互界面，
  约 125 KB。
- **网络屏幕**：把显示器贴在另一台电脑上也能当主控大屏——那台电脑运行
  `screen.lua`（或 unixshell 下的 `dcnet screen`）即可：屏幕自动广播登记，主控按屏幕
  尺寸推送面板帧，`mon net` 查看/开关。有线网络上暴露成外设的远端显示器
  （`monitor_0`）也可以直接用 `mon` 挂载。
- **可访问 CraftOS**：完整 ush 中的 `craftos` 命令在 multishell 里打开一个 ROM
  CraftOS shell 标签，不丢掉 ush 和机器规则。

## 资产

| 文件 | 是什么 | 放哪 |
|---|---|---|
| `dcnet-1.3.1.zip` | 独立项目：`dcnet/` 源码、`dist/` 单文件、文档、作业、CraftOS-PC 回归套件与 Python 云端参考服务端 | 解压得到 `dcnet/`；部署用其中的 `dist/master.lua`、`dist/worker.lua`、可选的 `dist/screen.lua` |
| `dcnet-ush-package-1.3.1.zip` | unixshell 包：`manifest`、`bin/dcnet.lua`、`lib/dcnet/` 模块、作业、worker 种子与配置样例 | 解压内容到包存储器的 `usr/pkgs/dcnet/`（或放进 `pkgserver` 的仓库） |
| `dcnet-worker-1.3.1.zip` | 计算端镜像：`startup.lua` + worker 所需的 dcnet 模块；无 ush/字体/UI | 解压内容到计算节点电脑文件系统根，开机直接跑 worker |
| `dcnet-INSTALL.txt` | 三种安装形态的说明 | - |
| `SHA256SUMS.txt` | 三个 zip 的 SHA-256 | - |

每个 zip 根附带仓库 `LICENSE`（MIT）。

## 安装

**A. 独立运行（不用 unixshell）**

把 `dist/master.lua` 放到主控电脑，`dist/worker.lua` 放到每台节点；两台/多台电脑接同一段
有线网络（有线调制解调器 + 网络线缆），分别运行两个文件即可。节点不需要预装作业。
想把显示器放在另一台电脑上，就把 `dist/screen.lua` 放到那台电脑并运行（可选）。

**B. unixshell 包（主控/带壳机器）**

把 `dcnet-ush-package-1.3.1.zip` 解压到 `<存储>/usr/pkgs/dcnet/`，或在包服务器仓库里
`pkg install dcnet`。然后 `/etc/dcnet.conf`：

```ini
root=/var/lib/dcnet
boot=master
multishell=1
forward=1
#transport=rednet
#key=...
```

重启后：tab 1 = dcnet master，tab 2 = ush；ush 里输入的命令通过控制队列交给主控。

**C. 计算端镜像**

把 `dcnet-worker-1.3.1.zip` 解压到节点电脑根目录（`startup.lua` 落在 `/`），开机直接
运行 `dcnet worker --headless`。它不会启动 ush，也没有中文字体/交互界面。

## 许可

仓库代码与文档：MIT License（见仓库根 `LICENSE`）。dcnet 不包含第三方运行时代码；
CraftOS-PC 只用于测试，不随资产分发。

## 校验

`SHA256SUMS.txt` 给出三个 zip 的 SHA-256；下载后先校验再解压。

## 重建

```bash
cd unixshell
python tools/build_dcnet_pkg.py
python tools/build_worker.py
python tools/release_dcnet.py
```

产物在 `unixshell/dist/release-dcnet/`，布局与本 release 一致。
