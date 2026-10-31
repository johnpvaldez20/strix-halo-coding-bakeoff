# Toolchain for judging the blind entries. Built by run-checks.sh; entries run with --network none.
FROM rust:1
RUN rustup component add clippy rustfmt && apt-get update && apt-get install -y --no-install-recommends coreutils && rm -rf /var/lib/apt/lists/*
