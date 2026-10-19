## unixshell（no craftos）

面向 CC:Tweaked 的类 UNIX shell，**不包含 `craftos` 命令**的构建变体：机器上没有
`usr/cmd/craftos.lua`，因此无法用 multishell 打开 ROM CraftOS shell；其余与完整
unixshell 相同。

本 tag 指向 `main` 的 `{{COMMIT}}`，资产由 `python tools/release_no_craftos.py`
用 `tools/deploy.py --without-craftos` 生成。

## 与完整版的区别

- 不部署 `usr/cmd/craftos.lua`，`craftos` 命令不存在。
- 其余文件、服务、包管理、网络、字体（字体本身在独立介质上）与完整版一致。
- 适合不允许操作员打开 CraftOS 标签的机器；需要该命令时用完整版。

## 资产

| 文件 | 是什么 | 放哪 |
|---|---|---|
| `unixshell-part1-no-craftos.zip` | 电脑自己的盘：启动路径 + base 模块（无 `craftos`） | 解压，把**内容**放到电脑文件系统根 |
| `unixshell-part2-no-craftos.zip` | 系统模块介质：惰性模块 + `rpv/`，根上有 `.pkgsys` | 解压，把**内容**放到介质根（保留 `.pkgsys`） |
| `unixshell-no-craftos-INSTALL.txt` | 两部分安装说明与尺寸 | - |
| `SHA256SUMS.txt` | 两个 zip 的 SHA-256 | - |

每个 zip 根附带仓库 `LICENSE`（MIT）。

## 安装

```
python tools/deploy.py --target <电脑目录> --part base --with-etc --without-craftos
python tools/deploy.py --target <介质目录> --part modules --without-craftos
```

或直接解压两个 zip 到对应根目录。

## 校验

`SHA256SUMS.txt` 给出两个 zip 的 SHA-256；下载后先校验再解压。

## 重建

```bash
cd unixshell
python tools/release_no_craftos.py
```

产物在 `unixshell/dist/release-no-craftos/`。
