# syntax=docker/dockerfile:1.7
#
# Strata on AMD (HIP / ROCm), gfx1151 (Ryzen AI Max "Strix Halo") by default. Unofficial: the official Dockerfile
# is NVIDIA-only. build.sh downloads a Strata release and hands it to this file as the named build context
# "strata" (--build-context strata=<dir>); nothing in this file fetches Strata itself. Three stages:
#
#   rocm-dev   Python venv. The ROCm "devel" wheels (~11 GB) are installed into it by setup.py in the next stage.
#   builder    compiles engine/strata and engine/strata-vision the way setup.py does. Discarded.
#   runtime    Ubuntu + venv + ROCm *runtime* wheels (no compiler or headers) + the engine + the source setup.py
#              and the server need. NO model files: they live in the /data volume.
#
# Build with ./build.sh (see README.md). Needs network during the build: PyPI, the ROCm wheel index setup.py
# names, GitHub (llama.cpp at the commit Strata pins), Ubuntu apt.

ARG BASE=ubuntu:24.04
ARG GPU_ARCH=gfx1151

# ---------------------------------------------------------------- stage 1: python venv
FROM ${BASE} AS rocm-dev
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git libatomic1 libgomp1 unzip \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/strata
COPY --from=strata requirements.txt .
RUN python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------- stage 2: compile the engine
FROM rocm-dev AS builder
ARG GPU_ARCH
ENV GPU_ARCH=${GPU_ARCH}
COPY --from=strata . .
# setup.build_engine_hip installs the ROCm wheels its own pin names (rocm_root) and compiles for GPU_ARCH. The pip
# cache mount keeps the ~10 GB download between builds. Native code for the CPU that runs `docker build`
# (STRATA_PORTABLE=OFF): build on the machine that runs the image.
RUN --mount=type=cache,target=/root/.cache/pip \
    .venv/bin/python - <<'PYEOF'
import json, os
import setup
llama = setup.get_llama_cpp()
arch = os.environ["GPU_ARCH"]
eng = setup.build_engine_hip({"arch": arch, "archs": [arch]}, llama, "cpu")
meta = json.loads((eng / "BUILD.json").read_text())
# the runtime image has no ROCm headers, so setup could not read hipBLASLt's version there: record it here
meta["hipblaslt_version"] = setup.hipblaslt_version(meta["lib_dirs"])
(eng / "BUILD.json").write_text(json.dumps(meta, indent=1))
print("BUILD.json:", json.dumps(meta))
PYEOF

# ---------------------------------------------------------------- stage 3: runtime
FROM ${BASE} AS runtime
# STRATA_EXECV=1: the server replaces setup.py as PID 1 so `docker stop` reaches it.
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 LANG=C.UTF-8 STRATA_EXECV=1 HOME=/home/ubuntu
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl libatomic1 libgomp1 python3 python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && install -d -o ubuntu -g ubuntu /opt/strata /data
USER ubuntu
WORKDIR /opt/strata

# PRUNE drops ROCm libraries the engine never loads (the ldd check at the end fails the build if a needed one went).
# It must be in the same RUN as the install: a later layer's rm would not make the image smaller.
ARG PRUNE=1
# the venv (same path as in the builder: BUILD.json and the stamps refer to it) with the ROCm *runtime* wheels of
# the version and index the builder's setup.py chose (its .strata-rocm.json stamp)
COPY --from=strata --chown=ubuntu:ubuntu requirements.txt .
RUN --mount=type=bind,from=builder,source=/opt/strata/.venv/.strata-rocm.json,target=/tmp/rocm.json \
    python3 -m venv .venv \
    && .venv/bin/pip install --no-cache-dir --upgrade pip \
    && .venv/bin/pip install --no-cache-dir -r requirements.txt \
    && .venv/bin/pip install --no-cache-dir \
         --index-url "$(.venv/bin/python -c "import json;print(json.load(open('/tmp/rocm.json'))['index'])")" \
         "rocm[libraries]==$(.venv/bin/python -c "import json;print(json.load(open('/tmp/rocm.json'))['version'])")" \
    && if [ "$PRUNE" = "1" ]; then \
      SP=$(realpath .venv/lib/python3*/site-packages); \
      cd $SP/_rocm_sdk_libraries_*/lib \
      && rm -rf libMIOpen* libhipdnn* hipdnn_plugins librccl* libhipfft* librocfft* \
           libhipsparse* librocsparse* rocsparse libhiprand* librocrand* libhipsolver* \
      && cd $SP/_rocm_sdk_core/lib \
      && rm -rf librocprofiler-sdk* rocprofiler-sdk librocjpeg* librocdecode* libamd_smi* \
           librocm-dbgapi* librocm-debug-agent* libroctracer* librocprof-trace-decoder* opencl python3* *.a ; \
    fi

# the source setup.py and the server need (also CMakeLists/src/include: setup hashes them to see the engine is current)
COPY --from=strata --chown=ubuntu:ubuntu . .
COPY --from=builder --chown=ubuntu:ubuntu /opt/strata/engine ./engine
COPY --from=builder --chown=ubuntu:ubuntu /opt/strata/third_party ./third_party

# BUILD.json: point lib_dirs at the runtime wheels (the builder's pointed at the devel ones)
RUN .venv/bin/python -I - <<'PYEOF'
import glob, json, pathlib
sp = glob.glob("/opt/strata/.venv/lib/python3*/site-packages")[0]
core = pathlib.Path(sp, "_rocm_sdk_core", "lib")
libs = sorted(pathlib.Path(sp).glob("_rocm_sdk_libraries_*"))
dirs = [core, core / "rocm_sysdeps" / "lib"] + [d / "lib" for d in libs]
p = pathlib.Path("/opt/strata/engine/BUILD.json")
m = json.loads(p.read_text())
m["lib_dirs"] = [str(d) for d in dirs if d.is_dir()]
p.write_text(json.dumps(m, indent=1))
print(m["lib_dirs"])
PYEOF
# fail the build if the engine cannot resolve its libraries with only the runtime wheels
RUN LD_LIBRARY_PATH=$(.venv/bin/python -I -c "import json;print(':'.join(json.load(open('engine/BUILD.json'))['lib_dirs']))") \
    sh -c '! ldd engine/strata | grep "not found" && ! ldd engine/strata-vision | grep "not found"' \
    && chmod +x setup.sh docker-entrypoint.sh

# our entrypoint: API keys from a mounted file, the Uncensored switch, then the upstream docker-entrypoint.sh
COPY --chmod=755 strata-entrypoint.sh /usr/local/bin/strata-entrypoint

ARG GPU_ARCH
ARG STRATA_REF=unknown
LABEL strata.ref="${STRATA_REF}" strata.gpu-arch="${GPU_ARCH}"

VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=600s --retries=3 \
  CMD curl -fs "http://127.0.0.1:${PORT:-8080}/health" || exit 1
ENTRYPOINT ["/usr/local/bin/strata-entrypoint"]
