# hotswap-listener — crate design

Status: research + design (2026-04-08, control-room lane)
Source: background research subagent + control-room synthesis
Scaffold: `crates/hotswap-listener/` (v0.0.0 with `make_listener()` only)
Cross-refs: Part D rollout (reveried SO_REUSEADDR/SO_REUSEPORT already shipped), Part H env-map

## TL;DR

A reusable Rust crate that gives any tokio+axum/hyper server a zero-downtime binary restart story. v0.1 uses the SO_REUSEPORT "start new, drain old" pattern with SIGUSR2 as the upgrade trigger. No fd handoff, no SCM_RIGHTS, no shared memory. Later versions add systemd socket activation and SCM_RIGHTS for completeness.

The crate is extracted from the pattern I just shipped into reveried. This design doc locks in the API before we fill in the supervisor logic.

## Part 1 — State of the art

Four production patterns studied, plus one we rejected:

### nginx (master + workers via fork)
- Master holds the listening socket. Forks N workers at boot, each inherits the fd.
- Binary upgrade: `kill -USR2 $master`. Master renames its pid file, re-execs itself with the new binary, new master forks new workers, old workers drain on `SIGWINCH`, old master exits on `SIGQUIT`.
- Pros: canonical, well-documented, zero-downtime. Cons: complex signal dance, master/worker model imposes structure.

### unicorn-rb (Ruby unicorn HTTP server)
- Same pattern as nginx, simpler signal model. `SIGUSR2` re-execs with new binary, old master forks a last worker to drain old requests, `kill -QUIT old_pid` finishes the cutover.
- Ruby-specific: passes the listening fd via `LISTEN_FDS` environment variable (systemd socket activation convention).

### Envoy (hot restart)
- More ambitious: parent and child communicate over a Unix domain socket, parent sends the listening fd via `SCM_RIGHTS`, parent also shares runtime counters via shared memory so stats aren't reset.
- Pros: truly seamless, counters preserved. Cons: heavy machinery, only worth it at Envoy's scale.

### systemd socket activation (`sd_listen_fds`)
- systemd holds the listening socket across restarts. When it spawns a unit, it passes the socket as fd 3 and sets `LISTEN_FDS=1` + `LISTEN_PID=<unit_pid>`.
- Pros: zero-downtime for free, no application-level supervisor, handles the hard parts.
- Cons: requires systemd, requires a `.socket` unit file, not portable.

### SO_REUSEPORT "start new, drain old" (the pattern we're building)
- Old process is running and listening on port X with `SO_REUSEPORT`.
- New process starts, also binds port X with `SO_REUSEPORT` — kernel adds it to the pool, starts distributing new connections between both.
- Old process receives `SIGTERM`, stops accepting new connections (axum `graceful_shutdown`), drains in-flight requests, exits.
- New process is now the only listener.
- Pros: no fd handoff, no SCM_RIGHTS, no shared memory, no exec() inside a running process. Each process is independent. Cons: shared socket ownership means connections balance across both during cutover (fine for stateless servers, maybe weird for sticky).

**v0.1 picks pattern #5.** Patterns #1–#3 can come in v0.2/v0.3 as optional backends.

## Part 2 — Fd handoff strategies (for later)

Three approaches to passing a listening socket between processes:

### A. Fork inheritance
`fork()` gives the child a copy of every open fd by default. Simplest approach. Problem: `fork()` is followed by `exec()` in our case, and fds survive exec() by default (unless `FD_CLOEXEC` is set), but we still need a way for the child to find the inherited fd. Unicorn's solution: pass fd numbers via `LISTEN_FDS` env var (same convention as systemd socket activation).

### B. SCM_RIGHTS over unix socket
Parent opens a unix socket, child connects, parent sends the listening fd via `sendmsg()` with `SCM_RIGHTS`. Works across `exec()` boundaries. More complex, but allows an already-running child to receive an fd from its parent without having been forked from it.

### C. SO_REUSEPORT
No handoff at all. Both processes bind independently. The kernel's REUSEPORT logic distributes incoming connections across the pool. This is what we're building in v0.1.

**Verdict**: C for v0.1 (cleanest), A for v0.3 if we want atomic cutover without a brief period of dual-bind, B for v0.4 if someone really needs it.

## Part 3 — API design

```rust
use hotswap_listener::{HotSwapServer, HotSwapConfig};
use std::time::Duration;
use tokio::sync::oneshot;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = HotSwapConfig::new("127.0.0.1:7437".parse()?)
        .drain_timeout(Duration::from_secs(30))
        .pid_file("/run/reveried.pid");

    HotSwapServer::new(config)
        .serve(|listener, shutdown_rx| async move {
            let app = build_axum_router();
            axum::serve(listener, app)
                .with_graceful_shutdown(async move {
                    let _ = shutdown_rx.await;
                })
                .await?;
            Ok(())
        })
        .await?;
    Ok(())
}
```

Key decisions:
- `serve` closure gets two args: `TcpListener` + `oneshot::Receiver<()>` for graceful drain signal.
- User is responsible for wiring `shutdown_rx` into their framework's graceful shutdown hook. `axum::serve(..).with_graceful_shutdown()` takes a future, so `.await`ing `shutdown_rx` works directly.
- `HotSwapConfig` is a builder, every knob is optional.

## Part 4 — Signal protocol

| Signal | Action |
|---|---|
| `SIGHUP` | Reload config (future; no-op in v0.1) |
| `SIGUSR2` | Fork + exec current binary. New child binds via `SO_REUSEPORT`. Parent sends SIGTERM to itself after new child is "ready". |
| `SIGTERM` | Trigger `shutdown_rx`. User's server drains in-flight requests, then exits. After `drain_timeout`, force kill. |
| `SIGINT` | Immediate exit. No drain. Useful for Ctrl-C during development. |
| `SIGCHLD` | Supervisor mode only: track child exits, log, optionally respawn. |

v0.1 implements SIGUSR2 + SIGTERM + SIGINT. Supervisor-with-respawn comes in v0.2.

## Part 5 — Crate layout

```
crates/hotswap-listener/
├── Cargo.toml
├── README.md
├── src/
│   ├── lib.rs          # public API, re-exports
│   ├── config.rs       # HotSwapConfig builder
│   ├── server.rs       # HotSwapServer
│   ├── supervisor.rs   # signal handling, fork/exec path
│   ├── socket.rs       # make_listener() — SO_REUSEADDR/PORT setup
│   └── signal.rs       # tokio::signal::unix wrappers
├── examples/
│   ├── axum-minimal.rs
│   ├── hyper-lowlevel.rs
│   └── graceful-drain.rs
└── tests/
    ├── integration.rs       # binary upgrade end-to-end
    ├── signal_handling.rs   # SIGTERM drain behaviour
    └── drain_timeout.rs     # force-kill on timeout
```

## Part 6 — Dependencies

Minimum viable set:

```toml
[dependencies]
anyhow = "1"
tokio = { version = "1", features = ["rt", "net", "signal", "macros"] }
socket2 = { version = "0.5", features = ["all"] }
tracing = "0.1"
thiserror = "2"
rustix = { version = "0.38", features = ["process", "fs"] }
```

**Avoid**: `libc` direct calls (use rustix), `ctrlc` crate (tokio::signal covers it), `tokio::process` for the exec path (we want unix exec(), not spawn()), any async runtime other than tokio.

## Part 7 — What's tricky

### Graceful drain handoff
After receiving `SIGTERM`, we trigger `shutdown_rx` which the user's server awaits. `axum::serve(listener, app).with_graceful_shutdown(fut)` stops accepting new connections when `fut` resolves, then waits for in-flight ones to complete. The supervisor has to **also** wait — with a timeout — before exiting, otherwise the parent dies before the drain finishes.

Proposal: `serve()` runs the user's future inside `tokio::select!` against a timeout:

```rust
tokio::select! {
    res = user_serve_fut => res,
    _ = tokio::time::sleep(config.drain_timeout) => {
        tracing::warn!("drain timeout hit, forcing exit");
        Err(HotSwapError::DrainTimeout)
    }
}
```

### exec() inside a running process
When SIGUSR2 fires, the supervisor needs to `execve()` itself with the new binary path. Rust's `std::os::unix::process::CommandExt::exec()` replaces the current process image. **Destructors don't run.** Any held resources (open files, locks, heap allocations in TLS) are leaked. The supervisor has to drop everything it holds before the exec — including the listening socket, since the new binary will bind its own.

Alternative: fork first, exec in the child, keep the parent alive briefly for handoff. Cleaner but now we have two processes during transition.

v0.1 strategy: parent receives SIGUSR2, forks a child, child execs new binary, parent waits for child to indicate readiness (100 ms sleep in v0.1, marker file in v0.2), parent sends SIGTERM to *itself* to start drain. Old parent exits after drain, new child is the only process left. No exec in a running process, so destructors do run.

### Windows support
`fork()` doesn't exist on Windows. The crate cfg-gates out all of this on non-unix in v0.1 and documents that it's Linux/macOS only. Windows support in v1.0 would need `CreateProcess` + named-pipe fd handoff, which is a different enough story that it belongs in a separate backend module.

### PID file races
If two supervisors start simultaneously and both try to write the same pid file, chaos. v0.1 uses `O_CREAT | O_EXCL` on the pid file open — second supervisor fails fast. flock() is an alternative but more invasive.

### Ready handshake
The parent needs to know when the new child is actually bound and ready to serve before sending itself SIGTERM. v0.1: sleep 100 ms after fork, cross fingers. v0.2: child writes a marker file, parent polls. v0.3: unix socket handshake.

## Part 8 — Testing strategy

Three integration tests cover the meaningful behaviours:

1. **Binary upgrade**: Start supervisor. Make request. Assert 200. Send SIGUSR2. Make request. Assert 200 (served by new process). Assert old pid has exited. Assert new pid is the only listener.
2. **Graceful drain**: Start supervisor. Open a long-lived request (e.g. SSE or long POST). Send SIGTERM. Assert the long request completes before process exits. Assert no new connections accepted after SIGTERM.
3. **Drain timeout**: Start supervisor with `drain_timeout = 500ms`. Open a request that blocks longer than that. Send SIGTERM. Assert process exits at the timeout regardless of the in-flight request.

## Part 9 — Crate name availability

(Check actual crates.io before v0.1 publish.)

- `hotswap-listener` — likely free, descriptive
- `houdini-serve` — likely free, cute
- `fd-relay` — implies SCM_RIGHTS which is v0.3+
- `reincarnate` — cute but cryptic
- `phoenix-serve` — `phoenix` is taken but `phoenix-serve` likely free
- `tower-hotswap` — parks on the tower ecosystem, forces compatibility with `tower::Service`

**Recommendation**: `hotswap-listener`. Scaffold is already at that name.

## Part 10 — Phased rollout

### v0.0.0 — scaffold (shipped)
- `HotSwapConfig`, `HotSwapServer` stubs
- `make_listener()` with SO_REUSEADDR+SO_REUSEPORT (the one real function)
- Single test verifying rebind-after-drop works

### v0.1 — the useful version
- Supervisor loop with SIGUSR2 / SIGTERM / SIGINT
- Fork + exec path
- Graceful drain via `oneshot::Receiver<()>` passed into the user's serve closure
- Drain timeout with force-exit
- `axum-minimal` example
- Integration tests #1, #2, #3

### v0.2 — systemd socket activation
- If `LISTEN_FDS` env var is set at startup, inherit the listener from fd 3 instead of binding
- `pid_file` becomes optional (systemd tracks the unit)
- Signal protocol adapts: SIGHUP maps to systemd `ExecReload=`

### v0.3 — SCM_RIGHTS fd handoff
- Alternative to SO_REUSEPORT for people who want atomic cutover
- Unix socket pair between parent and child for fd passing
- New example: `scm-rights-handoff.rs`

### v1.0 — stable API, cross-platform where feasible
- Windows backend via CreateProcess + named pipes (different module)
- Stable semver guarantees
- Published to crates.io

## Integration with reveried

Reveried already uses `SO_REUSEADDR + SO_REUSEPORT` via inline `socket2` code in `crates/reverie-store/src/http/mod.rs::serve()`. Migration path:

1. Extract that code into `hotswap_listener::make_listener()` (done in the v0.0.0 scaffold).
2. Reveried imports `hotswap_listener = { path = "../hotswap-listener" }`.
3. Replace the inline socket building in reveried's `serve()` with `hotswap_listener::make_listener(addr)`.
4. Optionally adopt `HotSwapServer::new(config).serve(|listener, shutdown_rx| ...)` once v0.1 ships — adds the signal-driven drain + upgrade path.
5. Add a `--hotswap` CLI flag to reveried that opts into the full supervisor mode. Default behaviour stays compatible with the current direct-serve.

## Open questions

1. **Does reveried want fork+exec upgrade or systemd socket activation?** If we run under systemd (`systemd --user enable reveried`), activation is free. If we run under tmux manually, fork+exec is the only option.
2. **Counter preservation across restarts?** Nginx and Envoy preserve some state (counters, shared caches) across the cutover. v0.1 doesn't. For reveried, prometheus counters reset on restart which is fine because the scrape layer computes rates — but gauge freshness flickers.
3. **Do we want a `HotSwapServer::serve_with_supervisor()` variant** that also handles respawn on panic? Borrows from tokio-supervisor / shakmaty-supervisor patterns. Could be v0.2.
4. **Should the drain signal be `oneshot::Receiver<()>` or a cancellation token?** `tokio_util::sync::CancellationToken` is more idiomatic for long-running tasks that have multiple cancel points. Trade-off: adds a dep.

---

Control-room lane · research + design · scaffold already committed. Fill in v0.1 when it's the next priority.
