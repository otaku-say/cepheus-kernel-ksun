# cepheus-kernel-ksun

小米 9（`cepheus`，SM8150）在 **crDroid 14 / Android 14** 固件上使用的可 root 内核。
基线：crDroid 官方 `android_kernel_xiaomi_cepheus` **16.0 分支（Linux 4.14.355-openela）**；
root：**KernelSU-Next（legacy 分支，manual hook）**，内置而非模块。

产物同时提供三种形态，方便直接嵌进固件包：

| 产物 | 用途 |
|---|---|
| `Image` / `Image.gz-dtb` | 内核本体 |
| `cepheus-kernel-ksun.zip` | AnyKernel3 包，TWRP 直接刷（保持 boot 分区布局） |
| `boot.img` | **与原厂 boot.img 结构逐字节同构**，直接替换固件包里的 `boot.img` |

## 为什么换基线

原 crDroid 14.0 分支最后一笔提交是 2024-08-31（`InfiniR Cepheus v1.31`，4.14.352）。
同一仓库的 `16.0` 分支是 4.14.355、领先 **439 个提交**，且：

- `drivers/kernelsu` 的 Kconfig/Makefile 接线与 14.0 完全一致；
- `fs/exec.c`、`fs/open.c`、`fs/stat.c`、`fs/read_write.c`、`drivers/input/input.c`
  里 **6 个 KernelSU manual hook 调用点全部还在**；
- defconfig 自带 `CONFIG_LOCALVERSION="-InfiniR_cepheus_v2.00_A16_KSUN"` 与 `CONFIG_UNICODE=y`。

也就是说 16.0 分支是"给 KernelSU Next 准备过的"，切换成本几乎为零。

## 为什么只能是 manual hook

4.14 上 KernelSU 系只有一种可行形态，这不是取舍而是硬约束：

- `kernel/hook/syscall_table_hook.c` 里有编译期门禁
  `#if LINUX_VERSION_CODE < KERNEL_VERSION(4,17,0) #error "syscall table hook requires kernel >= 4.17"`；
- `CONFIG_KSU_KPROBES_HOOK` 的 Kconfig 注明 "should not be used on kernel below 5.10"，
  且本内核 `CONFIG_KPROBES` 未开启。

而 manual hook 模式下 setuid / umount 的触发链是
`security_add_hooks(ksu_hooks, …, "ksu")` → `task_fix_setuid` → `ksu_handle_setresuid` → `ksu_handle_umount`，
所以 **KernelSU 必须是 built-in（`obj-y`），不能编译成 late-load 模块**——4.14 的
`security_add_hooks()` 是 `__init`，只有 initcall 阶段注册才有效。

## 与上游集成的两处改进

1. **确定性补丁代替 `$(shell sed -i)`**
   KernelSU 的 `kernel/Kbuild` 会在 make 解析阶段直接 `sed -i` 改内核源码
   （`fs/namespace.c`、`include/linux/seccomp.h`、`security/selinux/*`）。
   并行编译下这跟 `fs/`、`security/` 的编译是竞态的：补丁可能落在编译之后
   （符号未定义）或完全失效，导致同一份源码两次构建结果不同。
   本仓库把**真正必需**的三处改动前置为固定补丁：

   `patches/kernel/*.patch` 是这几处改动的等价补丁（供审阅与上游化），
   而 `scripts/build.sh` 用**等价的幂等内联编辑**落地——这样基线上游改一行上下文
   也不会把构建打断。CI 的 `verify` 任务会拿补丁去 pristine 树上试打，
   一旦上游漂移立刻红。

   | 补丁 | 必要性 |
   |---|---|
   | `kernel/reboot.c` 加 `ksu_handle_sys_reboot` | KernelSU 用它判断 manual hook 是否接入，缺了直接 `$(error)` |
   | `include/linux/seccomp.h` 加 `atomic_t filter_count` | `policy/app_profile.c` 无条件访问该字段 |
   | `security/selinux/include/objsec.h` 加 `selinux_inode()` / `selinux_cred()` | KSU 代码调用这两个 5.x 才有的访问器 |

   其余注入（`path_umount`、`selinux/hooks.c` 访问器重构）在 4.14 上不需要，
   构建脚本会把它们全部注释掉，构建因此可复现。

2. **`allow_shell` 用内核命令行，而不是改源码**
   `allow_shell` 是 `module_param(allow_shell, bool, 0)`，属于内建模块参数。
   推荐在 boot cmdline 里追加：

   ```
   kernelsu.allow_shell=1 kernelsu.force_feature=shell_su_adb_only:1
   ```

   语义：`allowlist.c` 放行 uid 2000，再经 `ksu_shell_su_allowed_for_current()` 校验，
   只有祖先进程是 `adbd` 或 ksu 域时才给 root。这样 `adb shell su` 可用，
   而降权到 shell uid 的应用蹭不到 root —— 比把 `allow_shell` 改成全局 `true` 安全得多，
   而且内核更新后不需要重新打补丁。

## boot.img 与原厂的一致性

`scripts/mkboot_v0.py` 复刻了原厂 boot.img 的完整结构：

```
page 0        boot_img_hdr_v0 (page_size 4096, header_version 0)
page 1        "UNCOMPRESSED_IMG" + u32 len(Image) + raw Image + 追加 DTB(4 个 FDT)
下一 page     lz4-legacy ramdisk（原样保留）
下一 page     AVB0 vbmeta 块（704 B，故意保留旧值：vbmeta flags=3 已关校验）
...补零...
最后 64 B     AvbFooter('AVBf') 指向上面的 vbmeta 块
```

用原厂内核数据回灌验证的结果：**除 header 里 20 字节遗留 `id` 字段外，
与原厂 `boot.img` 逐字节一致**（唯一预期差异）。


## 已验证产物（GitHub Actions run 41802246301，全绿）

| 产物 (ksu 变体) | 大小 | 说明 |
|---|---|---|
| `Image` | 47,953,936 B | `Linux version 4.14.355-openela-InfiniR_cepheus_v2.00_A16_KSUN`，Proton Clang 13 |
| `Image.gz-dtb` | 18,605,797 B | gzip(Image) + 追加 DTB |
| `boot.img` | 134,217,728 B | 与原厂 boot.img 同构（128 MiB 分区大小） |
| `cepheus-kernel-ksun.zip` | 19,819,010 B | AnyKernel3 |

`pure` 变体（`CONFIG_KSU=n`，给 Magisk）：`Image` 47,689,744 B，`boot.img` sha256 `80ac75ad…`。

构建期断言全部通过（缺一个就红）：

```
ok  ksu_handle_execveat / faccessat / stat / vfs_read / sys_reboot /
    input_handle_event / ksu_lsm_hook_init        (vmlinux 中全部定义)
hook refs  fs/exec.o 1 | fs/open.o 1 | fs/stat.o 1 | fs/read_write.o 1
           drivers/input/input.o 1 | kernel/reboot.o 1
ok  shell_su_adb_only present
```

boot.img 结构核对（对照原厂 `crDroidAndroid-14.0-20250523`）：

| | 原厂 | 本次构建 |
|---|---|---|
| 总大小 | 134,217,728 | 134,217,728 |
| kernel 载荷 | `UNCOMPRESSED_IMG`+Image+DTB，49,776,700 | 同结构，49,952,820 |
| ramdisk | lz4，1,996,541 | 同（原样保留） |
| AVB | 页对齐处 704 B vbmeta + 末尾 `AVBf` | 同 |

## 离线兼容性检查（不需要真机）

`scripts/compat-check.sh`（实现是同目录的 `compat_check.py`）每次构建都会跑，
只要有一项失败就让 CI 变红。基线来自原厂 `crDroidAndroid-14.0-20250523` 的 boot.img，
已固化进 `prebuilt/`（`stock-kernel.config` 6050 行、`stock-dtb.sha256`、`stock-ramdisk.sha256`），
所以检查完全离线、可复现。

| 检查 | 判据 |
|---|---|
| config parity | 原厂 1691 个 `=y/=m` 项必须逐项一致（`prebuilt/compat-allowlist.txt` 只放有正当理由的例外） |
| module drift | 不允许把任何驱动变成 `=m`（ROM 没有 `/vendor/lib/modules`） |
| subsystems | binder / binderfs / configfs / FUSE / sdcardfs / dm-verity / SELinux / COMPAT / overlayfs / tmpfs-xattr / ext4 / f2fs / zram 必须 `=y` |
| boot.img shape | 128 MiB、header v0、page 4096、`UNCOMPRESSED_IMG` 包装、AVB 块与尾部 `AvbFooter` |
| device tree | 追加的 4 个 DTB 必须与原厂 hash 集合完全一致 |
| ramdisk | 必须与原厂 ramdisk 逐字节相同 |
| cmdline | 原厂 cmdline 必须是前缀（KSU 变体会在后面追加两个参数） |

本地随时可以跑：

```bash
OUT=./out ./scripts/build.sh          # 构建完自动检查
./scripts/compat-check.sh ./out       # 或单独复检，输出 out/compat-report.md
```

它覆盖的是"驱动/结构/ABI 层面能不能起来"，**不覆盖**引导、闭源 HAL、相机/指纹/基带
这些运行时行为——那一步仍需真机（建议只刷 boot 分区，出问题 `fastboot flash boot` 回滚）。

`CONFIG_SDCARD_FS` 被显式保留：16.0 分支默认关掉了它，而本 ROM 的 `init.rc` /
`installd.rc` 仍会 `chmod`/`mkdir` `/config/sdcardfs`，保持与原厂一致可以消掉这个未知项。

## 构建

```bash
# 本地/沙箱（任意支持 clang 的 Linux）
JOBS=$(nproc) ./scripts/build.sh

# 纯内核（给 Magisk 用，关掉 CONFIG_KSU）
ENABLE_KSU=0 ./scripts/build.sh

# 顺带生成可直接嵌入固件包的 boot.img
RAMDISK=prebuilt/boot.ramdisk.lz4 ./scripts/build.sh
```

关键环境变量：`KERNEL_REF`(16.0)、`KSU_SHA`、`KSU_VERSION_OVERRIDE`(33355)、
`TOOLCHAIN`(host/proton)、`JOBS`、`WORK`、`OUT`。

流水线会自检并在缺失时直接失败：

- `.config` 里 `CONFIG_KSU=y` + `CONFIG_KSU_MANUAL_HOOK=y`；
- `vmlinux` 里 7 个 `ksu_*` 符号全部定义；
- `fs/exec.o`、`fs/open.o`、`fs/stat.o`、`fs/read_write.o`、`drivers/input/input.o`、
  `kernel/reboot.o` 每个都有未定义的 `ksu_` 引用（证明调用点真的编译进去了）。

## 版本口径（为什么钉 e3292239）

KernelSU-Next 的 manager v3.4.2（当前最新 release）只认 `KERNEL_SU_UAPI_VERSION=5`；
legacy 分支 HEAD 已提到 6，会让 manager 弹"管理器版本过低"。
`e3292239` 是 legacy 上最后一个 UAPI=5 的提交，并且正好包含
`shell_su_adb_only` 与 `force_feature` 两个特性，功能不缺。
`KSU_VERSION_OVERRIDE=33355` 对齐 manager 的 versionCode（浅克隆会让 Kbuild 算出版本 1）。

## 刷入

AnyKernel3（推荐，会在设备上就地把 kernel 写进现有 boot 分区）：

1. TWRP → Install → `cepheus-kernel-ksun.zip`
2. 重启
3. 安装 KernelSU-Next Manager（v3.4.2+，包名 `com.rifsxd.ksunext`），打开应显示"工作中"

整包集成：把本仓库产出的 `boot.img` 覆盖进 crDroid OTA 包即可，
`updater-script` 里已有的
`package_extract_file("boot.img", "/dev/block/bootdevice/by-name/boot")` 不需要任何改动；
`dtbo.img` / `vbmeta.img` 保持原样（vbmeta flags=3 已关闭 verity/verification）。

## 已知限制与回归清单

- 4.14 的 manual hook 只覆盖 6 个调用点 + 1 个哨兵；`su` 提权、模块挂载、
  App Profile 的边界行为需实机逐项验证。
- 与 Magisk 二选一：两者抢同一套 hook。`ENABLE_KSU=0` 的产物专供 Magisk。
- 基线从 14.0 换到 16.0 后需回归：充电与温控（`init.mi_thermald`）、相机（MiuiCamera）、
  UDFPS 指纹、WiFi 省电、待机电流、32 位应用。
- 内核不等价于原厂 InfiniR v1.31（后者是 clang 19 + PGO/BOLT 构建），
  性能特征可能有差异；如在意可把 `TOOLCHAIN` 换成与官方一致的预编译 clang。
