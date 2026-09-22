#!/bin/sh
# 编出 linyapsd 静态链接要用的两个库：libdbus-1.a 和 libexpat.a。
#
# 为什么不直接用发行版的 libdbus-1.so：
#   linyapsd 要能在任何同架构、装了 D-Bus 的机器上跑，不能挑宿主的
#   共享库版本，所以库随包带上、静态链进产物。发行版基本只提供 .so，
#   静态库得自己编。
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

if [ ! -d "dbus-$DBUS_VER" ]; then
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
    cmake -S "$SRC/expat-$EXPAT_VER" -B "$VENDOR/build-expat" \
        -DCMAKE_BUILD_TYPE=Release \
        -DEXPAT_SHARED_LIBS=OFF \
        -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
        -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        >/dev/null
    cmake --build "$VENDOR/build-expat" -j "$(nproc)" >/dev/null
    cmake --install "$VENDOR/build-expat" >/dev/null
fi

# ------------------------------------------------------------------- dbus
# 关掉 systemd / selinux / apparmor / audit / X11：
#   前三个会拖进宿主的一堆库，X11 的 autolaunch 对容器场景没意义
#   （玲珑会把 DBUS_SESSION_BUS_ADDRESS 指到宿主 bus）。
# 只要 libdbus 库，守护进程和命令行工具都不编。
if [ ! -f "$VENDOR/build-dbus/dbus/libdbus-1.a" ]; then
    echo "==> 编静态 libdbus"
    # PKG_CONFIG_LIBDIR 只认我们自己的 prefix，避免误用系统的动态 expat
    PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
    "$MESON" setup "$VENDOR/build-dbus" "$SRC/dbus-$DBUS_VER" \
        --prefix="$PREFIX" --buildtype=release --default-library=static \
        -Dsystemd=disabled -Dselinux=disabled -Dapparmor=disabled -Dlibaudit=disabled \
        -Dx11_autolaunch=disabled -Dlaunchd=disabled -Dkqueue=disabled \
        -Dmessage_bus=false -Dtools=false \
        -Dmodular_tests=disabled -Dinstalled_tests=false \
        -Ddoxygen_docs=disabled -Dducktype_docs=disabled \
        -Dxml_docs=disabled -Dqt_help=disabled \
        >/dev/null
    PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ninja -C "$VENDOR/build-dbus" >/dev/null
fi

echo "==> 依赖就绪"
ls -l "$PREFIX/lib/libexpat.a" "$VENDOR/build-dbus/dbus/libdbus-1.a"
