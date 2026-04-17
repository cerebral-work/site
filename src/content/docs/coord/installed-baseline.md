# Coord Installed Baseline

This file records the sha256 of the canonical tracked `scripts/coord` at
the time its in-repo tracking was formalized. The **tracked** copy in
`scripts/coord` is the source of truth; `~/.claude/bin/coord` is a local
install artifact derived from it via `make install-coord`.

| Field | Value |
|---|---|
| Canonical location | `scripts/coord` (in-repo) |
| Install target | `~/.claude/bin/coord` |
| sha256 (tracked) | `38d8aa937530a5371c073543d5bbe7506d08f99008c81ac9a1ab2f39a5027419` |
| Captured | 2026-04-07 |
| Ticket | TOD-446 |
| Schema | `scripts/coord-schema-v0.json` (schema v1) |

## History

- Originally TOD-446 was scoped to track `~/.claude/bin/coord` as the
  canonical copy. TOD-430 (strict unknown-flag parsing) landed concurrently
  and made the tracked `scripts/coord` authoritative instead. This baseline
  records the post-TOD-430 tracked sha.
- The pre-TOD-430 installed binary has sha
  `918c6242e0bc6ca33c1fbcdd7ba15833548221a8d6718eb8d96885cc3cd81da4` and
  should be considered **stale**. Run `make install-coord` on any machine
  still carrying that version to pick up the strict-parsing fix.

## Verifying

```bash
# Check the tracked file matches the recorded baseline:
sha256sum scripts/coord
# expected: 38d8aa937530a5371c073543d5bbe7506d08f99008c81ac9a1ab2f39a5027419

# Check what's installed vs what's tracked:
sha256sum scripts/coord ~/.claude/bin/coord
```

If the two hashes differ, the install target is out of date:

```bash
make install-coord
```

## Installation

```bash
make install-coord
```

See the top-level `Makefile` for details. The target is idempotent,
copies (not symlinks, for mkdir-based test fixture safety), and prints
the installed sha256 for verification.

## Drift detection

`.github/workflows/coord-docs-sync.yml` enforces that every subcommand in
`scripts/coord` is documented in `docs/coord/protocol-v0.md` and vice
versa. The pre-commit hooks (post-TOD-458) skip `scripts/coord` for
`trailing-whitespace` and `end-of-file-fixer` to preserve the
byte-identical invariant this baseline depends on.
