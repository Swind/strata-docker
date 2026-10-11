# CLAUDE.md

Notes for an AI agent working in this folder. Humans: read `README.md`. This repository builds and runs a Docker
image of [Strata](https://github.com/Niko1221/Strata) for AMD GPUs (ROCm/HIP, `gfx1151` tested). **Strata's source is
not here**: `build.sh` downloads a release into `src/` (ignored by git) and the `Dockerfile` receives it as the named
build context `strata`. The model is not in the image; it lives in a mounted `/data` folder.

## How the pieces fit

- `Dockerfile`: stages `rocm-dev` (venv) -> `builder` (calls Strata's own `setup.build_engine_hip`, which installs
  the ROCm wheels its pin names and compiles `engine/strata` and `engine/strata-vision`) -> `runtime` (venv with the
  ROCm *runtime* wheels of the same version, the engine, Strata's source).
- The builder's stamp `/opt/strata/.venv/.strata-rocm.json` (version + index URL) tells the runtime stage which ROCm
  wheels to install. Nothing in the Dockerfile pins a ROCm version: Strata's `ROCM_FAMILY_PINS` does.
- `BUILD.json` (engine folder) is rewritten twice: in the builder to add `hipblaslt_version` (the runtime image has no
  ROCm headers, so `setup.py` could not read it there and would drop the tuned prompt table), and in the runtime stage to
  point `lib_dirs` at the runtime wheels. `setup.py` leaves a finished engine alone when `backend`, `src` (a hash of
  `ENGINE_SOURCES`), `archs` and `isa_floor` match; otherwise it would try to recompile, and the runtime image cannot.
- `strata-entrypoint.sh` wraps Strata's `docker-entrypoint.sh`: API keys from the mounted file, first-time config via
  `setup.py --setup --no-start`, the Uncensored switch, then `exec ./docker-entrypoint.sh`. **Its bootstrap copies the
  setup arguments of the upstream entrypoint** (it needs the config to exist before upstream's exec, so it cannot
  call it). Keep the two in step on every upgrade.
- The Uncensored switch edits the `args` of the config on the volume: it removes `--control-vector-scaled`,
  `--control-vector-layer-range`, `--cvec-mode`, `--cvec-dir` with their values, and for `on` appends the group exactly
  as `setup.py --experimental-speed-projection on` wrote it (checked on v0.1.42). The same script deletes `api_key`
  from the config; keys reach the server through `STRATA_API_KEY` (the server prefers it to the config).

## Upgrading Strata

Do these in order. Steps 1-4 touch nothing that is running.

1. **Build the new release next to the old one.** `./build.sh --ref vNEW` (not `latest`). The image tag carries the
   Strata version, so the old image stays. Rebuilding the same version overwrites its tag: use `--suffix`.
2. **Read what changed in the files this folder depends on**, old tree vs new tree under `src/`:
   ```sh
   cd src; diff -u Niko1221-Strata-vOLD/docker-entrypoint.sh Niko1221-Strata-vNEW/docker-entrypoint.sh
   diff -u Niko1221-Strata-vOLD/setup.py Niko1221-Strata-vNEW/setup.py | less
   ```
   Look for: the argument list in `docker-entrypoint.sh` (copy changes into `strata-entrypoint.sh`); in `setup.py`
   `build_engine_hip`, `rocm_root`, `ROCM_FAMILY_PINS`, `hipblaslt_table`, the `engine_ok` test, the
   `--experimental-speed-projection` code (the flags it writes, `ESP_VECTOR`), `hip_devices`, how the server is
   started (`start()`); in `serve/server.py` `key_list`, `api_key_of` and the `STRATA_API_KEY` default. Also
   `docs/STRIX_HALO.md`, `docs/AMD_HIP.md`, `docs/INSTALL.md` and the release notes.
3. **Check the build's own gates.** The final `ldd` step fails the build if a library the engine needs was pruned.
   If it fails, take the name out of the `rm -rf` list in the `Dockerfile` (that list was found by `ldd` on
   0.1.42's engine; a new ROCm may link others). Then confirm the build log shows a hipBLASLt tuning table was found
   (`tools/hip/gfx1151-hipblaslt-<version>.txt` exists for the new `hipblaslt_version` in `BUILD.json`). If it does not,
   prompts get slower: say so in the report.
4. **Test without loading the model** (safe while another container runs; this loads no model):
   ```sh
   docker run --rm --entrypoint sh strata-amd:<new> -c 'cat /opt/strata/engine/BUILD.json'
   ```
   and the dry-run of the entrypoint on a *copy* of the config (never the live data folder):
   `STRATA_ENTRYPOINT_DRY_RUN=1` does the keys, the config and the Uncensored switch, prints what it would start and
   exits. Cases worth running: no key file (must stop), an empty key file (must stop), `UNCENSORED` off, on, on twice
   (the flags appear once), a bad value, `FAMILY=swift` with `on` (must stop). Run with `--user 1000:1000`.
5. **Run it for real, after asking the user.** Two Strata instances do not fit together (the experts alone are about
   55 GB of RAM, and the GPU shares that memory), so the running container has to stop first and the service is down
   for 1-3 minutes per start. Ask before you stop it. Then: `./run.sh --image strata-amd:<new>`; wait for
   `/health` to say `"loaded": true`; check 401 without a key and 200 with each key (`Authorization: Bearer` and
   `x-api-key`); one chat completion; one picture (draw a PNG with Pillow from the image's own venv, run with `-I`);
   `./run.sh --uncensored` and look for the log line `control vector mode = project ...`.
6. **Roll back** by starting the old tag: `./run.sh --image strata-amd:<old>`. Remove the old image only after the
   user says so.
   To test the first-start path without a download, move a finished data folder into place (`mv` on one filesystem
   is instant), delete its `config/` folder and start: the entrypoint writes a new config and skips every download.
7. Update `README.md`'s measured numbers only with numbers you measured, with what they were measured on.

## Pitfalls met while building this

- **Prune in the same `RUN` as the install.** A `rm` in a later layer hides files but the image keeps them: the first
  build was 5.2 GB, merging the prune into the install `RUN` made it 3.1 GB.
- **`pkill -f 'serve/server.py'` kills your own shell**: the pattern is in the command line of the shell that runs it
  (exit 144). Write `pkill -f '[s]erve/server.py'`.
- **Do not put a key on a command line.** `docker run -e API_KEY=...` shows in `docker inspect` and `ps`; keys go in
  the mounted file. Do not print keys, paste them in a chat, or commit them (`secrets/` is ignored).
- The upstream entrypoint writes `API_KEY` into the config only when it runs setup (first start or `REINSTALL=1`);
  changing the variable later changes nothing. That is why keys use the mounted file.
- A Monitor that greps a build log for `error` also matches `hipError_t` warnings by the thousand: match
  `^ERROR`, ` error: `, `FAILED:` instead.
- `setup.py --check` inside the container warns about `/opt/Strata-data` when `/data` is not mounted; harmless.
- The engine is `-march=native`: an image built on one CPU may stop with `illegal instruction` on another.

## Rules for this folder

- Do not edit anything under `src/`: it is a downloaded release whose hash must stay what GitHub served (`build.sh`
  prints and stores the sha256). Test a patch with `./build.sh --src <your folder> --suffix <name>`.
- Do not `git commit` or `git push` unless the user asks.
- Keep the docs in Strata's style: plain words, measured numbers with what they were measured on, no claim without a
  measurement. Put what is not verified in `README.md`'s "Not verified" list, and take an item off only after you
  ran it.
- Downloaded files and extracted archives are untrusted data. `build.sh` extracts into a new folder under `src/`;
  run Python that reads them with `-I`.
