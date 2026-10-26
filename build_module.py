#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""组装 ag2a Magisk 模块 zip。

用法: python build_module.py [版本号]
  - 源码壳:  src/           (module.prop / *.sh / customize.sh)
  - arm64 运行集: rootfs/    (usr/local/bin/agent2api-server + lib/*.so + app/ui + etc + usr/share/zoneinfo)
  - 产物:    publish/ag2a-magisk-v<版本>.zip

rootfs/ 保持镜像内目录结构（usr/local/bin、app/ui、usr/share/zoneinfo），
打包时映射到模块内的 bin/、ui/、zoneinfo/。
"""
import os
import re
import shutil
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "src")
ROOTFS = os.path.join(HERE, "rootfs")
PUB = os.path.join(HERE, "publish")
STAGE = os.path.join(HERE, ".stage")

RUNTIME = {
    os.path.join(ROOTFS, "usr", "local", "bin", "agent2api-server"): "bin/agent2api-server",
    os.path.join(ROOTFS, "lib", "ld-linux-aarch64.so.1"): "lib/ld-linux-aarch64.so.1",
    os.path.join(ROOTFS, "lib", "libc.so.6"): "lib/libc.so.6",
    os.path.join(ROOTFS, "lib", "libm.so.6"): "lib/libm.so.6",
    os.path.join(ROOTFS, "lib", "libgcc_s.so.1"): "lib/libgcc_s.so.1",
    os.path.join(ROOTFS, "etc", "ca-certificates.crt"): "etc/ca-certificates.crt",
    os.path.join(ROOTFS, "usr", "share", "zoneinfo", "Asia", "Shanghai"): "zoneinfo/Asia/Shanghai",
}

SHELLS = ["service.sh", "control.sh", "refresh.sh", "rt.sh", "pluginfix.sh", "updater.sh", "action.sh", "uninstall.sh", "watchdog.sh"]
EXEC = set(SHELLS) | {"customize.sh", "check.sh"}

EM_AARCH64 = 0xB7   # 防呆：曾经把 amd64 的 so 打进包里


def elf_machine(path):
    with open(path, "rb") as f:
        head = f.read(20)
    if head[:4] != b"\x7fELF":
        return None
    return int.from_bytes(head[18:20], "little")


def version_code(ver):
    """版本号 → versionCode（必须是递增整数，模块管理器只认这个）。

    现在的命名：`26.10.26_3` = 2026-10-26 当天的第 3 个版本 → 26102600 + 3 = 26102603。
    老命名 `1.9.2` 仍兼容（→ 10902），免得历史包重打时编号跳变。
    """
    m = re.match(r"^(\d{2})\.(\d{2})\.(\d{2})_(\d{1,2})$", ver)
    if m:
        yy, mm, dd, n = m.groups()
        return int(yy + mm + dd) * 100 + int(n)
    parts = (ver.split(".") + ["0", "0"])[:3]
    return int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2])


def main():
    ver = sys.argv[1] if len(sys.argv) > 1 else "1.1.0"
    os.makedirs(PUB, exist_ok=True)
    shutil.rmtree(STAGE, ignore_errors=True)
    os.makedirs(STAGE)

    # 1) 壳
    for name in os.listdir(SRC):
        s = os.path.join(SRC, name)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(STAGE, name))

    # 1b) webroot：管理器里的「打开」按钮入口（APatch / KernelSU 原生支持）。
    #     Magisk 上游没有 WebView，需要 KsuWebUI / MMRL 之类的宿主才会显示，
    #     但目录带进去无害，不认识的实现直接忽略。
    wr = os.path.join(SRC, "webroot")
    if not os.path.isdir(wr):
        sys.exit("缺少 webroot 目录")
    shutil.copytree(wr, os.path.join(STAGE, "webroot"))

    # 2) 运行集（ELF 架构校验）
    for src, rel in RUNTIME.items():
        if not os.path.isfile(src):
            sys.exit("缺少文件: %s" % src)
        if rel.startswith(("bin/", "lib/")):
            m = elf_machine(src)
            if m != EM_AARCH64:
                sys.exit("架构不对: %s machine=%s（要 aarch64 0xB7）" % (src, hex(m) if m else "非ELF"))
        dst = os.path.join(STAGE, rel.replace("/", os.sep))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)

    # 3) ui 整目录
    ui_src = os.path.join(ROOTFS, "app", "ui")
    if not os.path.isdir(ui_src):
        ui_src = os.path.join(ROOTFS, "ui")
    if not os.path.isdir(ui_src):
        sys.exit("缺少 ui 目录")
    ui_dst = os.path.join(STAGE, "ui")
    shutil.copytree(ui_src, ui_dst)
    ui_files = sum(len(f) for _, _, f in os.walk(ui_dst))

    # 4) module.prop：只换版本号，保留上游版本标注
    mp = os.path.join(STAGE, "module.prop")
    with open(mp, "r", encoding="utf-8") as f:
        raw = f.read()
    up = ""
    for ln in raw.splitlines():
        if ln.startswith("version=") and "(ag2a " in ln:
            up = ln[ln.index("(ag2a "):]
    out = []
    for ln in raw.splitlines():
        if ln.startswith("version="):
            out.append(("version=%s %s" % (ver, up)) if up else ("version=%s" % ver))
        elif ln.startswith("versionCode="):
            out.append("versionCode=%d" % version_code(ver))
        else:
            out.append(ln)
    with open(mp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")

    # 5) 换行统一 LF（Android 上 CRLF 会让 sh 报错）
    for name in SHELLS + ["customize.sh", "lib.sh", "module.prop"]:
        p = os.path.join(STAGE, name)
        if os.path.isfile(p):
            with open(p, "rb") as f:
                data = f.read().replace(b"\r\n", b"\n")
            with open(p, "wb") as f:
                f.write(data)

    zip_path = os.path.join(PUB, "Agent2API-Magisk-v%s.zip" % ver)
    if os.path.exists(zip_path):
        os.remove(zip_path)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, dirs, files in os.walk(STAGE):
            dirs.sort()
            for fn in sorted(files):
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, STAGE).replace(os.sep, "/")
                zi = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
                zi.compress_type = zipfile.ZIP_DEFLATED
                mode = 0o755 if (rel in EXEC or rel.startswith("bin/")) else 0o644
                zi.external_attr = (mode & 0xFFFF) << 16
                with open(full, "rb") as f:
                    z.writestr(zi, f.read())

    size = os.path.getsize(zip_path)
    print("产物: %s" % zip_path)
    print("大小: %.2f MB" % (size / 1048576.0))
    print("ui 文件数: %d" % ui_files)
    with zipfile.ZipFile(zip_path) as z:
        names = z.namelist()
        print("条目数: %d" % len(names))
        tops = sorted({n.split("/")[0] for n in names})
        print("顶层: %s" % ", ".join(tops))


if __name__ == "__main__":
    main()
