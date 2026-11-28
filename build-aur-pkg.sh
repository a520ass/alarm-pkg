#!/usr/bin/env bash
# build-aur-pkg.sh — arm64 主机上用「常驻 ArchLinuxARM 容器 + yay」构建 AUR / 本地包
#
# 与旧版的区别：
#   * 容器不 --rm：失败也不删，可 `docker exec -it <名字> bash` 进去查
#   * 容器常驻（sleep infinity）：重复运行直接复用，yay 与 base-devel 只装一次
#   * 初始化幂等（/var/.alarm-ready 打标），REFRESH=1 可强制重跑
#
# 用法：
#   ./build-aur-pkg.sh <AUR包名>
#   ./build-aur-pkg.sh <含PKGBUILD的目录>
#   CLEAN=1 / RESET=1 / REFRESH=1 同 build-pkg.sh
#
# 环境变量：
#   IMG  OUT  NOCHECK  JOBS  NAME
#   PREDEPS="pkg1 pkg2"   构建前先预装，用来钉死虚拟依赖的提供者
#   YAY_VOL=alarm-yay-cache   PACMAN_VOL=alarm-pacman-cache
set -euo pipefail

KIND=yay
IMG=${IMG:-menci/archlinuxarm:base-devel}
OUT=${OUT:-$PWD/out}
YAY_VOL=${YAY_VOL:-alarm-yay-cache}
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
    -v "$YAY_VOL":/home/builder/.cache/yay \
    -v "$PACMAN_VOL":/var/cache/pacman/pkg \
    -w /work \
    "$IMG" sleep infinity >/dev/null
}

init_once() {
  if [[ ${REFRESH:-0} != 1 ]] && docker exec "$NAME" test -f /var/.alarm-ready >/dev/null 2>&1; then
    echo "==> 容器已初始化，跳过（REFRESH=1 可强制重跑）"
    return 0
  fi
  echo "==> 容器初始化（首次较慢：pacman -Syu + base-devel + yay-bin）"
  docker exec -i \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$NAME" bash -euo pipefail -s <<'INIT'
# pacman 7 的下载沙箱在容器里会被 seccomp 拦掉
grep -qx "DisableSandbox" /etc/pacman.conf || \
  sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
getent passwd alpm >/dev/null || useradd -r -M -d / -s /usr/bin/nologin alpm

pacman -Syu --noconfirm --needed
pacman -S --noconfirm --needed base-devel sudo git openssl

getent group "$HOST_GID" >/dev/null || groupadd -g "$HOST_GID" builder
id builder >/dev/null 2>&1 || useradd -m -u "$HOST_UID" -g "$HOST_GID" builder
echo "builder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/builder
mkdir -p /home/builder/.cache/yay
chown -R "$HOST_UID:$HOST_GID" /home/builder 2>/dev/null || true
chown -R "$HOST_UID:$HOST_GID" /out /work 2>/dev/null || true

# yay-bin：aarch64 预编译，不需要 Go 工具链
if ! command -v yay >/dev/null 2>&1; then
  echo "==> 安装 yay-bin (aarch64)"
  rm -rf /tmp/yay-bin
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
  chown -R "$HOST_UID:$HOST_GID" /tmp/yay-bin
  ( cd /tmp/yay-bin && sudo -u builder makepkg -si --noconfirm )
fi
sudo -u builder yay --version 2>/dev/null | sed -n '1p'

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

asbuilder() {
  # sudo 默认 env_reset 会把 MAKEFLAGS 冲掉，必须显式带进去
  sudo -u builder env PKGDEST=/out MAKEFLAGS="$MAKEFLAGS" "$@"
}

YAYFLAGS=(--needed --noconfirm --answerclean None --answerdiff None)
[[ $NOCHECK == 1 ]] && YAYFLAGS+=(--mflags "--nocheck")

# ---------- 预装依赖：钉死虚拟依赖的提供者，避开交互式 provider 选择 ----------
if [[ -n ${PREDEPS:-} ]]; then
  echo "==> 预装: $PREDEPS"
  # shellcheck disable=SC2086
  asbuilder yay -S "${YAYFLAGS[@]}" $PREDEPS
fi

if [[ $MODE == local ]]; then
  cd "/work/$SUBDIR"

  # 用 yay 把 depends / makedepends 里的 AUR 依赖装齐
  cat > /tmp/getdeps.sh <<'EOS'
. ./PKGBUILD >/dev/null 2>&1 || true
printf '%s\n' "${depends[@]}" "${makedepends[@]}" 2>/dev/null || true
EOS
  # 只把"确实没满足"的依赖交给 yay。虚拟依赖若已被某个 provides 满足，
  # pacman -T 会过滤掉它，否则 yay 会当显式目标再弹一次 provider 菜单。
  mapfile -t ALLDEPS < <(bash /tmp/getdeps.sh | grep -v '^$' | sort -u)
  if (( ${#ALLDEPS[@]} > 0 )); then
    MISSING_RAW=$(pacman -T "${ALLDEPS[@]}" 2>/dev/null || true)
    mapfile -t DEPS < <(printf '%s\n' "$MISSING_RAW" | grep -v '^$')
    if (( ${#DEPS[@]} > 0 )); then
      echo "==> 未满足的依赖: ${DEPS[*]}"
      # shellcheck disable=SC2086
      asbuilder yay -S --asdeps "${YAYFLAGS[@]}" "${DEPS[@]}" || \
        echo "==> 有依赖未装上，交给 makepkg -s 再试一次"
    else
      echo "==> 依赖已全部满足，跳过"
    fi
  fi

  # 本地源包优先从当前目录 / .src 复用，避免重复下载
  if [[ -d $PWD/.src ]]; then SRCDEST_DIR=$PWD/.src; else SRCDEST_DIR=$PWD; fi
  echo "==> SRCDEST=$SRCDEST_DIR"

  MF=()
  [[ $NOCHECK == 1 ]] && MF+=(--nocheck)
  sudo -u builder env PKGDEST=/out SRCDEST="$SRCDEST_DIR" \
    MAKEFLAGS="$MAKEFLAGS" \
    makepkg -sf --noconfirm "${MF[@]}"
else
  asbuilder yay -S "${YAYFLAGS[@]}" "$TARGET"
fi

chown -R "$HOST_UID:$HOST_GID" /out 2>/dev/null || true
BUILD
ST=$?
set -e

if (( ST != 0 )); then
  echo "!! 构建失败（exit $ST），容器 $NAME 已保留，可直接进去排查："
  echo "   docker exec -it $NAME bash"
  [[ $MODE == local ]] && \
    echo "   docker exec -it $NAME bash -lc 'cd /work/$SUBDIR && sudo -u builder makepkg -f'"
  exit "$ST"
fi

echo "== 产物 =="
if compgen -G "$OUT/*.pkg.tar.*" >/dev/null; then
  ls -lh "$OUT"/*.pkg.tar.*
else
  echo "!! /out 里没有包。看构建日志，或检查容器内的 ~/.cache/yay 构建目录。"
fi
#（注：内容由AI生成）
