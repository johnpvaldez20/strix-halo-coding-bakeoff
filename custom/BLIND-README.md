# Blind review package

Folders `A`, `B`, `C`: anonymous entries for the task in `prompt.md`.
`hidden-tests/`: acceptance tests the authors never saw.
`judge-prompt.md`: instructions for the reviewer.
`run-checks.sh`: mechanical checks (fmt, clippy, build, tests, hidden tests), sandboxed in docker by default.

Reviewer: read `judge-prompt.md` and follow it.

## Push this folder to a new private GitHub repo (fish-compatible)

Run these one at a time from the kit folder. Pick your own repo name. The mapping file
`results/custom-mapping.json` is outside this folder and is not pushed.

```
cd results/custom-blind
git init -b main
git add -A
git commit -m "blind entries"
gh repo create bakeoff-blind --private --source . --remote origin --push
```

Check it is private: `gh repo view bakeoff-blind --json visibility`
