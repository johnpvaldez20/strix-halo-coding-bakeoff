# Task: `flightcache`, a concurrent single-flight LRU/TTL cache in Rust

You are writing a production-quality Rust library crate from scratch. It will be judged by
strict reviewers on correctness, tests, error handling, concurrency safety, API design,
idiomatic Rust and simplicity. A hidden integration-test suite will be compiled against the
exact public API below, so the API must match **exactly** (names, generics, signatures, bounds,
derives). You may add private items and extra public items, but nothing listed may be missing
or different.

## Hard constraints

1. Crate name `flightcache`, library only, `edition = "2021"`, stable Rust.
2. **Standard library only.** No `[dependencies]`, no `[dev-dependencies]`, no `build.rs`,
   no proc-macros. The checks run with networking disabled.
3. `#![forbid(unsafe_code)]` at the top of `src/lib.rs`.
4. Must pass, with zero warnings or failures:
   `cargo build`, `cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`.
5. No public method may panic, except that a panic inside a user-supplied loader closure
   propagates to the caller that ran it (see 6.4). Lock poisoning must never make the cache
   unusable or cause later panics.
6. No busy-waiting / spin loops / `sleep`-based polling in the library.

## Public API (must match exactly)

```rust
use std::error::Error;
use std::fmt;
use std::hash::Hash;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Time source. Lets tests control expiry deterministically.
pub trait Clock: Send + Sync {
    fn now(&self) -> Instant;
}

/// Real time (`Instant::now()`).
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;
impl Clock for SystemClock { /* ... */ }

/// Manually advanced clock for tests. Starts at the `Instant` it was created.
#[derive(Debug)]
pub struct ManualClock { /* private */ }
impl ManualClock {
    pub fn new() -> Self;
    /// Moves this clock forward by `by`. Callable through `&self` from any thread.
    pub fn advance(&self, by: Duration);
}
impl Default for ManualClock { /* same as new() */ }
impl Clock for ManualClock { /* ... */ }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CacheConfig {
    /// Maximum number of entries held at any time. Must be >= 1.
    pub capacity: usize,
    /// Number of independently locked partitions. Must be >= 1 and <= capacity.
    pub shards: usize,
    /// Time-to-live measured from insertion/replacement. `None` = never expires.
    pub ttl: Option<Duration>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    ZeroCapacity,
    ZeroShards,
    MoreShardsThanCapacity { shards: usize, capacity: usize },
}
impl fmt::Display for ConfigError { /* ... */ }
impl Error for ConfigError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LoadError<E> {
    /// This caller ran the loader and it returned `Err(e)`.
    Failed(E),
    /// This caller waited on another caller's load for the same key, and that load returned `Err`.
    LeaderFailed,
    /// This caller waited on another caller's load for the same key, and that loader panicked.
    LeaderPanicked,
}
impl<E: fmt::Display> fmt::Display for LoadError<E> { /* ... */ }
impl<E: Error + 'static> Error for LoadError<E> { /* source() returns the inner error for Failed */ }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CacheStats {
    pub hits: u64,
    pub misses: u64,
    pub loads: u64,
    pub evictions: u64,
    pub expirations: u64,
}

pub struct Cache<K, V> { /* private */ }

impl<K, V> Cache<K, V>
where
    K: Hash + Eq + Clone + Send + Sync + 'static,
    V: Clone + Send + Sync + 'static,
{
    /// Uses `SystemClock`.
    pub fn new(config: CacheConfig) -> Result<Self, ConfigError>;
    pub fn with_clock(config: CacheConfig, clock: Arc<dyn Clock>) -> Result<Self, ConfigError>;

    pub fn get(&self, key: &K) -> Option<V>;
    /// Inserts or replaces. Returns the previous value if one was present and not expired.
    pub fn insert(&self, key: K, value: V) -> Option<V>;
    /// Returns the removed value if one was present and not expired.
    pub fn remove(&self, key: &K) -> Option<V>;
    pub fn len(&self) -> usize;
    pub fn is_empty(&self) -> bool;
    /// Removes every entry. Does not change any statistic.
    pub fn clear(&self);
    /// Removes all expired entries now and returns how many were removed.
    pub fn purge_expired(&self) -> usize;
    pub fn stats(&self) -> CacheStats;

    /// Returns the cached value for `key`, or computes it with `load` exactly once even
    /// when many threads ask for the same missing key at the same time (single-flight).
    pub fn get_or_try_insert_with<E, F>(&self, key: K, load: F) -> Result<V, LoadError<E>>
    where
        F: FnOnce() -> Result<V, E>;
}
```

`Cache<K, V>` must be `Send + Sync` for those bounds so it can be shared through `Arc`.

## Required semantics

### 1. Configuration
- `capacity == 0` -> `Err(ConfigError::ZeroCapacity)`; else `shards == 0` -> `Err(ZeroShards)`;
  else `shards > capacity` -> `Err(MoreShardsThanCapacity { shards, capacity })`.
- Keys are assigned to shards by hash. The per-shard capacities must sum to exactly
  `capacity`, so `len() <= capacity` always holds and a cache that has received enough
  distinct keys holds exactly `capacity` entries.

### 2. LRU eviction
- Inserting a new key into a full shard evicts that shard's least-recently-used entry
  (`evictions += 1`). With `shards == 1` the order must be exact global LRU.
- "Use" means: a `get` hit, a hit in `get_or_try_insert_with`, an `insert` (new or
  replacing; replacing also resets the TTL), and a successful load.
- `clear` and `remove` do not count as evictions.

### 3. TTL
- With `ttl = Some(d)`, an entry written at time `t` (by insert, replace, or successful load,
  read from the configured `Clock`) is expired when `clock.now() >= t + d`.
- An expired entry is never returned. Each expired entry is counted in `expirations`
  exactly once, when it is removed (lazily on access, in `purge_expired`, or when
  `insert` replaces it). `len()` may include expired entries that have not been removed yet.
- `insert` over an expired entry returns `None`.

### 4. Statistics
- `hits`: calls to `get` or `get_or_try_insert_with` that returned a live cached value
  without loading or waiting.
- `misses`: every `get` that returned `None`, and every `get_or_try_insert_with` call that
  did not find a live value (including callers that waited on another caller's load).
- `loads`: number of times a loader closure was invoked.
- `evictions`, `expirations`: as defined above. `insert`, `remove`, `len`, `clear`,
  `stats` do not change hits or misses.

### 5. Concurrency
- `get`, `insert`, `remove` must never block on an in-progress load (not even for the same key).
- Loads for different keys must run concurrently, also when the keys share a shard.
  The loader must not run while any cache lock is held.
- A loader may call any method of the same cache for other keys without deadlocking.
  (Calling `get_or_try_insert_with` for the *same* key from inside its own loader is unspecified.)

### 6. Single-flight (`get_or_try_insert_with`)
1. Live value present -> return it (hit). No loader runs.
2. Otherwise, if no load for this key is in progress, this caller becomes the leader,
   runs `load` exactly once (`loads += 1`), and:
   - `Ok(v)`: stores `v` (subject to capacity/TTL as an insert would), wakes all waiters,
     returns `Ok(v)`; waiters return `Ok(v.clone())`.
   - `Err(e)`: stores nothing, returns `Err(LoadError::Failed(e))`; every waiter returns
     `Err(LoadError::LeaderFailed)`. The failure is not cached: the next call loads again.
3. If a load for this key is already in progress, the caller blocks (no polling) until it
   finishes and returns as above. Its own `load` closure is dropped without being called.
4. If the leader's loader panics, the panic propagates out of the leader's call unchanged,
   every waiter returns `Err(LoadError::LeaderPanicked)`, no value is stored, the in-flight
   marker is cleared, and the cache remains fully usable (the next call loads again).
5. What happens when `insert`/`remove`/`clear` touch a key while its load is in flight is
   your design decision; document it.

## Deliverables

- `Cargo.toml`, `src/lib.rs` (plus any modules you want under `src/`).
- Your own tests in `tests/*.rs` and/or `#[cfg(test)]` modules. They are judged for
  coverage of the semantics above, including concurrency, and must be deterministic
  (use `ManualClock` for time; no flaky sleeps for correctness).
- Rustdoc on every public item.
- `DESIGN.md` (max ~400 words): data structures, locking strategy, why it cannot deadlock,
  complexity of each operation, and the decision from 6.5.
- Do not create `tests/hidden_suite.rs` (that name is reserved).

## Output format (mandatory, machine-parsed)

Output every file in full, each wrapped exactly like this, with the path relative to the
crate root and nothing else on the marker lines:

=== FILE: Cargo.toml ===
<entire file content>
=== END FILE ===

=== FILE: src/lib.rs ===
<entire file content>
=== END FILE ===

Do not put markdown code fences around or inside the markers' content unless they are part of
the file itself. Do not abbreviate, elide, or write "rest unchanged". Text outside the
markers is ignored.
