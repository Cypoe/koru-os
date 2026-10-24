#!/usr/bin/env bash
# Install the membrane + signal discipline into koru-os (or any repo).
# Adapted from koru's hooks/install.sh: same self-contained-corpus default,
# same seed-signals step; the WMFX cc_live leg is gone (no worldmodel engine
# here — the commit-msg Gates wall is this repo's measured instrument), and
# post-commit writes a local .git/signal-cards.jsonl ledger instead of NATS.
#
#   hooks/install.sh                 # install into THIS repo (self corpus)
#   hooks/install.sh /path/to/repo   # install into another repo
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CORPUS_ROOT="$(cd "$HERE/.." && pwd)"
TARGET="$(cd "${1:-$CORPUS_ROOT}" && pwd)"

HOOKS="$(git -C "$TARGET" rev-parse --absolute-git-dir)/hooks"
mkdir -p "$HOOKS" "$TARGET/concepts" "$TARGET/signals"
[ -e "$TARGET/concepts/.gitkeep" ] || : > "$TARGET/concepts/.gitkeep"
for h in commit-msg commit-msg.cjs post-commit post-commit.cjs pre-commit; do
  cp "$HERE/$h" "$HOOKS/$h"; chmod +x "$HOOKS/$h"
done

echo "installed commit-msg + post-commit + pre-commit -> $HOOKS"
echo "topology: self-contained (this repo is its own corpus — no .membrane pointer)"

# --- seed the belief-class + koru-os signals; never clobber a gardened one ---
if [ -d "$HERE/signals" ]; then
  for sig in "$HERE"/signals/*.signal; do
    [ -e "$sig" ] || continue
    dest="$TARGET/signals/$(basename "$sig")"
    [ -e "$dest" ] || cp "$sig" "$dest"
  done
  echo "signals                            -> $TARGET/signals/ (contradiction, correction, regime-change, oracle-lesson)"
fi

echo ""
echo "The commit-msg gate now requires, on every authored commit:"
echo "  ## World Model   Signal: <type> — <note>   (or Signals: acknowledged-none)"
echo "  ## Membrane      Action/Concept lineage, or Evolution: acknowledged-none"
echo "  ## Gates         required when koru/ or scripts/build-* is staged:"
echo "                   'name: pass/total' rows, or 'deferred — <reason>'"
echo ""
echo "Beliefs live in concepts/frag-<id>.md (frontmatter: type/id/provenance/ts)."
echo "Signals grow by declaration — declare one and its interface file is minted"
echo "(edit-distance-1 near-misses refuse, so typos can't fork the ontology)."
echo "Telemetry: .git/signal-cards.jsonl (append-only, untracked)."
