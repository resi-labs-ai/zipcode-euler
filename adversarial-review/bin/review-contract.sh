#!/bin/bash
# Adversarial review of ONE contract: every active panelist runs every mission for that
# contract, independently. Mirrors the prompt tree at prompts/src/<group>/<contract>/.
#
#   prompts/src/<group>/<contract>/_boot.md      shared boot context
#                                   1.md 2.md ... mission files
#                                   context.files inline manifest (for inline-api panelists)
#
# Output mirrors it at reports/src/<group>/<contract>/<panelist>-<mission>.md
#
# Panelist delivery (from panel.env TYPE):
#   session      -> Claude session drives it; script writes a PENDING stub to fill in.
#   agentic-cli  -> `codex exec` with _boot+mission; reads repo files itself.
#   inline-api   -> panelist_inline.py: _boot+mission+inlined context.files (Fugu).
#
# Usage:
#   source panel.env            # to export any API keys into the environment
#   bin/review-contract.sh bridge/szalpha
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # adversarial-review/
REPO="$(cd "$HERE/.." && pwd)"                            # repo root
# shellcheck disable=SC1091
source "$HERE/panel.env"

KEY="${1:?usage: review-contract.sh <group>/<contract>   e.g. bridge/szalpha}"
PROMPTS="$HERE/prompts/src/$KEY"
[ -d "$PROMPTS" ] || { echo "no prompt dir: $PROMPTS" >&2; exit 1; }
BOOT="$PROMPTS/_boot.md"
MANIFEST="$PROMPTS/context.files"
[ -f "$BOOT" ] || { echo "no _boot.md in $PROMPTS" >&2; exit 1; }

# Missions = sorted N.md (numeric), excluding _boot.md.
missions=()
for f in "$PROMPTS"/[0-9]*.md; do [ -f "$f" ] && missions+=("$f"); done
[ "${#missions[@]}" -gt 0 ] || { echo "no mission files (N.md) in $PROMPTS" >&2; exit 1; }

# Source under review = first file in the manifest (its basename drives the x-ray lookup).
SRC=""
if [ -f "$MANIFEST" ]; then
  SRC="$(grep -vE '^\s*#|^\s*$' "$MANIFEST" | head -1 | sed 's/:.*//' | xargs)"
fi
NAME="$( [ -n "$SRC" ] && basename "$SRC" .sol || basename "$KEY" )"
XRAY="$(find "$REPO/contracts/src" -path '*x-ray*' -name "$NAME.md" 2>/dev/null | head -1 || true)"

OUT="$HERE/reports/src/$KEY"
mkdir -p "$OUT"

echo "== adversarial review: $KEY =="
echo "missions: ${#missions[@]}   panelists: ${#PANEL[@]}   x-ray: ${XRAY:-<none>}"
echo "out: reports/src/$KEY/"
echo

pids=()
for mf in "${missions[@]}"; do
  mnum="$(basename "$mf" .md)"
  for entry in "${PANEL[@]}"; do
    IFS='|' read -r PNAME PTYPE PMODEL PBASE PKEYENV PEFFORT <<< "$entry"
    report="$OUT/$PNAME-$mnum.md"
    log="$OUT/$PNAME-$mnum.log"
    case "$PTYPE" in
      session)
        # Claude session fills this; leave a PENDING stub if not already written.
        [ -f "$report" ] || printf '<!-- PENDING: Claude session runs %s mission %s via Agent tool, boot=%s mission=%s -->\n' \
          "$PNAME" "$mnum" "$BOOT" "$mf" > "$report"
        echo "  [session] $PNAME-$mnum  -> run via Agent tool (stub written)"
        ;;
      agentic-cli)
        echo "  [run]     $PNAME-$mnum (agentic-cli)"
        ( bash "$HERE/bin/panelist-codex.sh" "$PMODEL" "$BOOT" "$mf" >"$report" 2>"$log" ) &
        pids+=("$!:$PNAME-$mnum")
        ;;
      inline-api)
        echo "  [run]     $PNAME-$mnum (inline-api)"
        ( python3 "$HERE/bin/panelist_inline.py" --api "${FUGU_API:-responses}" \
            --base-url "$PBASE" --model "$PMODEL" --api-key-env "$PKEYENV" \
            ${PEFFORT:+--effort "$PEFFORT"} \
            --boot "$BOOT" --mission "$mf" --manifest "$MANIFEST" \
            --max-tokens "${ADV_MAX_TOKENS:-32000}" --timeout "${ADV_TIMEOUT:-3600}" \
            >"$report" 2>"$log" ) &
        pids+=("$!:$PNAME-$mnum")
        ;;
      *) echo "  [skip]    $PNAME-$mnum (unknown type: $PTYPE)" ;;
    esac
  done
done

fail=0
if [ "${#pids[@]}" -gt 0 ]; then
  for p in "${pids[@]}"; do
    pid="${p%%:*}"; tag="${p##*:}"
    if wait "$pid"; then echo "  [ok]   $tag"; else echo "  [FAIL] $tag (see reports/src/$KEY/$tag.log)"; fail=1; fi
  done
fi

echo
echo "scripted panelists done. Pending for the Claude session:"
echo "  - run each session-panelist mission via the Agent tool (overwrite the PENDING stubs)"
echo "  - reconcile all reports in reports/src/$KEY/ against ${XRAY:-the x-ray}"
echo "  - write reports/src/$KEY/synthesis.md (findings + suggested tickets)"
exit "$fail"
