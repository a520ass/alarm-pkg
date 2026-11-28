#!/usr/bin/env bash
# build-pkg.sh — arm64 主机上用「常驻 ArchLinuxARM 容器」makepkg 构建本地 PKGBUILD
#
# 与旧版的区别：
#   * 容器不 --rm：失败也不删，可 `docker exec -it <名字> bash` 进去查
#   * 容器常驻（sleep infinity）：重复运行直接复用，初始化只做一次
#   * 初始化幂等：装了 base-devel / 建了 builder / 改过 makepkg.conf 都只跑一遍
#
# 用法：
#   ./build-pkg.sh <含PKGBUILD的目录>
#   CLEAN=1   ./build-pkg.sh <目录>     # 只删容器，不构建
#   RESET=1   ./build-pkg.sh <目录>     # 删容器重建（换了 IMG 或 OUT 时）
#   REFRESH=1 ./build-pkg.sh <目录>     # 强制重跑容器初始化（pacman -Syu + 装包）
#
# 环境变量：
#   IMG=menci/archlinuxarm:base-devel   OUT=./out   NOCHECK=1   JOBS=8
#   NAME=<自定义容器名>   PACMAN_VOL=alarm-pacman-cache
set -euo pipefail

KIND=plain
IMG=${IMG:-menci/archlinuxarm:base-devel}
OUT=${OUT:-$PWD/out}
PACMAN_VOL=${PACMAN_VOL:-alarm-pacman-cache}
NOCHECK=${NOCHECK:-0}
JOBS=${JOBS:-}
TARGET=${1:-}

if [[ -z $TARGET ]]; then
  echo "用法: $0 <含PKGBUILD的目录>" >&2
  exit 1
fi

case $TARGET in
  /*) HOSTPATH=$TARGET ;;
  *)  HOSTPATH=$PWD/$TARGET ;;
esac

[[ -d $HOSTPATH ]] || { echo "ERROR: $HOSTPATH 不是目录" >&2; exit 1; }
[[ -f $HOSTPATH/PKGBUILD ]] || { echo "ERROR: $HOSTPATH/PKGBUILD 不存在" >&2; exit 1; }

WORKDIR=$(cd "$(dirname "$HOSTPATH")" && pwd)
SUBDIR=$(basename "$HOSTPATH")
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
    -v "$PACMAN_VOL":/var/cache/pacman/pkg \
    -w /work \
    "$IMG" sleep infinity >/dev/null
}

init_once() {
  if [[ ${REFRESH:-0} != 1 ]] && docker exec "$NAME" test -f /var/.alarm-ready >/dev/null 2>&1; then
    echo "==> 容器已初始化，跳过（REFRESH=1 可强制重跑）"
    return 0
  fi
  echo "==> 容器初始化（首次较慢：pacman -Syu + base-devel）"
  docker exec -i \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$NAME" bash -euo pipefail -s <<'INIT'
# pacman 7 的下载沙箱在容器里会被 seccomp 拦掉
grep -qx "DisableSandbox" /etc/pacman.conf || \
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
getent passwd alpm >/dev/null || useradd -r -M -d / -s /usr/bin/nologin alpm

pacman -Syu --noconfirm --needed
pacman -S --noconfirm --needed base-devel sudo git

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" builder
id builder >/dev/null 2>&1 || useradd -m -u "$HOST_UID" -g "$HOST_GID" builder
echo "builder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/builder
chown -R "$HOST_UID:$HOST_GID" /out /work 2>/dev/null || true

touch /var/.alarm-ready
echo "==> 初始化完成"
INIT
}

echo "==> 目标: $TARGET"
echo "==> 容器: $NAME   镜像: $IMG   产物: $OUT"
ensure_container
init_once

echo "==> 开始构建 $SUBDIR"
set +e
docker exec -i \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e SUBDIR="$SUBDIR" \
  -e NOCHECK="$NOCHECK" \
  -e JOBS="$JOBS" \
  "$NAME" bash -euo pipefail -s <<'BUILD'
# ---------- 并行度：makepkg.conf 里 #MAKEFLAGS 默认是注释状态 ----------
JOBS=${JOBS:-$(nproc)}
sed -i '/^#\?MAKEFLAGS=/d' /etc/makepkg.conf
printf 'MAKEFLAGS="-j%s"\n' "$JOBS" >> /etc/makepkg.conf
export MAKEFLAGS="-j$JOBS"
echo "==> MAKEFLAGS=$MAKEFLAGS"

cd "/work/$SUBDIR"

# 本地源包优先复用，避免 makepkg 判定缺失后再联网下载
if [[ -d $PWD/.src ]]; then SRCDEST_DIR=$PWD/.src; else SRCDEST_DIR=$PWD; fi
echo "==> SRCDEST=$SRCDEST_DIR"

MF=()
[[ $NOCHECK == 1 ]] && MF+=(--nocheck)
# sudo 默认 env_reset 会把 MAKEFLAGS 冲掉，必须显式带进去
sudo -u builder env PKGDEST=/out SRCDEST="$SRCDEST_DIR" \
  MAKEFLAGS="$MAKEFLAGS" \
  makepkg -sf --noconfirm "${MF[@]}"

chown -R "$HOST_UID:$HOST_GID" /out 2>/dev/null || true
BUILD
ST=$?
set -e

if (( ST != 0 )); then
  echo "!! 构建失败（exit $ST），容器 $NAME 已保留，可直接进去排查："
  echo "   docker exec -it $NAME bash"
  echo "   docker exec -it $NAME bash -lc 'cd /work/$SUBDIR && sudo -u builder makepkg -f'"
  exit "$ST"
fi

echo "== 产物 =="
if compgen -G "$OUT/*.pkg.tar.*" >/dev/null; then
  ls -lh "$OUT"/*.pkg.tar.*
else
  echo "!! 构建通过但 /out 里没有包，检查 PKGBUILD 的 package() 是否真产出了文件。"
fi
#（注：内容由AI生成）
