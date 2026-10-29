# Agent2API-Magisk 变更记录

产物：`publish/Agent2API-Magisk-vX.Y.Z.zip`
上游二进制版本记在 `module.prop` 的 `version=… (ag2a <版本>)`。

---

## 26.10.30_5（当前）

- **修管理器的「有更新」提示不再出现**：`module.prop` 的 `updateJson` 之前是 `https://gh-proxy.com/https://raw.githubusercontent.com/…/update.json`，多一跳镜像、还可能被管理器判超时；拉不到 update.json 就等于「永远是最新」。现在改成 GitHub Pages 直链 `https://huxc573.github.io/Agent2API-Magisk/update.json`，与 workbuddy2api-panel-magisk 完全一致（占位符 `__AG2A_PAGES__` 由打包时注入）。

## 26.10.30_4

- **运行体改钉 `3.3.0-beta.5.1`**：`3.3.0-beta.5.1` 的官方镜像已经推出来了（Docker Hub 有这个 tag），里面就是修掉启动 panic 的版本；`26.10.30_1` 临时用的 beta.4 作废。
- **修管理器的「更新日志」显示成一坨 HTML**：`update.json` 的 `changelog` 之前指向 `github.com/…/blob/main/CHANGELOG.md`（网页），管理器把整页 HTML 当文本抓下来显示。现在改走 GitHub Pages（源＝main 根目录）`https://huxc573.github.io/Agent2API-Magisk/CHANGELOG.md`，纯文本直连可用，跟 workbuddy2api-panel-magisk 一个写法。

## 26.10.30_1

- **钉回上游 `3.3.0-beta.4`**：beta.5 的 headless 启动是坏的 —— 二进制在 `server/src/server/core/update/mod.rs:518` 里 `tokio::spawn`，而这一段跑在还没有 Tokio 运行时的主线程上，进程启动即 `panic: there is no reactor running`、`rc=134`，看门狗反复重拉也起不来（上游 issue #391；当时 beta.5.1 只有 tag、没 release 包，随后镜像才推出来）。上游 `main` 已把 `init_global` 里的 spawn 删掉，模块侧改不了二进制，只能钉版等它发新包。
- 新增 `UPSTREAM_PIN`：仓库根这个文件非空时，每小时轮询与手动触发的 tag 都只认它，避免自动把坏版本再推上来；上游发了可用的新版就删掉它恢复跟随。
- ⚠`_7` 里那条「证书/时区 env 没 export」是真 bug，但不是这次起不来的原因。

## 26.10.29_7

- **修证书/时区 env 没导出**：`ag2a_cert_env` / `ag2a_tz_env` 只 echo 了 `SSL_CERT_FILE=…`、`TZ=…`，而调用方是 `eval "$(…)"` —— 不加 `export` 就只是给当前 shell 设了个变量，随后 `exec` 出去的网关（和它 spawn 的插件）根本看不到：rustls 拿不到根证书、时间按 UTC 走。现在两个函数都带 `export`；顺手去掉指向不存在目录的 `SSL_CERT_DIR=$MODDIR/etc/certs`。`check.sh` 增加一行「env 交给网关」把子进程真正可见的 env 打出来，漏 export 一眼可见。

## 26.10.29_6

- **起不来时自动留证据**：`service.sh` 等满 15 秒端口还没监听、且确认没有进程在跑时，会自动前台跑一次二进制把真实报错写进 `run.log`（`[diag]` 段）；说明行摘要会跳过 `[diag]`/`[watchdog]` 的框线行，直接取网关自己的报错。
- 新增 `sh action.sh log [行数]`：直接看 `run.log` 尾部。

## 26.10.29_5

- **「打开」页加 run.log 尾部**（最近 10 行，自动滤掉看门狗的重拉日志）＋刷新按钮：网关起不来时不用开终端就能看到原因。
- 修 `module.prop` 括号里的上游版本一直停在 `beta.4`：打包时改读 CI 解析出的 `$UPSTREAM_TAG`（此前是从 `src/module.prop` 里抠，源码那行不动它就永远不动）。
- 未运行时把 run.log 最后一条日志摘要进模块说明行，管理器列表里直接能看到。

## 26.10.29_2

- **「打开」改成集成面板**（原来只读端口就自动跳走）：显示面板地址、进程状态、模块版本与运行体是否同步、有没有新版；三个按钮＝打开面板 / 用浏览器打开 / **打开 GitHub 更新地址**（系统浏览器跳 Releases）。不再自动跳转。
- **管理器内更新**：`module.prop` 加 `updateJson=`，指向仓库根目录的 `update.json`。Magisk / KernelSU / APatch 会比 `versionCode`，有新版就在模块列表显示「更新」并直接刷入。CI 每次出包后按打好的 zip 重写 `update.json` 并提交，保证两者永远一致。
- 仓库地址在打包时注入（`$AG2A_SELF_REPO`），改名只改 CI 一行，不用回来改 HTML/`module.prop`。
- ⭐更新源走 `gh-proxy.com` 镜像：实测国内直连 `raw.githubusercontent.com`、`github.com/releases/download` 全部超时，只有镜像能通。

## 26.10.26_4

- 发布策略：本仓库只出包，**所有 Release 一律 pre-release**，不占 Latest（Latest 恒为空），下载按 Release 页日期取最新。
- CI 版本序号改为「当天已有最大序号 + 1」，删过旧 Release 后不会重号（此前 `_1` 会被重用）。
- README 下载入口从 `releases/latest` 改为 `releases`。
- 定时从「每天 03:30」→「每 3 小时」→ 现为**每小时**（`cron: 30 * * * *`）。GitHub 的 schedule 是尽力而为，实测每 3 小时的配置被排队拖成 4~9 小时一次（3 天只跑 10 次），所以改成每小时轮询。

## 26.10.26_1

**版本号改日期制**：`26.10.26_1` = 2026-10-26 当天第 1 个版本，`versionCode` = `26102600 + 序号`
（`build_module.py` 里 `version_code()`，老式 `1.9.2` 仍能解析成 `10902`，历史包不受影响）。

**修插件起不来。** 面板里两个插件（提供商增强 / 网页提供商）装得上但启动即失败：
`启动插件进程失败（…/bin/agent2api-providers）: No such file or directory (os error 2)`。

原因是插件和主程序一样是 glibc 二进制，ELF 解释器写死 `/lib/ld-linux-aarch64.so.1`，
而 Android 根目录没有 `/lib` ⇒ execve 直接 ENOENT（文件明明在，缺的是解释器）。
主程序能跑是因为 `service.sh` 用模块自带 loader 起的；插件由面板自己 spawn，绕不过去。

- 新增 `pluginfix.sh`：把 `plugins/*/*/bin/*` 下的 ELF 换成 4 行启动壳
  `exec <模块>/lib/ld-linux-aarch64.so.1 --library-path <模块>/lib "${0}.real" "$@"`，
  真身挪到同名 `.real`。只碰 ELF、遇到 `#!` 跳过 ⇒ 幂等；插件升级换回 ELF 后下次启动自动重套。
- `service.sh start` 在拉起网关前先跑它；手动补一次：`sh action.sh fixplugins`。
- 顺手把模块说明行改明白：`运行中 · IP:端口 · 23:25 启动 ｜ 执行=重启进程`。
  APatch 点「执行」成功后**自己退回列表**（`ExecuteAPMActionScreen` 里 `popBackStack()`，
  脚本控制不了），所以结果只能看这一行——启动时刻变了就是这次重启成功了。
- 再加一层反馈：执行完推一条系统通知（`cmd notification post`）——
  「网关已重启 · pid xxxx · 端口 3065」/「网关重启失败 · …」，退回列表后下拉通知栏就知道结果。

## v1.9.1

**按钮语义修正。** 以前「执行」一个按钮既看状态又开浏览器，想只重启网关没有办法。
上游仍是 3.3.0-beta.4，纯行为修正。

- 新增 `webroot/index.html` ⇒ 管理器里多一个「打开」按钮：读 `/data/adb/ag2a/port`
  拿端口（走管理器注入的 `ksu.exec`），直接跳进面板；另带「用浏览器打开」兜底。
  APatch（≥ 10568）/ KernelSU 原生支持；Magisk 上游没有 WebView，需 KsuWebUI 或 MMRL。
- `action.sh` 不带参数（＝点「执行」）由「打开面板」改成**重启网关进程**：
  打印重启前后 pid、端口是否 LISTEN、当前运行体路径与自动更新状态。
  打开面板挪到 `action.sh open`。
- 重启判定直接用 `service.sh restart` 的退出码（它内部已等到端口 LISTEN 才返回 0），
  不再另写一套轮询，避免两处判活漂移。
- ⚠ 按钮行为由模块目录里的脚本决定，所以刷完要重启一次才换成新行为（面板不受影响，走 rt/）。

## v1.9.0

**运行体分离：升级安装刷完 zip 不用重启手机，服务立刻就是新版本**（首次安装仍需重启，见 README 安装第 3 步）。上游仍是 3.3.0-beta.4，模块侧架构改动。

### 要解决的问题

刷入新 zip 后模块列表显示新版本号，但网关跑的仍是旧二进制 —— 只有重启手机才更新。
原因是 `/data/adb/modules/ag2a` 由 Magisk 管理，刷 zip 只解到
`/data/adb/modules_update/ag2a`，**重启时才整体替换**到 `modules/`；
运行体（二进制 + ui）放在那儿，跑着的进程自然是旧的。

### 改法

| 位置 | 内容 |
|---|---|
| `/data/adb/ag2a/rt/bin/`、`rt/ui/` | **运行体权威位置**（v1.9.0 起）。数据目录 Magisk 从不碰 ⇒ 同步完重启网关即生效 |
| 模块目录 `bin/`、`ui/` | 同一份副本：首次安装的源头 + rt 缺失时的回退 |
| 模块目录 `lib/`、`etc/`、`zoneinfo/` | 不变，仍留在模块目录 |

- 新增 `rt.sh`：`sync` / `check` / `status`。同步用 `cp → .new → mv`（同一文件系统上原子替换），
  全部到位后**最后**才写 `rt/.rtver` 作为提交点；中途断电/失败时戳是旧值，下次启动整份重同步自愈。
- `lib.sh` 新增 `ag2a_rt()` / `ag2a_rtver()` / `ag2a_modver()` / `ag2a_rt_need_sync()`；
  `ag2a_bin()` / `ag2a_ui()` 改为 **rt 优先、缺失回退模块目录**。
- `service.sh`：启动前做一次自愈判断（2 次 stat + 1 次 cat，不复制）；`AGENT2API_UI_DIR` 走 `ag2a_ui()`；
  `run.log` 记一行运行体来源与版本戳，排查「升级了还是老服务」先看这行。
- `customize.sh`：刷入末尾先 `rt.sh sync`（源＝`$MODPATH`），再用 **`$MODPATH` 里的新脚本**
  停旧实例、从 rt 拉起 —— 用模块目录里的旧脚本会 exec 旧二进制，等于白干。首次安装（模块目录还没落地）
  和模块被停用时跳过启动。同步失败会明确提示「当前仍是旧版本在跑」。
- `updater.sh`：自动更新写入 `rt/bin` + `rt/ui`，不再覆盖模块目录。
- `ag2a_pids()` 匹配扩到四条路径：`rt/`、`$MODDIR/bin/`、`/data/adb/modules/ag2a/bin/`、
  `modules_update/ag2a/bin/`。第三条是关键：`customize.sh` 里 `$MODDIR=$MODPATH=…/modules_update/ag2a`，
  少了它就认不出正跑着的旧网关，stop 会变成「停不掉 + 再起一个」。
- `uninstall.sh`：`pkill` 覆盖 rt 路径；删数据目录前检查 rt 二进制是否仍被进程占用。
- `check.sh`：改为显示实际生效的 bin/ui 路径与两边版本戳。

### 判据细节

`ag2a_rt_need_sync` 用「**rt 比模块旧**」而不是「版本不相等」。刷完 zip 但没重启时，
rt 已是新版、模块目录还是旧版；用「不相等」会把 rt 降级回旧版。

### 代价与风险

- 多占一份运行体 ≈ 22 MB（`/data/adb/ag2a/rt/`）。
- 全程只写 `/data/adb/ag2a/rt/`，模块目录一个字节不动；Magisk 侧行为不变。
- rt 里的二进制 SELinux 上下文沿用 `/data/adb`（与 `/data/adb/ap/bin/busybox` 同域，可直接 exec）。

---

## v1.8.1

**运行集升到上游 3.3.0-beta.4。模块侧无功能改动，纯跟随上游。**

### 上游 3.3.0-beta.4（发布 2026-10-26）

| 项 | 值 |
|---|---|
| 二进制 | 11 951 592 → 14 049 112 B（+2.1 MB），sha256 `89912b74…` |
| 架构 | ELF64 aarch64（`e_machine=0xb7`） |
| glibc | 最高需求 2.34（模块自带 2.36） |
| 依赖库 | `libc.so.6` / `libgcc_s.so.1` / `libm.so.6`，与上版一致 |
| ui | 213 → 218 文件 |
| 官方 digest | `1430c20870601f9946e73c6eed9f4259a6c17638363251298a217337c640d12c`，下载后逐字对齐 |
| env 新增键 | 无（仍只有 `AGENT2API_PROXY_HOME/HOST/PROXY_PORT/CAPTCHA_ENABLED`） |

上游要点：OpenAI Images 接口（生成 + 参考图编辑，复用网关鉴权/模型绑定/账号重试/记账）、
模型可单独配置路由并支持拖动排序、请求跟踪视图回放选路、会话粘滞管理、
账号逐个/按组导出 JSON、请求指纹脱敏（字面量 + 正则）、
运行日志三档分页与筛选导出、插件中心与签到中心补齐手机端。

⚠ 体积涨 2.1 MB 属上游自身变化（新增图片链路与路由视图），非打包问题。

---

## v1.8.0

**运行集升到上游 3.3.0-beta.3；自动更新新增 pre-release 通道。**

### 1. 上游 3.3.0-beta.3（发布 2026-10-24）

| 项 | 值 |
|---|---|
| 二进制 | 12 611 032 → 11 951 592 B（-659 KB），sha256 `b3355af4…` |
| 架构 | ELF64 aarch64（`e_machine=0xb7`） |
| glibc | 最高需求 2.34（模块自带 2.36） |
| 依赖库 | `libc.so.6` / `libgcc_s.so.1` / `libm.so.6`，与上版一致 |
| ui | 213 文件（数量不变，内容更新） |
| 官方 digest | `13e4ae3c000bff031d95e6da64646aaf8bc2c6f2debde19888cfa4008b4fcd5e`，下载后逐字对齐 |

上游要点：ZCode 令牌池与模型路由修复、账号批量操作（余额查询 / Token/余额限制规则）、
插件模型目录成功刷新后持久化、侧边栏分组顺序入库并纳入云同步、Linux 插件入口执行权限补齐。

### 2. 修掉「永远看不到新版」

`/releases/latest` 只返回**正式版**。上游从 3.2.0 起全部标成 pre-release，latest 至今停在 `v3.0.8`
⇒ 即使开着自动更新也永远判「无新版」，3.2 / 3.3 上不去。

改为：`/releases?per_page=12` 取列表 → 按通道筛 → `vercmp_gt` 挑最大 →
再单独 `GET /releases/tags/<tag>` 取该版本 arm64 资产的官方 digest。

### 3. 新增更新通道 `AG2A_UPDATE_CHANNEL`

| 值 | 行为 |
|---|---|
| `beta`（默认） | 连 pre-release 一起取，能升到 `v3.3.0-beta.3` |
| `stable` | 只留 `prerelease=false`，最高 `v3.0.8` |

改法：`sh action.sh auto channel beta|stable`；`auto status` 会显示当前通道。
升级安装时旧 `update.conf` 若缺这个键，`customize.sh` 自动补一行。

**实测**（真实 API）：beta → `v3.3.0-beta.3`，stable → `v3.0.8`；digest 提取与官方逐字一致。
`vercmp_gt` 7 组：`3.3.0-beta.3 > 3.2.0-beta.2 / > 3.3.0-beta.2 / > 3.0.8` 全 PASS，
反向比较与相等 3 组全 PASS。

---

## v1.7.2

**合并手机端实测修复 + 保留 3.2.0-beta.2 运行集。**
手机侧走的是同一条血脉（1.6.1 → 1.6.2 → … → 1.6.5），但两条线各自改了不同部分：
手机侧修的是真机暴露的执行路径 bug，本地这条线修的是上游版本与更新源。本版把两边的改动合到一起。

### 1. 判活不再全表扫描（手机侧 v1.6.2 的核心发现）

`ag2a_pids()` 原来遍历 `/proc/[0-9]*`，**对每个进程 fork 一次 `tr`** 读 cmdline。
1000 个进程 ⇒ 2000 次 fork ⇒ **单次 14 500 ms CPU**。放进 3 秒一轮的循环里永远追不上自己，
单核 100% ⇒ 19 小时掉电 102%。这就是"一晚上掉电 80%"的根因。

| 实现 | 单次耗时 |
|---|---|
| 遍历 `/proc` + 每进程 `tr` | 14 500 ms |
| `pgrep -f <完整二进制路径>` | **72 ms** |
| `ps -A -o PID,ARGS`（无 pgrep 时兜底） | 75 ms |

⛔ `pgrep -f` 必须用完整路径，并排掉 `$$` / `$PPID`，否则会把调用者自己当网关杀掉（退出码 137）。

### 2. `restart` 永不返回（手机侧 v1.6.5 bug 2）

原写法 `restart) stop_gw ;;` 只停不起：`$1` 仍是 `restart`，后面的
`[ -z "$1" ] || [ "$1" = "start" ]` 不成立 ⇒ 一路掉到文件末尾的**前台 `exec`** ⇒
调用方（Shizuku / 面板 / action.sh）等不到结束而超时，那个网关也随会话结束而死。
修法：`restart) … ; set -- start ;;`。

### 3. 开机无参数启动绕过全部后台逻辑（手机侧 v1.6.5 bug 1）

APatch / Magisk 开机执行的是**无参数**的 `sh service.sh`。原代码只认 `start`，
于是无参路径直接掉到前台 `exec`：网关起来了，但**看门狗、状态刷新、管理员播种全部没执行**。
把 4 条分支（`start` / 无参数 / `stop` / `restart`）当作 4 条独立路径分别测。

### 4. 端口保活：`wait` 而非轮询（手机侧 v1.6.4）

新增 `watchdog.sh`：`service.sh start` 用 `setsid` 拉起它，它 `fork` 出 `service.sh run`
（做完前置后 `exec` 成网关本体），然后 `wait` 那个子进程。

- `wait` 是阻塞系统调用：网关活着时看门狗 **0 tick**、不阻休眠；网关一死**立即**返回。
- 对比「每 30 秒 pgrep 一次」：不仅省电，发现还更及时（立即 vs 最多 30 秒）。
- ⛔ 不能用 `setsid` 起网关本身 —— 脱离父子关系后 `wait` 立刻返回 ⇒ 每秒重启一次的死循环。
- 退避：存活 ≥60 秒算正常（归零），否则 1/2/5/10/30/60 秒递增。
- `stop` 顺序必须是**先停看门狗再停网关**，否则看门狗会把网关立刻拉回来。

### 5. 自动更新改 daemon，放弃 crond（手机侧 v1.6.2）

设备是 APatch：`/system/bin/crond`、magisk / ksu 的 busybox **全都不存在**，
`start_crond()` 必然失败，兜底的"开机补跑一次"等于**自动更新永久静默失效**。
而且探测本身写的 `tr '\0' ' ' < cmdline` 正是第 1 条那个 14.5 秒的全表扫描。

改为 `updater.sh daemon`：先跑一次 `tick`，再算距下一个目标时刻还有多久，`sleep` 过去；
单次睡眠封顶 1800 秒（兜住深睡拉长 sleep 与用户中途改钟点）。关掉自动更新时**根本不起这个进程**。

### 6. 安装期"假成功"（手机侧 v1.6.4）

安装时 `MODPATH` 是临时目录（`/data/adb/modules_update/ag2a`），安装器收尾会清空它。
从那里拉起的网关 cmdline 记的是临时路径，进程活着但二进制已被删 ⇒
提示"已启动"而实际连不上。修法：

- 只在**最终目录**（`/data/adb/modules/ag2a`）已存在时才尝试启动；全新安装直接提示"重启后生效"；
- 启动后**必须验证端口真在 LISTEN**（读 `/proc/net/tcp`，0A 状态），不靠"进程存在"；
- 失败时如实报错并给出 `run.log` 路径，不再说"已启动"。

### 7. 安装期路径错乱

`ag2a_pids` 原来只匹配 `$MODDIR`，认不出从 `modules_update` 拉起的进程 ⇒ 再起一个 ⇒
端口被占、旧进程变孤儿。改为双路径匹配 + awk 去重。

### 8. busybox 三方案探测

写死 `/data/adb/magisk/busybox` 在本机（APatch 只有 `/data/adb/ap/bin/busybox`）不存在
⇒ 播种管理员的 `nc` fallback 直接失败。改为 `ap → magisk → ksu` 顺序探测，只在 source 时做几次 stat。

### 9. 配置项统一判定

`ag2a_update_on()` 收进 `lib.sh`：`update.off` 文件或 `AG2A_UPDATE_INTERVAL=0` 都算关闭。
原来 service / updater / customize 三处各写一份，必然漂移。

### 10. 升级安装先问"保持默认 / 重新设置"

默认项是「保持默认」，音量上直接确认＝端口与更新开关全部不动。原来一刷就把配置问到默认值。

### 11. 保留本地这条线的改进

- 运行集 **3.2.0-beta.2**（离线包导入，sha256 对齐包内 `.sha256`，aarch64 校验，需要 GLIBC ≤ 2.34 / 自带 2.36）；
- 双仓库探测 `Agent2API/agent2api` → `aimod-cc/agent2api`，命中哪个就用哪个下载；
- `vercmp_gt()` 防降级：封库后 API 仍返回陈旧的 `v3.0.9-beta.1`，少了这道闸会被反向覆盖；
- 首次安装**默认关闭自动更新**（两个仓库当前都不可达，面板另有更新入口）；
- `upstream.version` 每次刷入**无条件重写**：刷进去的就是已装版本，否则离线导入新版后会被判成"有新版本"去下旧包；
- `tick` 成败都记「今天查过了」。手机侧写的 `slot-21600`（6 小时后重试）在 daemon 下会让
  `_last < _slot` 恒成立 ⇒ 变成每 30 分钟联网重试，已改掉；
- `check.sh` 的自检不再遍历 `/proc` 全表，且不再把 `updater.sh daemon`（正常的定时器）误报成"常驻循环残留"。

### 验证（未上真机）

- 10 个 `.sh` 全过 `bash -n`；
- 21 项静态断言全过（判活实现 / 双路径 / LISTEN 校验 / 无参数分支 / restart 复写 / daemon / 双仓库 / 防降级 / 首次默认关 / 无条件重写 upstream.version / 无 CRLF …）；
- `vercmp_gt` 9 组自测全过（含 `beta.2 > beta.1`、`3.2.0 > 3.2.0-beta.2`、相等不通过）；
- 包：231 条目 / 9.92 MB，10 个脚本 mode=755、`lib.sh` 与 `module.prop` 644；
- `bin/agent2api-server` 12 611 032 B，sha256 `32d822a8…`，`e_machine=0xb7`；`ui/` 213 文件。

真机刷入后核对：

```sh
su -c 'sh /data/adb/modules/ag2a/check.sh'
```

要看的三行：`常驻循环: 无`、`更新定时器: 未启动`（自动更新关着时就是未启动）、
`pid:` 有值且 `netstat` 显示端口监听。

---

## v1.7.1

上游运行集升到 **3.2.0-beta.2**（群包离线导入）；自动更新改双仓库探测 + 防降级；
首次安装默认关闭自动更新。

## v1.7.0

上游运行集 3.2.0-beta.2 首次导入（二进制 12 611 032 B，ui 208 → 213 文件）。

## v1.6.1

删掉 `control.sh` 的 3 秒轮询与 `updater.sh` 的 60 秒轮询，`service.sh` 改一次性启动。
**当时漏掉了 `ag2a_pids` 本身的 14.5 秒全表扫描** —— 循环没了，但每次判活的代价没变。
