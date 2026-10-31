# Local LLM coding bake-off on AMD Strix Halo

Results and scripts from a coding benchmark of three open-weight models run locally on one
AMD Ryzen AI Max+ 395 ("Strix Halo") machine.

## Purpose

Find which local model is best for coding on this machine. Each model is run at the highest
quality (precision) that fits in memory. Quality was prioritized over speed; run time was not
a selection criterion.

## Hardware and OS

| Item | Value |
|---|---|
| Machine | Framework Desktop |
| CPU | AMD Ryzen AI Max+ 395, 16 cores / 32 threads |
| GPU | Radeon 8060S integrated (RDNA 3.5, gfx1151) |
| Memory | 128 GB LPDDR5X unified (OS reports ~125 GB) |
| OS | CachyOS Linux, kernel 7.3.0-2-cachyos |

## Runtime

- llama.cpp `llama-server`, build 11804, Vulkan backend, `Release`, `GGML_NATIVE=ON`.
- One model loaded at a time, on 127.0.0.1:8080.
- Server flags, identical for all models:
  `-ngl 999 -fa on --jinja --reasoning-format deepseek --no-kv-unified -c 65536 -np 1`
- KV cache: f16 (llama.cpp default).
- Per-model sampling flags are added to the server command and also sent with each request.

## Models and sampling

Sampling for each model is the value recommended by its vendor / model card.

| Model | Type | File | Size | temp | top_p | top_k | min_p | presence |
|---|---|---|---|---|---|---|---|---|
| Ornith-1.5-122B | MoE | official Q6_K (`ornith-ai/Ornith-1.5-122B-GGUF`) | 102 GB | 0.6 | 0.95 | 20 | 0 | 0 |
| Qwen3.8-27B | dense | Unsloth BF16 (`unsloth/Qwen3.8-27B-GGUF`) | 54.7 GB | 1.0 | 0.95 | 20 | 0 | 0 |
| MiniMax-M2.5 230B | MoE | Unsloth UD-Q3_K_XL | ~101 GB | 1.0 | 0.95 | 40 | 0.01 | 0 |

Qwen runs in thinking mode (its default).

## Fairness note: precision differs

The three models do not run at the same precision: Ornith is Q6_K, Qwen is BF16, MiniMax is
Q3 (UD-Q3_K_XL). Each is the highest precision of that model that fits in ~125 GB. Ornith at
BF16 (~244 GB) or Q8 (~130 GB) does not fit. This favors Qwen on precision. MiniMax is the most
compressed of the three.

The test therefore answers "which model is best on this machine", not "which model is best
at equal precision".

## Part 1: Aider Polyglot

| Setting | Value |
|---|---|
| Benchmark | Aider Polyglot, all 225 exercises (C++, Go, Java, JavaScript, Python, Rust) |
| Edit format | `diff` |
| Tries | 2 (`pass_rate_1`, `pass_rate_2`) |
| Threads | 1 |
| Aider | commit `5dc9490bb` (v0.86.3.dev) |
| polyglot-benchmark | commit `7e0611e` |
| Sandbox | Docker (Aider's `benchmark/Dockerfile`) |
| Context | 65536 tokens per request |

### Results so far

| Model | Status | Finished | Crashed | pass_rate_1 | pass_rate_2 | well-formed | Wall time |
|---|---|---|---|---|---|---|---|
| Ornith-1.5-122B Q6_K | complete | 225/225 | 0 | 47.6% | 80.4% | 96.4% | 2026-10-26 14:40 to 2026-10-28 17:41 CT (~51 h, ~13.6 min/exercise) |
| Qwen3.8-27B BF16 | in progress | 45/225 as of 2026-10-31 | - | - | - | - | started 2026-10-28 17:41 CT; ~65 h so far, ~87 min/exercise |
| MiniMax-M2.5 UD-Q3_K_XL | pending | - | - | - | - | - | - |

Times are US Central (CT). Per-model `stats.json` and `per_exercise.csv` go in
`results/<model>/`.

### Ornith-1.5-122B Q6_K details

From `results/ornith/stats.json`:

| Metric | Value |
|---|---|
| Exhausted context windows (at `-c 65536`) | 20 |
| Error outputs | 29 |
| Malformed responses | 8 |
| User asks | 96 |
| Test timeouts | 0 |
| Prompt tokens | 1,982,210 |
| Completion tokens | 2,580,093 |
| Total exercise time | 50.93 h |
| Time per exercise | 814.8 s |

Per language:

| Language | Completed | pass_rate_1 % | pass_rate_2 % | Well-formed % |
|---|---|---|---|---|
| cpp | 26 | 38.5 | 76.9 | 96.2 |
| go | 39 | 56.4 | 87.2 | 100.0 |
| java | 47 | 36.2 | 68.1 | 95.7 |
| javascript | 49 | 51.0 | 89.8 | 98.0 |
| python | 34 | 50.0 | 85.3 | 97.1 |
| rust | 30 | 53.3 | 73.3 | 90.0 |

Context limit: 20 exhausted context windows occurred at the 65536-token context used for all
models. They fall in cpp (10, of which 2 failed), java (6, all failed), javascript (3, all failed)
and go (1, failed): 12 of Ornith's 44 failures were exercises that hit the context limit.
Exercises that hit the limit likely lost points, so a larger context would be a fairer
setting. The same context is used for every model in this run.

## Part 2: custom Rust project (pending)

Each model gets the same spec (`custom/prompt.md`: `flightcache`, a concurrent single-flight
LRU/TTL cache, standard library only). The outputs are anonymized to A/B/C, run through
mechanical checks (fmt, clippy, build, own tests, a hidden test suite), and ranked blind by a
cloud judge model using a fixed rubric.

Not run yet. The hidden test suite (`custom/hidden-tests/`), the judge prompt
(`custom/judge-prompt.md`) and the reference implementation used to validate the hidden tests
(`custom/_reference/`) are withheld from this repo so the blind judging is not compromised.
They will be published after Part 2 judging is done. Until then, Part 2 steps after
generation, and the Part 2 portion of `selftest/run-selftest.sh`, will not run from this repo.

## How to reproduce

See `KIT-GUIDE.md` for the full run guide. In short:

1. `./00-check.sh`: checks prerequisites (llama.cpp build, Docker, Python, disk, memory).
2. Download the models with `hf download` (commands in `KIT-GUIDE.md`) into `~/models/...`,
   or point `config.sh` at your own paths.
3. `./01-setup-aider.sh`: clones Aider and polyglot-benchmark and builds the Docker image.
   `config.sh` defaults to Aider `main`; to match these results use
   `env AIDER_REF=5dc9490bb ./01-setup-aider.sh` and check out polyglot-benchmark commit
   `7e0611e` in `work/aider/tmp.benchmarks/polyglot-benchmark`.
4. `./10-aider-bench.sh`: runs Part 1 for each model in turn (resumable; re-run to continue).
5. `./11-aider-summary.sh --refresh`: writes `results/summary.md` and `results/summary.csv`.
6. `./20-custom-run.sh`, `./21-custom-anonymize.sh`, `./22-custom-check.sh`: Part 2.

All settings are in `config.sh`. The API key is read from a file (default
`~/.config/llama/api-key`); create your own. The scripts are bash with their own shebangs. On
the original machine they were launched from a fish shell, so some examples use fish syntax
(`env VAR=value ./script.sh`), which also works in bash.

`./selftest/run-selftest.sh` exercises the scripts with a fake `llama-server` and fake `docker`,
without loading a model.

## License

The kit's own code (scripts in this repo) is MIT licensed; see `LICENSE`.

Aider (https://github.com/Aider-AI/aider) and the polyglot benchmark
(https://github.com/Aider-AI/polyglot-benchmark) are third-party projects under their own
licenses. They are not included in this repo; `01-setup-aider.sh` clones them at setup time.
Model weights are not included and are under their publishers' licenses.
