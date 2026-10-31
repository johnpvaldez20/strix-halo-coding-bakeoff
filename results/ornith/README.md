# Ornith-1.5-122B Q6_K: Aider Polyglot results

TODO: add `stats.json` and `per_exercise.csv` from the test machine
(`~/bakeoff/results/ornith/`). Pending; not yet copied in. Scrub usernames, home paths, LAN
IPs and hostnames before committing them.

Summary (from the run log, `aider.log`):

- 225/225 finished, 0 crashed
- pass_rate_1 = 47.6%, pass_rate_2 = 80.4%, well-formed = 96.4%
- Run: 2026-10-26 14:40 to 2026-10-28 17:41 CT (~51 h)
- Server command (paths shortened):
  `llama-server -m ~/models/ornith-official/Ornith-1.5-122B-Q6_K.gguf --alias bakeoff-ornith -ngl 999 -fa on --jinja --reasoning-format deepseek --no-kv-unified -c 65536 -np 1 --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0 --host 127.0.0.1 --port 8080 --api-key-file ~/.config/llama/api-key --timeout 172800`
