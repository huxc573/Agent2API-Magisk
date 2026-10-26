# ag2a Magisk 模块

在手机本地（arm64）跑 [Agent2API](https://github.com/aimod-cc/agent2api)，把多家 AI 客户端的登录态变成
OpenAI 兼容网关。**不依赖 Debian rootfs、不 chroot**：二进制只依赖 glibc 的 4 个 .so，用 loader 直跑。

> **致谢 / 上游**：服务本体、panel UI、官方插件都由 **[aimod-cc/agent2api](https://github.com/aimod-cc/agent2api)**
> 提供（MIT，镜像 `aimodcc/agent2api`）。本项目只做「装进 Android」的那层壳——脚本、打包、启动壳、
> WebUI 入口页；Release 里的运行体由 CI 从官方镜像原样抽取，未改二进制。详见 [THIRD-PARTY.md](THIRD-PARTY.md)。

## 下载与安装

从 [Releases](../../releases/latest) 取最新 zip，在 APatch / Magisk / KernelSU 里刷入。
版本号是日期制：`26.10.26_1` = 2026-10-26 第 1 个包（`versionCode = 26102601`，只增不减）。

## 默认值（26.10.26_1 / 上游 3.3.0-beta.4）

| 项 | 值 | 改法 |
|---|---|---|
| 端口 | **3065**（上游官方默认） | `sh action.sh config` 或改 `/data/adb/ag2a/port` |
| 管理员 | **不预设**：首次打开面板自己创建（密码≥8 位） | `sh action.sh config` 可预设 |
| 自动更新 | **默认关闭**（GitHub 两个上游仓库当前都不可达） | `sh action.sh auto on` / `auto 03:30` |
| 面板自带更新 | **关闭**（`AGENT2API_SELF_UPDATE=0`） | 改 `env` 后重启网关 |
| 数据目录 | `/data/adb/ag2a/` | — |

### 刷入时怎么选：音量键

Magisk / KernelSU 的安装界面**只有日志区、没有输入框**，也不把 stdin 交给 `customize.sh`
（用 `read` 会永久阻塞，就是「进度条卡住、提示也不显示」）。能用的交互只有**音量键**，
业界做法（OpenList-Magisk、box_for_magisk 等）都是读 `/dev/input` 的 `EV_KEY` 事件：

- **音量下** = 切下一项，**音量上** = 确认
- **没有超时**：不按就一直停在那行，只有按了音量上才继续（安装完成前不会自动跳过）

每次刷入都会问（**默认项＝当前值**，直接按音量上＝不改）：

| 问题 | 选项 |
|---|---|
| 网关端口 | 当前值 / 另一个常见值（3065 ↔ 52018） |
| 自动更新 | 开启 / 关闭（首次安装默认关闭；升级安装默认＝当前状态） |

**管理员账号不在刷入时设**：`login.html` 会探测「有没有账号」，没有就把按钮切成
「创建账号并进入面板」、密码框提示「设置密码（至少 8 位）」。所以打开网页自己建就行，
比发一个默认 `adminadmin` 安全。想预设也可：`sh action.sh config`。

**装完不用重启手机**：刷 zip 时 `customize.sh` 末尾会先把新的 `bin/` `ui/` 同步到
`/data/adb/ag2a/rt/`，再用**新脚本**停掉旧实例、从 rt 重新拉起网关 —— 服务当场就是新版本。
重启仍推荐——让 Magisk 的开机流程接管，进程路径也干净。

> 为什么以前刷完不重启服务还是老的：`/data/adb/modules/ag2a` 是 Magisk 的地盘，
> 刷 zip 只是把文件解到 `/data/adb/modules_update/ag2a`，**要重启才整体替换**。
> 运行体放那儿，跑着的当然还是旧二进制。v1.9.0 把运行体挪到数据目录下的 `rt/`
> （`/data/adb/ag2a` 是模块自己的地盘，Magisk 从不碰），重启网关进程即生效。
>
> ```sh
> su -c 'sh /data/adb/modules/ag2a/rt.sh status'   # 看 rt/模块 各是哪个版本
> su -c 'sh /data/adb/modules/ag2a/rt.sh sync'     # 手动重同步（一般用不到）
> ```

**卸载＝彻底清干净，但只碰自己的三个路径**。`uninstall.sh` 里所有删除都走白名单
`safe_rm`，只接受 `/data/adb/modules/ag2a`、`/data/adb/modules_update/ag2a`、`/data/adb/ag2a`
这三个**逐字写死**的路径；其它路径（含空串、`/sdcard`、相似名）一律拒绝并打印原因。
数据目录由 `ag2a_data_dir()` 统一校验，只认 `/data/adb/ag2a`，外部无法改成别的目录。
想重装后保留账号，卸载前先 `touch /data/adb/ag2a/keep`。
只想清账号回到「创建账号」页（不卸载）：

```sh
su -c 'sh /data/adb/modules/ag2a/action.sh reset'
```

装完还想改（能打字的地方）：

```sh
su -c 'sh /data/adb/modules/ag2a/action.sh config'
```

逐项问「端口 / 自动更新 / 钟点」，**音量键或回车＝保持现值**，改完自动 `service.sh restart` 生效。

### 进程模型（v1.8.1）

```
service.sh start ──setsid──> watchdog.sh ──fork──> service.sh run ──exec──> agent2api-server
                                   │                      （网关本体）
                                   └── wait（阻塞，零 CPU） ←┘
```

- 网关是看门狗的**直接子进程**，看门狗用 `wait` 等它：网关活着时看门狗 0 tick，一死 `wait` 立刻返回 ⇒ 立即重拉（不是 30 秒后）。
- 退避：存活 <60 秒算异常，1/2/5/10/30/60 秒递增，防止配置写坏时把 CPU 烧在重启上。
- ⛔ 不用 `sleep N + pgrep` 轮询，也不用 `setsid` 起网关（脱离父子关系会让 `wait` 立刻返回，变成每秒重启）。

### 更新到底在什么时候跑

`updater.sh daemon` 是一个**睡到点才醒**的进程，不是 60 秒轮询：

- 每轮先跑一次 `tick`（该不该查，跑完就退），然后算「距下一个 04:00 还有多久」，`sleep` 过去；
- 单次睡眠封顶 1800 秒（兜住深睡把 sleep 拉长、以及用户中途改钟点），醒来重算；
- `sleep` 期间零 CPU、不阻休眠；一天只有到点那 1 次真干活；
- 自动更新关着时**根本不起这个进程**（`ag2a_update_on` 判完直接退出），所以关掉就彻底安静。

为什么不用 crond：本机（APatch）`/system/bin/crond`、magisk/ksu 的 busybox 全都不存在，
探测必然失败，失败后「开机补跑一次」等于自动更新永久静默失效。

版本比对靠 `/data/adb/ag2a/upstream.version`，**只有严格更新才下载**（`vercmp_gt`）：
封库后 GitHub API 可能仍返回陈旧 release（v3.0.9-beta.1），少了这道闸会被反向覆盖成旧版。

### 不想更新怎么办
三种粒度的关法：

| 目的 | 命令 |
|---|---|
| 关掉自动更新（手动也不动） | `sh /data/adb/modules/ag2a/action.sh auto off` |
| 看当前状态 | `sh /data/adb/modules/ag2a/action.sh auto status` |
| 只临时停一次联网（保留配置） | `touch /data/adb/ag2a/update.off`，恢复 `rm` 掉 |
| 换钟点 | `sh /data/adb/modules/ag2a/action.sh auto 03:30` |
| 手动查一次（不看开关也会执行） | `sh /data/adb/modules/ag2a/updater.sh now` |

关闭后 `updater.sh daemon` 进程**直接退出**（不是挂着空睡），`ps` 里看不到它。

### 改密码
上游只认 db 里 `kv.panelAdmin` 的 bcrypt 哈希，面板**没有**改密入口，
`AGENT2API_ADMIN_PASSWORD` 环境变量实测不生效（admin/admin、admin/adminadmin 都被拒）。
模块用 `POST /api/panel/setup` 建号（`CAPTCHA_ENABLED=0` 时免人机验证，要求 ≥8 位）；
密码只从 `admin_pw` 取，播种成功后该文件自动删除。

```sh
# 重装模块最简单：卸载时数据目录保留 ⇒ 刷入时重新输入密码即可覆盖？
```
不建议走「删库重建」（会丢面板里已登的客户端账号）。真要改密码，直接替换库里的哈希：

```sh
sqlite3 /data/adb/ag2a/proxy.db "select key,value from kv where key like '%anel%'"
# 用 bcrypt 10 轮生成新串后 update 回去，再 sh service.sh restart
htpasswd -bnBC 10 "" '新密码' | tr -d ':\n'
```


## 管理器里的三个按钮

| 按钮 | 来源 | 干什么 |
|---|---|---|
| **打开** | `webroot/index.html` | 读 `/data/adb/ag2a/port` 拿到端口，直接跳进面板 |
| **执行** | `action.sh` | 重启网关进程（= `service.sh restart`），并打印重启前后状态 |
| **卸载** | 管理器自带 | 走 `uninstall.sh`，只删自己那三个路径 |

「打开」依赖管理器的模块 WebUI：APatch（≥ 10568）、KernelSU 及各分支原生支持
（WebView 载入 `webroot/`，并注入 `ksu` 对象供页面执行 root 命令）。
Magisk 上游没有任何 WebView 代码，装 KsuWebUI 或 MMRL 才会出现这个按钮 ——
没有也不影响，`sh action.sh open` 会用系统浏览器打开。

⚠ 这两个按钮本身在**刷完后要重启一次**才换成新行为：管理器读的是
`/data/adb/modules/ag2a/` 里的脚本，而它要重启才被替换（运行体走 rt/ 所以面板不受影响）。

⚠ **点「执行」成功后管理器会自己退回列表**：APatch 的 `ExecuteAPMActionScreen` 在脚本返回成功后
直接 `navigator.popBackStack()`，脚本改不了这个行为。所以别指望停在输出页看结果——看模块列表的
说明行：`运行中 · IP:端口 · 23:25 启动 ｜ 执行=重启进程`，启动时刻变了就是这次重启成功了。

## 插件为什么起不来

面板里的「提供商增强 / 网页提供商」是上游单独发布的插件包，面板自己下载、验签、解压到
`/data/adb/ag2a/plugins/<id>/<版本>/bin/`，然后 **exec 直接拉起**。它们也是 glibc 二进制，
ELF 解释器写死 `/lib/ld-linux-aarch64.so.1` —— Android 根目录没有 `/lib`，execve 返回 ENOENT，
面板日志里就是 `启动插件进程失败（…）: No such file or directory (os error 2)`（文件其实在）。

`pluginfix.sh` 在每次 `service.sh start` 拉起网关**之前**把入口换成 4 行启动壳，真身挪到同目录 `.real`：

```sh
#!/system/bin/sh
exec /data/adb/modules/ag2a/lib/ld-linux-aarch64.so.1 \
     --library-path /data/adb/modules/ag2a/lib "${0}.real" "$@"
```

只处理 ELF、遇到 `#!` 直接跳过 ⇒ 幂等；插件升级把入口换回 ELF 后，下次启动自动重新套壳。
面板里插件已装但没起来时，手动补一次再点插件的启用/刷新：

```sh
su -c 'sh /data/adb/modules/ag2a/action.sh fixplugins'
```

## 运行体分离（v1.9.0）

升级频繁，但 `/data/adb/modules/ag2a` 只有重启才会被 Magisk 整体替换 —— 运行体放那儿，
刷完 zip 服务还是旧的。所以把**会变的部分**搬进数据目录：

| 位置 | 内容 | 为什么 |
|---|---|---|
| `/data/adb/ag2a/rt/bin/`、`rt/ui/` | 二进制 + 面板前端 | 只有它们跟着上游走；数据目录 Magisk 从不碰，写完重启网关即生效 |
| `模块目录/bin/`、`模块目录/ui/` | 同一份的副本 | 首次安装的源头、rt 出问题时的回退 |
| `模块目录/lib/`、`etc/`、`zoneinfo/` | glibc 四件套 + 根证书 + 时区 | 上游从没换过，不跟着版本搬；loader 也在这儿 |

- **同步逻辑只有一处**：`rt.sh sync` —— `cp → .new → mv`（原子替换），全部到位后**最后**才写
  `rt/.rtver`。中途断电/失败时戳还是旧值，下次启动发现「rt 比模块旧或没有戳」就整份重同步，自愈。
- **判据是「rt 比模块旧」而不是「不相等」**：刷完 zip 还没重启时 rt 是新版、模块目录是旧版，
  用「不相等」会把 rt 反而降级回去。
- **兜底**：`ag2a_bin()` / `ag2a_ui()` 在 rt 缺失时回退模块目录，任何情况下网关都起得来。
- 代价：多占一份运行体（约 22 MB）。

```sh
su -c 'sh /data/adb/modules/ag2a/rt.sh status'   # rt / 模块 各自的版本戳和实际路径
su -c 'sh /data/adb/modules/ag2a/rt.sh check'    # 需要同步返回 0，不需要返回 1
```

## 文件

| 路径 | 说明 |
|---|---|
| `src/` | 脚本壳（module.prop / *.sh / `webroot/`），改逻辑改这里 |
| `rootfs/` | 保持镜像内结构：`usr/local/bin/agent2api-server`、`lib/*.so`、`app/ui`、`etc/ca-certificates.crt`、`usr/share/zoneinfo/Asia/Shanghai` |
| `build_module.py` | 组装 zip：映射目录、**校验 ELF 必须是 aarch64(0xB7)**、统一 LF、写 0755 |

## 打一个包

版本号用**日期制**：`YY.MM.DD_序号`，序号＝当天第几个包（同一问题反复改就是 1、2、3）。

```bash
python build_module.py 26.10.26_1
# → publish/ag2a-magisk-v26.10.26_1.zip，versionCode=26102601
```

`versionCode` = `YYMMDD * 100 + 序号`（`build_module.py:version_code()`）。
老式 `1.9.2` 也能解析（→ 10902），重打历史包不会让编号跳变。

运行集更新（上游发新版时）：

```bash
# GitHub 两个仓库都不可达时，用上游发布的整包（含全平台资产）离线取：
#   直连不通时：解压 release zip → linux-server-arm64/agent2api-server-linux-arm64.tar.gz
# 有 GitHub 可用时：
gh release download v3.3.0-beta.4 -R aimod-cc/agent2api -p "agent2api-server-linux-arm64.tar.gz*" -D /tmp/a
cd /tmp/a && sha256sum -c agent2api-server-linux-arm64.tar.gz.sha256 && tar -xzf agent2api-server-linux-arm64.tar.gz
cp agent2api-server  <模块>/rootfs/usr/local/bin/agent2api-server
rm -rf <模块>/rootfs/app/ui && cp -r ui <模块>/rootfs/app/ui
python build_module.py <模块版本>
```

⚠换二进制前先确认新版的 glibc 需求不超过模块自带的 `libc.so.6`（模块是 2.36）：
`strings agent2api-server | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1`。

`lib/*.so` 与 `zoneinfo`、`ca-certificates.crt` 只在**换 glibc 大版本**时才需要重新取
（那时从 `aimodcc/agent2api` 镜像里扒 `usr/lib/aarch64-linux-gnu` 的同名 4 个 so）。
上游 tarball 里**不含** lib / zoneinfo / CA，所以这三样一直是模块自带的。

> 模块 bin/ 和 lib/ 里**全部**是 aarch64；之前 1.0.0 误把 amd64 的 so 打进去了，
> 现在 `build_module.py` 会直接拒绝非 0xB7 的 ELF。

## 手机上

刷入后**先跑自检**再判断：

```sh
su -c 'sh /data/adb/modules/ag2a/check.sh'
```

自检打印 abi / selinux / 关键文件 / `ld.so --list` 依赖解析 / 端口监听 / 进程 /
`env` 与 `update.conf` / 管理员是否已建 / 面板 HTTP 探活 / `run.log` 尾部。

```sh
su -c 'sh /data/adb/modules/ag2a/service.sh'      # 立刻启动（不重启）
su -c 'sh /data/adb/modules/ag2a/service.sh stop'  # 停
su -c 'sh /data/adb/modules/ag2a/service.sh start' # 启
su -c 'tail -50 /data/adb/ag2a/run.log'
# 面板：http://127.0.0.1:3065/
```

## 自动更新

**默认关闭。** 上游 GitHub 的两个仓库（`Agent2API/agent2api`、`aimod-cc/agent2api`）随时可能被封，
开着就等于每天 04:00 试一次，通不通看运气；要不要开、最后用什么手段（面板内更新 / 自建源）等上游稳定后再定。
手动开：`sh action.sh auto on`。

开启后按两个仓库顺序探测，谁先返回可用列表就用谁，比 `/data/adb/ag2a/upstream.version`：

```
GET api.github.com/repos/<命中仓库>/releases?per_page=12  → 全部 tag + prerelease 标志
按通道筛：beta=全要 / stable=只留 prerelease=false
逐条 vercmp 取最大 → 再 GET releases/tags/<tag> 拿 assets[].digest
比版本：只有严格更新才继续（封库后 API 可能残留旧 release，防降级）
下 https://github.com/<命中仓库>/releases/download/<tag>/agent2api-server-linux-arm64.tar.gz
sha256 对齐 digest → 解出 agent2api-server + ui/ → 验 aarch64 → 替换 rt/bin + rt/ui → service.sh restart
```

写的是 `rt/` 不是模块目录：模块目录要重启才被替换，写进去跑着的还是旧二进制（见「运行体分离」）。

⚠ **不能用 `/releases/latest`**：它只返回「正式版」。上游 3.2.0 之后全部标成 pre-release，
latest 至今停在 `v3.0.8`，用它就永远看不到 3.2/3.3 —— 这也是加了通道的原因。

比原来拉 Docker 层好在：只下 8.4MB（原来要下整个 Debian 基础层）、有官方 sha256、
换之前还验一次 ELF 是不是 aarch64。

### 下载源：加速 + 原生兜底
`api.github.com` 国内基本直连可用（几百字节），真正卡的是资产下载
（会 302 到 `objects.githubusercontent.com`，常被墙）。所以下载走「多源顺序试」：

```
gh-proxy.com → ghproxy.net → ghfast.top → github.com 直连
```

每源下完都拿 **GitHub API 给的官方 digest** 校验，不匹配就换下一个 ⇒
镜像就算投毒/给错版本也过不去；全挂才判失败。默认列表内置在脚本里，
要换自建反代写 `update.conf`：

```sh
AG2A_UPDATE_SOURCES=https://gh.你的域名/,https://gh-proxy.com/,
# 末项留空 = 最后退回 GitHub 直连
```

```sh
su -c 'sh /data/adb/modules/ag2a/updater.sh now'      # 立即检查
vi /data/adb/ag2a/update.conf                          # 改钟点 / 是否重启
su -c 'sh /data/adb/modules/ag2a/action.sh auto off'   # 关掉自动更新
su -c 'tail -50 /data/adb/ag2a/update.log'
```

`update.conf`：

```sh
AG2A_UPDATE_INTERVAL=86400    # 0=关；非 0 时按下面的钟点每天查
AG2A_UPDATE_AT=04:00          # 每天几点查
AG2A_UPDATE_RESTART=1         # 1=更新后自动重启网关
AG2A_UPDATE_CHANNEL=beta      # beta=连 pre-release 一起取（默认）/ stable=只要正式版
# 上游仓库，空格分隔，按顺序探测（改过名，两个都留着）
AG2A_UPDATE_REPOS=Agent2API/agent2api aimod-cc/agent2api
```

通道改法：`sh action.sh auto channel beta|stable`（改文件也算，`auto status` 会显示当前通道）。
`beta` 下会取到 `v3.3.0-beta.4`；`stable` 下最高只能到 `v3.0.8`——上游把 3.2 之后的新版全标成 pre-release。

匿名 GitHub API 60 次/小时，一次检查用 2 次（列表 + 单 tag 详情），一天一次绰绰有余；
要更稳可在 env 里给 `GITHUB_TOKEN`（只用于 API 查询，资产下载走 302 不需要）。
失败**不会当天重试**（`tick` 无论成败都记「今天查过了」，daemon 醒来发现今天已查过就直接睡到明天），次日钟点再来。
改完 `update.conf` 要重排定时器：`action.sh auto off|on|HH:MM` 会自动重排，
直接改文件的话跑一次 `sh service.sh crontab`（= 停旧定时器 + 起新的）。

### 面板里的「软件更新」默认关
上游面板自带一键更新 / 回滚（`/api/update/install|rollback|restart`），但它假设自己独占
进程与目录，和模块的更新通道会打架。所以 `env` 里默认 `AGENT2API_SELF_UPDATE=0`：
面板上这些入口不出现，后端也会拒（400）。想改用面板内更新，把它改成 1 并重启网关，
同时关掉模块的自动更新（`sh action.sh auto off`）。

## 已知取舍

- **lib 不随更新替换**（ag2a 换 glibc 版本概率极低；真换了 `ld.so --list` 会报缺库）。
- **CA 证书**打包时从镜像抄（150 张），更新时会跟随上游一起换。
- **DNS** 走 bionic 的 `getaddrinfo`，不需要 wb2api 那种 `WB2A_DNS` 补丁。
- 自动建管理员依赖 `CAPTCHA_ENABLED=0`；若把 env 里该项改成 1，setup 接口会被人机验证拦住，
  需要手动在面板注册。
