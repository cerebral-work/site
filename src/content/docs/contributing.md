# Contributing to Reverie

## Developer Certificate of Origin (DCO)

All contributions must be signed off under the
[Developer Certificate of Origin](https://developercertificate.org/) (DCO).
By adding a `Signed-off-by` line to your commit messages, you certify that
you wrote the contribution or otherwise have the right to submit it under
the project's license.

```bash
git commit -s -m "your commit message"
```

## Development Setup

```bash
git clone git@github.com:todie/reverie.git
cd reverie
make hooks   # install pre-commit
make build   # verify compilation
make test    # run tests
```

## Workflow

1. Create a branch from `main`
2. Make changes, ensure `make ci-check` passes
3. Commit with conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`
4. Open a PR linked to the Linear issue

## Code Style

- `cargo fmt` enforced via pre-commit
- `cargo clippy -- -D warnings` enforced via pre-commit
- `cargo deny check` for dependency audit
- No `unwrap()` in library code (ok in tests)
- `thiserror` for library errors, `anyhow` for application errors

## Architecture Decisions

See `docs/daemon-spec.md` for the full architecture. Key principles:
- Every design choice should map to a neuroscience mechanism
- Every change must show measurable LoCoMo improvement (see `docs/locomo-harness.md`)
- The fast path (session writes) and slow path (dream consolidation) must remain separate (CLS theory)
