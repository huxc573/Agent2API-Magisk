/*
 * spawnhook - 让 glibc 插件在缺少 /lib/ld-linux-aarch64.so.1 的 Android 上跑起来
 *
 * 背景：插件是 glibc 二进制，ELF 里 PT_INTERP 写死 /lib/ld-linux-aarch64.so.1。
 *       Android 根目录没有 /lib（部分 ROM 直接删了），execve 返回 ENOENT。
 *       网关是 execve 直接拉起插件的，落盘即执行，中间没有可干预的时机。
 *
 * 做法：网关本身是用模块自带的 ld.so 拉起来的（service.sh 里那行 loader --library-path），
 *       所以给它设 LD_PRELOAD=libspawnhook.so 即可拦截它所有 spawn 调用：
 *       发现目标 ELF 的解释器不存在、且就是 /lib/ld-linux-aarch64.so.1，
 *       就改成用模块自带的 loader 拉起同一个文件。
 *
 * 不改网关、不改插件、不动系统分区、不抢时间窗口 -> 网页内安装/升级全部零感知。
 *
 * 开关：存在 /data/adb/ag2a/spawnhook.off 时完全旁路（排障用）。
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <spawn.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <elf.h>
#include <stdio.h>

#ifndef AG2A_LOADER
#define AG2A_LOADER "/data/adb/modules/ag2a/lib/ld-linux-aarch64.so.1"
#endif
#ifndef AG2A_LIBDIR
#define AG2A_LIBDIR "/data/adb/modules/ag2a/lib"
#endif
#define AG2A_KILL_SWITCH "/data/adb/ag2a/spawnhook.off"

/* 插件 ELF 里写死的解释器；只有命中它才接管，bionic 程序（/system/bin/*）一律不碰 */
static const char kWant[] = "/lib/ld-linux-aarch64.so.1";

static int disabled(void)
{
    return access(AG2A_KILL_SWITCH, F_OK) == 0;
}

/* 读 ELF 的 PT_INTERP，判断是不是需要接管。返回 1 = 需要。 */
static int wants_hijack(const char *path)
{
    if (!path || path[0] != '/')
        return 0;

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 0;

    unsigned char eh[sizeof(Elf64_Ehdr)];
    ssize_t n = read(fd, eh, sizeof eh);
    if (n != (ssize_t)sizeof eh || memcmp(eh, ELFMAG, SELFMAG) != 0) {
        close(fd);
        return 0;
    }

    const Elf64_Ehdr *e = (const Elf64_Ehdr *)eh;
    if (e->e_ident[EI_CLASS] != ELFCLASS64 || e->e_phoff == 0 || e->e_phnum == 0 ||
        e->e_phentsize != sizeof(Elf64_Phdr)) {
        close(fd);
        return 0;
    }

    int hit = 0;
    for (int i = 0; i < e->e_phnum; i++) {
        Elf64_Phdr ph;
        if (pread(fd, &ph, sizeof ph, (off_t)(e->e_phoff + (off_t)i * sizeof ph)) !=
            (ssize_t)sizeof ph)
            break;
        if (ph.p_type != PT_INTERP || ph.p_filesz == 0 || ph.p_filesz > 256)
            continue;
        char buf[257];
        if (pread(fd, buf, ph.p_filesz, (off_t)ph.p_offset) != (ssize_t)ph.p_filesz)
            break;
        buf[ph.p_filesz] = '\0';
        if (strcmp(buf, kWant) == 0)
            hit = 1;
        break;
    }
    close(fd);
    return hit;
}

/* 需要接管就返回 1，并给出新的 argv（调用方负责 free） */
static int build_argv(const char *path, char *const argv[], char *const envp[], char ***out)
{
    (void)envp;
    if (disabled() || !wants_hijack(path))
        return 0;
    /* 解释器已经能直接找到就没必要插手（例如别家 ROM 有 /lib） */
    if (access(kWant, X_OK) == 0)
        return 0;
    if (access(AG2A_LOADER, X_OK) != 0)
        return 0;

    int argc = 0;
    if (argv)
        while (argv[argc])
            argc++;

    /* [loader, --library-path, libdir, 原路径, 原 argv[1..], NULL] */
    char **na = (char **)calloc((size_t)argc + 4, sizeof(char *));
    if (!na)
        return 0;
    int k = 0;
    na[k++] = (char *)AG2A_LOADER;
    na[k++] = (char *)"--library-path";
    na[k++] = (char *)AG2A_LIBDIR;
    na[k++] = (char *)path;
    for (int i = 1; i < argc; i++)
        na[k++] = argv[i];
    na[k] = NULL;
    *out = na;
    return 1;
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa,
                const posix_spawnattr_t *attr, char *const argv[], char *const envp[])
{
    static int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                       const posix_spawnattr_t *, char *const[], char *const[]);
    if (!real)
        real = (int (*)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                        const posix_spawnattr_t *, char *const[], char *const[]))
            dlsym(RTLD_NEXT, "posix_spawn");
    char **na = NULL;
    if (real && build_argv(path, argv, envp, &na)) {
        int rc = real(pid, AG2A_LOADER, fa, attr, na, envp);
        free(na);
        return rc;
    }
    return real ? real(pid, path, fa, attr, argv, envp) : -1;
}

int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa,
                 const posix_spawnattr_t *attr, char *const argv[], char *const envp[])
{
    static int (*real)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                       const posix_spawnattr_t *, char *const[], char *const[]);
    if (!real)
        real = (int (*)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                        const posix_spawnattr_t *, char *const[], char *const[]))
            dlsym(RTLD_NEXT, "posix_spawnp");
    char **na = NULL;
    if (real && build_argv(file, argv, envp, &na)) {
        int rc = real(pid, AG2A_LOADER, fa, attr, na, envp);
        free(na);
        return rc;
    }
    return real ? real(pid, file, fa, attr, argv, envp) : -1;
}

int execve(const char *path, char *const argv[], char *const envp[])
{
    static int (*real)(const char *, char *const[], char *const[]);
    if (!real)
        real = (int (*)(const char *, char *const[], char *const[]))dlsym(RTLD_NEXT, "execve");
    char **na = NULL;
    if (real && build_argv(path, argv, envp, &na)) {
        real(AG2A_LOADER, na, envp);
        free(na);
    }
    return real ? real(path, argv, envp) : -1;
}

int execv(const char *path, char *const argv[])
{
    extern char **environ;
    return execve(path, argv, environ);
}

int execvp(const char *file, char *const argv[])
{
    extern char **environ;
    return execve(file, argv, environ);
}
