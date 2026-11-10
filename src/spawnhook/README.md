# libspawnhook.so —— 让 glibc 插件在 Android 上能跑

## 为什么需要

上游插件是 glibc 二进制，ELF 里 `PT_INTERP` 写死 `/lib/ld-linux-aarch64.so.1`。
Android 根目录没有 `/lib`（部分 ROM 直接删了这个 symlink），`execve` 直接 ENOENT，
面板日志就是：

```
启动插件进程失败（agent2api-providers）：No such file or directory (os error 2)
```

网关 spawn 插件是「落地即执行」，中间没有钩子；改插件文件又会破坏官方签名
（`install.rs` 的验签 payload 含入口二进制 sha256），而且安装事务失败会回滚删目录。

## 怎么解决

网关本身是模块用自带 loader 拉起来的，所以给它加 `--preload` 一个拦截库即可：

```
ld-linux-aarch64.so.1 --library-path <模块lib> --preload <模块lib>/libspawnhook.so agent2api-server
```

`libspawnhook.so` 钩 `posix_spawnp` / `posix_spawn` / `execve` / `execv` / `execvp`：
目标 ELF 的 `PT_INTERP` 命中 `/lib/ld-linux-aarch64.so.1` 且该路径不存在时，
改成 `ld.so --library-path <模块lib> <原文件>` 启动。

- 插件文件一个字节不动 ⇒ 签名完好，面板「下载并安装」/自动升级全部正常
- 不改网关二进制 ⇒ 跟随上游发版零影响
- 没有时间窗口 ⇒ 装完立刻能跑，不需要重启
- bionic 程序（`/system/bin/*`，解释器 `/system/bin/linker64`）不匹配，一律不碰

## 编译

本机没有 aarch64 交叉工具链时用 zig（单文件、自带 glibc 头）：

```sh
zig cc -target aarch64-linux-gnu.2.38 -O2 -shared -fPIC -nostdlib -lc -o libspawnhook.so spawnhook.c
```

zig 的 glibc 链接脚本会给产物加上 `DT_NEEDED libpthread.so.0`，而模块的 `lib/` 里只有
`libc.so.6`，直接放进去会加载失败（`libpthread.so.0: cannot open shared object file`）。
glibc 2.34+ 已经把 libpthread 合进 libc，所以把 `.dynstr` 里那条字符串原地改成 `libc.so.6`
（`\0` 补齐，长度不变）即可：

```sh
python - <<'PY'
p = 'libspawnhook.so'
d = bytearray(open(p, 'rb').read())
old = b'libpthread.so.0\x00'
while True:
    i = d.find(old)
    if i < 0:
        break
    d[i:i + len(old)] = b'libc.so.6\x00' + b'\x00' * (len(old) - 10)
open(p, 'wb').write(d)
PY
```

产物提交在 `rootfs/lib/libspawnhook.so`（19 KB），CI 不重编，直接用。

## 排障

- `touch /data/adb/ag2a/spawnhook.off` ⇒ 完全旁路（不传 `--preload`）
- 启动前 `ag2a_preload_arg()` 会跑一次 `--list` 自检，库加载不了就不带参数，不会把网关拖死
- `sh /data/adb/modules/ag2a/action.sh fixplugins` ⇒ 报当前状态
