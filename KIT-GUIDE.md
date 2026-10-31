# Coding bake-off kit: Ornith 1.5 122B vs Qwen3.8 27B vs MiniMax M2.5

> This is the original run guide for the kit, as used on the test machine. See `README.md`
> for results. `custom/hidden-tests/`, `custom/judge-prompt.md` and `custom/_reference/` are
> referenced below but are **not yet in this repo**; they will be published after Part 2
> judging. Until then, Part 2 steps 7-9 and the Part 2 portion of the selftest cannot run.

Runs on a Framework Desktop (Ryzen AI Max+ 395, 125 GB unified memory) against
llama.cpp's `llama-server`, one model at a time on 127.0.0.1:8080. Two parts:

1. **Aider Polyglot**, the standard benchmark: 225 Exercism exercises in C++, Go, Java,
   JavaScript, Python and Rust. Two tries per exercise.
2. **Custom Rust project**: one demanding spec in `custom/prompt.md`, the same prompt for each
   model, and a hidden test suite the models never see. The entries are then anonymized to
   A/B/C for a blind review by a judge model.

Default model order is **ornith, then qwen, then minimax**. To change it, edit `MODELS_DEFAULT`
in `config.sh`, or name the models on the command line.

All commands below work in fish. Every script is bash with its own shebang: run it as
`./script.sh` and never `source` it.

## Fairness choices (deliberate)

- **Each model runs with its vendor's recommended sampling** (temperature, top-p, top-k, min-p).
  It is not one shared temperature: each model is judged the way its makers say to run it.
  The values are in `config.sh`, in the server command lines, and sent with every request:
  - ornith: 0.6 / 0.95 / 20 / 0
  - qwen thinking mode: 1.0 / 0.95 / 20 / 0
  - minimax: 1.0 / 0.95 / 40 / 0.01
- Everything else is identical for every model:
  - context of 65536 tokens per request
  - `-ngl 999 -fa on --jinja --reasoning-format deepseek`
  - Aider edit format `diff`, `--tries 2`, 1 thread
  - the same prompt and hidden tests
- The quantization differs, because each model is at the best quant that fits in 125 GB:
  - Ornith Q6_K, 102.4 GB
  - Qwen BF16, 54.7 GB (lossless)
  - MiniMax UD-Q3_K_XL, about 101 GB
  
  MiniMax at Q3 is the most compressed of the three. Keep that in mind when you read its scores.

## Run order

Do these steps in order from the kit folder. Each step can be re-run: it skips finished
work and resumes interrupted work.

**1. Unpack and check the machine.**

```
tar -xzf bakeoff.tar.gz
cd bakeoff
./00-check.sh
```

It lists anything missing, with the exact `pacman` / `systemctl` / `rustup` / `hf` command to fix it.
Docker is required for Part 1 and is the default sandbox for Part 2. After
`sudo usermod -aG docker $USER` you need to log out and back in.

**2. Download the models.** Skip any you already have. Qwen is Unsloth's BF16, split into
2 shards, and lands in `~/models/qwen3.8-27b/BF16/`. `config.sh` loads the first `.gguf`
in that folder (shard `-00001-of-`), skipping `mmproj` files.

```
hf download ornith-ai/Ornith-1.5-122B-GGUF Ornith-1.5-122B-Q6_K.gguf --local-dir ~/models/ornith-official
hf download unsloth/Qwen3.8-27B-GGUF --include 'BF16/*' --local-dir ~/models/qwen3.8-27b
```

MiniMax is expected at
`~/models/minimax/UD-Q3_K_XL/MiniMax-M2.5-UD-Q3_K_XL-00001-of-00004.gguf` (Unsloth `UD-Q3_K_XL`, 4 split files).

**3. Set up Aider and the benchmark image.** This takes about 10-20 minutes and builds a docker
image of about 5 GB.

```
./01-setup-aider.sh
```

**4. Part 1: run the Aider Polyglot benchmark.** This takes days in total; see the time notes.

```
./10-aider-bench.sh
```

Run it in a terminal that stays open, for example in tmux. If it is interrupted, run the same
command again to resume. Watch progress with `tail -f logs/aider-ornith.log`.

**5. Part 1 summary.** The tables are `results/summary.md` and `results/summary.csv`. Step 4
also writes them at the end. `--refresh` re-reads the run folders, so it works while a run is
still going.

```
./11-aider-summary.sh --refresh
```

**6. Part 2: generate the three Rust projects.** This sends one request per model, with no timeout.

```
./20-custom-run.sh
```

**7. Part 2: anonymize the entries.** This writes `results/custom-blind/A,B,C` and keeps the
mapping separately in `results/custom-mapping.json`.

```
./21-custom-anonymize.sh
```

**8. Part 2: run the mechanical checks.** It runs fmt, clippy, build, the entries' own tests
and the hidden tests, inside docker with no network. The result is
`results/custom-blind/checks/SUMMARY.md`.

```
./22-custom-check.sh
```

**9. Judge.** Push the blind folder to a private repo; `results/custom-blind/README.md` has the
exact `gh` commands. Then give the judge model `judge-prompt.md` and the repo. The judge runs
`./run-checks.sh` itself, reads every entry, scores it on the fixed rubric and ranks the
entries blind. Do not show the judge `results/custom-mapping.json` until it has ranked.

To check that the scripts work without loading any model, the kit has an offline selftest
that uses a fake server and a fake docker. It is safe to run while no llama-server is up:

```
./selftest/run-selftest.sh
```

## Overrides, without editing config.sh

Use `env NAME=value` in front of the script:

- One model, or a custom order: `./10-aider-bench.sh qwen`, or `env MODELS="qwen ornith" ./20-custom-run.sh`
- Quick partial Polyglot run: `env LANGUAGES=rust,python ./10-aider-bench.sh`
- Smoke test of 5 random exercises: `env NUM_TESTS=5 ./10-aider-bench.sh ornith`
- Different context: `env CTX=32768 ./10-aider-bench.sh`, but use the same value for every model
- Docker only via sudo: `env DOCKER_CMD_OVERRIDE="sudo docker" ./10-aider-bench.sh`
- Regenerate one Part 2 answer: `env FORCE=1 ./20-custom-run.sh minimax`, then `env FORCE=1 ./21-custom-anonymize.sh`
- Different model file: `env MODEL_PATH_qwen=/path/file.gguf ./20-custom-run.sh qwen`

A run started with LANGUAGES or NUM_TESTS gets its own result name, so it never mixes with the full run.

## If Qwen BF16 will not load on Vulkan

If the server log in `logs/server-qwen-*.log` shows a BF16 or unsupported-type error, or the
load crashes, fall back to Unsloth's Q8_0, which is 29.0 GB and near-lossless:

```
hf download unsloth/Qwen3.8-27B-GGUF Qwen3.8-27B-Q8_0.gguf --local-dir ~/models/qwen3.8-27b
```

Then edit `config.sh`: replace the `MODEL_PATH[qwen]=...` line with
`MODEL_PATH[qwen]="$HOME/models/qwen3.8-27b/Qwen3.8-27B-Q8_0.gguf"`. You can also run once with
`env MODEL_PATH_qwen=$HOME/models/qwen3.8-27b/Qwen3.8-27B-Q8_0.gguf ./10-aider-bench.sh qwen`.
Note in the results that Qwen ran at Q8_0.

## What the scripts do with llama-server

For every model, the scripts:

1. Kill **every** running `llama-server` and wait until it has exited. Any other
   llama-server you have running counts too, so stop anything you need first.
2. Wait until free memory covers the model size plus 6 GB.
3. Start the server and wait until `/health` returns 200. The wait can be up to 1 hour, since a
   100 GB load from disk is slow.
4. Check that the API key works, then run the model.
5. Unload the server.

A watchdog restarts the server if it dies during an Aider run, up to 5 times. Aider keeps retrying the
request in the meantime. The exact command line used is saved as `results/<model>/server-cmd.txt`.
The server's own timeout is set to 48 h, so a slow Qwen answer is never cut off.

## Disk and time

- **Disk:**
  - models: 102.4 GB + 54.7 GB + about 101 GB, plus 29 GB if you add the Q8_0 fallback
  - Aider image: about 5 GB
  - `work/`: about 1-2 GB
  - results: small
- **Speed:** generation on this machine is limited by memory bandwidth, so the dense model is the slow one.
  - **Qwen BF16 (dense, 54.7 GB read per token) is the slowest at about 3-5 tok/s.**
  - The MoE models read only their active experts per token, so they are faster despite being bigger.
- **Part 1 duration:** Polyglot with thinking models produces a lot of tokens. As a rough guide,
  10-20k tokens per exercise means **about a week for Qwen alone** on all 225 exercises, and
  days for each MoE model.
  - The real seconds-per-exercise figure is in `results/summary.md` after the first exercises finish.
  - Use `env LANGUAGES=rust ./10-aider-bench.sh` (30 exercises) if you need a faster signal.
- **Part 2:** one long answer per model, from minutes to a few hours for Qwen.
- Files in `work/aider/tmp.benchmarks/` are created by root inside docker. The scripts hand
  them back to your user after each pass. If a pass was killed hard, run
  `sudo chown -R $USER work/aider/tmp.benchmarks`.

## Security

- Part 2 runs model-written Rust code (build scripts are rejected, but tests run). By default
  it runs inside docker with `--network none`. Use `--native` only if you accept running that
  code on your machine.
- Nothing here talks to anything outside localhost, except `git clone` and `docker build` in
  setup, `hf download`, and the optional `gh` push you run yourself.
- The API key is read from `~/.config/llama/api-key` and passed to docker through a temporary
  0600 env file. It is not passed on a command line.

## Files

- `config.sh`: every setting (models, paths, sampling, context, Aider options).
- `00-check.sh`: prerequisites and fix commands.
- `01-setup-aider.sh`: clones Aider and polyglot-benchmark, and builds the image.
- `10-aider-bench.sh`, `11-aider-summary.sh`: Part 1.
- `20-custom-run.sh`, `21-custom-anonymize.sh`, `22-custom-check.sh`: Part 2.
- `custom/prompt.md`: the task the models get.
- `custom/hidden-tests/`: 26 acceptance tests, never shown to the models.
- `custom/judge-prompt.md`: the reviewer persona and the fixed rubric.
- `custom/run-checks.sh`, `custom/checks.Dockerfile`: the mechanical checks that ship with the blind folder.
- `custom/_reference/`: a reference implementation that was used to validate the hidden tests.
  It is never sent to the models or the judge.
- `lib/`: shared shell and python helpers.
- `selftest/`: the fake server, fake docker and the offline end-to-end test.
- Created at run time:
  - `results/`: per model `stats.json`, `per_exercise.csv`, `server-cmd.txt`; the summaries;
    `custom/`, `custom-blind/` and `custom-mapping.json`
  - `logs/`: server and benchmark logs
