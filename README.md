# qodercli-openwrt

把官方 **qodercli**（国际版）与 **qoderclicn**（国内版）CLI 重新打包成 OpenWrt 的 ipk，并用 procd
常驻跑 `remote-control` 守护进程：手机 App 用同一个账号登录，就能给这台 OpenWrt 派活。

已在 2026-11-13 于一台 arm64 实体设备实测跑通 `qoderclicn` 1.1.87：`/etc/openwrt_release` 报
`SNAPSHOT`、`armvirt/64`、`aarch64_generic`（R24.03.19 by flippy），rootfs 里的 libstdc++ 停在
GCC 11.3 —— payload 能加载、`remote-control` 注册成功并保持心跳。

---

## 先纠正三个前提

这个项目最初的描述里有三处和事实不符，实现按事实来了。

**1. 没有"编译"这一步。**
`qodercli` / `qoderclicn` 官方只发布 Bun 单文件可执行程序（约 168 MiB），没有公开源码，
无法"编译成 ipk"。这里做的是：选对官方发布渠道 → 校验 → 按 opkg 的容器格式重新封装 → 附上
procd/uci 服务定义。产物是打包件，不是编译产物。

**2. "剥离过新的 gcc 符号"不保证能跑。**
决定一个 ELF 能否在 OpenWrt 上启动的是 **PT_INTERP（动态链接器）和 libc**：
musl 根文件系统里只有 `/lib/ld-musl-aarch64.so.1`，一个 `ld-linux-x86-64.so.2` 的二进制
无论怎么 strip 都起不来。所以兼容性由构建期的一道硬门禁保证 ——
[lib/elfcheck.py](lib/elfcheck.py) 直接读 ELF 头，架构或 libc 不匹配就拒绝出包，
而不是事后靠"符号干净"来祈祷。

**3. "适合 openwrt 全版本"只能指全部发布线，不能指全部 CPU 架构。**
官方 manifest 只发布 `amd64` / `amd64-baseline` / `arm64` 以及它们的 `-musl` 变体。
MIPS / MIPS64 / ARMv7 / riscv64 / 32 位 x86 **根本没有官方二进制**，本项目不会伪造一个装得上
但跑不起来的包，而是在 `--list-support` 和构建日志里明确说"这类设备无法支持"。
（大量家用路由是 MIPS，请以此判断能不能用。）

---

## 支持矩阵

| | |
|---|---|
| 变体 | `qoder`（国际版）、`qoderclicn`（国内版），两个渠道只差 base URL 与二进制名 |
| CPU | x86_64、arm64（必须是 **musl** rootfs；glibc 镜像要显式 `--libc glibc`） |
| ipk `Architecture` | `x86_64`；`aarch64_generic`、`aarch64_cortex_a53`、`aarch64_cortex_a72`、`aarch64_corelr8a` |
| OpenWrt 发布线 | 稳定的只有 19.07 / 21.02 / 22.03 / 23.05 / 24.10 / 25.12（2026-11-13 对 downloads.openwrt.org/releases 实测，不存在 25.5）；容器格式在 21.02–24.10 实测一致 |
| 无法支持 | mips / mipsel / mips64 / armv7 / riscv64 / i386，以及 glibc rootfs 上的 musl 包 |

ipk 就是 `debian-binary` + `control.tar.gz` + `data.tar.gz` 的 gzip tar（不是 `ar`），
服务定义只用 `procd` + `uci` + BusyBox ash，这些在上面的版本里没变，所以"跨版本"是成立的。

## 两种打包模式

| 模式 | 大小 | 说明 |
|---|---|---|
| `stub`（默认） | ~10.7 KB | 只装 wrapper、fetch 脚本和 procd 服务；168 MiB 的 payload 由设备上 `fetch-payload.sh` 拉到**真实存储**上（带空闲空间门禁，绝不落 `/tmp`，那是 tmpfs） |
| `embed` | ~72 MiB | payload 直接进 `data.tar.gz`，适合 eMMC 大的盒子或 x86 软路由；离线/无 HTTP 出口的环境也用这个 |

`stub` 和 `embed` 的产物文件名相同，所以 embed 一律落在 `$OUT/embed/`（默认 `dist/embed/`）
这个独立 feed，`--mode both` 一次出两套，两个目录各有一份 `Packages`。

## 符号兼容层：老 rootfs 为什么也能跑

官方 payload 是链接在较新 libstdc++ 上的。musl 在 `execve` 时解析**全部**强符号，
所以设备上 libstdc++ 只要缺一个，整个二进制就起不来 —— 2026-11-13 在一台
OpenWrt aarch64（`libstdcpp6 11.3.0-4`）上实测到的就是这一个：

```
Error relocating .../qoderclicn: _ZSt21__glibcxx_assert_failPKciS0_S0_: symbol not found
```

这不是 glibc/musl 之争，剥符号表也修不了：它是 libstdc++ ≥ GCC 12 才有的
`std::__glibcxx_assert_fail`。两条路都能补上，本项目选第二条，因为它不把 2.75 MB
的发行版库塞进包里：

1. 装一份 Alpine 的 musl 版 `libstdc++`（2.75 MB，包体膨胀，且引入外来二进制）
2. **自带一个 1.9 KB 的 stub 库**，只导出缺的那个符号（`compat/shim.cpp`）

stub 的实现是 `__builtin_trap()`：这些函数原本就不该返回，继续往下跑比原地死掉更糟。
它 `-shared -nostdlib` 编出来，没有 PT_INTERP、没有 `DT_NEEDED`，因此既不会拉进第二套
C++ 运行时，也不可能自己加载失败。

注入只能靠 `LD_PRELOAD`：`DT_NEEDED` 按**名字**查找，一个改名叫 `libqoder-compat.so`
的文件系统永远不会去打开它。运行时决策在 `templates/compat-env.sh.in`：

| uci `option compat` | 行为 |
|---|---|
| `auto`（默认） | 只有 `fetch-payload.sh` 证明这台设备缺符号时才前置 stub |
| `on` / `off` | 强制开 / 强制关（排障用） |

判定不靠猜版本号，靠问加载器本人：`fetch-payload.sh`（安装和 `--verify` 都会）跑一次
`<payload> --version`，把 musl 那行错误解析成符号名。缺的都在 `COMPAT_SYMBOLS` 里 → 写
`/etc/<srv>/compat.on` 标记并用带 stub 的环境复测；缺的不在里面 → **直接让安装失败**，
并指名是哪个符号，而不是留给 procd 反复 respawn。探针没有给出结论时同样失败：
coreutils 版 `timeout` 不认 `-t`，那种"没输出"曾经被当成"能加载"，现在要求正向证据
（exit 0）才算干净。

构建期门禁（`lib/compatgate.py` + `lib/depcheck.py`）保证这层不会被写歪：stub 必须无
`DT_NEEDED`、导出符号集**恰好等于** `etc/compat.conf` 的 `COMPAT_SYMBOLS`（多了会覆盖设备
上本来正常的实现，少了等于没修）、payload 确实引用这些符号（否则是死重）、体积不超过
`MAX_SHIM_BYTES`、sha256 与清单一致。加新符号的路径：改 `compat/shim.cpp` →
`./compat/build.sh` → 把 `compat/SHA256SUMS` 的新值填进 `etc/compat.conf`。

实测证据可以复现：

```sh
python3 lib/depcheck.py <payload> work/devsys                      # missing_strong: 1
python3 lib/depcheck.py <payload> work/devsys --preload compat/arm64/libqoder-compat.so
                                                                  # missing_strong: 0 → OK
```

`work/devsys` 是那台设备 `/usr/lib` 的只读拷贝，所以"补上这一个符号就够了"是算出来的，
不是猜的。

## 目录结构

```
bin/build.sh            取 manifest → 下载 → 校验 → ELF 门禁 → 渲染模板 → 封 ipk → 生成 feed 索引
bin/test-sim.sh         在 busybox ash + 假 rootfs 里跑设备侧脚本的行为测试（stub 包）
bin/test-sim-embed.sh   同一套思路针对 embed 包：verify/wrapper 必须用包内 payload
bin/test-compat.sh      兼容层三级测试：包内容门禁 / 真实动态链接器 / 设备侧判定
compat/shim.cpp         兼容 stub 的源码（只导出 libstdc++ ≥ GCC 12 才有的中止路径符号）
compat/build.sh         重新生成 compat/<arch>/libqoder-compat.so 并打印 sha256
compat/<arch>/          签入的 stub 二进制，每种架构 ~1.9 KB
etc/compat.conf         符号清单、体积上限、每个架构产物的 sha256
etc/variants.conf       两个渠道的地址、二进制名、arch 令牌
etc/ipk-matrix.conf     架构→Architecture 映射、发布线、空间余量、capacity/spawn 默认值
lib/elfcheck.py         兼容性硬门禁：读 ELF e_machine 与 PT_INTERP
lib/depcheck.py         符号闭合检查：DT_NEEDED + 强/弱未定义符号对目标 rootfs 求差集
lib/compatgate.py       打包前校验 compat stub（自包含/符号集/体积/哈希/是否真被引用）
lib/manifest.py         解析渠道 manifest，输出 shell 变量；未知架构直接报错
lib/mktar.py            确定性 tar（root:root、排序、mtime=SOURCE_DATE_EPOCH）
lib/render.py           %%KEY%% 模板替换，漏填即报错
lib/index.py            Packages / Packages.gz feed 索引
lib/verify.py           产物结构 + 语法 + 哈希 + 索引一致性校验
templates/              stub、fetch-payload、run-daemon、compat-env、init.d、uci config、postinst/prerm 等
```

## 构建

```sh
./bin/build.sh                                   # 两个变体 × 两种架构，stub 模式，全部发布线通用
./bin/build.sh --list-support                    # 只看支持矩阵
./bin/build.sh --variant qoderclicn --arch arm64 --mode embed   # 内嵌 payload，产物在 dist/embed/
./bin/build.sh --version 1.1.87 --offline        # 锁版本 / 只用 work/cache 里已有的下载
```

产物落在 `dist/`：`*.ipk` + `Packages` + `Packages.gz`（可直接当 opkg feed 发布）。
embed 包与同名 stub 包在设备上互斥（都提供 `/usr/bin/<bin>`），所以 `--mode embed`
一律发布到 `$OUT/embed/` 这个独立 feed（`--dist DIR` 时是 `DIR/embed/`），`--mode both`
就是两个 feed 各一份。

## 设备侧安装

```sh
# 1. 装包（scp 单个 ipk，或把 dist/ 挂成 HTTP feed）
opkg install /tmp/qodercli_1.1.87-r1_aarch64_generic.ipk
#    feed 方式：
#    echo "src/gz qoder http://<打包机地址>:8000" >> /etc/opkg/distfeeds.conf
#    opkg update && opkg install qodercli

# 2. 放 payload —— 只有 stub 模式需要
df -h                                   # 先确认哪个挂载点有 ~200 MiB 真实空间
/usr/libexec/qodercli/fetch-payload.sh --dir /mnt/sda1/qodercli
#    离线：fetch-payload.sh --from /tmp/qodercli-linux-x64-musl.tar.gz --dir ...
#    空间不够时脚本会列出真正放得下的挂载点：从 /proc/mounts 取 fstype，
#    自动排除 tmpfs / squashfs / 伪文件系统和 noexec 挂载，vfat 会额外警告
#    反过来，主动 --dir 到 tmpfs/noexec 会被拒绝——"装成功、重启就没"是静默故障
#    实在要用内存盘：再加 --allow-volatile

# 3. 记住这个位置，让 wrapper 和守护进程都找得到
uci set qodercli-rc.config.data_dir=/mnt/sda1/qodercli
# embed 模式跳过 2、3，payload 已在 /usr/libexec/qodercli/payload/

# 4. 自检
qodercli --version
/usr/libexec/qodercli/fetch-payload.sh --verify
```

第 2 步和 `--verify` 都以一次真实加载收尾：脚本问设备的加载器，缺符号就自动开启兼容层
（见上文），开不了就报错退出，而不是留一个跑不起来的二进制让 procd 反复 respawn。

## 登录与常驻服务

守护进程通过**出站连接**向 Qoder 云注册成一个"环境"，会话由云端下发 —— 不需要端口映射，
SSH 断开也完全无关，手机 App 看到的就是这台设备。

```sh
# 凭据二选一（国内版落 $HOME/.qoder-cn，国际版落 $HOME/.qoder，实测目录名不同）：
qodercli login                      # 交互式登录，凭据落在 uci option home 指向的 $HOME/.qoder*
# 或者把 PAT 写进 token 文件，启动器把它导出成该版本真正读取的变量名：
printf '%s\n' '<你的 PAT>' > /etc/qodercli-rc/token && chmod 600 /etc/qodercli-rc/token

uci set qodercli-rc.config.enabled=1
uci commit qodercli-rc
/etc/init.d/qodercli-rc enable && /etc/init.d/qodercli-rc start
```

**`enable` 和 `enabled` 是两件事**，这是最容易踩的坑：`/etc/init.d/X enable` 只写
`/etc/rc.d/S99X` 开机符号链接，实例开不开完全由 uci 的 `option enabled` 决定。只跑了
`enable && start` 的话 procd 会报告 `active with no instances` —— 脚本被调用了、退出码 0、
什么都没启动。现在 `start_service` 在这种情况下会往 stderr 打一句提示，不再静默。

看它到底跑没跑起来（**看这里，别指望 logread**）：

```sh
/etc/init.d/qodercli-rc status        # running，而不是 active with no instances
tail -f /root/.qoder*/logs/latest/qodercli.log     # CLI 自己的结构化运行日志
logread | grep qodercli-rc            # procd 转发的 stdout/stderr（verbose 的 JSON 事件在这）
netstat -tnp | grep qodercli          # 到云端 443 的 ESTABLISHED 连接 = 已经注册上
```

CLI 每次运行都在 `$HOME/.qoder/logs/latest/`（国内版是 `$HOME/.qoder-cn/logs/latest/`）写一份
运行日志，注册成功的标志是里面的 `Remote-control event stream connected` 和 `env_xxx` 环境
ID。服务侧不再另开一份日志文件：procd 的 `stdout`/`stderr` 参数是布尔值，早期版本往里塞的是
路径，结果静默无效 —— 这才是"日志到底在哪儿"的根源。

手机 App 看不到环境时先对账号：设备登录的是哪个版本就连哪个云（国内版打的是
`gateway.qoder.com.cn`），环境列表按账号隔离，App 必须是同一个账号。

> PAT 必须由你自己在 Qoder 账号里创建。这个项目不收集、不内置、也不代拿任何凭据。

**变量名两个版本不一样，实测过**：国内版只认 `QODERCN_DEVICE_TOKEN`（给它
`QODER_PERSONAL_ACCESS_TOKEN` 仍然回答 "Not logged in"，给 `QODERCN_DEVICE_TOKEN` 才会走到云端
并返回 401）。名单在 `etc/variants.conf` 的 `V_TOKEN_ENV`，uci 可覆盖：

```sh
uci set qodercli-rc.config.token_env='QODER_PERSONAL_ACCESS_TOKEN QODER_DEVICE_TOKEN'
```

token 文件第一行为空时启动器直接退出，不会匿名注册。
> `enabled` 默认是 `0`：payload 没装好或没登录就开机自启，只会在认证错误里 respawn 刷日志。

**内存**：一条会话实测 RSS ≈ 300–350 MB，而上游 `--capacity` 默认是 **32**。路由器或 SBC 上
这么跑会直接把机器打死，所以本项目的默认值写死成 `1`（`etc/ipk-matrix.conf` 里的
`DEFAULT_CAPACITY`），并发需求大请换内存充足的设备，别调这个数。

其余可调项都在 `/etc/config/qodercli-rc`：`directory`、`spawn`（`same-dir`/`worktree`）、
`name`（App 里显示的环境名，默认取主机名）、`verbose`、`extra_args`、`respawn_*`。

## 自动更新的风险

CLI 内置的更新器会把自己换成 **glibc** 构建 —— 在 musl 的 OpenWrt 上换完就起不来，而且我没找到
可验证的关闭开关。所以处理方式不是猜测，而是给出检测与恢复：

```sh
/usr/libexec/qodercli/fetch-payload.sh --verify   # 0 正常 / 1 已被替换 / 4 payload 完好但本机没有 musl 加载器
/usr/libexec/qodercli/fetch-payload.sh --force    # 重新装回官方 musl 构建
```

## 校验与测试

```sh
python3 lib/verify.py dist          # 容器成员、control 字段、Architecture 与文件名、conffiles、
                                    # sh -n 语法、payload 哈希、ELF、索引 Size/SHA256sum 一致性
./bin/test-sim.sh                   # busybox ash + 假 rootfs 的行为测试（stub 包，23 项）
./bin/test-compat.sh [IPK]          # 兼容层 19 项：产物门禁 / 真链接器 / 设备侧判定
./bin/test-sim-embed.sh [IPK]       # embed 包 4 项：verify/篡改检测/wrapper 都指向包内 payload
```

`test-sim.sh` 会解开一个 x86_64 stub 包，用一个最小 `uci` 替身走真实配置读取路径，验证：
payload 缺失时 wrapper 退 127 并给出取包提示；`--from` 安装校验哈希并触发 musl 加载器守卫；
篡改 payload 能被 `--verify` 抓到；wrapper 把执行权正确交给 ELF（本机没有 musl 加载器而失败，
这正是断言本身）；启动器拼出的 `remote-control --directory/--capacity/--spawn/--name` 与
`HOME`、token 变量注入正确（含 `token_env` 覆盖与空 token 拒绝）；ELF 门禁拒绝 glibc、放行官方
musl 包；存储门禁拒绝 tmpfs 目标且不把它列进建议。假 rootfs 建在 `work/` 而不是 `/tmp`，否则
这道门禁会在测试机上把自己拦下来。

`test-compat.sh` 分三级，一级比一级硬：产物门禁（`compatgate.py` 拒绝错架构、错哈希、错符号、
超限）；用本机链接器造一个"引用了符号但系统里没人实现"的可执行文件，证明没有 stub 时加载失败、
`LD_PRELOAD` 上 stub 后能跑、且真被调用时是 `SIGILL` 而不是继续执行；最后是假 rootfs 里的
设备侧判定——覆盖到的缺口自动开 shim、没覆盖的指名拒绝、`compat=off` 尊重、探针没结论时不许
报"干净"。

## 定时重打包

[.github/workflows/nightly.yml](.github/workflows/nightly.yml) 每天拉一次官方 manifest，重建
整个 stub feed、跑结构和行为校验，上游版本号变了就发一个 release。本地也可以直接：

```sh
./bin/build.sh && python3 lib/verify.py dist && ./bin/test-sim.sh
```

## 许可

本仓库的脚本、模板、测试以及 `compat/` 下自建的兼容 stub 采用 [MIT](LICENSE)（见
[LICENSE](LICENSE)）。

授权范围**不包含** `qodercli` / `qoderclicn` 可执行程序本身：那些文件由官方发布渠道提供，
随包分发时仍受其自身条款约束，本仓库只是校验并按 opkg 容器格式重新封装，不代表任何官方授权
或背书。发布产物请自行确认对上游条款的合规性。
