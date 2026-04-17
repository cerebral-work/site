# SQLite Backup/Restore — Research

**Status**: research complete, 2026-04-16
**Covers**: T62 (Backup/restore for engram SQLite)
**Conclusion**: use `rusqlite::backup` API for live backups; `VACUUM INTO` for cold snapshots; pre-dream auto-backup is the right trigger

---

## Options Evaluated

### Option A: `rusqlite::backup` (online backup API)

SQLite's online backup API (C: `sqlite3_backup_*`, Rust: `rusqlite::backup::Backup`) copies pages
while the source database remains writable. Works with WAL mode.

```rust
use rusqlite::{Connection, backup};
use std::time::Duration;
use std::path::Path;

pub fn backup_db(src: &Connection, dst: impl AsRef<Path>) -> rusqlite::Result<()> {
    let mut dst_conn = Connection::open(dst)?;
    let b = backup::Backup::new(src, &mut dst_conn)?;
    // 5 pages per step, 250ms sleep between steps → minimal read-lock contention
    b.run_to_completion(5, Duration::from_millis(250), Some(|p: backup::Progress| {
        tracing::debug!(remaining = p.remaining, total = p.pagecount, "backup step");
    }))
}
```

**`StepResult` variants**: `Done`, `More`, `Busy` (retriable), `Locked` (writer active, retriable).

**WAL interaction**: In WAL mode, the backup API copies the WAL frames. Between steps, WAL
checkpointing can occur normally. Use small page batches (5-10 pages) to avoid holding the read
lock across a full backup of a large DB.

**Crate feature**: requires `backup` feature in `Cargo.toml`:
```toml
rusqlite = { version = "0.31", features = ["backup", "bundled"] }
```

**Verdict**: best option for live backup while daemon is running.

---

### Option B: `VACUUM INTO <path>`

```sql
VACUUM INTO '/path/to/backup.db';
```

Creates a fully defragmented, compacted copy. Requires an exclusive lock for the duration — the
daemon cannot serve reads/writes during this. For a small DB (~6MB) this takes <100ms, but it's
not safe for production hot-path use.

**Verdict**: good for pre-release cold snapshots or offline tooling, not for `reverie backup` CLI.

---

### Option C: File copy (`cp engram.db engram.db.bak`)

Unsafe in WAL mode — WAL file (`engram.db-wal`) must be copied atomically with the main file.
A copy of just `engram.db` without the WAL may be inconsistent if a transaction is in progress.

**Verdict**: rejected. Use online backup API instead.

---

## Recommended Implementation (T62)

### CLI commands

```
reverie backup [--path <dst>]   # live backup to timestamped file
reverie restore <path>          # swap in a backup (daemon must be stopped)
```

Default backup path: `~/.engram/backups/engram-YYYY-MM-DDTHH:MM:SS.db`

### Backup flow

```rust
// In crates/reveried/src/ops/backup.rs
pub async fn run_backup(state: Arc<AppState>, dst: PathBuf) -> anyhow::Result<()> {
    let conn = state.store.connection()?;
    tokio::task::spawn_blocking(move || {
        backup_db(&conn, &dst)
    }).await??;
    tracing::info!(path = %dst.display(), "backup complete");
    Ok(())
}
```

Run in `spawn_blocking` — the backup API is synchronous (C FFI) and can be slow on large DBs.

### Restore flow

Restore must happen while the daemon is stopped (cannot restore into a live WAL-mode DB):

```rust
// CLI only — assert daemon is not running
pub fn run_restore(src: PathBuf, db_path: PathBuf) -> anyhow::Result<()> {
    // Rename existing DB aside, then copy backup into place
    let bak = db_path.with_extension("db.pre-restore");
    std::fs::rename(&db_path, &bak)?;
    std::fs::copy(&src, &db_path)?;
    // Also remove stale WAL/SHM if present
    let _ = std::fs::remove_file(db_path.with_extension("db-wal"));
    let _ = std::fs::remove_file(db_path.with_extension("db-shm"));
    Ok(())
}
```

### Pre-dream auto-backup (configurable)

```toml
[dream]
pre_cycle_backup = true    # default: true
backup_retention_days = 7  # prune backups older than 7 days
```

Trigger in `crates/reverie-dream/src/scheduler.rs` before each cycle starts. This gives a
rollback point if a dream cycle corrupts data.

---

## WAL Mode Interaction Summary

| Operation | WAL safe? | Notes |
|-----------|-----------|-------|
| `backup::Backup` | Yes | Uses read snapshot; writers continue |
| `VACUUM INTO` | Yes | But acquires exclusive lock for duration |
| `cp engram.db` | No | WAL file must be copied atomically |
| Restore (daemon stopped) | Yes | Remove WAL/SHM after copy |

---

## References

- rusqlite backup API: docs.rs/rusqlite/latest/rusqlite/backup/index.html
- rusqlite backup source: github.com/rusqlite/rusqlite/blob/master/src/backup.rs
- WAL mode best practices: sqlite.org/wal.html
