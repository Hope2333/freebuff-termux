/**
 * freebuff-wrapper.c — Freebuff for Termux launcher
 *
 * Bionic-compiled C wrapper (~5KB ELF) that:
 *   1. Cleans LD_* environment variables to prevent glibc ld.so pollution
 *   2. Detects proot(1) availability, sets up path redirections for /proc/stat
 *   3. LD_PRELOADs hook.so for supplementary glibc function interception
 *   4. Execs the freebuff binary (either under proot or directly)
 *
 * This wrapper does NOT depend on bash, zsh, node, or any rc files.
 * It uses only basic C runtime + standard POSIX syscalls.
 *
 * Build:
 *   gcc -O2 -s -o freebuff-wrapper freebuff-wrapper.c
 *
 * Install:
 *   install -m 755 freebuff-wrapper /usr/bin/freebuff
 *
 * The wrapper locates hook.so and the binary relative to its own
 * installation path:
 *   <prefix>/bin/freebuff         ← this wrapper
 *   <prefix>/lib/freebuff/hook.so ← LD_PRELOAD hook
 *   The freebuff binary path is configured at compile time or
 *   discovered via the installed npm package.
 */
#define _GNU_SOURCE
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/stat.h>
#include <limits.h>
#include <libgen.h>
#include <errno.h>

/* ── Default paths (overridable at build with -D) ─────────────────── */
#ifndef FREEBUFF_BINARY
#  define FREEBUFF_BINARY \
    "/data/data/com.termux/files/home/.config/manicode/freebuff"
#endif
#ifndef HOOK_SO
#  define HOOK_SO \
    "/data/data/com.termux/files/home/develop/freebuff-termux/tools/hook.so"
#endif
#ifndef PROOT_PATH
#  define PROOT_PATH \
    "/data/data/com.termux/files/usr/bin/proot"
#endif
#ifndef FAKE_STAT_PATH
#  define FAKE_STAT_PATH \
    "/data/data/com.termux/files/usr/tmp/.freebuff-proc-stat"
#endif

/* ── Helpers ──────────────────────────────────────────────────────── */
static void xunsetenv(const char *name) {
    /* Ignore error if not set — that's fine */
    (void)unsetenv(name);
}

static int exists(const char *path, int mode_mask) {
    struct stat st;
    if (stat(path, &st) != 0 || (st.st_mode & S_IFMT) == S_IFDIR)
        return 0;
    if (mode_mask == 0)
        return 1;
    return access(path, mode_mask) == 0;
}

static void create_fake_stat(const char *path) {
    /* Write enough data for libuv's uv_cpu_info() to parse.
     * 8 CPU cores with all-zero counters satisfies the parser
     * while avoiding exposing real CPU data (which is restricted
     * on Android 11+). */
    const char *content =
        "cpu  0 0 0 0 0 0 0 0 0 0\n"
        "cpu0 0 0 0 0 0 0 0 0 0 0\n"
        "cpu1 0 0 0 0 0 0 0 0 0 0\n"
        "cpu2 0 0 0 0 0 0 0 0 0 0\n"
        "cpu3 0 0 0 0 0 0 0 0 0 0\n"
        "cpu4 0 0 0 0 0 0 0 0 0 0\n"
        "cpu5 0 0 0 0 0 0 0 0 0 0\n"
        "cpu6 0 0 0 0 0 0 0 0 0 0\n"
        "cpu7 0 0 0 0 0 0 0 0 0 0\n"
        "intr 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
        " 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"
        "ctxt 0\n"
        "btime 0\n"
        "processes 0\n"
        "procs_running 1\n"
        "procs_blocked 0\n"
        "softirq 0 0 0 0 0 0 0 0 0 0\n";

    FILE *f = fopen(path, "w");
    if (!f) return;
    fwrite(content, 1, strlen(content), f);
    fclose(f);
    chmod(path, 0644);
}

/* ── argv builder ─────────────────────────────────────────────────── */
typedef struct {
    char **argv;
    int cap, len;
} Argv;

static Argv *argv_new(int hint) {
    Argv *a = malloc(sizeof(Argv));
    a->cap = hint ? hint : 16;
    a->len = 0;
    a->argv = malloc(a->cap * sizeof(char *));
    return a;
}

static void argv_add(Argv *a, const char *s) {
    if (a->len >= a->cap - 1) {
        a->cap *= 2;
        a->argv = realloc(a->argv, a->cap * sizeof(char *));
    }
    a->argv[a->len++] = strdup(s);
}

static void argv_emit(Argv *a) {
    a->argv[a->len] = NULL;
}

/* ── Main ─────────────────────────────────────────────────────────── */
int main(int argc, char *argv[], char *envp[]) {
    /* 1. Strip LD_* variables that would poison glibc ld.so */
    xunsetenv("LD_LIBRARY_PATH");
    xunsetenv("LD_PRELOAD");
    xunsetenv("LD_DEBUG");
    xunsetenv("LD_BIND_NOW");
    xunsetenv("LD_ORIGIN_PATH");
    xunsetenv("LD_RUN_PATH");
    xunsetenv("GLIBC_LD_LIBRARY_PATH");

    /* 2. Check if user explicitly wants to skip proot */
    int use_proot = 1;
    int user_argc = argc;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-proot") == 0) {
            use_proot = 0;
            user_argc--;
        }
    }

    /* 3. Check proot availability */
    int has_proot = use_proot && exists(PROOT_PATH, X_OK);

    /* 4. Check hook.so and binary availability */
    int has_hook = exists(HOOK_SO, R_OK);
    int has_binary = exists(FREEBUFF_BINARY, X_OK);

    if (!has_binary) {
        fprintf(stderr, "freebuff-wrapper: binary not found at %s\n"
                "Run 'freebuff --version' to trigger download, or\n"
                "reinstall via: bash <(curl -sL https://...) install.sh\n",
                FREEBUFF_BINARY);
        return 1;
    }

    /* 5. Build argv */
    Argv *cmd = argv_new(4 + user_argc);

    if (has_proot) {
        /* Create fake /proc/stat for os.cpus() */
        create_fake_stat(FAKE_STAT_PATH);

        cmd->argv[cmd->len++] = (char *)PROOT_PATH;
        cmd->argv[cmd->len++] = "-b";
        char bind_arg[512];
        snprintf(bind_arg, sizeof(bind_arg), "%s:/proc/stat",
                 FAKE_STAT_PATH);
        cmd->argv[cmd->len++] = strdup(bind_arg);
    }

    /* 6. Set LD_PRELOAD for hook.so (setenv before exec, but after
     *    unsetenv above — we selectively re-introduce our own hook).
     *    This is done via env manipulation in exec, not via argv. */
    if (has_hook) {
        setenv("LD_PRELOAD", HOOK_SO, 1);
    }

    /* 7. Append binary + original args (skip --no-proot) */
    cmd->argv[cmd->len++] = (char *)FREEBUFF_BINARY;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-proot") != 0)
            cmd->argv[cmd->len++] = argv[i];
    }
    argv_emit(cmd);

    /* 8. Exec */
    execvp(cmd->argv[0], cmd->argv);

    /* 9. Fallback: exec without proot */
    if (has_proot) {
        fprintf(stderr, "freebuff-wrapper: proot exec failed (%m), "
                "falling back to direct exec\n");
    }

    /* Build direct execve call */
    char **fb = malloc((user_argc + 1) * sizeof(char *));
    fb[0] = (char *)FREEBUFF_BINARY;
    int fi = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--no-proot") != 0)
            fb[fi++] = argv[i];
    }
    fb[fi] = NULL;

    execve(FREEBUFF_BINARY, fb, environ);
    fprintf(stderr, "freebuff-wrapper: execve %s failed: %m\n",
            FREEBUFF_BINARY);
    return 1;
}
