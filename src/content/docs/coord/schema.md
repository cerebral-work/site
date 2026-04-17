# coord session-record schema versioning

This document describes how the coord protocol's session-record JSON schema
is versioned, evolved, and migrated. It is the companion to
[`protocol-v0.md`](./protocol-v0.md) (the wire/state contract) and
[`coord.proto`](./coord.proto) (the protobuf-shaped draft for v1+ backends).

## Files

| Path                                  | Role                                                                 |
| ------------------------------------- | -------------------------------------------------------------------- |
| `scripts/coord-schema-v1.json`        | Frozen v1 schema. Initial published version.                         |
| `scripts/coord-schema-vN.json`        | Frozen schema at version N. Never edited after release.              |
| `scripts/coord-schema-latest.json`    | Plain-file copy of the highest-numbered `coord-schema-vN.json`.      |
| `scripts/migrations/N_to_N+1.sh`      | Filter that lifts one record from schema N to N+1.                   |
| `scripts/migrations/README.md`        | Migration authoring contract.                                        |
| `.github/workflows/coord-schema-drift.yml` | CI gate for the above.                                          |

`coord-schema-latest.json` is a regular file, not a symlink. Symlinks are
mishandled by some CI fixtures and Windows checkouts; the byte-identical
copy is enforced by the drift workflow.

## Versioning contract

The schema follows protobuf-style discipline. Field numbers are reserved in
comments inside the JSON schema (`// #N`) so that the schema and
`coord.proto` can stay in lock-step.

Bump rules:

1. **Add a field** (optional, with a sane default) — additive, no version
   bump required. Readers preserve unknown fields in `blob._unknown`.
2. **Make a field required** — bump the schema integer.
3. **Rename a field** — forbidden. Add a new field, deprecate the old, drop
   it after a grace period (and bump on drop).
4. **Change a field's type** — forbidden. Add a new field with the new type,
   deprecate the old.
5. **Remove a field** — bump the schema integer. The removed field number
   stays reserved forever.

Every record carries a top-level `schema: <int>`. Readers MUST tolerate a
record with a higher `schema` than they were built against by either
refusing it cleanly or running it through the migration chain backwards
(if every intermediate migration is `REVERSIBLE=true`).

## Migration authoring rules

Full contract lives in [`scripts/migrations/README.md`](../../scripts/migrations/README.md).
Summary:

- **Pure filter.** Reads one record on stdin, emits the migrated record on
  stdout, exits 0 or non-zero. No filesystem, no network.
- **Header block** declares `REVERSIBLE`, `FROM_SCHEMA`, `TO_SCHEMA`, and
  `DESCRIPTION` in the first 20 lines.
- **Idempotent.** Running a migration twice on a record that's already at
  the target version is a no-op (echo input unchanged, exit 0).
- **Atomic.** Either fully succeeds with valid JSON on stdout, or fails
  with non-zero and nothing useful on stdout.
- **Pure bash + jq.** No new tooling deps.
- **Reversibility** means an opposite-direction migration produces a
  byte-identical record. If you mark a script `REVERSIBLE=true` you SHOULD
  ship the matching `N+1_to_N.sh` in the same PR.

## How `coord migrate` will consume this (deferred)

The `coord migrate` subcommand is intentionally **not** implemented in this
ticket — it lives behind a follow-up because `scripts/coord` is currently
under heavy concurrent edit by several other in-flight tickets. When it
lands, the runner will:

1. Walk every session record under `~/.claude/coord/sessions/`.
2. Read its `schema` field.
3. Resolve the chain of migration scripts from that version up to the
   highest numbered `scripts/coord-schema-vN.json`.
4. Pipe the record through each script in order, writing to a tempfile
   and renaming on success.
5. Refuse to downgrade unless every intermediate migration is
   `REVERSIBLE=true` and the matching down-migrations exist.

The header declarations in each script are the contract `coord migrate`
will rely on, which is why CI enforces them today even before the runner
exists.

## CI behavior

`.github/workflows/coord-schema-drift.yml` runs on any PR that touches
`scripts/coord`, `scripts/coord-schema-*.json`, `scripts/migrations/**`,
or `docs/coord/**`. It enforces:

1. Every `scripts/coord-schema-vN.json` parses as JSON.
2. `scripts/coord-schema-latest.json` exists and parses as JSON.
3. `scripts/coord-schema-latest.json` is byte-identical to the
   highest-numbered `scripts/coord-schema-vN.json` (no drift).
4. Every script in `scripts/migrations/` is executable and carries the
   four required header declarations.
5. Every script accepts a sample session record on stdin, exits 0, and
   emits valid JSON.
6. Every script is idempotent: running it twice on its own output also
   exits 0 and emits valid JSON.

Pure bash + jq, no new CI deps.
