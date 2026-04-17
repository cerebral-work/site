# Research Index

| Doc | Summary |
|-----|---------|
| [app-tracing-enforcement.md](app-tracing-enforcement.md) | Audit of reveried's OTLP/Tempo tracing coverage: ~20 spans across 193 public functions, with only HTTP middleware instrumented. Recommends span additions at DB ops, event publishes, and child tasks. |
| [engram-as-policy-substrate.md](engram-as-policy-substrate.md) | Retrospective on evolving engram from a memory journal into an active policy substrate that shapes LLM routing, scoring, and consolidation decisions. |
| [hotswap-listener-design.md](hotswap-listener-design.md) | Design for a reusable `hotswap-listener` crate enabling zero-downtime binary restarts via SO_REUSEPORT + SIGUSR2; defers fd handoff and SCM_RIGHTS to later versions. |
| [kernel-tracing.md](kernel-tracing.md) | Survey of kernel-level process observability options for the reverie env-map; recommends `procfs` + `/proc` polling (zero root, ~5 ms/10 PIDs) over eBPF which is blocked on WSL2. |
| [ldap-kerberos.md](ldap-kerberos.md) | Auth research for multi-host mesh scenarios; recommends doing nothing now (single-user localhost) and adopting mTLS via `rustls`+`rcgen` when remote GPU workers are introduced. |
| [rust-monorepo-publishing.md](rust-monorepo-publishing.md) | Survey of crates.io publishing workflows for Cargo workspaces, covering selective publishing, `cargo-release`, registry alternatives, and the recommended release pipeline for reverie. |
| [ebbinghaus-stability-fsrs.md](ebbinghaus-stability-fsrs.md) | FSRS v4 algorithm research (T50): full formulas for stability/retrievability/difficulty; concludes FSRS requires grade input reverie lacks — recommends retrievability-aware increment formula instead. |
| [sqlite-backup-restore.md](sqlite-backup-restore.md) | SQLite backup options for T62: recommends `rusqlite::backup` online API (WAL-safe, non-blocking) for live backups; `VACUUM INTO` for cold snapshots; pre-dream auto-backup as the trigger. |
| [dream-cycle-rate-limiting.md](dream-cycle-rate-limiting.md) | Rate limiting design for T63: three-layer approach using `Semaphore(1)` + `try_acquire_owned()`, `MissedTickBehavior::Skip`, and minimum-interval guard in a single `DreamGuard` choke point. |
