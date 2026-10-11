# strata-docker

A Docker image that runs [Strata](https://github.com/Niko1221/Strata) (Qwen3.8-Flash-Next on one graphics card plus
system RAM) on **AMD GPUs through ROCm/HIP**. Strata's own `Dockerfile` is NVIDIA-only; this is an unofficial one
for the AMD path. It is written for the Ryzen AI Max "Strix Halo" (`gfx1151`).

- The image holds the runtime and the engine. **It holds no model**: the model files live in a folder you mount at
  `/data`.
- **Strata itself is not in this repository.** `build.sh` downloads a Strata release and builds from it.
- Only `gfx1151` has been run. Another AMD GPU needs `--arch` and its own ROCm wheels (not tried).

Measured on a Ryzen AI Max+ 395 (128 GB), Strata v0.1.42, IQ3_S: the image is 3.13 GB, a short chat answers at
about 38 tokens/s (one run), and a picture is read correctly with the CPU image encoder.

## Quick start

```sh
./build.sh --ref v0.1.42                 # downloads the release, builds strata-amd:0.1.42-gfx1151
mkdir -p secrets data
python3 -c "import secrets; print(secrets.token_urlsafe(32))" > secrets/api-keys   # one key per line
chmod 600 secrets/api-keys
./run.sh                                 # first start downloads the model into ./data (about 85 GB)
curl http://127.0.0.1:8080/health
```

`./run.sh --uncensored` turns on the [Uncensored switch](#uncensored-switch). `./run.sh --help` lists every option.

## What a deployment has to provide

**On the host**

| What | Detail |
| --- | --- |
| CPU | x86-64 with AVX2. The engine is compiled for the CPU that runs `docker build` (`-march=native`): **build on the machine that runs the image**. |
| GPU | AMD `gfx1151` (Radeon 8060S / 8050S / 8040S). |
| Kernel | the `amdgpu` driver, with `/dev/kfd` and `/dev/dri`. |
| Memory | what Strata needs for the model you pick (about 62 GB for IQ3_S, see Strata's `docs/MODELS.md`). On Strix Halo the GPU can only use as much of the RAM as the kernel's GTT limit allows: Strata's `docs/STRIX_HALO.md` shows the `ttm.pages_limit` / `ttm.page_pool_size` boot settings. |
| Docker | with BuildKit and `--build-context` (tried with Docker 29.8.2). The container needs `--ulimit memlock=-1`; `run.sh` sets it. |
| Disk | the model folder: about 87 GB for IQ3_S (79 GB of GGUF files and image encoder, 6.5 GB of MTP files, a 1.5 GB pack); the first start downloads about 85 GB of it. The build downloads the ROCm "devel" wheels (about 11 GB) and keeps them in Docker's build cache. |
| Network | while building: GitHub (the release and llama.cpp at the commit Strata pins), PyPI, the ROCm wheel index named by Strata's `setup.py`, Ubuntu apt. While running: nothing, except the first start's model download from Hugging Face. |

**As inputs**

| Input | Where | Notes |
| --- | --- | --- |
| Strata release | `build.sh --ref vX.Y.Z` | Pin it. `latest` is for trying a new release, not for a deployment. |
| Image name and tag | `build.sh` prints it; `run.sh --image` | `strata-amd:<version>-<arch>[-suffix]`. |
| Data folder | `--data-dir` / `DATA_DIR` | Writable by the user the container runs as (`--user`, default your uid). An empty folder makes the first start download the model. |
| API keys file | `--keys-file` / `KEYS_FILE` | One key per line. Readable by that same user. See [API keys](#api-keys). |
| Model choice | `--family --model --context --vision` | Defaults: `qwen`, `IQ3_S`, 131072, `cpu` (images on). Used only when the config is first written. |
| Uncensored | `--uncensored` / `UNCENSORED=on` | Default off. |
| Port and address | `--port`, `--bind` | Default `0.0.0.0:8080`. The server refuses to start without a key. |
| Restart policy | `-- --restart unless-stopped` | Anything after `--` goes to `docker run`. Use `-d` to detach. |

Do not publish the port beyond a network you trust: the connection is plain HTTP, so the keys travel in clear text.

## Build

```sh
./build.sh                     # the latest release
./build.sh --ref v0.1.42       # one release
./build.sh --src ~/Strata      # a Strata folder you already have (a checkout, a patched tree)
./build.sh --suffix test       # strata-amd:0.1.42-gfx1151-test
```

`build.sh` downloads `https://github.com/Niko1221/Strata/archive/refs/tags/<tag>.tar.gz` into `src/`, prints its
sha256 and keeps it there, then runs `docker build --build-context strata=<that folder>`. The `Dockerfile` never
fetches Strata. The image carries the tag it was built from as the label `strata.ref`.

The build has three stages: a Python venv, a stage that installs the ROCm "devel" wheels and compiles the engine and
the CPU image encoder, and the runtime stage with only the ROCm runtime libraries (the wheels, minus libraries the engine never loads), the
engine and Strata's source. On a 32-thread machine the compile took about a minute; the ROCm download is the long part.

## Run

```sh
./run.sh --data-dir /srv/strata-data --keys-file /etc/strata/api-keys
./run.sh --uncensored
./run.sh -d --name strata -- --restart unless-stopped
```

Defaults can sit in `run.env` (shell syntax, for example `DATA_DIR=/srv/strata-data`). Command-line options win.
The container starts `strata-entrypoint.sh`, which reads the keys, writes the config if there is none, applies the
Uncensored switch and hands over to Strata's own `docker-entrypoint.sh`. Loading takes 1-3 minutes and the PC can
be slow meanwhile; `/health` (no key needed) answers `"loaded": true` when it is ready. The image has a healthcheck.

Environment variables of the container (`run.sh` sets the first group from its options):

| Variable | Default | Meaning |
| --- | --- | --- |
| `FAMILY` `MODEL` `CONTEXT` `VISION` | `qwen` `IQ2_XS` `32768` `no` | what setup writes into the config **the first time**. Later changes need `REINSTALL=1`. |
| `KV` `LOW_RAM` `GPU` `GPUS` `LAYER_SPLIT` `GGUF_DIR` `RESIDENT_BUDGET_GIB` `KV_STREAMING` | unset | passed to setup as in Strata's `docker-entrypoint.sh` |
| `UNCENSORED` | `off` | `on` / `off`, applied on every start |
| `STRATA_API_KEYS_FILE` | `/run/secrets/strata_api_keys` | where the key file is mounted |
| `STRATA_API_KEY` | unset | keys, comma separated: used only when there is no key file |
| `ALLOW_NO_API_KEY` | `0` | `1` starts with no key at all (anyone who can reach the port can use the model) |
| `REINSTALL` | `0` | `1` runs setup again for this model (new context, vision, KV, ...) |
| `CONFIG` | unset | start with this config file as it is: no setup, no Uncensored switch |

## API keys

Keys come from a **mounted file**, never from the image and never from the config on `/data`.

- `run.sh` mounts `--keys-file` read-only at `/run/secrets/strata_api_keys`. With Docker Compose or Swarm, a secret
  named `strata_api_keys` lands at the same path.
- One key per line. Blank lines are ignored and `#` starts a comment, so a label can sit above each key:

  ```
  # bot
  Xk3...
  # dev
  9aQ...
  ```
- A client sends a key as `Authorization: Bearer <key>` or `x-api-key: <key>`. Any one of the keys passes. All keys
  have the same rights; the server does not say which one was used.
- A key must not contain a comma. Make keys with `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`.
- The file must be readable by the user the container runs as. `run.sh` runs it as your uid; with another `--user`,
  `chown`/`chmod` the file to match.
- **Add or revoke a key:** edit the file and restart the container (1-3 minutes of downtime, the model reloads).
- On start the entrypoint joins the keys with commas into `STRATA_API_KEY`, which the server reads in preference to
  the config's `api_key`, and it deletes any `api_key` from the config on the volume.
- Without a key file (and without `STRATA_API_KEY`) the container stops with an error, unless `ALLOW_NO_API_KEY=1`.

## Uncensored switch

`UNCENSORED=on` (`./run.sh --uncensored`) turns on Strata's *experimental speed projection*: a small control vector
that removes one "refusal" direction from layers 4-44, so the model declines far fewer requests. Strata's own docs
([`docs/DETAILS.md`](https://github.com/Niko1221/Strata/blob/main/docs/DETAILS.md), "Experimental speed projection") say it
is experimental, that it shifts ordinary answers a little (on their Q2_0 test: perplexity +15% on code, +0.4% on a chat),
and that removing refusals removes a safety behaviour: you are responsible for what the model writes with it on.

- Default is **off**. The entrypoint adds or removes the control-vector flags in the config on every start, so
  switching is a restart (the conversation cache is dropped once).
- Only the original model (`FAMILY=qwen`). Any other family stops with an error.
- It is on for every request while loaded. A request can turn it off with `"experimental_speed_projection": false`
  in the body (the web app has the same switch in its Sampling drawer).
- The log line `control vector mode = project, dir = per-layer, layers 4..44 (41 steered)` shows it is on.

## The data folder

Everything you mount at `/data`, created by Strata's setup:

```
config/strata-<model>.json   the install config (no API keys in it)
models/<size>/*.gguf         the model, as downloaded from Hugging Face
models/mmproj-*.gguf         the image encoder
packs/<model>/               Strata's prepared copy of the dense weights
mtp/                         the draft layer that speeds up generation
```

Several models can share one folder; `MODEL` picks which config starts.

## Using the API

OpenAI-compatible at `http://<host>:8080/v1` (`/chat/completions`, `/models`), Anthropic-compatible at `/v1/messages`,
Responses API at `/v1/responses`, the web app at `/`. Any model name works. Pictures go in as `image_url` content
with a base64 `data:` URL. `"reasoning_effort": "none"|"low"|"medium"|"high"` sets the thinking. Strata answers one
request at a time unless `parallel` is set in the config. More: Strata's `docs/DETAILS.md`.

## Upgrading Strata

Build the new release next to the old one (`./build.sh --ref vNEW`; the tag differs by version), run it with
`./run.sh --image strata-amd:<new tag>`, and keep the old image until the new one works. `CLAUDE.md` is the checklist
for doing this with an AI agent.

## Not verified

- Another GPU than `gfx1151`.
- The first start on an **empty** data folder (the ~85 GB download from Hugging Face, then the conversion, through
  `strata-entrypoint.sh`). Run with the model files already in place it works: it wrote the config, downloaded
  nothing, found the hipBLASLt tuning table and loaded the model (Strata v0.1.42, IQ3_S).
- An image built on one CPU and run on another (the engine is `-march=native`).
- `--security-opt seccomp=unconfined` in `run.sh` is kept from the first working run; whether it is needed was not tested.

## Files

| File | What |
| --- | --- |
| `Dockerfile` | the three-stage build; Strata comes in as the build context named `strata` |
| `build.sh` | download a release (or take `--src`), build and tag the image |
| `run.sh` | run it: data folder, key file, Uncensored switch |
| `strata-entrypoint.sh` | keys, first-time config, Uncensored switch, then Strata's entrypoint |
| `CLAUDE.md` | notes for AI agents: upgrading Strata, testing, pitfalls |

`src/`, `secrets/`, `data/`, `run.env` and `*.log` are in `.gitignore`.
