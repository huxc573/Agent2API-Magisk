# Agent2API-Magisk

在 Android（arm64）上把 [Agent2API](https://github.com/aimod-cc/agent2api) 跑成开机自启的 Magisk 模块。
不 chroot、不做 Debian rootfs：二进制只依赖 glibc 的 4 个 .so，用模块自带的 loader 直跑。

- 适用 APatch / Magisk / KernelSU
- 仓库名沿用社区习惯：上游名 + `-Magisk`（同 `OpenList-Magisk`、`box_for_magisk`）

> **上游与致谢**：服务本体、panel UI、官方插件全部来自
> [aimod-cc/agent2api](https://github.com/aimod-cc/agent2api)（**MIT**，镜像 `aimodcc/agent2api`）。
> 本项目只做「把它装进 Android」这层壳——挂载逻辑、启动/看门狗、插件启动壳、WebUI 入口页、打包与 CI。
> Release 里的运行体由 CI 原样取自上游（优先用上游 Release 资产并校验其 `.sha256`，没有资产才从官方镜像 `aimodcc/agent2api` 抽），未改二进制。详见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 安装

1. 从 [Releases](../../releases) 下最上面那个 zip（**全部以 pre-release 发布**，页面没有 Latest，按时间倒序取第一行），在管理器里刷入；
2. 按音量键答两题（音量下＝下一项，音量上＝确认）——端口（3065 ↔ 52018，首项是当前值）、自动更新（开/关，首次默认关）；
   已装过的机器会**先多问一题**「是否重新设置」，音量上直接确认＝配置一个字都不动；
3. **首次安装要重启手机**：刷 zip 只解到 `modules_update/`，模块目录要重启才整体替换，安装器会提示「首次安装，重启设备后自动运行」。
   只有升级安装（模块已在）才不用重启：`customize.sh` 会把 `bin/`+`ui/` 同步到 `/data/adb/ag2a/rt/`，再用新脚本停旧起新；
4. 重启后打开 `http://127.0.0.1:<第 2 步选的端口>/`（默认 3065）自己建管理员（密码 ≥8 位，不预设默认账号）。

## 管理器里的三个按钮

| 按钮 | 来源 | 行为 |
|---|---|---|
| **打开** | `webroot/index.html` | 集成面板：端口、进程状态、模块版本/运行体、有无新版、**run.log 尾部**；三个按钮＝打开面板 / 用浏览器打开 / 打开 GitHub 更新地址 |
| **执行** | `action.sh` | 重启网关进程，并推一条系统通知报结果 |
| **卸载** | 管理器自带 | 走 `uninstall.sh`，只删自己那三个写死路径 |

- 「打开」依赖管理器的模块 WebUI：APatch（≥10568）、KernelSU 及各分支原生支持；Magisk 上游没有 WebView，装 KsuWebUI 或 MMRL 才会出现。没有也不影响，`sh action.sh open` 用系统浏览器打开。
- 面板里的「更新」一栏读的是仓库的 `update.json`（跟管理器自己弹的更新提示同一个数据源）；网络不通就只显示「查不到」，点下面的按钮自己看。
- 起不来先看「打开」页最下面的**日志**块（`/data/adb/ag2a/run.log` 尾部，已滤掉看门狗的「重拉中」）：网关自己的报错都在那儿。
- ⚠ 这两个按钮的行为由模块目录里的脚本决定，**刷完要重启一次**才换成新版（服务本身不受影响）。
- ⚠ 点「执行」成功后管理器会自己退回列表（APatch `ExecuteAPMActionScreen` 里的 `popBackStack()`，脚本控制不了）。结果看通知，或看模块说明行：`运行中 · IP:端口 · 23:25 启动 ｜ 执行=重启进程`。

## 管理器里的更新提示

`module.prop` 里有一行 `updateJson=`，指向仓库根目录的 `update.json`（走 **GitHub Pages** 直链，管理器 1~2 秒能拉到）：

```
updateJson=https://huxc573.github.io/Agent2API-Magisk/update.json
```

```json
{ "version": "26.10.30_5", "versionCode": 26103005,
  "zipUrl": "https://gh-proxy.com/https://github.com/…/releases/download/v26.10.30_5/…zip",
  "changelog": "https://huxc573.github.io/Agent2API-Magisk/CHANGELOG.md" }
```

Magisk / KernelSU / APatch 都会读这行，拿 `update.json` 的 `versionCode` 和本机的比，**大于本机就在模块列表里显示「更新」**，点一下直接下 `zipUrl` 刷入。每次 CI 出包后按打好的 zip 自动重写这个文件并提交，所以它永远指向最新那个包——这也是为什么包全是 pre-release 也不影响管理器更新（管理器不看 Release 的「Latest」，只看这个 JSON）。

- ⚠ `zipUrl` 套了 `gh-proxy.com` 镜像：实测国内直连 `raw.githubusercontent.com` 和 `github.com/…/releases/download/…` 都是超时（000）。镜像挂了就改一行 URL 重新出包，或者直接去 Releases 页手动刷。
- `updateJson` 与 `changelog` 都走 **GitHub Pages**（源＝main 根目录），不能指向 `github.com/…/blob/…` 网页（管理器抓到整页 HTML，日志里显示一堆 `<meta>` / `<link>`），也不要套 `gh-proxy` 中转（多一跳会被判超时，拉不到就等于「永远没更新」）。
- ⚠ 装的是**旧版（没有 updateJson 的那几版）**的，要手动刷一次新版，之后才会有提示。

## 常用命令

```sh
M=/data/adb/modules/ag2a
su -c "sh $M/check.sh"              # 自检：文件 / 依赖 / 端口 / 进程 / 面板探活
su -c "sh $M/action.sh config"      # 改端口、管理员、更新钟点（会重启网关）
su -c "sh $M/action.sh open"        # 系统浏览器打开面板
su -c "sh $M/action.sh reset"       # 清账号库，回到「创建账号」页
su -c "sh $M/action.sh fixplugins"  # 插件入口重新套壳（见下）
su -c "sh $M/service.sh stop|start|restart"
su -c "sh $M/rt.sh status"          # rt/ 与模块目录各是哪个版本
su -c "tail -50 /data/adb/ag2a/run.log"
```

卸载会清干净，但只碰 `/data/adb/modules/ag2a`、`/data/adb/modules_update/ag2a`、`/data/adb/ag2a` 三个逐字写死的路径（`uninstall.sh` 的 `safe_rm` 白名单）。
想重装保留账号：卸载前 `touch /data/adb/ag2a/keep`。

## 为什么升级不用重启手机

`/data/adb/modules/ag2a` 由管理器管，刷 zip 只解到 `modules_update/`，**重启才整体替换**——运行体放那儿，
跑着的自然还是旧二进制。所以会变的部分搬到数据目录：

| 位置 | 内容 |
|---|---|
| `/data/adb/ag2a/rt/bin/`、`rt/ui/` | 二进制 + 面板前端（权威位置） |
| `模块目录/bin/`、`ui/` | 同份副本：首次安装的来源 + rt 缺失时的回退 |
| `模块目录/lib/`、`etc/`、`zoneinfo/` | glibc 四件套 + 根证书 + 时区，上游从不换 |

`rt.sh sync` 用 `cp → .new → mv` 原子替换，全部到位后**最后**写 `rt/.rtver` 当提交点；断电半份的话，
下次启动发现「rt 比模块旧或缺戳」就整份重同步。代价：多占约 22 MB。

## 插件（提供商增强 / 网页提供商）

插件是上游单独发布的包，面板自己下载、验签、解压到 `/data/adb/ag2a/plugins/<id>/<版本>/bin/` 后 **exec 直接拉起**。
它们同样是 glibc 二进制，ELF 解释器写死 `/lib/ld-linux-aarch64.so.1`——Android 根目录没有 `/lib`，
`execve` 返回 ENOENT，面板日志就是 `启动插件进程失败（…）: No such file or directory (os error 2)`（文件其实在）。

`pluginfix.sh` 在网关启动前把入口换成 4 行启动壳，真身挪到同目录 `.real`：

```sh
#!/system/bin/sh
exec /data/adb/modules/ag2a/lib/ld-linux-aarch64.so.1 \
     --library-path "/data/adb/modules/ag2a/lib:${0%/*}" "${0}.real" "$@"
```

只碰 ELF、遇到 `#!` 跳过 ⇒ 幂等；插件升级换回 ELF 后下次启动自动重套。

## 进程模型

```
service.sh start ──setsid──> watchdog.sh ──fork──> service.sh run ──exec──> agent2api-server
                                   └── wait（阻塞，零 CPU） ──────────────┘
```

网关是看门狗的直接子进程，`wait` 等它：活着 0 tick，一死立刻重拉。存活 <60 秒算异常，退避 1/2/5/10/30/60 秒。
⛔ 不用 `sleep+pgrep` 轮询，也不用 `setsid` 起网关（脱离父子关系会让 `wait` 立即返回，变成每秒重启）。

## 自动更新

**默认关闭**——上游仓库随时可能不可达，开着就是每天 04:00 试一次运气。开启后：按通道挑 tag → 逐条比版本（防降级）
→ 取官方 `digest` 校 sha256 → 多源下载 → 验 aarch64 → 只写 `rt/bin`、`rt/ui` → 重启网关。

```sh
su -c "sh $M/action.sh auto on|off|status"      # 开关 / 状态
su -c "sh $M/action.sh auto 03:30"             # 换钟点
su -c "sh $M/action.sh auto channel beta|stable"
su -c "sh $M/updater.sh now"                   # 立刻查一次
```

- ⚠ 不能用 `/releases/latest`：上游正式版最高只到 **v3.0.8**（v3.0.9 之后全是 beta），latest 永远返回它 ⇒ 只能按 tag 列表挑。
- 资产下载走多源：`gh-proxy.com → ghproxy.net → ghfast.top → GitHub 直连`，每个源都用 API 给的 digest 校验。
- 定时器是「睡到点才醒」的进程，不是轮询；关掉时它根本不启动。

## 已知取舍

- 多占约 22 MB（rt 副本）。
- 仅 arm64；glibc 需求不能超过模块自带的 2.36。
- 面板自带的「软件更新」默认关（`AGENT2API_SELF_UPDATE=0`），避免和模块更新互相覆盖。

## 开发

| 路径 | 说明 |
|---|---|
| `src/` | 脚本壳（`module.prop`、`*.sh`、`webroot/`） |
| `rootfs/` | 运行体，**不入库**，由 `scripts/ci/rootfs.sh` 抽取（先试上游 Release 资产，缺了才走镜像） |
| `build_module.py` | 组装 zip：注入仓库地址、映射目录、校验 ELF 必须 aarch64、统一 LF、脚本 0755 |
| `update.json` | 管理器更新源（CI 每次出包后重写并提交） |
| `.github/workflows/build.yml` | 每小时查上游（cron `30 * * * *`），有新版就出包并发 **pre-release**（不占 Latest） |

上游一发版，下一轮定时就会出包；想立刻出包不用等，在 Actions 里手动跑 `build`（勾 `force` 可强制出）。

版本号是日期制 `YY.MM.DD_序号`，`versionCode = YYMMDD*100 + 序号`：

```bash
python build_module.py 26.10.26_1     # → publish/Agent2API-Magisk-v26.10.26_1.zip
scripts/ci/rootfs.sh 3.3.0-beta.4     # 本地抽运行体（需要 docker + gh 登录）
```

## 许可

本仓库 **MIT**；随包分发的上游二进制（MIT）、glibc/libgcc（LGPL/GPL+异常）、CA 证书（MPL-2.0）、tzdata 见 [THIRD-PARTY.md](THIRD-PARTY.md)。
