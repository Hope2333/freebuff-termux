# Freebuff for Termux

**Freebuff** — 免费的 AI 编程助手（[Codebuff](https://codebuff.com) 的免费版），适配 Android Termux。

## 快速开始

```bash
# 1. 安装依赖
apt install -y glibc-repo && apt update && apt install -y glibc openssl-glibc patchelf
pkg install proot gcc nodejs

# 2. 安装 freebuff（patch npm 包 + binary + C wrapper）
bash scripts/install.sh

# 3. 运行——无需 shell rc 配置
freebuff --version
```

首次运行 `install.sh` 会从 GitHub Releases 自动下载约 129MB 的二进制文件（若网络慢等待即可）。

## 架构概览

```
终端                          freebuff-termux
  │
  ├── /usr/bin/freebuff
  │     └─ C 包装器（Bionic 编译，原生 Termux ELF，~5KB）
  │          ├─ unsetenv(LD_LIBRARY_PATH) 等
  │          ├─ 创建假 /proc/stat（绕过 Android 11+ 内核限制）
  │          └─ execvp(proot -b /tmp/fake_stat:/proc/stat, binary)
  │                │
  │                ├─ [proot] ptrace 级路径重定向
  │                │    └─ /proc/stat 读取 → fake_stat 内容
  │                │
  │                └─ ~/.config/manicode/freebuff
  │                     └─ 原始 binary（patchelf 改 interpreter）
  │                          └─ glibc ld.so（自动加载 libc.so.6 等）
  │
  └── fallback（无 proot 时）
       └─ 直接 execve(binary)
             └─ os.cpus() 会崩溃（/proc/stat 不可读）
```

**关键设计**：
- **C 包装器**编译为原生 Bionic ELF（不依赖 glibc），清除所有 `LD_*` 环境变量，防止 glibc ld.so 被污染
- **`/proc/stat` 修复**：Android 11+ 内核禁止读取 `/proc/stat`。C 包装器自动创建假 stat 文件，通过 proot bind mount 映射，让 libuv 的 `uv_cpu_info()` 正常工作
- **Binary 的 interpreter** 通过 `patchelf` 改为 glibc 的 ld.so
- **glibc 的 `.so` 链接脚本**改为 symlink（`libc.so → libc.so.6` 等），防止 `dlopen("libc.so")` 加载到 ASCII 文本而非 ELF

## 当前状态

| 步骤 | 状态 | 说明 |
|------|------|------|
| npm 安装（patch os 字段） | ✅ **通过** | `npm install -g freebuff` 成功 |
| `android-arm64` 平台映射 | ✅ **通过** | JS 包装器能正确下载 linux-arm64 binary |
| Binary 下载 | ✅ **通过** | GitHub Releases ~124MB |
| glibc 兼容性 | ✅ **通过** | patchelf 改 interpreter → 直接执行 |
| `dlopen` 兼容性 | ✅ **通过** | 修复 `.so` 链接脚本为 symlink |
| 环境变量隔离 | ✅ **通过** | C 包装器清除 `LD_*` |
| `/proc/stat` （os.cpus()） | ✅ **通过** | proot bind mount 假 stat 文件 |
| TUI 文件浏览器 | ✅ **通过** | 目录列表、splash、登录页均正常 |
| 自动更新 | ⚠️ **需手动重装** | C 包装器暂不处理更新逻辑 |
| 非 `/data/` 路径 | ✅ **通过** | `/data/data/` 下也可工作 |

## 解决方案详解

### 问题 1：npm EBADPLATFORM

`package.json` 中 `os: ["darwin", "linux", "win32"]`，Termux 上报 `process.platform = "android"`。

**方案**：添加 `"android"` 到 os 列表（`patches/0001-add-android-os-support.patch`）。

### 问题 2：JS 包装器平台映射缺失

`index.js` 的 `PLATFORM_TARGETS` 没有 `android-arm64`。

**方案**：添加映射 `android-arm64 → freebuff-linux-arm64.tar.gz`（`patches/0002-add-android-platform-mapping.patch`）。

### 问题 3：glibc 兼容性（Binary 运行）

下载的 binary 是 **glibc-linked** (Bun 编译)，Termux 是 Bionic libc。

**方案**：`patchelf --set-interpreter` 将 interpreter 改为 glibc ld.so：
```bash
patchelf --set-interpreter /data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1 \
  ~/.config/manicode/freebuff
```
binary 直接运行时内核自动调用 glibc ld.so，不再需要 `--library-path` 参数。

### 问题 4：dlopen + 链接脚本冲突（"invalid ELF header"）

Termux glibc 包中 `libc.so`、`libm.so` 等是 **GNU ld 脚本（ASCII 文本）** 而非 symlink。Bun binary 内部 `dlopen("libc.so")` 时会加载到非 ELF 文件 → 报 `invalid ELF header`。

**方案**：
1. 将所有 `*.so` 链接脚本改为 symlink → `libc.so.N`（版本化 ELF）
2. C 包装器清除 `LD_LIBRARY_PATH` 防止意外泄露

### 问题 5：环境变量污染

父 shell 如果设了 `LD_LIBRARY_PATH`，会泄露给 glibc ld.so，导致错误加载。

**方案**：C 包装器内 `unsetenv("LD_LIBRARY_PATH")`，不依赖任何 shell rc 文件。

### 问题 6：Android 内核限制 /proc/stat 不可读

Android 11+ 内核禁止非特权进程读取 `/proc/stat`、`/proc/loadavg` 等。Bun 的 libuv 调用 `uv_cpu_info()` → 读取 `/proc/stat` → EACCES → `Failed to get CPU information`（ERR_SYSTEM_ERROR）。

**方案**：通过 proot 在 syscall 级别劫持 `/proc/stat` 的 `openat` 系统调用，重定向到自制假文件：
```bash
# 假 /proc/stat 内容（libuv 只需要 stat 字段存在即可）
echo "cpu  0 0 0 0 0 0 0 0 0 0
cpu0 0 0 0 0 0 0 0 0 0 0
..." > /tmp/fake_stat

# proot bind mount
proot -b /tmp/fake_stat:/proc/stat freebuff
```

C 包装器自动检测 proot 可用性并执行上述操作。无 proot 时 fallback 到直接执行（os.cpus() 会崩溃）。

### 问题 7：/data/ 目录限制（SELinux）

Android 的 SELinux 策略限制非特权进程读取 `/data/` 目录内容。某些 Bun 版本在启动时扫描父目录时可能触发 `CouldntReadCurrentDirectory`。

**方案**：此问题在 freebuff 特定版本中影响有限。C 包装器通过 proot 可能缓解该问题。

## 项目结构

```
freebuff-termux/
├── scripts/
│   ├── install.sh                # 全自动安装脚本
│   └── freebuff-wrapper.c        # C 包装器源码（75 行）
├── patches/
│   ├── 0001-add-android-os-support.patch
│   └── 0002-add-android-platform-mapping.patch
├── Makefile
└── README.md
```

### `scripts/install.sh`
全自动完成：
1. 查询 npm registry 获取最新版本
2. `npm pack` 下载 freebuff 包
3. 修改 `package.json` → 添加 `android` 到 os
4. 修改 `index.js` → 添加 `android-arm64` 映射
5. `termux-fix-shebang` → shebang 修复
6. 增加下载超时（20s → 120s）
7. 重新打包，全局安装
8. 触发 binary 下载（GitHub Releases ~129MB）
9. `patchelf` → 修改 interpreter 为 glibc ld.so
10. 修复 glibc lib 链接脚本（`.so` → symlink）
11. 编译 C 包装器，安装为 `/usr/bin/freebuff`

### `scripts/freebuff-wrapper.c`
Bionic 编译的 C 包装器 (~5KB)，逻辑：
- `unsetenv()` 清除 `LD_LIBRARY_PATH`、`LD_PRELOAD` 等
- 检测 proot 可用性，创建假 `/proc/stat`，执行 `proot -b` 绑定
- `execvp()` 运行 binary
- 不依赖 bash、zsh、node 或任何 rc 文件
- 无 proot 时 fallback 到直接 execve

## 依赖

| 包 | 必要性 | 安装 |
|----|--------|------|
| `nodejs` | ✅ 必需 | `pkg install nodejs` |
| `glibc` | ✅ 必需 | `apt install -y glibc-repo && apt update && apt install -y glibc` |
| `openssl-glibc` | ✅ 必需 | `apt install -y openssl-glibc` |
| `patchelf` | ✅ 必需 | `pkg install patchelf` |
| `gcc` | ✅ 必需（编译 C wrapper） | `pkg install gcc` |
| `proot` | ✅ 强烈推荐 | `pkg install proot`（无 proot 时 os.cpus() 崩溃） |

## 已知限制

1. **自动更新**：freebuff 自动更新需 JS 包装器的 spawn 路径（C 包装器暂不处理更新，需手动重装）
2. **proot 依赖**：无 proot 时 CLI 会因 `os.cpus()` 崩溃（`--version` 不受影响）
3. **glibc 依赖**：需要额外安装 glibc + openssl-glibc
4. **网络要求**：首次下载 ~124MB
5. **proot 性能开销**：ptrace 模式会引入轻微 I/O 延迟（处理交互式 TUI 时无感）

## 链接

- [Freebuff on npm](https://www.npmjs.com/package/freebuff)
- [Codebuff GitHub](https://github.com/CodebuffAI/codebuff)
- [Codebuff Community Releases](https://github.com/CodebuffAI/codebuff-community/releases)
- [opencode-termux](https://github.com/Hope2333/opencode-termux)
