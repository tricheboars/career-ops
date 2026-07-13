#!/usr/bin/env bash
# sync-ct203.sh — keep local checkout and the CT 203 scanner (10.1.30.50) in sync.
#
# CT 203 is the daily writer (triage.mjs adds tracker rows + reports via cron).
# Local sessions are interactive writers (in-session evals). To avoid split-brain:
#   - START of a local work session:  ./sync-ct203.sh pull
#   - END of a local work session:    ./sync-ct203.sh push
#   - Any time:                       ./sync-ct203.sh status
#   - Deploy pipeline code:           ./sync-ct203.sh push-scripts
#
# pull         = CT 203 → local   (tracker, reports, scan data, digests, follow-ups)
# push         = local → CT 203   (tracker, reports)
# push-scripts = local → CT 203   (pipeline scripts + providers/ + plugins/ + portals.yml)
#                After a push-scripts, run `npm install --omit=dev` on CT 203 if
#                package.json changed, then `node lib/location-gate.mjs` as a smoke test.
# status       = md5sum compare of pipeline scripts both sides

set -euo pipefail
CT=root@10.1.30.50
REMOTE=/opt/career-ops
LOCAL="$(cd "$(dirname "$0")" && pwd)"

# Full import closure of the CT 203 cron path (scan → triage → notify → followup →
# merge → listener/apply). v1.19.0 scan.mjs pulls in the shared helpers below and
# everything in providers/ + plugins/ (see DIRS).
SCRIPTS=(scan.mjs triage.mjs openrouter-eval.mjs notify-telegram.mjs followup-check.mjs \
         merge-tracker.mjs telegram-listener.mjs apply-orchestrator.mjs apply-auto.mjs \
         scan-builtin.mjs daily-pipeline.sh generate-interview-prep.mjs \
         role-matcher.mjs tracker-links.mjs tracker-parse.mjs tracker-utils.mjs \
         fingerprint-core.mjs verify-portals.mjs \
         lib/location-gate.mjs lib/ats-fetch.mjs lib/telegram.mjs)
DIRS=(providers plugins)

case "${1:-}" in
  pull)
    echo "⬇️  Pulling data from CT 203..."
    rsync -az "$CT:$REMOTE/data/applications.md" "$LOCAL/data/"
    rsync -az "$CT:$REMOTE/data/scan-history.tsv" "$LOCAL/data/"
    rsync -az "$CT:$REMOTE/data/pipeline.md" "$LOCAL/data/" 2>/dev/null || true
    rsync -az "$CT:$REMOTE/data/last-digest.json" "$LOCAL/data/" 2>/dev/null || true
    rsync -az "$CT:$REMOTE/data/follow-ups.md" "$LOCAL/data/" 2>/dev/null || true
    rsync -az "$CT:$REMOTE/reports/" "$LOCAL/reports/"
    echo "✅ Pulled. Tracker rows: $(grep -c '^|' "$LOCAL/data/applications.md")"
    ;;
  push)
    echo "⬆️  Pushing tracker + reports to CT 203..."
    rsync -az "$LOCAL/data/applications.md" "$CT:$REMOTE/data/"
    rsync -az "$LOCAL/reports/" "$CT:$REMOTE/reports/"
    echo "✅ Pushed."
    ;;
  push-scripts)
    echo "⬆️  Deploying pipeline scripts to CT 203..."
    for f in "${SCRIPTS[@]}"; do
      rsync -az "$LOCAL/$f" "$CT:$REMOTE/$f"
    done
    for d in "${DIRS[@]}"; do
      rsync -az --delete "$LOCAL/$d/" "$CT:$REMOTE/$d/"
    done
    rsync -az "$LOCAL/portals.yml" "$CT:$REMOTE/portals.yml"
    rsync -az "$LOCAL/package.json" "$CT:$REMOTE/package.json"
    echo "✅ Scripts deployed. If package.json changed: ssh $CT 'cd $REMOTE && npm install --omit=dev'"
    echo "   Smoke test: ssh $CT 'cd $REMOTE && node lib/location-gate.mjs && node scan.mjs --dry-run --company Tempus'"
    ;;
  status)
    for f in "${SCRIPTS[@]}"; do
      L=$(md5sum "$LOCAL/$f" 2>/dev/null | cut -d' ' -f1 || true)
      R=$(ssh "$CT" "md5sum $REMOTE/$f 2>/dev/null" | cut -d' ' -f1 || true)
      if [ -n "$L" ] && [ "$L" = "$R" ]; then echo "SAME  $f"; else echo "DIFF  $f"; fi
    done
    for d in "${DIRS[@]}"; do
      L=$(cd "$LOCAL" && find "$d" -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum | cut -d' ' -f1)
      R=$(ssh "$CT" "cd $REMOTE && find $d -type f 2>/dev/null | sort | xargs md5sum 2>/dev/null | md5sum" | cut -d' ' -f1)
      if [ -n "$L" ] && [ "$L" = "$R" ]; then echo "SAME  $d/"; else echo "DIFF  $d/"; fi
    done
    ;;
  *)
    echo "Usage: $0 pull|push|push-scripts|status"; exit 1 ;;
esac
