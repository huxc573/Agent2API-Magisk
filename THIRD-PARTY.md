# 第三方组件与致谢

本项目是 **Agent2API 的 Android/Magisk 包装层**，不含服务本体源码。
Release 里打包的 `bin/agent2api-server`、`ui/`、`lib/*.so`、插件包等运行体全部来自上游项目，
由 CI 从官方镜像 `aimodcc/agent2api` 原样抽取，未做二进制修改。

## Agent2API

- 仓库：<https://github.com/aimod-cc/agent2api>
- 镜像：<https://hub.docker.com/r/aimodcc/agent2api>
- 许可：**MIT License**，Copyright (c) 2026 aimod-cc (<https://github.com/aimod-cc>)
- 备用仓库（同名镜像站）：<https://github.com/Agent2API/agent2api>

上游许可全文：

```
MIT License

Copyright (c) 2026 aimod-cc (https://github.com/aimod-cc)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## glibc 运行库

`lib/ld-linux-aarch64.so.1`、`libc.so.6`、`libm.so.6`、`libgcc_s.so.1` 取自上游镜像的
Debian 基础层，许可为 **LGPL-2.1-or-later**（glibc）/ **GPL-3.0-or-later with GCC Runtime
Library Exception**（libgcc）。本项目只把这些库原样随包分发，供 glibc 二进制在 Android 上运行，
未做修改。

## 其它

- `etc/ca-certificates.crt`：Mozilla CA 证书集合，MPL-2.0。
- `zoneinfo/Asia/Shanghai`：IANA tzdata，公有领域。
