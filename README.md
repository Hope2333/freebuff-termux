# Freebuff for Termux

**Freebuff** — a free AI coding assistant (the free tier of [Codebuff](https://codebuff.com)), adapted for Android Termux.

## Quick Start

```bash
# 1. Install dependencies
apt install -y glibc-repo && apt update && apt install -y glibc openssl-glibc patchelf
pkg install proot gcc nodejs

# 2. Install freebuff (patches npm package + binary + C wrapper)
bash scripts/install.sh

# 3. Run — no shell rc configuration needed
freebuff --version
```

The first run of `install.sh` automatically downloads about 129MB of binary from GitHub Releases. If your connection is slow, just wait.

## Install from the hope2333 software source (Termux)

Configure the source (one line):

```sh
curl -fsSL https://hope2333.github.io/repo/install.sh | sh
```

Configure + install in one line:

```sh
curl -fsSL https://hope2333.github.io/repo/install.sh | sh -s -- --install freebuff
```

Upgrade later:

```sh
pacman -Syu                    # pacman client
apt update && apt upgrade     # apt client (mirrorlist package updates via the [hope2333-meta] source)
```

Details: https://hope2333.github.io/wiki/guides/install.html

## Architecture Overview

```
Terminal                       freebuff-termux
  │
  ├── /usr/bin/freebuff
  │     └─ C wrapper (Bionic-compiled, native Termux ELF, ~5KB)
  │          ├─ unsetenv(LD_LIBRARY_PATH) etc.
  │          ├─ creates fake /proc/stat (bypasses Android 11+ kernel restriction)
  │          └─ execvp(proot -b /tmp/fake_stat:/proc/stat, binary)
  │                │
  │                ├─ [proot] ptrace-level path redirection
  │                │    └─ /proc/stat reads → fake_stat content
  │                │
  │                └─ ~/.config/manicode/freebuff
  │                     └─ original binary (patchelf'd interpreter)
  │                          └─ glibc ld.so (auto-loads libc.so.6 etc.)
  │
  └── fallback (when proot is unavailable)
       └─ direct execve(binary)
             └─ os.cpus() crashes (/proc/stat unreadable)
```

**Key design decisions**:

- **C wrapper** is compiled as a native Bionic ELF (no glibc dependency). It clears all `LD_*` environment variables to prevent contaminating glibc ld.so.
- **`/proc/stat` fix**: Android 11+ kernels block reading `/proc/stat`. The C wrapper automatically creates a fake stat file and maps it via proot bind mount, allowing libuv's `uv_cpu_info()` to work normally.
- **Binary interpreter** is changed to glibc's ld.so via `patchelf`.
- **glibc `.so` linker scripts** are converted to symlinks (`libc.so -> libc.so.6` etc.) to prevent `dlopen("libc.so")` from loading ASCII text instead of an ELF.

## Current Status

| Step | Status | Notes |
|------|--------|-------|
| npm install (patched os field) | ✅ **Pass** | `npm install -g freebuff` succeeds |
| `android-arm64` platform mapping | ✅ **Pass** | JS wrapper downloads the correct linux-arm64 binary |
| Binary download | ✅ **Pass** | GitHub Releases ~124MB |
| glibc compatibility | ✅ **Pass** | patchelf changes interpreter, binary runs directly |
| `dlopen` compatibility | ✅ **Pass** | Fixed `.so` linker scripts to symlinks |
| Environment variable isolation | ✅ **Pass** | C wrapper clears `LD_*` |
| `/proc/stat` (os.cpus()) | ✅ **Pass** | proot bind mount of fake stat file |
| TUI file browser | ✅ **Pass** | Directory listing, splash, login page all work |
| Auto-update | ⚠️ **Manual reinstall needed** | C wrapper doesn't handle update logic yet |
| Non-`/data/` path | ✅ **Pass** | Works under `/data/data/` as well |

## Solution Details

### Problem 1: npm EBADPLATFORM

`package.json` lists `os: ["darwin", "linux", "win32"]`, but Termux reports `process.platform = "android"`.

**Solution**: Add `"android"` to the os list (`patches/0001-add-android-os-support.patch`).

### Problem 2: JS Wrapper Platform Mapping Missing

`index.js`'s `PLATFORM_TARGETS` has no `android-arm64` entry.

**Solution**: Add the mapping `android-arm64 -> freebuff-linux-arm64.tar.gz` (`patches/0002-add-android-platform-mapping.patch`).

### Problem 3: glibc Compatibility (Binary Runtime)

The downloaded binary is **glibc-linked** (compiled by Bun), but Termux uses Bionic libc.

**Solution**: Use `patchelf --set-interpreter` to change the interpreter to glibc's ld.so:

```bash
patchelf --set-interpreter /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 \
  ~/.config/manicode/freebuff
```

The kernel automatically invokes glibc's ld.so when the binary runs. No `--library-path` argument is needed.

### Problem 4: dlopen + Linker Script Conflict ("invalid ELF header")

In the Termux glibc package, `libc.so`, `libm.so`, and others are **GNU ld scripts (ASCII text)** instead of symlinks. When the Bun binary calls `dlopen("libc.so")` internally, it loads the non-ELF file and gets `invalid ELF header`.

**Solution**:
1. Convert all `*.so` linker scripts to symlinks pointing to `libc.so.N` (versioned ELF files).
2. The C wrapper clears `LD_LIBRARY_PATH` to prevent accidental leaks.

### Problem 5: Environment Variable Pollution

If the parent shell has `LD_LIBRARY_PATH` set, it leaks to glibc's ld.so and causes incorrect library loading.

**Solution**: The C wrapper calls `unsetenv("LD_LIBRARY_PATH")` and does not depend on any shell rc files.

### Problem 6: Android Kernel Restriction on /proc/stat

Android 11+ kernels block unprivileged processes from reading `/proc/stat`, `/proc/loadavg`, and similar files. Bun's libuv calls `uv_cpu_info()`, which reads `/proc/stat`, gets EACCES, and fails with `Failed to get CPU information` (ERR_SYSTEM_ERROR).

**Solution**: Use proot to intercept the `openat` syscall for `/proc/stat` at the ptrace level, redirecting it to a hand-crafted fake file:

```bash
# Fake /proc/stat content (libuv only needs the stat fields to exist)
echo "cpu  0 0 0 0 0 0 0 0 0 0
cpu0 0 0 0 0 0 0 0 0 0 0
..." > /tmp/fake_stat

# proot bind mount
proot -b /tmp/fake_stat:/proc/stat freebuff
```

The C wrapper automatically detects whether proot is available and performs the steps above. Without proot, it falls back to direct execution (and os.cpus() will crash).

### Problem 7: /data/ Directory Restriction (SELinux)

Android's SELinux policy restricts unprivileged processes from reading the contents of `/data/` directories. Some Bun versions may trigger `CouldntReadCurrentDirectory` when scanning parent directories at startup.

**Solution**: This issue has limited impact on specific freebuff versions. The C wrapper may mitigate it through proot.

## Project Structure

```
freebuff-termux/
├── scripts/
│   ├── install.sh                # Fully automated install script
│   └── freebuff-wrapper.c        # C wrapper source code (75 lines)
├── patches/
│   ├── 0001-add-android-os-support.patch
│   └── 0002-add-android-platform-mapping.patch
├── Makefile
└── README.md
```

### `scripts/install.sh`

The fully automated install script does the following:

1. Queries the npm registry for the latest version
2. Downloads the freebuff package with `npm pack`
3. Patches `package.json` to add `android` to the os field
4. Patches `index.js` to add the `android-arm64` platform mapping
5. Runs `termux-fix-shebang` to fix shebang lines
6. Increases the download timeout (20s to 120s)
7. Repacks and installs globally
8. Triggers the binary download (GitHub Releases ~129MB)
9. Runs `patchelf` to set the interpreter to glibc's ld.so
10. Fixes glibc library linker scripts (`.so` to symlinks)
11. Compiles the C wrapper and installs it as `/usr/bin/freebuff`

### `scripts/freebuff-wrapper.c`

A Bionic-compiled C wrapper (~5KB) with this logic:

- Calls `unsetenv()` to clear `LD_LIBRARY_PATH`, `LD_PRELOAD`, and similar variables
- Detects whether proot is available, creates a fake `/proc/stat`, and runs `proot -b` bind mount
- Calls `execvp()` to launch the binary
- Does not depend on bash, zsh, node, or any rc files
- Falls back to direct execve when proot is unavailable

## Dependencies

| Package | Required | Install |
|---------|----------|---------|
| `nodejs` | ✅ Required | `pkg install nodejs` |
| `glibc` | ✅ Required | `apt install -y glibc-repo && apt update && apt install -y glibc` |
| `openssl-glibc` | ✅ Required | `apt install -y openssl-glibc` |
| `patchelf` | ✅ Required | `pkg install patchelf` |
| `gcc` | ✅ Required (compiles C wrapper) | `pkg install gcc` |
| `proot` | ✅ Strongly recommended | `pkg install proot` (without it, os.cpus() crashes) |

## Known Limitations

1. **Auto-update**: Freebuff's auto-update needs the JS wrapper's spawn path. The C wrapper doesn't handle updates yet, so manual reinstall is required.
2. **proot dependency**: Without proot, the CLI crashes due to `os.cpus()` (though `--version` works fine).
3. **glibc dependency**: Requires additional installation of glibc and openssl-glibc.
4. **Network requirement**: First download is ~124MB.
5. **proot performance overhead**: ptrace mode introduces slight I/O latency (imperceptible during interactive TUI use).

## Links

- [Freebuff on npm](https://www.npmjs.com/package/freebuff)
- [Codebuff GitHub](https://github.com/CodebuffAI/codebuff)
- [Codebuff Community Releases](https://github.com/CodebuffAI/codebuff-community/releases)
- [opencode-termux](https://github.com/Hope2333/opencode-termux)
