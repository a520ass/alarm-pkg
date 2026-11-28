#!/usr/bin/env bash
# build-paru-pkg.sh — arm64 主机上用「常驻 ArchLinuxARM 容器 + paru」构建 AUR / 本地包
#
# 与旧版的区别：
#   * 容器不 --rm：失败也不删，可 `docker exec -it <名字> bash` 进去查
#   * 容器常驻（sleep infinity）：重复运行直接复用，paru 与 base-devel 只装一次
#   * 初始化幂等（/var/.alarm-ready 打标），REFRESH=1 可强制重跑
#
# 用法：
#   ./build-paru-pkg.sh <AUR包名>
#   ./build-paru-pkg.sh <含PKGBUILD的目录>
#   PREDEPS="gcc-arm-none-eabi-bin" ./build-paru-pkg.sh uboot-pinebookpro
#   CLEAN=1 / RESET=1 / REFRESH=1 同 build-pkg.sh
#
# 环境变量：
#   IMG  OUT  NOCHECK  JOBS  NAME
#   PREDEPS="pkg1 pkg2"   构建前先预装，用来钉死虚拟依赖的提供者
#   PARU_VOL=alarm-paru-cache   PACMAN_VOL=alarm-pacman-cache
set -euo pipefail

KIND=paru
IMG=${IMG:-menci/archlinuxarm:base-devel}
OUT=${OUT:-$PWD/out}
PARU_VOL=${PARU_VOL:-alarm-paru-cache}
PACMAN_VOL=${PACMAN_VOL:-alarm-pacman-cache}
NOCHECK=${NOCHECK:-0}
JOBS=${JOBS:-}
PREDEPS=${PREDEPS:-}
TARGET=${1:-}

if [[ -z $TARGET ]]; then
  echo "用法: $0 <AUR包名 | 含PKGBUILD的目录>" >&2
  exit 1
fi

case $TARGET in
  /*) HOSTPATH=$TARGET ;;
  *)  HOSTPATH=$PWD/$TARGET ;;
esac

if [[ -d $HOSTPATH ]]; then
  MODE=local
  [[ -f $HOSTPATH/PKGBUILD ]] || { echo "ERROR: $HOSTPATH 下没有 PKGBUILD" >&2; exit 1; }
  WORKDIR=$(cd "$(dirname "$HOSTPATH")" && pwd)
  SUBDIR=$(basename "$HOSTPATH")
else
  MODE=aur
  WORKDIR=$PWD
  SUBDIR=""
fi

mkdir -p "$OUT"
NAME=${NAME:-alarm-$(printf '%s|%s|%s|%s' "$KIND" "$IMG" "$WORKDIR" "$OUT" | md5sum | cut -c1-10)}

command -v docker >/dev/null || { echo "ERROR: 没有 docker" >&2; exit 1; }

label() { docker inspect -f "{{index .Config.Labels \"$1\"}}" "$NAME" 2>/dev/null || true; }

if [[ ${CLEAN:-0} == 1 ]]; then
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  echo "已清理容器 $NAME"
  exit 0
fi

[[ ${RESET:-0} == 1 ]] && docker rm -f "$NAME" >/dev/null 2>&1 || true

ensure_container() {
  if docker container inspect "$NAME" >/dev/null 2>&1; then
    if [[ $(label alarm.img) != "$IMG" || $(label alarm.work) != "$WORKDIR" || $(label alarm.out) != "$OUT" ]]; then
      echo "==> 旧容器参数对不上（镜像/目录/产物路径变了），重建"
      docker rm -f "$NAME" >/dev/null 2>&1 || true
    else
      if [[ $(docker inspect -f '{{.State.Running}}' "$NAME") != true ]]; then
        docker start "$NAME" >/dev/null
        echo "==> 复用已有容器 $NAME（已启动）"
      else
        echo "==> 复用已有容器 $NAME"
      fi
      return 0
    fi
  fi
  echo "==> 创建容器 $NAME"
  docker run -d --name "$NAME" \
    --label "alarm.img=$IMG" \
    --label "alarm.work=$WORKDIR" \
    --label "alarm.out=$OUT" \
    --platform linux/arm64 \
    --security-opt seccomp=unconfined \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -v "$WORKDIR":/work \
    -v "$OUT":/out \
    -v "$PARU_VOL":/home/builder/.cache/paru \
    -v "$PACMAN_VOL":/var/cache/pacman/pkg \
    -w /work \
    "$IMG" sleep infinity >/dev/null
}

init_once() {
  if [[ ${REFRESH:-0} != 1 ]] && docker exec "$NAME" test -f /var/.alarm-ready >/dev/null 2>&1; then
    echo "==> 容器已初始化，跳过（REFRESH=1 可强制重跑）"
    return 0
  fi
  echo "==> 容器初始化（首次较慢：pacman -Syu + base-devel + paru-bin）"
  docker exec -i \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$NAME" bash -euo pipefail -s <<'INIT'
# pacman 7 的下载沙箱在容器里会被 seccomp 拦掉
grep -qx "DisableSandbox" /etc/pacman.conf || \
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
getent passwd alpm >/dev/null || useradd -r -M -d / -s /usr/bin/nologin alpm

# openssl 必须显式装：paru 动态链接 libssl.so / libcrypto.so
pacman -Syu --noconfirm --needed
pacman -S --noconfirm --needed base-devel sudo git openssl

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" builder
id builder >/dev/null 2>&1 || useradd -m -u "$HOST_UID" -g "$HOST_GID" builder
echo "builder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/builder
mkdir -p /home/builder/.cache/paru
chown -R "$HOST_UID:$HOST_GID" /home/builder 2>/dev/null || true
chown -R "$HOST_UID:$HOST_GID" /out /work 2>/dev/null || true

PACVER=$(pacman -Q pacman | awk '{print $2}')
if [[ $(vercmp "$PACVER" 7.1) == -1 ]]; then
  echo "!! pacman $PACVER 低于 7.1，paru-bin 的 depends 会拒绝安装" >&2
fi

# paru-bin：aarch64 预编译，不编译 Rust
if ! command -v paru >/dev/null 2>&1; then
  echo "==> 安装 paru-bin (aarch64 预编译)"
  rm -rf /tmp/paru-bin
  git clone --depth 1 https://aur.archlinux.org/paru-bin.git /tmp/paru-bin
  chown -R "$HOST_UID:$HOST_GID" /tmp/paru-bin
  if ! ( cd /tmp/paru-bin && sudo -u builder makepkg -si --noconfirm ); then
    echo "!! paru-bin 安装失败，容器保留，可进去手动处理：" >&2
    echo "   cd /tmp/paru-bin && sudo -u builder makepkg -si" >&2
    exit 1
  fi
fi
sudo -u builder paru --version 2>/dev/null | sed -n '1p'

touch /var/.alarm-ready
echo "==> 初始化完成"
INIT
}

echo "==> 模式: $MODE   目标: $TARGET"
echo "==> 容器: $NAME   镜像: $IMG   产物: $OUT"
ensure_container
init_once

echo "==> 开始构建"
set +e
docker exec -i \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e MODE="$MODE" \
  -e SUBDIR="$SUBDIR" \
  -e TARGET="$TARGET" \
  -e NOCHECK="$NOCHECK" \
  -e JOBS="$JOBS" \
  -e PREDEPS="$PREDEPS" \
  "$NAME" bash -euo pipefail -s <<'BUILD'
# ---------- 并行度：makepkg.conf 里 #MAKEFLAGS 默认是注释状态 ----------
JOBS=${JOBS:-$(nproc)}
sed -i '/^#\?MAKEFLAGS=/d' /etc/makepkg.conf
printf 'MAKEFLAGS="-j%s"\n' "$JOBS" >> /etc/makepkg.conf
export MAKEFLAGS="-j$JOBS"
echo "==> MAKEFLAGS=$MAKEFLAGS"

# ---------- 关键：paru 的 PKGBUILD 审查菜单必须显式关掉 ----------
# --noconfirm 只管 pacman 层的确认，管不住 review，无 TTY 环境会直接卡死。
PF=(--noconfirm --skipreview)
[[ $NOCHECK == 1 ]] && PF+=(--mflags "--nocheck")

# ---------- 预装依赖：钉死虚拟依赖的提供者 ----------
if [[ -n ${PREDEPS:-} ]]; then
  echo "==> 预装: $PREDEPS"
  # shellcheck disable=SC2086
  sudo -u builder env MAKEFLAGS="$MAKEFLAGS" \
    paru -S "${PF[@]}" --needed $PREDEPS
fi

if [[ $MODE == local ]]; then
  cd "/work/$SUBDIR"
  # 本地源包优先复用，避免 makepkg 再去下载
  if [[ -d $PWD/.src ]]; then SRCDEST_DIR=$PWD/.src; else SRCDEST_DIR=$PWD; fi
  echo "==> paru -Bi 本地构建，SRCDEST=$SRCDEST_DIR"
  # paru -B 原生吃"含 PKGBUILD 的目录"，AUR 依赖由 paru 自己递归解决
  sudo -u builder env PKGDEST=/out SRCDEST="$SRCDEST_DIR" \
    MAKEFLAGS="$MAKEFLAGS" \
    paru -Bi "${PF[@]}" .
else
  # --batchinstall：依赖链全部构建完再统一安装，比逐包安装快
  sudo -u builder env PKGDEST=/out MAKEFLAGS="$MAKEFLAGS" \
    paru -S "${PF[@]}" --needed --batchinstall "$TARGET"
fi

chown -R "$HOST_UID:$HOST_GID" /out 2>/dev/null || true
BUILD
ST=$?
set -e

if (( ST != 0 )); then
  echo "!! 构建失败（exit $ST），容器 $NAME 已保留，可直接进去排查："
  echo "   docker exec -it $NAME bash"
  [[ $MODE == local ]] && \
    echo "   docker exec -it $NAME bash -lc 'cd /work/$SUBDIR && sudo -u builder paru -Bi --noconfirm --skipreview .'"
  exit "$ST"
fi

echo "== 产物 =="
if compgen -G "$OUT/*.pkg.tar.*" >/dev/null; then
  ls -lh "$OUT"/*.pkg.tar.*
else
  echo "!! /out 里没有包。paru 有时把包留在 ~/.cache/paru，检查："
  echo "   docker exec $NAME find /home/builder/.cache/paru -name '*.pkg.tar.*'"
fi
#（注：内容由AI生成）
