#!/bin/sh
# Run the strata-amd image. The model is not in the image: --data-dir is mounted at /data (an empty folder makes
# the first start download the model). API keys come from a mounted file, one key per line.
#   ./run.sh                          Uncensored off
#   ./run.sh --uncensored             Uncensored on (Strata's experimental speed projection, qwen family only)
# Options:
#   --uncensored | --no-uncensored    the refusal-direction control vector (default: off)
#   --keys-file FILE                  API keys, one per line (default ./secrets/api-keys)
#   --data-dir DIR                    model files, packs and config (default ./data)
#   --model M --family F --context N --vision no|cpu --port N    what to run (defaults: IQ3_S qwen 131072 cpu 8080)
#   --bind ADDR                       host address to publish the port on (default 0.0.0.0: every interface)
#   --image IMG   --name NAME   -d|--detach   --user UID:GID   -- ARGS (more `docker run` arguments)
# Defaults can be kept in ./run.env (shell syntax, e.g. DATA_DIR=/srv/strata-data); command-line options win.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
[ ! -f "$HERE/run.env" ] || . "$HERE/run.env"
IMAGE="${IMAGE:-strata-amd:latest}"; NAME="${NAME:-strata-amd}"; PORT="${PORT:-8080}"; BIND="${BIND:-0.0.0.0}"
DATA_DIR="${DATA_DIR:-$HERE/data}"; KEYS_FILE="${KEYS_FILE:-$HERE/secrets/api-keys}"
FAMILY="${FAMILY:-qwen}"; MODEL="${MODEL:-IQ3_S}"; CONTEXT="${CONTEXT:-131072}"; VISION="${VISION:-cpu}"
UNCENSORED="${UNCENSORED:-off}"; DETACH=""; RUN_USER="${RUN_USER:-$(id -u):$(id -g)}"
while [ $# -gt 0 ]; do
  case "$1" in
    --uncensored) UNCENSORED=on; shift ;;
    --no-uncensored) UNCENSORED=off; shift ;;
    --keys-file) KEYS_FILE="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --family) FAMILY="$2"; shift 2 ;;
    --context) CONTEXT="$2"; shift 2 ;;
    --vision) VISION="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --bind) BIND="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --user) RUN_USER="$2"; shift 2 ;;
    -d|--detach) DETACH="-d"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    --) shift; break ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[ -f "$KEYS_FILE" ] || { echo "no API key file: $KEYS_FILE (one key per line; see README.md)" >&2; exit 1; }
[ -d "$DATA_DIR" ] || { echo "no data folder: $DATA_DIR (create it; an empty one downloads the model)" >&2; exit 1; }
KEYS_FILE="$(cd "$(dirname "$KEYS_FILE")" && pwd)/$(basename "$KEYS_FILE")"; DATA_DIR="$(cd "$DATA_DIR" && pwd)"
VIDEO="$(getent group video | cut -d: -f3)"; RENDER="$(getent group render | cut -d: -f3)"
echo "image $IMAGE, model $FAMILY/$MODEL, port $PORT, Uncensored $UNCENSORED, data $DATA_DIR"
# shellcheck disable=SC2086
exec docker run --rm $DETACH --name "$NAME" -p "$BIND:$PORT:8080" \
  --device /dev/kfd --device /dev/dri ${VIDEO:+--group-add $VIDEO} ${RENDER:+--group-add $RENDER} \
  --ulimit memlock=-1 --security-opt seccomp=unconfined --user "$RUN_USER" \
  -v "$DATA_DIR:/data" -v "$KEYS_FILE:/run/secrets/strata_api_keys:ro" \
  -e FAMILY="$FAMILY" -e MODEL="$MODEL" -e CONTEXT="$CONTEXT" -e VISION="$VISION" -e UNCENSORED="$UNCENSORED" \
  "$@" "$IMAGE"
