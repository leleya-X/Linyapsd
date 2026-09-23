# Linyapsd

玲珑（Linyaps）应用在宿主机侧的小助手。一个 Zig 写的 D-Bus 服务，
完全静态链接，除 Linux 内核外不依赖宿主的任何东西。

## 它解决什么问题

玲珑容器把 `/` 挂成只读 overlay，不提供 `/var/lib`，也没有宿主那套共享库。于是容器内的应用：

- 读不到 `/var/lib/linglong/states.json` —— 已安装应用列表的唯一来源
- 跑不动 `ll-cli` —— 缺 `libostree` 等宿主库

但玲珑容器**并不隔离两样东西**：

- `$HOME`（容器和宿主是同一个目录，可读写）
- session bus 的 socket `$XDG_RUNTIME_DIR/bus`（容器内实测 `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`）

所以应用可以往 `~/.local/share/dbus-1/services/` 放一份**最标准的 D-Bus 服务文件**，
由宿主的 session bus 按需把本程序拉起来，替它做上面两件事。数据通过 D-Bus 返回值直传，
不落盘、不需要中转文件。

## 接口

| | |
|---|---|
| bus name | `io.github.leleya_x.Linyapsd` |
| 对象路径 | `/io/github/leleya_x/Linyapsd` |
| 接口 | `io.github.leleya_x.Linyapsd.Manager` |

| 方法 | 签名 | 说明 |
|---|---|---|
| `Ping` | `() -> s` | 返回 `pong` |
| `Version` | `() -> s` | 版本号 |
| `ReadStates` | `() -> s` | 宿主 `/var/lib/linglong/states.json` 全文 |
| `ExecLlCli` | `as -> iss` | 跑 ll-cli 只读子命令，返回 `(退出码, stdout, stderr)` |
| `Quit` | `() -> s` | 让本实例退出，下次调用由 bus 重新拉起 |

调用方全部退出后它也会自己走，见下面「没人用了就自己退出」。

`ExecLlCli` 只接受白名单子命令：`list`、`info`、`search`、`ps`。
不经过 shell，参数原样交给 `execv`，所以不存在命令注入；白名单挡的是不该被远程触发的子命令。

命令行上还认两个参数：

```bash
linyapsd --version    # 打印版本号，退出 0（-V 同义）
linyapsd              # 正常提供服务
```

认不出的参数会报错并退出 2，不会当作没看见然后照常起服务。

**接口刻意做窄：没有任何能改动宿主数据的方法。** `Quit` 是唯一的例外，
但它只关乎本进程自己的生命周期，不碰文件、不跑 ll-cli。
它存在的理由是：部署方换上新版本后，文件换了不等于新版本生效 ——
旧进程还占着 bus name 的话，调用照旧由它响应，从外面完全看不出已经换了。
有了 `Quit` 就能请它让位，下次调用拉起的就是新的。

### 没人用了就自己退出

既然是被 bus 按需拉起来的，没人在用的时候也不该继续待在内存里。
所以它会记住谁调用过自己（调用方的 D-Bus 唯一名，`:1.23` 这种），
订阅 `NameOwnerChanged`，等这些连接都从总线上消失就自己退出；
下次有人调用时，bus 照服务文件重新拉起一个。实测调用方退出后 0.1 秒内消失。

"调用方"是连接级、不是进程级：进程崩了、被 `kill -9` 了、被窗口管理器关掉了，
连接一样由内核关掉，总线一样会报出来。所以这件事不指望应用配合 ——
`Quit` 是给部署方换版本用的，退出不依赖它。

另有一种空转：程序被 `StartServiceByName` 单独叫起来，调用方却没跟上来。
那种情况下它没被谁调用过，也就没人会记得它、更没人会来划掉它，
所以另设一道：起来满 30 秒还没有任何人调用就收工。计时掐的是单调时钟，
不是把每轮的等待加起来 —— 总线上别的连接进进出出都会推广播过来打断每一轮，
累加出来的时长会远小于真实经过的时间。

信号里那三个参数读不齐就当没这条，不去猜：宁可多留一会儿，
也不能凭一条没读懂的消息就断定调用方已经走光了。

## 构建

需要 Zig 0.16+、cmake、ninja、python3、curl。

```bash
./tools/build-deps.sh          # 编静态依赖，只需跑一次
zig build -Doptimize=ReleaseSmall
# 产物：zig-out/bin/linyapsd，约 500 KB，statically linked
```

`zig build` 默认按 **musl** 编（`build.zig` 里的默认 target），不跟宿主的
libc 走；显式传 `-Dtarget=...` 时以传进去的为准。理由见下面「[为什么按 musl 编](#为什么按-musl-编)」。

### 为什么要自己编依赖

产物的目标是「任何同架构、装了 D-Bus 的机器都能直接跑」，所以不能挑宿主的共享库版本。
发行版基本只提供 `libdbus-1.so`，静态库得自己编；而 Arch 的 `libdbus-1.so` 还额外拖一个
`libsystemd.so`。

`tools/build-deps.sh` 因此从源码编出两份静态库（都落在 `vendor/`，不往系统里装）：

- `libexpat.a` —— dbus 解析 XML 要用
- `libdbus-1.a` —— 编的时候关掉 systemd / selinux / apparmor / audit / X11 autolaunch，
  这些要么会拖进宿主的库，要么在本场景用不上

库和源码都在 `vendor/` 下，已 gitignore，随时可以删掉重来。
脚本用项目内的虚拟环境装 meson，系统的 python 环境不受影响。

**这两个库也得按 musl 编。** 它们是最终产物的一部分，用宿主那套 glibc 的
gcc 编出来的 `.a` 链不进 musl 程序。所以脚本不用宿主编译器，而是把
`zig cc -target <arch>-linux-musl` 包一层当 CC/CXX/AR —— zig 自带头文件和
libc，不需要另外装 sysroot 或 musl-gcc。换工具链整个重编，脚本里有个
stamp 记着上次用的 triple，对不上就把旧产物丢掉重来，免得 glibc 和 musl
的 `.a` 混着用。

### 为什么按 musl 编

「静态链接」本身只保证产物不带 `.so` 依赖，不保证它不依赖宿主的**数据**。
glibc 的静态库会把 NSS、locale、gconv、DNS 那一整套一起链进去：现在一个都
不调，所以看不出问题；等哪天代码里多一次 `getpwuid()` 或 `setlocale()`，
静态 glibc 下就会在运行时静默失败（它要去 dlopen `libnss_*.so.2`，而静态
程序没有那个动态加载环境），locale、时区同理。这种坑在开发机上永远复现不了，
只有拿到别的机器上才炸。

musl 没有这层包袱：对应的功能都是直接读文件（`/etc/passwd`、`/usr/share/zoneinfo`），
读不到就是读不到，不会在运行时去找共享库。代价是产物对这些文件的位置有硬编码，
但它们本来就是「装了 D-Bus 的 Linux」的同义词。

顺带产物也从 1.5 MB 缩到 500 KB —— glibc 那套整块链进来的东西本来就没用上。

### D-Bus 协议用 libdbus，不自己实现

早先这里有一套手写的协议栈（SASL 握手、头字段编解码全自己来），图的是零依赖。
结果它在**服务激活**这条路径上栽了跟头：手工启动一切正常，由 bus 按需拉起时，
挂起的那个调用永远收不到投递。

原因不是规范写错，而是规范之外实现必须遵守的细节太多 —— 认证起始的那个特殊 nul 字节、
broker 如何把新连接认领回它刚拉起的 unit …… 这类东西自造一遍划不来。
换成 libdbus 之后激活立刻正常。

如果哪天想重新捡起自写实现，先想清楚这些细节怎么处理。

## 部署

落点**不带任何应用 ID**，全宿主共用一份 —— 它是通用助手，不是哪个应用的私有部件：

```bash
# 1. 装到固定位置
install -Dm755 zig-out/bin/linyapsd "$HOME/.local/share/linyapsd/linyapsd"

# 2. 写 D-Bus 服务文件
mkdir -p "$HOME/.local/share/dbus-1/services"
cat > "$HOME/.local/share/dbus-1/services/io.github.leleya_x.Linyapsd.service" <<EOF
[D-BUS Service]
Name=io.github.leleya_x.Linyapsd
Exec=$HOME/.local/share/linyapsd/linyapsd
EOF

# 3. 让 session bus 重新扫描一次（只需一次，见下）
kill -HUP "$(ps -eo pid,args --no-headers \
  | awk '/dbus-broker-launch --scope user/ && !/at-spi/ {print $1; exit}')"
```

验证：

```bash
dbus-send --session --print-reply --dest=io.github.leleya_x.Linyapsd \
  /io/github/leleya_x/Linyapsd io.github.leleya_x.Linyapsd.Manager.ReadStates
```

### 第 3 步为什么只需要一次

`dbus-broker-launch` 在**启动时**扫描各个 service 目录，并对扫到的目录挂 inotify 监听。
关键在 `launcher_load_service_dir()`：

```c
dir = opendir(dirpath);
if (!dir) {
        if (errno == ENOENT || errno == ENOTDIR) {
                return 0;          // 目录不存在 —— 直接跳过，不挂监听
        }
        ...
}
r = dirwatch_add(launcher->dirwatch, dirpath);
```

也就是说，如果 `~/.local/share/dbus-1/services/` 在 session bus 启动时**还不存在**
（全新系统上通常如此），那个目录就永远不会被监听，之后往里放文件也不会被识别，
调用时会得到 `org.freedesktop.DBus.Error.ServiceUnknown: The name is not activatable`。

一旦目录存在并被扫到、监听挂上，后续增删改 `.service` 文件都会自动触发 reload：

```
dbus-broker-launch[1308]: Noticed file-system modification, trigger reload.
```

SIGHUP 走的是 `launcher_reload_config()`，只重新读配置、重新扫描目录并重挂监听，
**不重启 bus、不断开已有连接**。

所以：只要做一次「建目录 + HUP」，之后就永久自动。也可以不做 HUP，注销重登一次效果相同。

## 设计与边界

**不依赖 systemd。** 本程序不带 unit 文件、不知道 systemd 存在，只做两件事：
占一个 bus name、响应方法调用。

**但底层由谁拉起，取决于发行版选了哪个 bus 实现**，这不是本程序能决定的：

| session bus | activation 时谁 fork |
|---|---|
| `dbus-daemon`（传统） | daemon 自己 |
| `dbus-broker`（Arch 等） | broker 转交 systemd，生成瞬态单元 `dbus-<name>@<n>.service` |

同一份 `linyapsd` 在两种实现下都能工作 —— libdbus 会处理这两种情况。
**可移植性只取决于架构相同、且 host 上有 D-Bus**：库都静态链进产物了，
宿主的 libc 版本、有没有 libdbus、有没有 systemd 都不影响。

**出错不静默。** ll-cli 输出超出缓冲、D-Bus 回复发不出去，都会如实报错，
而不是截断后当完整结果返回、或让调用方一直干等到超时。

**安全性没有变化。** 这条链路本质上仍是「借宿主的某个进程在宿主命名空间里 fork」，
和直接写 systemd unit 一样是容器逃逸。D-Bus 只是让接口更规范、痕迹更少（不留 unit 文件、
不留中转文件、清理只需删两个文件），并不提升隔离性。

**清理：**

```bash
rm -f  ~/.local/share/dbus-1/services/io.github.leleya_x.Linyapsd.service
rm -rf ~/.local/share/linyapsd
```

（落点是共用的，删之前先确认没有别的应用还在用它。）

## 许可证

GPL-2.0-only，见 [LICENSE](LICENSE)。本程序是 [LinyapsSeal](https://github.com/leleya-X/Linyaps-Seal)
的组成部分，作为独立仓库维护在 <https://github.com/leleya-X/Linyapsd>，沿用其上游许可证。
