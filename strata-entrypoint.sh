#!/bin/sh
# Entrypoint of the strata-amd image. Three jobs, then it hands over to Strata's own docker-entrypoint.sh:
#   1. API keys: read from a mounted file (never from the config on /data).
#   2. Config: when /data/config has none for FAMILY+MODEL (or REINSTALL=1), run setup.py once, as upstream does.
#   3. Uncensored: UNCENSORED=on|off adds/removes Strata's experimental speed projection (a refusal-direction
#      control vector) in that config on every start, so switching it needs only a restart.
# Environment (all optional):
#   FAMILY MODEL CONTEXT VISION KV LOW_RAM HOST PORT GPU GPUS LAYER_SPLIT GGUF_DIR RESIDENT_BUDGET_GIB KV_STREAMING
#       the same as upstream docker-entrypoint.sh (used only when the config is first written)
#   STRATA_API_KEYS_FILE   file with one API key per line ('#' comments, blank lines ignored)
#                          default /run/secrets/strata_api_keys
#   STRATA_API_KEY         fallback when there is no file: the keys, comma separated
#   ALLOW_NO_API_KEY=1     start without any key (anyone who can reach the port can use the model)
#   UNCENSORED=on|off      default off; qwen family only
#   CONFIG                 a ready config file: used as it is (no bootstrap, no Uncensored switch)
#   STRATA_ENTRYPOINT_DRY_RUN=1   do steps 1-3, print what would start, and exit (a test hook)
set -e
cd /opt/strata || exit 1

STRATA_DATA="${STRATA_DATA:-/data}"
FAMILY="${FAMILY:-qwen}"
MODEL="${MODEL:-IQ2_XS}"
CONTEXT="${CONTEXT:-32768}"
VISION="${VISION:-no}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
LOW_RAM="${LOW_RAM:-auto}"
KEYS_FILE="${STRATA_API_KEYS_FILE:-/run/secrets/strata_api_keys}"
UNCENSORED="${UNCENSORED:-off}"
PY=.venv/bin/python

die() { echo "strata-entrypoint: $*" >&2; exit 1; }

# ---- 1. API keys
if [ -f "$KEYS_FILE" ]; then
  [ -r "$KEYS_FILE" ] || die "$KEYS_FILE is not readable by uid $(id -u): fix its owner or mode (the container runs as that user)"
  keys="$(sed -e 's/\r$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$KEYS_FILE" | grep -v -e '^#' -e '^$' || true)"
  [ -n "$keys" ] || die "$KEYS_FILE has no keys (one per line; '#' starts a comment)"
  case "$keys" in *,*) die "a key in $KEYS_FILE contains a comma; keys are passed comma separated" ;; esac
  STRATA_API_KEY="$(printf '%s\n' "$keys" | paste -sd, -)"
  export STRATA_API_KEY
  echo "API keys: $(printf '%s\n' "$keys" | wc -l) from $KEYS_FILE"
elif [ -n "${STRATA_API_KEY:-}" ]; then
  export STRATA_API_KEY
  echo "API keys: from the STRATA_API_KEY environment variable"
elif [ "${ALLOW_NO_API_KEY:-0}" = "1" ]; then
  echo "WARNING: no API key: anyone who can reach port $PORT can use this model." >&2
else
  die "no API key. Mount a key file at $KEYS_FILE (-v keys.txt:$KEYS_FILE:ro), or set ALLOW_NO_API_KEY=1."
fi
first_key="${STRATA_API_KEY%%,*}"

# ---- 2. config (the same naming as upstream docker-entrypoint.sh)
case "$FAMILY" in qwen) prefix="" ;; *) prefix="${FAMILY}-" ;; esac
tag="${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="$STRATA_DATA/config/strata-$tag.json"
mkdir -p "$STRATA_DATA/config"

if [ -n "${CONFIG:-}" ]; then
  [ -f "$CONFIG" ] || die "CONFIG=$CONFIG does not exist."
  cfg="$CONFIG"
  echo "Config: $cfg (from CONFIG; Uncensored switch not applied)"
else
  if [ "${REINSTALL:-0}" = "1" ] || [ ! -f "$cfg" ]; then
    if [ -n "${GGUF_DIR:-}" ]; then
      echo "Setting up $tag from the GGUF files in $GGUF_DIR."
    else
      echo "Setting up $tag: downloading what is missing from $STRATA_DATA (~70-80 GB the first time)."
    fi
    set -- --family "$FAMILY" --model "$MODEL" --context "$CONTEXT" --vision "$VISION" \
      --data-dir "$STRATA_DATA" --host "$HOST" --api-key "$first_key" \
      --port "$PORT" --no-start --low-ram "$LOW_RAM"
    [ -z "${KV:-}" ] || set -- "$@" --kv "$KV"
    [ -z "${GPUS:-}" ] || set -- "$@" --gpus "$GPUS"
    [ -z "${GPU:-}" ] || set -- "$@" --gpu "$GPU"
    [ -z "${LAYER_SPLIT:-}" ] || set -- "$@" --layer-split "$LAYER_SPLIT"
    [ -z "${GGUF_DIR:-}" ] || set -- "$@" --gguf-dir "$GGUF_DIR"
    [ -z "${RESIDENT_BUDGET_GIB:-}" ] || set -- "$@" --resident-budget-gib "$RESIDENT_BUDGET_GIB"
    [ -z "${KV_STREAMING:-}" ] || set -- "$@" --kv-streaming "$KV_STREAMING"
    $PY setup.py --setup --yes "$@"
    [ -e "/opt/strata/strata-$tag.json" ] || die "setup finished but wrote no strata-$tag.json"
    cp -f "/opt/strata/strata-$tag.json" "$cfg"
  fi
  # ---- 3. Uncensored switch + no keys at rest: patch the config on the volume
  UNCENSORED="$(printf '%s' "$UNCENSORED" | tr 'A-Z' 'a-z')"
  case "$UNCENSORED" in on|1|true|yes) UNCENSORED=on ;; off|0|false|no|"") UNCENSORED=off ;; *) die "UNCENSORED must be on or off, not '$UNCENSORED'" ;; esac
  CFG="$cfg" UNCENSORED="$UNCENSORED" FAMILY="$FAMILY" $PY -I - <<'PYEOF'
import json, os, pathlib, sys
cfg_path = pathlib.Path(os.environ["CFG"])
cfg = json.loads(cfg_path.read_text())
on = os.environ["UNCENSORED"] == "on"
vector = "/opt/strata/data/experimental-speed-projection/Qwen3.8-Flash-Next-experimental-speed-projection.gguf"
# the flags setup.py writes for --experimental-speed-projection on (flag, number of values)
GROUP = (("--control-vector-scaled", 1), ("--control-vector-layer-range", 2), ("--cvec-mode", 1), ("--cvec-dir", 1))
names = {g[0]: g[1] for g in GROUP}
args, out, i = cfg["args"], [], 0
while i < len(args):
    if args[i] in names:
        i += 1 + names[args[i]]
        continue
    out.append(args[i]); i += 1
if on:
    if os.environ["FAMILY"] != "qwen":
        sys.exit("strata-entrypoint: UNCENSORED=on is made for the original Qwen3.8-Flash-Next (FAMILY=qwen), not "
                 + os.environ["FAMILY"])
    if not pathlib.Path(vector).is_file():
        sys.exit(f"strata-entrypoint: the control vector is missing from this image: {vector}")
    out += ["--control-vector-scaled", vector + ":1.0", "--control-vector-layer-range", "4", "44",
            "--cvec-mode", "project", "--cvec-dir", "per-layer"]
changed = out != args
cfg["args"] = out
if "api_key" in cfg:                       # keys come from the mounted file, not from the volume
    del cfg["api_key"]; changed = True
if changed:
    tmp = cfg_path.with_name(cfg_path.name + ".tmp")
    tmp.write_text(json.dumps(cfg, indent=1))
    tmp.replace(cfg_path)
print("Uncensored (experimental speed projection):", "ON" if on else "off")
PYEOF
  echo "Config: $cfg"
fi

if [ "${STRATA_ENTRYPOINT_DRY_RUN:-0}" = "1" ]; then
  echo "dry run: would start the server with $cfg"; exit 0
fi
unset REINSTALL            # the config is written above: upstream must not run setup again
[ -z "${CONFIG:-}" ] || export CONFIG
exec ./docker-entrypoint.sh
