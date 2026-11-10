# lib/compat —— 上游运行时要找的「老库名」

模块的 `lib/` 里已经有 glibc 真正的那几份（`libc.so.6` / `libm.so.6` / `libgcc_s.so.1`），
但上游 3.5.0 起新增的脚本插件要下载 **Bun** 当运行时，Bun 的 ELF 里仍然写着
`NEEDED libpthread.so.0` / `libdl.so.2` / `librt.so.1`——这些 soname 在 glibc 2.34 之后
已经并进 `libc.so.6`，发行版只留一个几百字节到几十 KB 的空壳，用来让老二进制继续能加载。
Android 没有这些壳，于是 Bun 一启动就报：

```
error while loading shared libraries: libpthread.so.0: cannot open shared object file
```

插件本身的 `libspawnhook.so` 只把解释器指到模块自带的 loader，**不会补这些 soname**，
所以这里放三份官方壳，跟着 `--library-path` 一起被找到。

## 从哪来的

Debian 12 (bookworm) `libc6` arm64 包里的同款文件，原样取出、未改：

- 包：`libc6_2.36-9+deb12u14_arm64.deb`
- 路径：`/lib/aarch64-linux-gnu/{libpthread.so.0,libdl.so.2,librt.so.1}`
- 每个约 66 KB，导出为空（符号早就在 `libc.so.6` 里），只带版本信息

换新版本时重新取一遍即可：

```sh
curl -sLO https://deb.debian.org/debian/pool/main/g/glibc/libc6_2.36-9+deb12u14_arm64.deb
ar x libc6_*.deb data.tar.xz
tar xf data.tar.xz ./lib/aarch64-linux-gnu/libpthread.so.0 ./lib/aarch64-linux-gnu/libdl.so.2 ./lib/aarch64-linux-gnu/librt.so.1
```

自己用 zig 编空壳也能跑（`zig cc -target aarch64-linux-gnu.2.38 -shared -nostdlib`），
但会缺版本信息，Bun 启动时刷两行
`no version information available (required by …)`，所以用发行版的壳更干净。
