# CI 踩坑记录（2026-11）

这条流水线从"看起来成功"到真正产出内核，前后 6 次运行，每个问题都值得记下来。

## 1. `| tee` 会吞掉失败

```yaml
run: ./scripts/build.sh 2>&1 | tee build.log   # ❌ 永远 exit 0
```

第一次运行显示 success，产物里只有一个 2.5 KB 的 `build.log`。
必须加 `set -o pipefail`。

## 2. `git -C dir apply` 配合相对路径补丁

```bash
git -C /tmp/k apply --check "$p"   # ❌ $p = patches/... 相对当前目录
```
`git -C` 先切换目录，于是 git 去 `/tmp/k/patches/...` 找文件。要用绝对路径，
或者干脆不 clone 整个内核、只抓三个被测文件用 `patch -p1 --dry-run`（现在的做法，秒级完成）。

## 3. dtc 的 libyaml

runner 上 `pkg-config --exists yaml-0.1` 成立 → `scripts/dtc/Makefile` 把
`yamltree.o` 编进来并加 `-lyaml`；但 host link 走的是 proton-clang 里的 `ld`，
于是 `yaml_*` 全部 undefined。

修法：构建前把那段 `ifeq` 判断整体替换成
`HOST_EXTRACFLAGS += -DNO_YAML`（我们从不需要 dtc 输出 YAML）。

**注意**：这段逻辑一开始被我放进了 `if ENABLE_KSU:` 分支，pure 变体因此没生效、
继续在同一个地方挂掉。教训是"与 root 无关的构建修补必须放在两个变体都经过的路径上"。

## 4. 32 位 compat vDSO 用的是 `CROSS_COMPILE_COMPAT`

```make
# arch/arm64/kernel/vdso32/Makefile
LD_COMPAT ?= $(CROSS_COMPILE_COMPAT)ld
```

只设 `CROSS_COMPILE_ARM32` 不够：`ld` 会退回宿主 x86 的 ld，报
`cannot represent machine 'arm'`。两个变量都要设成 ARM32 前缀
（Ubuntu 上 `apt install gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi`
提供 `arm-linux-gnueabi-`）。

## 5. 相对路径的 `RAMDISK` 在 `cd` 之后失效

打包步骤运行时 CWD 已经是内核树，`[ -f "prebuilt/boot.ramdisk.lz4" ]` 为假，
boot.img 被静默跳过；而 `upload-artifact` 的 `if-no-files-found: warn`
让这一步看起来仍然成功。现在：输入一律按 `REPO_ROOT` 解析，缺文件直接 `exit 1`。

## 6. CRLF

Windows 上写的 `.sh` 工作副本是 CRLF（commit 时被 autocrlf 转回 LF）。
一旦哪天 autocrlf 被关掉，runner 上就会得到 `bad interpreter` 或
heredoc 找不到 `PYEOF`。现在有 `.gitattributes` 强制 `*.sh/*.py/*.patch/*.yml` 为 LF。

## 7. 失败时也要拿到日志

`upload-artifact` 加 `if: always()`，否则失败的运行只留下一个空产物列表，
排错只能靠 `actions/jobs/<id>/logs` 接口。
