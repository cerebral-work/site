#!/usr/bin/env bash
# sync-docs.sh — copy public-safe docs from the private reverie repo
# into src/content/docs/ for the cerebral.work website.
#
# Idempotent. Run before `bun run build`. Excludes internal-only files
# (CLAUDE.md, backlog, ops runbooks, mvp-b scratch).
set -euo pipefail

SRC="${SRC:-$HOME/projects/reverie}"
DST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/src/content/docs"

if [ ! -d "$SRC/docs" ]; then
    echo "sync-docs: SRC not found: $SRC/docs" >&2
    exit 1
fi

mkdir -p "$DST"/{architecture,coord,design,research}

# Whitelist — paths are relative to $SRC
FILES=(
    # top-level
    CHANGELOG.md
    CONTRIBUTING.md
    SECURITY.md
    # reverie core
    docs/daemon-spec.md
    docs/paper.md
    docs/locomo-harness.md
    docs/engram-api-surface.md
    docs/llm-offload.md
    docs/operations.md
    docs/coord-log-fanout.md
    docs/log-sidecar.md
    docs/log-sidecar-redis.md
    # architecture
    docs/architecture/adr-005-search-cutover.md
    docs/architecture/adr-006-multi-factor-scoring.md
    docs/architecture/adr-007-mesh-file-locking.md
    docs/architecture/adr-008-redis-schemas.md
    docs/architecture/pseudoagents.md
    docs/architecture/signed-salience-pulse.md
    docs/architecture/sleepers.md
    # coord
    docs/coord/protocol-v0.md
    docs/coord/heartbeat.md
    docs/coord/observability.md
    docs/coord/schema.md
    docs/coord/migrations.md
    docs/coord/installed-baseline.md
    # design
    docs/design/placement-heuristics.md
    docs/design/sentinel-handoff-eventmanager.md
    # research — the subset that stands alone
    docs/research/INDEX.md
    docs/research/portability.md
    docs/research/security-agent-v2.md
    docs/research/ebbinghaus-stability-fsrs.md
    docs/research/sqlite-backup-restore.md
    docs/research/dream-cycle-rate-limiting.md
    docs/research/engram-as-policy-substrate.md
    docs/research/hotswap-listener-design.md
    docs/research/app-tracing-enforcement.md
    docs/research/kernel-tracing.md
    docs/research/ldap-kerberos.md
    docs/research/rust-monorepo-publishing.md
)

# Collection layout: flatten docs/ prefix, strip the rest into slug-friendly paths.
#   CHANGELOG.md                            -> changelog.md
#   docs/daemon-spec.md                     -> daemon-spec.md
#   docs/architecture/pseudoagents.md       -> architecture/pseudoagents.md
#   docs/coord/protocol-v0.md               -> coord/protocol-v0.md
#   docs/design/placement-heuristics.md     -> design/placement-heuristics.md
#   docs/research/portability.md            -> research/portability.md
copied=0
skipped=0
for f in "${FILES[@]}"; do
    src_path="$SRC/$f"
    if [ ! -f "$src_path" ]; then
        echo "sync-docs: SKIP missing: $f"
        skipped=$((skipped+1))
        continue
    fi
    case "$f" in
        CHANGELOG.md)        dst_path="$DST/changelog.md" ;;
        CONTRIBUTING.md)     dst_path="$DST/contributing.md" ;;
        SECURITY.md)         dst_path="$DST/security.md" ;;
        docs/architecture/*) dst_path="$DST/architecture/${f##*/}" ;;
        docs/coord/*)        dst_path="$DST/coord/${f##*/}" ;;
        docs/design/*)       dst_path="$DST/design/${f##*/}" ;;
        docs/research/*)     dst_path="$DST/research/${f##*/}" ;;
        docs/*)              dst_path="$DST/${f##*/}" ;;
        *)                   dst_path="$DST/${f##*/}" ;;
    esac
    # Only copy when content actually differs
    if [ -f "$dst_path" ] && cmp -s "$src_path" "$dst_path"; then
        :
    else
        mkdir -p "$(dirname "$dst_path")"
        cp "$src_path" "$dst_path"
        copied=$((copied+1))
    fi
done

echo "sync-docs: copied=$copied skipped=$skipped total=${#FILES[@]}"
