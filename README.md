# CC-Tweaked-Program-Storage

此仓库储存适用于 CC:Tweaked 环境的 Lua 程序。**一个项目一个目录**，仓库根目录只放
仓库自身的东西（本文件、`LICENSE`），程序本体不直接放在根目录。

## 项目

| 目录 | 说明 |
|---|---|
| [`unixshell/`](unixshell/) | 面向 CC:Tweaked 的小型类 UNIX shell：命令与管道、可移动介质上的包管理、网络文件传输、中文字形分片，以及可选的类 GNOME 桌面（`gnome` 包）。该目录自带 `README.md` 与 `ROADMAP.md` / `ROADMAP.zh.md`。 |
| [`sentinel/`](sentinel/) | Sentinel 安全终端系统（原 HighSafe，协议 `secure_auth_v4`）：独立认证服务器 + 审计服务器 + 终端。终端不存密码、只存终端密钥（PSK），登录走挑战—应答，登录与操作事件签名后发往审计服务器落盘（分段 + 哈希链 + 归档换盘）。部署与配置见目录内 `README.md`。 |
| [`cardkey/`](cardkey/) | 卡密验证机：由 Sentinel 改造，登录改为输入卡密。卡密服务器统一校验，并**由服务器经独立驱动器网络写盘**（服务器 `/payload/` → 玩家软盘），终端不参与写盘。卡密由秘密 pepper 经 SHA-256 派生（不用 `math.random` 直接抽取），库内只存指纹；**写盘成功才扣次数**，盘满/无盘/取消均不扣。部署与配置见目录内 `README.md`。 |
| [`rpv1/`](rpv1/) | RPV1（Rednet Protocol Version 1）：跑在 CC:Tweaked 上的用户态 IPv4 网络栈库——MAC/IPv4/ARP/ICMP/UDP、路由与转发、分片重装、连接层拥塞控制，rednet 只作 WAN。含发布包（`dist/`：单文件 / 目录 / 安装器三种形态）与 CraftOS-PC 回归套件（`poc/`）。该目录自带 `README.md` 与设计文档；真机测试用的 Minecraft 服务器运行时（`server.jar`、`libraries`、`world`）不入库，用 `poc/mc/` 下的脚本重建。 |
| [`pylib/`](pylib/) | 手写的 CC:Tweaked Python 子集解释器：`pkg/pylib/pythonlib.lua`（解释器本体）、`pkg/pyrepl.lua`（REPL 前端）、解释器 import 的 15 个 `.py` 模块，以及包管理器清单 `pkg/manifest`、还原说明 `MANIFEST.md` 与 `SHA256SUMS` 校验和。`pkg/legacy-py.lua` 是被取代的早期解释器，仅留档。 |
| [`dcnet/`](dcnet/) | dcnet：CC:Tweaked 分布式计算网络——用有线局域网把多台电脑连成“主控 + 节点”集群，主控负责拆任务、派任务、收结果与超时重派，支持两级 reduce、云端卸载、文件通道和 HMAC 签名。纯 Lua、无第三方依赖，含 CraftOS-PC 真机回归套件与可部署的 Python 参考服务端；部署只需 `dist/master.lua` 与 `dist/worker.lua`。 |

## 约定

- 新增项目：在仓库根目录建一个与项目同名的目录，把项目文件整体放进去。
- 只提交**程序本体**（源码、脚本、文档、构建产物、测试与证据）；第三方运行时与存档
  （例如 Minecraft 服务器 jar / libraries / world）不入库。
- 每个项目的构建、测试与验收命令都**从它自己的目录里运行**（本项目内的相对路径都是
  相对项目根目录的）。

## 发布构建

每个项目一条命令即可重建它的发布产物（产物都带仓库的 `LICENSE`）：

| 项目 | 命令 | 产物 |
|---|---|---|
| sentinel / cardkey / pylib | `python tools/build_release.py --project sentinel` | `dist/release/sentinel-v2.0.0.zip` 等 |
| rpv1 | `pwsh -NoProfile -File rpv1/poc/build-dist.ps1` | `rpv1/dist/`（含 `LICENSE`、单文件 MIT 头部、`rpv-1.0.0.zip`） |
| unixshell | `python unixshell/tools/release.py --out dist/release` | 两个安装半、字体介质、`gnome` 包、`pkgserver`、`INSTALL.txt`、`SHA256SUMS.txt` |

CI 在 [`.github/workflows/release-builds.yml`](.github/workflows/release-builds.yml)：

- **分支推送**：构建全部项目（只做 CI 校验，不发布）。
- **新建 tag**（`sentinel` / `cardkey` / `pylib` / `rpv1` / `unixshell`）：构建该项目并**刷新对应 release 的资产**。
- **手动 `workflow_dispatch`**：在 Actions 页面选择项目构建（不发布）。

注意：GitHub 不会为「把已有 tag 强推到另一个提交」启动工作流，所以给已有 tag 重新发布时，用 `workflow_dispatch`，或先删掉再重建 tag。构建是确定性的（zip 使用固定时间戳），同一提交重复构建得到相同字节。

## 许可证

本仓库以 **MIT** 许可证发布，详见 [`LICENSE`](LICENSE)。
