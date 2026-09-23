#!/bin/sh
# 编出 linyapsd 静态链接要用的两个库：libdbus-1.a 和 libexpat.a。
#
# 为什么不直接用发行版的 libdbus-1.so：
#   linyapsd 要能在任何同架构、装了 D-Bus 的机器上跑，不能挑宿主的
#   共享库版本，所以库随包带上、静态链进产物。发行版基本只提供 .so，
#   静态库得自己编。
#
# 用 zig 自带的 musl 工具链，不用宿主的 gcc：
#   产物最终要链进 musl 静态程序，glibc 工具链编出来的 .a 链不进去。
#   zig 自带 musl 的头文件和 libc，不需要额外装 sysroot 或 musl-gcc。
#   换工具链必须整个重编，所以下面有个 stamp 记着上次用的是哪条 triple。
#
# 产物都落在 vendor/（已 gitignore）：
#   vendor/prefix/lib/libexpat.a
#   vendor/build-dbus/dbus/libdbus-1.a
# 全过程用项目内的虚拟环境和本地 prefix，不往系统里装任何东西。
#
# 只在构建 linyapsd 之前跑一次即可；重复跑会跳过已完成的步骤。

set -eu

cd "$(dirname "$0")/.."
ROOT=$PWD
VENDOR=$ROOT/vendor
PREFIX=$VENDOR/prefix
SRC=$VENDOR/src

EXPAT_VER=2.7.1
DBUS_VER=1.16.2
EXPAT_TAG=$(echo "$EXPAT_VER" | tr . _)
DBUS_TAR=dbus-$DBUS_VER.tar.gz
# gitlab 的 archive tarball 顶层目录会再带一层项目名前缀，解出来是
# dbus-dbus-1.16.2 而不是 dbus-1.16.2 —— 底下按这个名找源码目录
DBUS_SRCDIR=dbus-dbus-$DBUS_VER

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少 $1，请先安装" >&2
        exit 1
    }
}

need_cmd cmake
need_cmd ninja
need_cmd python3
need_cmd curl
need_cmd zig

# ------------------------------------------------------------------ 工具链
# 目标 triple 跟本机架构走，和 build.zig 的默认 target 一致。
case "$(uname -m)" in
    x86_64|amd64)  ZARCH=x86_64 ;;
    aarch64|arm64) ZARCH=aarch64 ;;
    riscv64)       ZARCH=riscv64 ;;
    loongarch64)   ZARCH=loongarch64 ;;
    *) echo "不认识的架构：$(uname -m)" >&2; exit 1 ;;
esac
TRIPLE=$ZARCH-linux-musl

# cmake 和 meson 只收一个可执行文件路径，给不了带空格的一整条命令，
# 所以把 zig 包成几个小脚本。
mkdir -p "$VENDOR"
TOOLDIR=$VENDOR/toolchain
mkdir -p "$TOOLDIR"
wrap() {  # wrap <包装名> <zig 子命令> [参数...]
    name=$1; shift
    printf '#!/bin/sh\nexec zig %s "$@"\n' "$*" > "$TOOLDIR/$name"
    chmod +x "$TOOLDIR/$name"
}
wrap cc cc -target "$TRIPLE"
wrap c++ c++ -target "$TRIPLE"
wrap ar ar
wrap ranlib ranlib

# 构建命令的输出平时收进日志，失败时原样吐出来再退出。
# 不能简单写 >/dev/null：这些工具并不都把错误发到 stderr（meson 就发到
# stdout），一重定向就只剩个退出码，出了事无从下手。
LOG=$VENDOR/build.log
run_quiet() {
    if ! "$@" >"$LOG" 2>&1; then
        echo "==> 失败：$*" >&2
        cat "$LOG" >&2
        rm -f "$LOG"
        exit 1
    fi
    rm -f "$LOG"
}

# 工具链一换，之前那批 .a 就作废 —— glibc 编的链不进 musl 程序。
# stamp 对不上就把产物整个丢掉重来。
STAMP=$VENDOR/.deps-toolchain
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$TRIPLE" ]; then
    LAST=$([ -f "$STAMP" ] && cat "$STAMP" || echo "无")
    echo "==> 依赖要按 $TRIPLE 重编（上次：$LAST）"
    rm -rf "$VENDOR/build-expat" "$VENDOR/build-dbus" "$VENDOR/prefix/lib/libexpat.a"
    echo "$TRIPLE" > "$STAMP"
fi

# ---------------------------------------------------------------- 虚拟环境
# meson 只装进 vendor/venv，系统里的 python 环境不动。
if [ ! -x "$VENDOR/venv/bin/meson" ]; then
    echo "==> 建虚拟环境并装 meson"
    mkdir -p "$VENDOR"
    python3 -m venv "$VENDOR/venv"
    "$VENDOR/venv/bin/pip" install --quiet meson
fi
MESON=$VENDOR/venv/bin/meson

# ------------------------------------------------------------------ 源码
mkdir -p "$SRC"
cd "$SRC"

if [ ! -d "expat-$EXPAT_VER" ]; then
    if [ ! -f "$EXPAT_TAR" ]; then
        echo "==> 下载 expat $EXPAT_VER"
        curl -sL -o "$EXPAT_TAR" \
            "https://github.com/libexpat/libexpat/releases/download/R_$EXPAT_TAG/expat-$EXPAT_VER.tar.gz"
    fi
    tar xf "$EXPAT_TAR"
fi

if [ ! -d "$DBUS_SRCDIR" ]; then
    if [ ! -f "$DBUS_TAR" ]; then
        echo "==> 下载 dbus $DBUS_VER"
        curl -sL -o "$DBUS_TAR" \
            "https://gitlab.freedesktop.org/dbus/dbus/-/archive/dbus-$DBUS_VER/dbus-dbus-$DBUS_VER.tar.gz"
    fi
    tar xf "$DBUS_TAR"
fi

# ------------------------------------------------------------------ expat
# dbus 用 expat 解析 XML，静态库得自己编一份。
if [ ! -f "$PREFIX/lib/libexpat.a" ]; then
    echo "==> 编静态 expat"
    run_quiet cmake -S "$SRC/expat-$EXPAT_VER" -B "$VENDOR/build-expat" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$TOOLDIR/cc" \
        -DCMAKE_AR="$TOOLDIR/ar" -DCMAKE_RANLIB="$TOOLDIR/ranlib" \
        -DEXPAT_SHARED_LIBS=OFF \
        -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
        -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib
    run_quiet cmake --build "$VENDOR/build-expat" -j "$(nproc)"
    run_quiet cmake --install "$VENDOR/build-expat"
fi

# ------------------------------------------------------------------- dbus
# 关掉 systemd / selinux / apparmor / audit / X11：
#   前三个会拖进宿主的一堆库，X11 的 autolaunch 对容器场景没意义
#   （玲珑会把 DBUS_SESSION_BUS_ADDRESS 指到宿主 bus）。
# 只要 libdbus 库，守护进程和命令行工具都不编。
if [ ! -f "$VENDOR/build-dbus/dbus/libdbus-1.a" ]; then
    echo "==> 编静态 libdbus"
    # PKG_CONFIG_LIBDIR 只认我们自己的 prefix，避免误用系统的动态 expat
    # CC/CXX/AR 走上面那层 zig 包装，meson 会记进它生成的 native file
    run_quiet env PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
        CC="$TOOLDIR/cc" CXX="$TOOLDIR/c++" AR="$TOOLDIR/ar" \
        "$MESON" setup "$VENDOR/build-dbus" "$SRC/$DBUS_SRCDIR" \
        --prefix="$PREFIX" --buildtype=release --default-library=static \
        -Dsystemd=disabled -Dselinux=disabled -Dapparmor=disabled -Dlibaudit=disabled \
        -Dx11_autolaunch=disabled -Dlaunchd=disabled -Dkqueue=disabled \
        -Dmessage_bus=false -Dtools=false \
        -Dmodular_tests=disabled -Dinstalled_tests=false \
        -Ddoxygen_docs=disabled -Dducktype_docs=disabled \
        -Dxml_docs=disabled -Dqt_help=disabled
    run_quiet env PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ninja -C "$VENDOR/build-dbus"
fi

echo "==> 依赖就绪"
ls -l "$PREFIX/lib/libexpat.a" "$VENDOR/build-dbus/dbus/libdbus-1.a"
