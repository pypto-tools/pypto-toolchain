# 在一台机器上部署 bundle

[English](deployment.md) | 中文

README 讲的是 bundle 是什么、为什么存在。这份讲怎么把它装到一台机器上，以及部署
实际会卡在哪里——大多和代理有关，而且都不是从错误信息里看得出来的。

## 宿主机契约

bundle 几乎不依赖宿主机，但"几乎"不是"完全"：

| 宿主机提供 | 谁检查 | 为什么 |
| --- | --- | --- |
| aarch64 或 x86_64 | `install.sh`，下载前 | 只构建了这两个架构 |
| glibc >= 2.28 | `install.sh`，下载前 | bundle 构建时的下限 |
| `binutils`（`as`、`ld`） | `doctor`、`verify` | GCC 驱动的是系统汇编器和链接器 |
| `glibc-devel` / `libc6-dev`（`crt1.o`、`libc.so`） | `doctor`、`verify` | 每次链接都要的 C 运行时启动文件 |
| multiarch 布局（如果是） | `install` 检测并自动适配 | GCC 的库搜索路径在 configure 时固化——见文末 |

装任何东西之前，先手工预检：

```bash
uname -m                          # aarch64 或 x86_64
ldd --version | head -1           # >= 2.28
cat /etc/os-release               # RHEL 系或 Debian 系，都支持
command -v as ld                  # binutils
gcc -print-file-name=crt1.o       # 要得到一个存在的绝对路径，而不是裸的 "crt1.o"
```

最后一条和 `verify` 用的是同一个手法。GCC 找不到文件时会把裸文件名原样回显，所以
只回显 `crt1.o` 表示"缺"，回显 `/usr/lib64/crt1.o`（Debian 和 Ubuntu 上是
`/usr/lib/x86_64-linux-gnu/crt1.o`）表示包已经装了。

在一台已经能构建 PyPTO 的机器上，这些通常本来就齐——**先查，再决定要不要动包管理器**。

## 代理：sudo 会丢掉你的环境

这是部署最常卡住的地方，而且它失败得很安静：下载不是被拒绝，是**卡住**。

```bash
export https_proxy=http://127.0.0.1:7892
sudo pypto-toolchain install 2026.08.5     # 里面的 curl 走直连
```

`sudo` 默认 `env_reset`，清空白名单之外的一切。你 export 的代理到不了 `install.sh`
里的 `git`，也到不了 `install` 里的 `curl`。三条出路，按可靠性排序：

### `sudo env VAR=value cmd`——推荐

```bash
sudo env https_proxy=http://127.0.0.1:7892 \
     /usr/local/bin/pypto-toolchain install 2026.08.5
```

sudo 看到的是一个叫 `env` 的命令加一串参数，它完全不知道这里涉及环境变量，策略层
无从拦截。**这在任何 sudoers 配置下都成立**——在一台不是你配的机器上，这一点很重要。

一个注意点：目标命令是由 `env` 按 sudo 的 `secure_path` 去找的，而它不一定包含
`/usr/local/bin`。像上面那样写绝对路径最省事。

管道安装同样可以，`env` exec 出来的 `bash` 照样继承 stdin：

```bash
curl -fsSL .../install.sh | sudo env https_proxy=http://127.0.0.1:7892 bash
```

### `sudo VAR=value cmd`

这里的赋值是**给 sudo 的参数**，除非该用户在 sudoers 里带 `SETENV`，或者变量名匹配
`env_keep`/`env_check`，否则会被直接拒绝：

```
sudo: sorry, you are not allowed to set the following environment variables: https_proxy
```

自己的机器上没问题，别人的机器上是碰运气。

### 写进 `/etc/pypto-env.conf` 的 `export`

持久生效。它能绕过 sudo 的原因值得理解：`install.sh` 和 CLI **都是自己 source 这个
文件的**，发生在 sudo 清空环境**之后**。

```bash
sudo tee -a /etc/pypto-env.conf > /dev/null <<'EOF'

# pypto-toolchain: 只有 install.sh 和 install 这两个联网步骤需要
export https_proxy="http://127.0.0.1:7892"
export http_proxy="http://127.0.0.1:7892"
export no_proxy="localhost,127.0.0.0/8,::1,10.0.0.0/8,192.168.0.0/16"
EOF
```

`export` 不能省：`curl` 和 `git` 是子进程，sourced 文件里的普通赋值只是当前 shell
的变量。注意这个文件里可能已有的条目（`PTOAS_ROOT`、`ASCEND_HOME_PATH` …）是**刻意
不 export** 的——它们由 `pypto-toolchain export` 读出来再自己发。**追加，不要照着它们
的风格改写。**

URL 里带凭据的话，给文件 `chmod 600`。另外也该想想一个全机器共享的文件适不适合放个人
代理：只有两条命令需要它，`sudo env` 往往是更合适的形状。`doctor` 打印代理时会把
userinfo 脱敏，因为那份报告经常被贴进工单。

`sudo -E` 是第四种，不推荐：它仍受 `env_keep` 白名单约束，能不能带过代理因机器而异。

### `127.0.0.1` 指的是**被部署的那台机器**

跑在你本地的代理，在目标机器上不是 `127.0.0.1:7892`。先在目标机器上测：

```bash
curl -sI --connect-timeout 5 -x http://127.0.0.1:7892 https://github.com | head -1
# HTTP/1.1 200 Connection established
```

不在的话，要么让代理监听 LAN 地址后用真实 IP，要么从有代理的那台机器开隧道：

```bash
ssh -R 7892:127.0.0.1:7892 <目标机器>
```

### 只有两步需要网络

`use`、`verify`、`doctor` 以及之后所有对工具链的使用都不联网。代理不好搞的话，它只被
CLI 的 clone 和 bundle 的下载需要——而这两件事都有离线替代（见下）。

## 完整流程

```bash
# 1. 宿主机那一半（上面的预检已经通过就跳过）
sudo dnf install -y binutils glibc-devel git tar findutils diffutils

# 2. 装 CLI —— 约 50 KB 脚本，不装 bundle
curl -fsSL https://raw.githubusercontent.com/pypto-tools/pypto-toolchain/main/install.sh \
  | sudo env https_proxy=http://127.0.0.1:7892 bash -s -- --storage /data/pypto

# 3. 在决定下载 200 MB 之前，先勘察这台机器
pypto-toolchain doctor

# 4. 下载、校验、解压
sudo env https_proxy=http://127.0.0.1:7892 \
     /usr/local/bin/pypto-toolchain install 2026.08.5

# 5. 选中并验证
sudo /usr/local/bin/pypto-toolchain use 2026.08.5
pypto-toolchain verify
```

第 2 步不碰机器上任何别的东西：不装 rpm、不替换系统 Python 或 GCC、除了你自己加的
那行代理之外不改 `/etc`、conda 环境原封不动。第 5 步的 `use` 只是挪一个符号链接。
在有消费者 source `activate.sh` 之前，**对正在运行的东西没有任何影响**，所以不用挑
窗口期。

然后：

```bash
source /opt/pypto/toolchain/2026.08.5/activate.sh
```

## bundle 落在哪

`/opt/pypto/toolchain/<版本>` 编译进了二进制，所以**路径字符串**是固定的。物理位置不
固定——`--storage` 把 `/opt/pypto` 指到更宽裕的文件系统：

```
/opt/pypto              -> /data/pypto     (--storage 建的符号链接)
  app/                  CLI 的 checkout
  toolchain/<版本>/     bundle 本体
  toolchain/current     -> <版本>
  cache/                下载的 tarball
```

如果 `/opt/pypto` 已存在且不是符号链接，`--storage` 会拒绝执行。先 `ls -ld /opt/pypto`
确认。

两个别放的地方：

- **home 目录或 CI 工作区。** CLI 当初就是为此从 `/home/pypto-tools` 搬走的，
  `install.sh` 至今还在提示那个旧布局。工作区清理、用户配额、家目录备份工具，都会把
  200 MB × N 个版本当成该回收或该复制的东西。
- **NFS。** `root_squash` 会让 root 的解压写不进去，而且从 NFS 跑编译器慢得能感觉到。
  选位置前先 `df -T <路径>`。

卸载就是对存储目录 `rm -rf`，加上删掉 `/usr/local/bin/pypto-toolchain`。

## 没有到 GitHub 的通路时

release 的实际资源由 `objects.githubusercontent.com` 提供，有些机器
`raw.githubusercontent.com` 通但它不通。缓存会在任何下载之前被检查，且 sha256 无论
来源如何都会校验，所以**任何搬运方式都一样安全**。

单机旁路：

```bash
scp pypto-toolchain-2026.08.5-aarch64.tar.gz <目标机器>:/tmp/
ssh <目标机器> 'sudo cp /tmp/pypto-toolchain-2026.08.5-aarch64.tar.gz /opt/pypto/cache/ \
                && sudo pypto-toolchain install 2026.08.5'
```

给整个机群供货——会在 GitHub release 之前被尝试，而且完全不需要代理：

```bash
echo 'PYPTO_TOOLCHAIN_MIRROR=http://<内网主机>:8080/toolchain' \
  | sudo tee -a /etc/pypto-env.conf
```

如果连 `install.sh` 都 clone 不动，把带过去的 checkout 指给它：

```bash
sudo PYPTO_TOOLCHAIN_REPO=/path/to/pypto-toolchain bash /path/to/install.sh --storage /data/pypto
```

## 故障排查

| 症状 | 成因 | 解法 |
| --- | --- | --- |
| `install` 卡住，没有进度 | 代理没能通过 `sudo` | `sudo env https_proxy=... <绝对路径> install <版本>` |
| `sorry, you are not allowed to set the following environment variables` | 用了 `sudo VAR=value` 但没有 `SETENV` | 改用 `sudo env` |
| `could not obtain a bundle matching sha256` | `objects.githubusercontent.com` 不可达 | 旁路塞进 cache，或设 `PYPTO_TOOLCHAIN_MIRROR` |
| 链接器报 `cannot find crt1.o` | 缺 C 运行时开发包 | `dnf install glibc-devel`，或 `apt install libc6-dev` |
| Debian/Ubuntu 上已装 `libc6-dev` 仍报 `cannot find crt1.o` | multiarch specs 文件没写成，或被重装冲掉了 | `pypto-toolchain install <版本> --force` |
| `verify` 的 `prefix matches build` 失败 | 解压位置不是 `/opt/pypto/toolchain/<版本>` | 重装；前缀是编译进去的，不能配置 |
| `doctor` 报 `no conda under …` 但提示符是 `(base)` | 它查的是 `${CONDA_ROOT:-$HOME/miniconda3}` | `CONDA_ROOT="$(conda info --base)" pypto-toolchain doctor` |
| `dnf` 在 repodata 上报 403 | 宿主机自己的软件源问题，与本工具无关 | `dnf clean all`；再不行换镜像源，或者预检已通过就直接跳过 |

`doctor` 的 migration notes（`no ccache on PATH`、某个 conda 环境里装了 pypto）**从不
阻塞安装**。它们描述的是这台机器今天所处的状态，迁移完成后会自动消失。

## Debian 和 Ubuntu

支持，`install` 会自动完成唯一需要的那一步适配。

GCC 解析 `crt1.o` 和架构相关的 glibc 头文件，走的是 configure 时固化进去的搜索路径，
也就是构建镜像的 RHEL 布局（`/usr/lib64`、`/usr/include`）；Debian 和 Ubuntu 用的是
multiarch 三元组目录（`/usr/lib/x86_64-linux-gnu`）。装 `libc6-dev` 能把文件放到磁盘
上，但放不到编译器会去找的地方，于是链接失败，报出来的 `crt1.o` 看着像 bundle 损坏。

`install` 的做法是往 GCC 自己的 lib 目录里写一个 specs 文件：

```
*self_spec:
+ -B/usr/lib/x86_64-linux-gnu -idirafter /usr/include/x86_64-linux-gnu
```

GCC 会**自动加载**这个位置的 specs 文件，所以没有任何下游需要记住一个参数，也没有
任何 CI job 需要导出环境变量。三个细节值得说明：

- **用 `-B` 而不是 `LIBRARY_PATH`。** `-B` 参与 `-print-file-name` 所查的 startfile
  搜索，所以 `verify` 的 crt 检查和链接本身是同一个理由通过的。`LIBRARY_PATH` 不被
  `-print-file-name` 查询，这正是旧变通办法即使能编译、那项检查也仍然是红的原因。
- **用 `-idirafter` 而不是 `-I`。** multiarch 头文件目录排在最后，bundle 自带的 C++
  头文件优先级不受影响。已在 Ubuntu 24.04 上确认：`<format>` 仍然解析到 bundle 内部。
- **靠行为检测，不读 `/etc/os-release`。** 只有在编译器找不到 `crt1.o` **且**
  `/usr/lib/*/crt1.o` 存在时才写这个文件。RHEL 机器因此永远不会拿到 specs 文件。

最后一条是正确性要求，不是洁癖。在一台 `ld.so.conf` 里挂了第二份 GCC 的 `libgcc_s`
的机器上——手工部署的 `/data/software/gcc-15`，正是这个 bundle 要消灭的那种漂移——
**只要存在**用户 specs 文件，C++ 链接就会以 `DSO missing from command line` 失败，
跟文件内容无关。无条件写入等于为了修 Debian 而弄坏本来正常的 RHEL 机器。

这个文件在版本前缀内部，所以 `install --force` 和每次版本升级都会重新生成，不需要
额外维护。

### 已验证

Ubuntu 24.04.3，x86_64，glibc 2.39，CANN 9.2.0：`verify` 十二项全过。用 `-std=c++23`
编出的共享库能通过 `ctypes` 加载，链接 `libascendcl.so` 没有 `@GLIBC_2.xx` 版本冲突。

### 为什么不配 sysroot

配 sysroot 是教科书解法，但在这里是错的解法。它会把工具链**产出物**的 glibc 版本也
钉死——今天在 2.34 宿主上构建的产物就要求 2.34，跟 bundle 自己声明的下限无关。更麻烦
的是，sysroot 里的 glibc 必须不低于产出物所链接的每一个宿主库的 glibc，CANN 也在内；
而那个版本是机器绑定的、不在 bundle 里，于是 bundle 反过来要追着它本该抽象掉的那个
fleet 走。sysroot 还会把宿主的 `/usr/include` 整个遮蔽，三个 PyPTO 仓库依赖的每一个
系统头文件都要显式列出并长期维护。这是设计变更，不是配置变更。
