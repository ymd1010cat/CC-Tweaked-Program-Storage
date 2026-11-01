# ITN-Pass 批次生成与分发（`/system/itnpass_batch.lua`）

本文讲清楚一件事：**在站端上用脚本生成一批卡密，把明文安全地带出站端，交给终端使用者**，
以及事后怎么查、怎么撤销、怎么让"到期"真正生效。

站端管理台（README 第 8 节）是给人手点的；这份文档讲的 `itnpass_batch` 是同一套库的
**可脚本化入口**，适合"一次发 50 张、分给三个小组、每张 2 次、30 天后作废"这类批量操作。
两者写的是同一个库（`/auth/itnpass_passes.db`）、同一份 pepper，可以混用，但**不要同时大批量
操作**（存储层没有文件锁，见 README 12.6）。

---

## 0. 为什么不能靠 `cardkeys_*.txt` 搬来搬去

卡密本身**不存在于任何文件里**：库里只有 `sha256(卡密 .. "|" .. pepper)` 的指纹。所以：

- 站端**没有"导入卡密文件"这一步**。生成的那一刻，指纹已经入库，明文只是给分发用的副本。
- 换一台站端**不能复用**另一台生成的卡密：pepper 不同，指纹对不上（要复用就整站复制
  `itnpass_pepper.txt` + `itnpass_passes.db`，见 README 10.6）。
- 一旦明文文件丢了，那批卡密就永远无法再取出（只能撤销重发）。

`itnpass_batch` 因此把"明文"当成**一次性的分发材料**：生成时落在站端内部的 staging 文件，
导出到你显式给出的路径后默认删除。

---

## 1. 部署与调用

站端需要（与 README 第 2、15 节一致）：

```
/startup.lua                      服务 + 管理台（批量工具不参与开机）
/sha256.lua
/itnpass_net.lua
/itnpass_mode.lua
/auth/itnpass_config.lua
/auth/itnpass_store.lua           批量工具的唯一数据入口
/auth/itnpass_pepper.txt          首次加载服务时自动生成，必须备份
/system/itnpass_batch.lua         本工具（新增）
```

调用方式（CraftOS shell）：

```
/system/itnpass_batch.lua <命令> [参数...]
```

也可以 `cd /system` 之后直接 `itnpass_batch <命令> ...`。命令不依赖服务进程是否在跑：
它自己加载 store、读写同一个库文件，和站端启动脚本互不影响。屏幕被服务占着时，先按
两次 Ctrl+T 回到 shell（README 10.7）。

**任何命令都只打印 ID（12 位指纹前缀）与前 6 位指纹，不打印完整卡密。** 完整卡密只会出现在
`export --out <路径>` 写出的文件里，而那个路径必须由你显式给出。

---

## 2. `new`：生成批次

```
itnpass_batch new <count> [--uses N] [--prefix P] [--profile NAME] [--expires DAYS]
```

| 参数 | 默认 | 取值 | 说明 |
| --- | --- | --- | --- |
| `<count>` | 无（必填） | 1 .. `max_batch`（配置，默认 200） | 本批张数；超过上限**直接报错**，不会被悄悄截断 |
| `--uses N` | 该 profile 的默认次数（`pyroet-os` = 1、`pyromputer-os` = 2、`default` = 配置 `default_uses`，默认 2） | 1 .. 1000 | 每张卡密可写盘次数；显式给出时永远优先 |
| `--prefix P` | `batch` | `[A-Za-z0-9._-]`，≤24 字符，首字符必须是字母或数字 | 批次 ID 前缀，同时是 staging 文件名前缀 |
| `--profile NAME` | 配置 `profile`（默认 `default`） | `/itnpass_profile.lua` 目录里的名字（`default` / `pyroet-os` / `pyromputer-os`），`[A-Za-z0-9._-]`、≤32 字符 | 这批卡密给哪种装机盘用。**名字必须在目录里**，拼错即 `error=bad_profile`；生成的记录会**绑定**该 profile，次数只能花在对应 payload 的写盘上（见 README 2.6） |
| `--expires DAYS` | 不设 | 1 .. 3650 | 到期天数。**注意见 6.3：站端不会自己看日期** |

行为：

1. 用 store 的 `mint` 派生卡密并生成待入库记录（此时**还没入库**）；
2. 把明文批次写到 `<export_dir>/.stage/<批次 ID>.txt`（默认 `/cardkeys/.stage/`），
   格式与站端管理台导出的 `cardkeys_*.txt` 完全一致（`# ITN-Pass batch` 头 + 每行一张
   `XXXX-XXXX-XXXX-XXXX`）；
3. staging 写成功并逐张回读校验后，才 `commitBatch` 入库（不扣次，只是登记）；
4. 打印每张的 JSON 行，最后一行是单行摘要。

任何一步失败（参数越界、staging 写不进去、入库条数不符）都会打印 `ok=0` 并以非零状态退出，
**并且不会留下"已入库但明文丢失"的记录**：staging 失败发生在入库之前。

输出示例：

```
{"id":"7b1e04c93a52","fp6":"7b1e04","uses_left":2,"uses_total":2,"status":"active","batch":"labA-20261101-093000","profile":"pyroet-os","expires":1767225600000}
...（每张一行）
ITNP_BATCH new count=20 ok=1 batch=labA-20261101-093000 uses=2 profile=pyroet-os expires=1767225600000 staged=/cardkeys/.stage/labA-20261101-093000.txt
```

- `id`：指纹前 12 位；撤销、列表都用它（`revoke` 也接受任意 ≥4 位唯一前缀）。
- `fp6`：前 6 位指纹，管理台截图里常用来对号。
- `expires`：绝对毫秒时间戳，`0` 表示这批没有设置到期。
- 批次元数据写在库记录的 `note` 字段里（`itnp-batch/1 batch=.. profile=.. prefix=.. uses=.. expires=..`），
  所以**不需要改数据库结构**，老版本 store 读到的只是一条普通备注。
- profile 的**绑定**另有一个追加字段 `profile`（`mint` 的可选第 4 个参数写它），它决定扣次口径，
  与 `note` 里的元数据分工：`note` 记录"这批是谁发的、什么时候到期"，记录字段决定"能花在哪种
  payload 上"。管理台手工生成的卡不写这个字段，因此任何 profile 都能用（README 5.5）。

重复同一秒生成会得到 `-2`、`-3` 后缀的批次 ID，staging 文件永远不会被覆盖。

---

## 3. `export`：把明文写到显式路径

```
itnpass_batch export --out <PATH> [--batch <ID>] [--keep]
```

- `--out` **必填**。目标父目录不存在会自动创建；目标是目录、或等于 staging 文件本身都会拒绝。
- 站端同时只有一个 staging 文件时可以直接导出；有多个（先 `new` 了好几次）时必须用
  `--batch <ID>` 指定，工具不会替你猜"最新那一批"。
- 写入后逐字节回读比对，比对不一致就删掉目标文件并报错。
- 成功后**默认删除 staging 文件**（站端不再留明文）；要再导出一次就加 `--keep`，
  或从已导出的文件自己复制。

输出：

```
{"batch":"labA-20261101-093000","out":"/disk/labA.txt","keys":20,"bytes":3120,"staging":"purged"}
ITNP_BATCH export count=20 ok=1 batch=labA-20261101-093000 out=/disk/labA.txt bytes=3120 staging=purged
```

`count` 是写出的卡密条数（按"能通过 `store.normalize` 的行"计），不是文件行数。

---

## 4. 把文件带出站端

导出到 `/disk/...` 需要网络 B 的驱动器里有一张软盘（就是平时写盘的那张）；不需要软盘时
可以导出到站端电脑盘上的任意路径，例如 `/cardkeys/out/labA.txt`。

三种可行做法，按量选：

1. **软盘带出（批量、推荐）**：网络 B 驱动器插软盘 → `export --out /disk/labA.txt` →
   取出软盘 → 插到另一台装有 disk drive 的 CC 电脑上 `type /disk/labA.txt` 阅读/抄录/拍照。
2. **屏幕上抄（少量）**：`type /cardkeys/.stage/labA-....txt` 直接打印到站端屏幕再抄。
   逐行 `type` 时注意屏幕滚动，抄完核对张数。
3. **管理台（≤5 张）**：管理台 8.3 会把 5 张以内的卡密直接列在屏幕上，适合临时补发。

**分发完成就删掉明文**：站端上的 staging（`/cardkeys/.stage/`）、导出到电脑盘的副本、
软盘里的副本，都属于"谁看到谁就能用"的材料。导出文件里每张卡密右上角写着可用次数，
分发记录（谁拿了哪张）建议记在站端之外。

---

## 5. 模式（`pass` / `free`）与 batch 的关系

- `free` 模式下**仍然可以** `new`/`export`：库、pepper、批次记录都照常写。区别只在"站端是否
  拿库来判定"——`free` 站端不查库，谁都能写盘，卡密在这个阶段**没有约束力**。
- 切回 `pass` 后，这些卡密立刻恢复有效（除非被撤销或次数用完），所以 **`free` 期间发出去的
  卡密要当作"已经发出去的额度"**，要么缩短 `--expires`，要么事后 `revoke`。
- 反过来，`free` 期间用掉的写盘**不扣次**：`free` 不 reserve/commit，库里次数不会减少。
- 两端模式必须一致（README 2.5）；站端 `pass`、终端 `free` 时终端发空码，会被拒成
  `empty code`，与批次无关。

一句话：**`free` 只是"不需要凭证"，不改变"凭证一旦存在就按库计次"的语义。**

---

## 6. 查询、失效与撤销

### 6.1 `list`

```
itnpass_batch list [--status active|used|expired|revoked]
```

每张一行 JSON（字段见 2 节的 `id`/`fp6`/`uses_left`/`uses_total`/`status`/`batch`/`profile`/`expires`），
最后一行摘要：

```
ITNP_BATCH list count=20 ok=1 total=20 shown=7 status=active
```

`count` = 库里总记录数，`shown` = 过滤后条数。状态优先级：
`revoked` > `used`（次数用完）> `expired`（`expires` 已过且未撤销）> `active`。
`--status` 大小写不敏感；`revoked` 是文档之外额外接受的值，方便脚本对账。

### 6.2 撤销单张：`revoke`

```
itnpass_batch revoke <id-prefix|完整卡密> --yes
```

- 必须带 `--yes`，否则 `ok=0 error=confirmation_required`，库一个字节都不改。
- 可用 12 位 ID、任意 ≥4 位唯一十六进制前缀，或完整卡密（`XXXX-XXXX-XXXX-XXXX`）。
  前缀太短、命中多张、没命中都会拒绝并给出原因。
- 撤销只置 `revoked` 标志：剩余次数不回收，也不能再恢复出明文。
- 站端下一次 `verify`/写盘就会拒绝（`[Error] revoked`）。

### 6.3 "到期"是怎么生效的（重要）

**站端只认 `revoked`，不认日期。** `--expires` 只是把到期时间记进备注，`list` 会把它算成
`expired`；真正让它失效的是 **`prune` 把到期证撤销**：

```
itnpass_batch prune
```

`prune` 一次做三件事，都只通过 store 的 API：

1. `store.prune()`：清掉过期的写盘预留（`reservation_ttl_ms`，默认 5 分钟）；
2. 把 `expires` 已过且未撤销的记录 `store.revoke` 掉 —— 这才是"到期"落地的地方；
3. 删除"整批已死"（本批所有记录都已撤销或已到期）的 staging 明文文件；
   **找不到对应库记录的 staging 文件会保留**：库损坏后它可能是唯一的明文副本。

```
ITNP_BATCH prune count=3 ok=1 reservations=0 expired=2 staging=1
```

`count` = 本次实际改动数（预留 + 撤销 + 删文件）。所以：**想用 `--expires` 当硬门禁，就把
`prune` 放进每日维护**（站端 shell 或另一台终端上跑）；不跑 `prune`，到期的证会一直是
`active`，直到次数用完。

### 6.4 恢复：`unrevoke` 需要完整卡密

```
itnpass_batch unrevoke <完整卡密>
```

接受 `XXXX-XXXX-XXXX-XXXX`（大小写/分隔符都会规范化）。**不能按 ID 恢复**：库里只有指纹，
按 ID 恢复等于要求把明文存进库，那就丢掉了"库泄露不等于卡密泄露"这个性质。传 ID 会得到
`error=needs_full_key`。这与管理台 8.5 的规则一致（README 也是这么写的）。

---

## 7. 三条完整示例

### 示例 A：生成 20 张、2 次/张、30 天后到期，并按 profile 标记

```
/system/itnpass_batch.lua new 20 --uses 2 --prefix labA --profile pyroet-os --expires 30
# → 20 行 JSON + ITNP_BATCH new count=20 ok=1 batch=labA-20261101-093000 ... staged=/cardkeys/.stage/labA-20261101-093000.txt

/system/itnpass_batch.lua export --out /disk/labA.txt --batch labA-20261101-093000
# → ITNP_BATCH export count=20 ok=1 batch=labA-20261101-093000 out=/disk/labA.txt bytes=3120 staging=purged
```

之后 softdisk 里就是完整的 20 张；staging 已被删除，站端不再留明文。

### 示例 B：对账——还有多少张能用，哪一批

```
/system/itnpass_batch.lua list --status active
# → 每行 {"id":"...","uses_left":2,"status":"active","batch":"labA-20261101-093000",...}
# → ITNP_BATCH list count=20 ok=1 total=20 shown=20 status=active

/system/itnpass_batch.lua list --status used
# → 只看次数用完的；用于判断是否需要补发
```

### 示例 C：日常维护——撤销一张 + 让到期批次落地

```
/system/itnpass_batch.lua revoke 7b1e04c9 --yes
# → ITNP_BATCH revoke count=1 ok=1 target=7b1e04c93a52

/system/itnpass_batch.lua prune
# → ITNP_BATCH prune count=3 ok=1 reservations=0 expired=2 staging=1
```

---

## 8. 日志

每条命令都往 `/auth/itnpass_server.log` 追加**一行**（与服务、管理台共享同一个文件，
一行 `grep ITNP_BATCH` 就是完整的批次操作审计）：

```
YYYY-MM-DD HH:MM:SS  ITNP_BATCH new count=20 ok=1 batch=labA-20261101-093000 uses=2 profile=pyroet-os expires=1767225600000 staged=/cardkeys/.stage/labA-20261101-093000.txt
YYYY-MM-DD HH:MM:SS  ITNP_BATCH export count=20 ok=1 batch=labA-20261101-093000 out=/disk/labA.txt bytes=3120 staging=purged
YYYY-MM-DD HH:MM:SS  ITNP_BATCH revoke count=1 ok=1 target=7b1e04c93a52
YYYY-MM-DD HH:MM:SS  ITNP_BATCH prune count=3 ok=1 reservations=0 expired=2 staging=1
YYYY-MM-DD HH:MM:SS  ITNP_BATCH list count=20 ok=1 total=20 shown=7 status=active
YYYY-MM-DD HH:MM:SS  ITNP_BATCH unrevoke count=1 ok=1 id=7b1e04c93a52
```

失败也会留一行（`ok=0 error=<原因码>`），包括没带 `--yes` 的撤销尝试：

```
ITNP_BATCH revoke count=0 ok=0 error=confirmation_required
```

日志里**不含完整卡密**：`revoke` 打到的是 ID，`unrevoke` 打到的也是 ID。

---

## 9. 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| `ok=0 error=bad_count` | `<count>` 不是正整数；`new 0` / `new abc` 都会被拒 |
| `ok=0 error=count_too_large` | 超过 `max_batch`（默认 200）；改集中配置或分批生成 |
| `ok=0 error=bad_uses` / `bad_expires` | 越界：`uses` 1..1000、`expires` 1..3650 天 |
| `ok=0 error=stage_failed` | staging 写不进去（`export_dir` 被普通文件占了、盘满）；**库未改动**，修好重跑 |
| `ok=0 error=ambiguous_staging` | 站端有多个未导出的批次；加 `--batch <ID>` 指明 |
| `ok=0 error=no_staging` | 没有待导出的批次（已导出并被清理），先 `new` |
| `ok=0 error=out_dir` / `out_is_dir` / `same_path` | `--out` 的父目录建不出来 / 目标是目录 / 目标就是 staging 文件 |
| `ok=0 error=no_keys` | 指定的 staging 文件里没有卡密（空批次或手工放的文件） |
| `ok=0 error=needs_full_key` | `unrevoke` 传的是 ID；必须给完整卡密（见 6.4） |
| `ok=0 error=confirmation_required` | `revoke` 少了 `--yes` |
| `ok=0 error=store_unavailable` | `/auth/itnpass_store.lua` 缺失/加载失败；先修好站端 |
| 生成的证 `list` 显示 `expired` 但还能用 | 还没跑 `prune`（见 6.3）：站端不认日期，只认 `revoked` |
| 导出的文件打不开/少了几张 | `export` 的字节回读校验会拒绝坏文件；用 `--keep` 保留 staging 后重试 |

---

## 10. 与管理台的分工

| | 管理台 | `itnpass_batch` |
| --- | --- | --- |
| 谁用 | 坐在站端前的人 | 脚本 / 想一次处理很多张的人 |
| 明文落点 | `/cardkeys/cardkeys_*.txt` + `latest.txt`（保留，要手动删） | `/cardkeys/.stage/<批次>.txt`（导出后默认删除） |
| 参数 | 逐项提问、按 `max_batch` 截断 | 命令行一次给全，越界直接报错 |
| 列表/撤销 | 单张、交互式 | 批量过滤、可脚本消费的 JSON 行 |
| 到期 | 不涉及 | 记录 `expires`，由 `prune` 落地 |
| 日志 | 不写日志文件 | 每次一条 `ITNP_BATCH` |

两条路写同一个库；**不要在写盘高峰用任一方批量生成**（存储层无文件锁，README 12.6）。
