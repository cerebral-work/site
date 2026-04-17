# Coord Schema Migrations

How we evolve the session / lock / message record shapes without breaking
cooperating Claude sessions or losing data.

Source of truth: `~/.claude/coord/schema-v0.json` (human-readable validator)
and `docs/coord/coord.proto` (codegen target for v1+). **Every field in one
mirrors the other.**

## 1. Ground rules

1. **Never rename a field.** If a name is wrong, add a new field with the right
   name, mark the old one `// deprecated: use X`, and keep writing both for
   a grace period of at least 1 minor version.
2. **Never change a field's type.** Add a new field with the new type; drop
   the old after the grace period.
3. **Never reuse a field number.** Once used, add to the `reserved` range in
   the `.proto` file. JSON Schema mirrors this by listing reserved numbers in
   description comments.
4. **Bump `schema`** only when a change is *not* fully backward-compatible.
   Additive changes (new optional field) don't need a bump; deletions and
   type changes do.
5. **Preserve unknown fields.** Readers stash everything they don't recognize
   into `blob._unknown` so round-trip doesn't lose data when a newer writer's
   record is read by an older reader. This matches protobuf's "unknown fields"
   behavior.

## 2. Version history

| schema | status | changed | grace-period |
|---|---|---|---|
| 1 | current | initial | n/a |
| 2 | planned | add `graph_id` on LockRecord for multi-lock transactions | |
| 3 | planned | `kind` becomes an enum instead of open string | v2→v3 grace |

## 3. Migration flow (when we ship schema 2)

### Step 1: additive land

- Add new field(s) with new field numbers to `.proto` and `schema-v0.json`
- Keep `schema: 1` in existing writers
- Bump `SchemaVersion.maximum` to 2 in the JSON schema (accepts both)
- Writers can start emitting `schema: 2` only after **every live session has
  upgraded** (verified via `coord peers | jq '.[].capabilities'`)

### Step 2: capability gate

- Writers check `coord peers` before emitting v2 records
- If any peer's `capabilities` lacks `coord-v2`, writer falls back to v1
- When all peers report `coord-v2`, emit v2 records

### Step 3: deprecation

- Old fields are marked deprecated in comments
- Readers still honor them for read-back compat
- Writers stop emitting after 30 days

### Step 4: removal (major version boundary)

- Drop fields from the `.proto` file (move to `reserved`)
- Drop from JSON schema
- Readers reject v1 records with a clear error
- Users run `coord migrate --to 2` to rewrite any stale v1 files

## 4. `coord migrate` subcommand (scaffold for v0)

Today's v0 ships a no-op scaffold:

```
coord migrate [--from N] [--to M] [--dry-run]
```

- v0 only has schema 1, so `coord migrate` is a no-op and prints "nothing to do"
- Future versions plug migration functions keyed on `(from, to)` pairs
- `--dry-run` reads + re-validates without writing
- Each migration function is **reversible** where possible (fields dropped on
  downgrade are stashed in `blob._dropped_vN`)

### Migration registry shape

```rust
pub struct Migration {
    pub from: u32,
    pub to:   u32,
    pub fwd:  fn(&Value) -> Result<Value>,
    pub rev:  Option<fn(&Value) -> Result<Value>>,  // None = irreversible
    pub notes: &'static str,
}

static MIGRATIONS: &[Migration] = &[
    // no migrations yet — v0 only has schema 1
];
```

When v2 ships:

```rust
fn migrate_1_to_2(v: &Value) -> Result<Value> {
    let mut next = v.clone();
    next["schema"] = json!(2);
    // Additive: new fields default to null / empty
    Ok(next)
}

fn migrate_2_to_1(v: &Value) -> Result<Value> {
    let mut next = v.clone();
    // Stash v2-only fields under blob._dropped_v2 for reversibility
    let dropped = json!({
        "graph_id": next.get("graph_id"),
    });
    next["blob"]["_dropped_v2"] = dropped;
    next.as_object_mut().unwrap().remove("graph_id");
    next["schema"] = json!(1);
    Ok(next)
}

MIGRATIONS = &[
    Migration {
        from: 1, to: 2, fwd: migrate_1_to_2, rev: Some(migrate_2_to_1),
        notes: "v2: add LockRecord.graph_id for multi-lock transactions",
    },
];
```

## 5. Protobuf cut-over (v0 JSON → v1 protobuf)

**Trigger conditions** (from `protocol-v0.md §12`):

1. Two Claude sessions on different hosts need to coordinate, OR
2. Filesystem becomes a performance bottleneck (hundreds of ops/sec), OR
3. We need an audit log across reboots

**When triggered**:

1. Run `protoc --rust_out=crates/reverie-coord/src/pb/ docs/coord/coord.proto`
2. Compile `crates/reverie-coord` with `LocalFsBackend`, `RedisBackend`, and
   any other implementations. All implement a common `CoordBackend` trait.
3. The `coord` shell binary gains a `--backend=local|redis` flag; default stays
   `local` for backward compat.
4. Migration path for existing v0 data: `coord migrate --from-backend=local --to-backend=redis`
   reads every JSON file under `/tmp/claude-coord/` and `HSET`s it into Redis.
   Idempotent, safe to re-run.
5. Shell binary either (a) links against the compiled Rust CLI via a subprocess
   or (b) stays shell and shells out to a `reverie-coord` binary for the Redis
   path. Preference: (b) for minimum disruption.

**Rollback**: `coord migrate --from-backend=redis --to-backend=local` does the
inverse. Both backends can coexist during the transition.

## 6. Compatibility matrix

| writer | reader v1 | reader v2 | reader v3 |
|---|---|---|---|
| v1 | read, round-trip | read + default v2 fields | refuse (major boundary) |
| v2 | read (ignore unknowns, preserve in `_unknown`) | full | read + default v3 fields |
| v3 | — | (ignore unknowns) | full |

Never allow **silent data loss**. A v2 reader reading a v1 record should
surface a warning ("defaulting 3 v2 fields on older record") but not fail. A
v1 reader reading a v2 record should preserve unknown fields in the round-trip
so nothing is dropped if the v1 reader re-writes the record.

## 7. Testing migrations

Each migration function ships with:

- A fixture pair under `crates/reverie-coord/tests/migrations/fixtures/v<from>-to-v<to>/`
- `input.json` (starting state) and `expected.json` (after forward migration)
- A reversibility test: forward + backward should land on `input.json`
  (modulo any intentionally lossy fields, documented in the migration's
  `notes`)
- Replay test: migration is idempotent (running it twice = running it once)

## 8. Deprecation telemetry

The `coord` CLI keeps a log of deprecation warnings at
`/tmp/claude-coord/deprecations.log`:

```
2026-04-07T16:45:00Z v1 record read, v2 writer active, 3 fields defaulted
```

When users `coord status`, a summary warns if any peer is running an older
schema version, so upgrades don't ambush anyone.

## 9. Open questions

- **Do we need a major version on top of the `schema` integer?** e.g.
  `schema: 1.2.3` with semver. Answer for now: **no**, keep it a flat integer.
  Semver complexity isn't worth it until we have at least 5 schema versions to
  manage, and by then v1 Redis will probably have shipped with real protobuf.
- **Should `blob._unknown` be a flat object or nested by version?** Leaning
  nested: `blob._unknown.v2 = {...}` so we can tell which version's fields
  were preserved. Deferred until we actually have a v2.
- **What happens on `schema` downgrade?** (e.g. v2 reader sees v1 record and
  "upgrades" it in place). Answer: **don't upgrade on read**. Only upgrade
  via explicit `coord migrate`. Prevents lost work from mixed-version mesh.
