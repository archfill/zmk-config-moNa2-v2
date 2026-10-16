#!/usr/bin/env bash
# build.yaml の各ターゲットを GitHub Actions と同じ Docker イメージでローカルビルドする。
#
#   scripts/build-local.sh                # 全ターゲット
#   scripts/build-local.sh usb_logging    # artifact 名に一致するものだけ
#   scripts/build-local.sh --update ...   # west update を強制
#   scripts/build-local.sh --pristine ... # ビルドディレクトリを作り直す
#
# ローカルの module checkout で west 取得分を上書きする場合:
#   LOCAL_MODULES="name=/abs/path name2=/abs/path2" scripts/build-local.sh ...
#   (name は /west/<name> にマウントされる。例: zmk-smart-mouse-layer=/Volumes/.../zmk-smart-mouse-layer)
#
# west workspace (zmk / zephyr / modules) は Docker volume に置き、repo には書き込まない。
# 成果物は build/firmware/<artifact>.uf2 に出力する。
set -euo pipefail

IMAGE="zmkfirmware/zmk-build-arm:3.5"
VOLUME="zmk-mona2-west"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_DIR/build/firmware"

# OrbStack の docker CLI が PATH に無い場合に補う
if ! command -v docker >/dev/null 2>&1 && [ -x /Applications/OrbStack.app/Contents/MacOS/xbin/docker ]; then
    PATH="/Applications/OrbStack.app/Contents/MacOS/xbin:$PATH"
fi

FORCE_UPDATE=0
PRISTINE=0
FILTER=""
for arg in "$@"; do
    case "$arg" in
    --update) FORCE_UPDATE=1 ;;
    --pristine) PRISTINE=1 ;;
    -h | --help)
        sed -n '2,14p' "$0"
        exit 0
        ;;
    *) FILTER="$arg" ;;
    esac
done

mkdir -p "$OUT_DIR"

MODULE_MOUNTS=()
for pair in ${LOCAL_MODULES:-}; do
    mod_name="${pair%%=*}"
    mod_path="${pair#*=}"
    if [ -z "$mod_name" ] || [ "$mod_name" = "$pair" ] || [ ! -d "$mod_path" ]; then
        echo "LOCAL_MODULES の指定が不正です: $pair (name=/abs/path)" >&2
        exit 1
    fi
    MODULE_MOUNTS+=(-v "$mod_path:/west/$mod_name:ro")
done

docker run --rm \
    ${MODULE_MOUNTS[@]+"${MODULE_MOUNTS[@]}"} \
    -v "$VOLUME:/west" \
    -v "$REPO_DIR:/zmk-config:ro" \
    -v "$OUT_DIR:/out" \
    -e FORCE_UPDATE="$FORCE_UPDATE" \
    -e PRISTINE="$PRISTINE" \
    -e FILTER="$FILTER" \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    "$IMAGE" bash -euo pipefail -c '
cd /west

# west.yml は repo の config から毎回コピーし、変更があれば west update する
mkdir -p config
cp /zmk-config/config/west.yml config/west.yml
hash="$(sha256sum config/west.yml | cut -d" " -f1)"
if [ ! -d .west ]; then
    west init -l config
fi
if [ "$FORCE_UPDATE" = 1 ] || [ "$(cat .west-yml-hash 2>/dev/null)" != "$hash" ]; then
    west update --fetch-opt=--filter=tree:0
    echo "$hash" > .west-yml-hash
fi
# CMake package 登録はコンテナ内の ~/.cmake に入り毎回消えるので、常に実行する
west zephyr-export >/dev/null

python3 - <<"PY" > /tmp/targets.tsv
import os, yaml
for t in yaml.safe_load(open("/zmk-config/build.yaml"))["include"]:
    board = t["board"]
    shield = t.get("shield", "")
    snippet = t.get("snippet", "")
    name = t.get("artifact-name") or "-".join(filter(None, [shield.replace(" ", "-"), board, "zmk"]))
    if os.environ["FILTER"] and os.environ["FILTER"] not in name:
        continue
    print("|".join([name, board, shield, snippet]))
PY

if [ ! -s /tmp/targets.tsv ]; then
    echo "対象のターゲットがありません (FILTER=$FILTER)" >&2
    exit 1
fi

while IFS='\''|'\'' read -r name board shield snippet; do
    echo "=== $name"
    args=(-s zmk/app -d "build/$name" -b "$board")
    [ "$PRISTINE" = 1 ] && args+=(-p always)
    [ -n "$snippet" ] && args+=(-S "$snippet")
    cmake_args=(-DZMK_CONFIG=/zmk-config/config -DZMK_EXTRA_MODULES=/zmk-config)
    [ -n "$shield" ] && cmake_args+=("-DSHIELD=$shield")
    west build "${args[@]}" -- "${cmake_args[@]}"
    cp "build/$name/zephyr/zmk.uf2" "/out/$name.uf2"
    chown "$HOST_UID:$HOST_GID" "/out/$name.uf2"
done < /tmp/targets.tsv
'

echo "出力: $OUT_DIR"
ls -l "$OUT_DIR"
