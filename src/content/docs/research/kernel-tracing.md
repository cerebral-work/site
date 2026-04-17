# Kernel-level tracing for the reverie env-map

Status: research (2026-04-08, control-room lane)
Source: background research subagent + control-room synthesis
Cross-refs: `docs/research/app-tracing-enforcement.md`, Part H env-map

## TL;DR

- **Primary path**: `procfs` crate + `/proc/<pid>/*` sampling every 2s. Zero root, zero kernel headers, ~5 ms per 10 PIDs.
- **eBPF / bpftrace**: not viable on WSL2 dev box — requires `CAP_SYS_ADMIN` + `CAP_PERFMON` + kernel headers we don't ship.
- **gdb / ptrace / gcore / strace / perf**: benevolent introspection of our own process tree. Opt-in, manual, invoked by meshctl keybinds for forensic snapshots — not on the hot path.

## Part 1 — WSL2 6.6 tracing surface

Kernel: `Linux 6.6.87.2-microsoft-standard-WSL2` (June 2025). Full Linux tracing subsystem is present but locked down without `CAP_SYS_ADMIN`.

**Available without root**:
- `/proc/<pid>/stat` — utime/stime/num_threads/state/rss
- `/proc/<pid>/status` — VmPeak, VmRSS, voluntary_ctxt_switches, nonvoluntary_ctxt_switches, SigQ
- `/proc/<pid>/io` — rchar/wchar/syscr/syscw/read_bytes/write_bytes/cancelled_write_bytes
- `/proc/<pid>/net/dev` — per-net-ns interface counters
- `/proc/<pid>/wchan` — current blocking kernel function (huge for "why is it stuck")
- `/proc/<pid>/schedstat` — scheduling accounting: runtime_ns, wait_sum_ns, pcount
- `/proc/<pid>/stack` — kernel stack trace
- `/proc/<pid>/fd/` — open file descriptors (count + targets)
- `/proc/<pid>/task/<tid>/*` — per-thread breakdown (all of the above, per TID)
- `/proc/meminfo`, `/proc/loadavg`, `/proc/stat` — system-wide

**Locked behind CAP_SYS_ADMIN**:
- `/sys/kernel/debug/tracing/*` (ftrace, tracefs)
- `perf_event_open()` for hardware counters
- eBPF program loading (`bpf()` syscall)
- bpftrace runtime (wraps the above)

**Available but broken on WSL2**:
- Kernel headers: **not shipped**. `linux-headers-generic` install is ~200 MB and still mismatches the microsoft-patched kernel ABI.
- BTF: `/sys/kernel/btf/vmlinux` exists (2.1 MB) — good news for CO-RE BPF if headers were present.

## Part 2 — Zero-root per-PID sampling (primary source)

One `procfs` read per target PID per tick gives a rich metric set:

| Field | Source | Type | Meaning |
|---|---|---|---|
| `state` | `/proc/<pid>/stat` field 3 | enum | R/S/D/Z/T — running/sleeping/disk-wait/zombie/stopped |
| `rss_bytes` | `/proc/<pid>/status VmRSS` | gauge | Resident memory |
| `vm_peak` | `/proc/<pid>/status VmPeak` | gauge | Peak virtual memory |
| `utime_ms` | `/proc/<pid>/stat` field 14 | counter | User CPU time |
| `stime_ms` | `/proc/<pid>/stat` field 15 | counter | Kernel CPU time |
| `num_threads` | `/proc/<pid>/stat` field 20 | gauge | Thread count |
| `voluntary_ctxt_switches` | `/proc/<pid>/status` | counter | Volunteer context switches |
| `nonvoluntary_ctxt_switches` | `/proc/<pid>/status` | counter | Preempted context switches |
| `io_read_bytes` | `/proc/<pid>/io read_bytes` | counter | Bytes read through disk layer |
| `io_write_bytes` | `/proc/<pid>/io write_bytes` | counter | Bytes written through disk layer |
| `io_syscr` | `/proc/<pid>/io syscr` | counter | Read syscall count |
| `io_syscw` | `/proc/<pid>/io syscw` | counter | Write syscall count |
| `wchan` | `/proc/<pid>/wchan` | string | Kernel function this task is sleeping in |
| `fd_count` | `ls /proc/<pid>/fd` | gauge | Open file descriptor count |
| `runtime_ns` | `/proc/<pid>/schedstat` field 1 | counter | Time spent running on CPU |
| `wait_sum_ns` | `/proc/<pid>/schedstat` field 2 | counter | Time spent waiting to run |

Sampling cost at 2s tick for ~10 PIDs: **~5 ms total** (measured). Negligible.

## Part 3 — eBPF / bpftrace (VIABLE via privileged Docker sidecar — 2026-04-08 update)

**Originally this section said eBPF wasn't viable on WSL2 because the user
distro lacks CAP + kernel headers. That's still true for running bpftrace
directly inside the user distro. But a privileged Docker sidecar container
bypasses both limits**, because Docker Desktop's VM hosts the kernel, not
the user distro, and the `quay.io/iovisor/bpftrace:latest` image ships its
own matching headers + BTF.

Confirmed experiment (2026-04-08T08:10Z):

```bash
docker run --rm -d --name reverie-bpf \
    --privileged --pid=host \
    --cap-add=SYS_ADMIN --cap-add=PERFMON --cap-add=BPF \
    -v /sys:/sys:ro -v /lib/modules:/lib/modules:ro \
    --entrypoint sleep \
    quay.io/iovisor/bpftrace:latest 300

docker exec reverie-bpf bpftrace -e '
    tracepoint:syscalls:sys_enter_* { @[probe] = count(); }
    interval:s:3 { exit(); }
'
# → Attaching 347 probes...
# → @[tracepoint:syscalls:sys_enter_<name>]: <count>
# → full histogram over 3s across ALL host PIDs
```

Result: **347 syscall tracepoints attached cleanly**, full histogram returned.
eBPF programs loaded into the host (Docker Desktop VM) kernel, executed, and
produced output. WSL2 + Docker Desktop is fine for eBPF if you're willing to
run a privileged sidecar.

### What this unlocks

The entire Part 6 integration plan gets a viable path now — instead of polling
`/proc/<pid>/*` from inside reveried, we run a long-lived `reverie-bpf` sidecar
container that:

1. Starts with `reveried-compose up` (add it to the existing obs stack compose file)
2. Runs a persistent bpftrace program that emits per-pid summaries every 10s
3. Writes summaries to a shared volume `/var/lib/reverie/bpf-summaries/<ts>.json`
4. Reveried's env_ticker reads the latest summary and merges it into `KernelHooks.per_pid[pid]`
5. meshctl TUI renders syscall rate, IO latency histograms, scheduler wakeups

### Real probes worth running in the sidecar

```bash
# Per-pid syscall rate histogram (the one we already tested)
tracepoint:syscalls:sys_enter_* { @[pid, probe] = count(); }
interval:s:10 { print(@); clear(@); }

# Block IO latency histogram per-pid (us)
tracepoint:block:block_rq_issue { @start[args->dev, args->sector] = nsecs; }
tracepoint:block:block_rq_complete /@start[args->dev, args->sector]/ {
    @lat_us[pid] = hist((nsecs - @start[args->dev, args->sector]) / 1000);
    delete(@start[args->dev, args->sector]);
}
interval:s:10 { print(@lat_us); clear(@lat_us); }

# TCP connect latency per-pid (us)
kprobe:tcp_v4_connect { @start[tid] = nsecs; }
kretprobe:tcp_v4_connect /@start[tid]/ {
    @connect_us[pid] = hist((nsecs - @start[tid]) / 1000);
    delete(@start[tid]);
}
interval:s:10 { print(@connect_us); clear(@connect_us); }

# Scheduler wakeups per-pid (context switches)
tracepoint:sched:sched_wakeup { @wakeups[pid] = count(); }
interval:s:10 { print(@wakeups); clear(@wakeups); }

# Memory allocation rate per pid (via mmap2)
tracepoint:syscalls:sys_enter_mmap { @mmap[pid] = count(); }
interval:s:10 { print(@mmap); clear(@mmap); }
```

### Caveats discovered

- **`--pid=host`** is required for the sidecar to see host PIDs by their real numbers. Without it, you see container-namespaced PIDs only.
- **`--privileged`** is a big hammer. Prefer `--cap-add=SYS_ADMIN --cap-add=PERFMON --cap-add=BPF` + specific volume mounts. Our test used `--privileged` for speed; the production sidecar should be scoped down.
- **`/lib/modules` mount** is read-only for safety and is what gives bpftrace access to kernel symbols.
- **`/sys` mount** gives access to `/sys/kernel/debug` tracing surface inside the container.
- **Startup cost** of bpftrace is ~1s per invocation. A persistent bpftrace process avoids this by staying attached across intervals. That's exactly the "long-running child" pattern we want.
- **Output parsing**: bpftrace's default text output is JSON-unfriendly. Use `bpftrace -f json` to get machine-readable output, then parse in reveried.
- **Attach cost**: 347 syscall tracepoints attached in about 200ms. Negligible once the process is running.

### Revised recommendation

The earlier Part 7 recommendation #4 ("long-running bpftrace child [hours, blocked]") is **no longer blocked**. Promote it:

**4.(REVISED) [1–2 hours] Long-running privileged bpftrace sidecar container**
- Add `reverie-bpftrace` service to the docker-compose obs stack
- Runs `bpftrace -f json -o /shared/summaries.json <script.bt>` with a persistent probe set
- Shared volume mount with reveried for the summary file
- Reveried reads and merges into the env-map every tick
- meshctl TUI gains a new "ebpf" sub-view or folds syscall rates into the kernel pane

This changes the effort/value calculation significantly. Kernel-level observability is on the table.

---

If root + kernel headers were available, the following one-liners would complement /proc sampling:

```bash
# syscall rate per pid
bpftrace -e 'tracepoint:syscalls:sys_enter_* /pid == 65170/ { @[probe] = count(); }'

# block IO latency histogram
bpftrace -e 'tracepoint:block:block_rq_issue { @start[args->dev, args->sector] = nsecs; }
             tracepoint:block:block_rq_complete /@start[args->dev, args->sector]/ {
                 @lat = hist(nsecs - @start[args->dev, args->sector]);
                 delete(@start[args->dev, args->sector]);
             }'

# tcp connect latency per pid
bpftrace -e 'kprobe:tcp_v4_connect { @start[tid] = nsecs; }
             kretprobe:tcp_v4_connect /@start[tid]/ {
                 @[comm, pid] = hist(nsecs - @start[tid]);
                 delete(@start[tid]);
             }'

# scheduler wakeups
bpftrace -e 'tracepoint:sched:sched_wakeup { @[comm] = count(); }'
```

**Integration shape if/when available**: run bpftrace as a long-running child of reveried, emit summaries to `/tmp/reverie-bpf-summary.json` every 10s, reveried reads and merges into `PidHooks.syscall_latency_p50/p99` on next tick. bpftrace startup cost is ~1s so it can't be re-launched per tick.

**Verdict for WSL2 now**: skip. Revisit when headers + CAP become available (probably never on this box).

## Part 4 — Benevolent introspection (gdb / ptrace / strace / perf)

Your own process tree is fair game. These tools don't run on the hot path — they're attached manually from a meshctl keybind for forensic snapshots.

| Tool | Use case | Root? | Invocation |
|---|---|---|---|
| `gcore <pid>` | Snapshot live process to core file | No (same-user) | `gcore -o /tmp/reveried.core 65170` |
| `gdb -p <pid>` | Attach, inspect symbols, detach | No (same-user, YAMA-permitting) | batch mode: `gdb -batch -ex 'p event_manager.in_flight' -ex 'detach' -p 65170` |
| `strace -p <pid> -c` | Sample syscall histogram for N seconds | No | `strace -p 65170 -c -S calls --summary-wall-clock --absolute-timestamps -- sleep 10` |
| `perf record -p <pid>` | CPU flamegraph, on-demand | Often yes (perf_event_paranoid) | `perf record -F 99 -p 65170 -g --call-graph dwarf -- sleep 10` |
| `/proc/<pid>/maps` | Memory map visualization | No | Parse + render per-pid bar chart |
| `/proc/<pid>/smaps` | Per-VMA RSS/PSS/USS breakdown | No | Expensive but precise |

**Integration into env-map + TUI**:
- `meshctl status` gains a keybind `F` → flamegraph current focused peer (spawns `perf record` for 10s, exits to flamegraph PNG).
- `meshctl status` gains a keybind `S` → strace sample (10s), render histogram in a modal overlay.
- `meshctl status` gains a keybind `G` → `gcore` snapshot to `~/.reverie/cores/<pid>-<ts>.core`, emit engram observation.
- Env-map exposes `gdb_attachable: bool` per pid (false if a ptracer already attached).
- YAMA ptrace scope: `/proc/sys/kernel/yama/ptrace_scope` — 0 means unrestricted, 1 means same-user descendants only. WSL2 default is usually 0 or 1; verify at boot.

**Safety invariant**: all of these are opt-in and manual. Don't invoke them from the 2s tick — they're expensive and intrusive.

## Part 5 — Rust ecosystem

| Crate | Version | Purpose | Verdict |
|---|---|---|---|
| `procfs` | 0.16 | Pure-Rust `/proc` parser | **Pick this.** Zero deps, thorough, well-maintained. |
| `libbpf-rs` | 0.24 | Rust wrapper for libbpf | Requires kernel headers + BTF + CAP. Not viable on WSL2. |
| `aya` | 0.13 | Pure-Rust eBPF framework | More ergonomic than libbpf-rs. Same WSL2 blockers. |
| `perf-event` | 0.4 | `perf_event_open()` wrapper | Needs CAP_SYS_ADMIN or paranoid=-1. Marginal. |
| `nix` / `rustix` | latest | ptrace/waitpid wrappers | For manual gdb-like introspection. Pick `rustix` (lighter). |

## Part 6 — Proposed integration

Extend `EnvSnapshot` (Part H) with:

```rust
#[derive(Clone, Serialize)]
pub struct KernelHooks {
    pub sampled_at: i64,             // unix seconds
    pub per_pid: HashMap<i32, PidHooks>,
    pub global: GlobalHooks,
}

#[derive(Clone, Serialize)]
pub struct PidHooks {
    pub pid: i32,
    pub cmd: String,
    pub state: char,
    pub rss_bytes: u64,
    pub utime_ms: u64,
    pub stime_ms: u64,
    pub num_threads: u32,
    pub vol_ctxt_sw: u64,
    pub nonvol_ctxt_sw: u64,
    pub io_read_bytes: u64,
    pub io_write_bytes: u64,
    pub io_syscr: u64,
    pub io_syscw: u64,
    pub wchan: Option<String>,
    pub fd_count: usize,
    pub runtime_ns: u64,
    pub wait_sum_ns: u64,
}

#[derive(Clone, Serialize)]
pub struct GlobalHooks {
    pub loadavg_1: f64,
    pub loadavg_5: f64,
    pub loadavg_15: f64,
    pub mem_total_kb: u64,
    pub mem_available_kb: u64,
    pub swap_used_kb: u64,
    pub cpu_count: usize,
    pub boot_time_unix: i64,
}
```

Sampling trigger: the env_ticker (Part H) on each 2s tick calls `sample_kernel_hooks(&[65170, <each claude session pid>, <redis>, <memcached>, <ollama>])` and populates `env.kernel_hooks`.

TUI pane: new view `ViewMode::Kernel` bound to `k` in the meshctl status hotkey map. Renders a table:

```
┌ kernel · per-pid sample ────────────────────────────────────────┐
│ PID     CMD          STATE  RSS      CPU%  CTXSW   IO    WCHAN  │
│ 65170   reveried     S      124 MiB  3.1%  142/12  0/0   futex  │
│ 21209   reveried     R      88 MiB   0.0%  0/0     0/0   -      │
│ 58793   claude       S      512 MiB  8.4%  89/3    2k/0  poll   │
│ ...                                                              │
└──────────────────────────────────────────────────────────────────┘
```

## Part 7 — Ranked recommendations

1. **[15 min] Add `procfs` dep to reveried + `sample_kernel_hooks()` function.** No root, no headers. Produces `PidHooks` for each passed-in PID. Plugs directly into the Part H env-map.
2. **[15 min] meshctl `ViewMode::Kernel` pane.** New hotkey `k`, ratatui Table rendering the kernel_hooks map. Colors: RSS growth yellow > 50%, red > 2× baseline; ctx-switch delta outliers flagged.
3. **[5 min] Per-thread breakdown.** Extend `PidHooks` with `tasks: HashMap<u32, TaskHooks>`. Call `procfs::process::Process::tasks()` per pid. Unlocks "which tokio worker is starved".
4. **[45 min] Prometheus exporter.** Add `kernel_rss_bytes{pid, cmd}` etc. to reveried `/metrics`. Grafana dashboard + long-term history + alerting.
5. **[15 min] Benevolent introspection keybinds.** `F` flamegraph, `S` strace sample, `G` gcore snapshot. All opt-in, all invoked from the focused peer row in the peers table.
6. **[hours, blocked]** bpftrace child process. Defer until root + kernel headers are available.

## WSL2 gotchas

- Microsoft-patched kernel ABI may not match upstream 6.6 headers exactly; building out-of-tree kernel modules is fragile.
- `/proc/sys/kernel/yama/ptrace_scope` should be checked at startup; if it's set to 2 or 3, gdb attach from the same user fails.
- WSL2 doesn't expose real hardware perf counters — `perf record` often falls back to software events only.
- `/proc/<pid>/net/*` shows per-network-namespace stats, and WSL2 uses a shared ns by default, so interface counters are host-wide not per-process.

---

Control-room lane · research only · informs Part H env-map design.
