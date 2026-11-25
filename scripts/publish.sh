#!/usr/bin/env bash
# Publish committed work to origin/main the safe way (AGENTS.md "Working on a unit", last step):
#   fetch -> rebase onto origin/main -> full `check --impl <lang> --update` on exactly that tree -> commit
#   newly passing tests -> push -> verify the commit really is on origin/main. Retries when origin/main moves
#   during the check. Runs in a separate detached worktree, so your own worktree (and its bin/) is untouched and
#   you can keep working while it runs (run it in tmux: checks take minutes).
#
# usage: scripts/publish.sh --impl <lang> [--also <lang>,<lang>] [--tries N] [<commit-ish>]
#   <commit-ish>  what to publish (default: HEAD of the current worktree). Commit everything first.
#   --also        extra implementations whose ratchet must hold too (`--ratchet-only`), e.g. when you changed
#                 harness/ or tests/. Implementations with an empty passing.txt are skipped automatically.
# Exit 0 only when the pushed commit is an ancestor of origin/main. Logs: /tmp/publish-<user>-<pid>/.
set -uo pipefail
impl=""; also=""; tries=6; rev=HEAD
while [ $# -gt 0 ]; do
  case "$1" in
    --impl) impl=$2; shift 2;;
    --also) also=$2; shift 2;;
    --tries) tries=$2; shift 2;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) rev=$1; shift;;
  esac
done
[ -n "$impl" ] || { echo "publish: --impl is required" >&2; exit 2; }
src=$(git rev-parse --show-toplevel) || exit 2
[ -z "$(git -C "$src" status --porcelain --untracked-files=no)" ] || { echo "publish: uncommitted changes in $src; commit first" >&2; exit 2; }
commit=$(git -C "$src" rev-parse --verify "$rev^{commit}") || exit 2
name=$(basename "$src")
pub=/work-wt/.publish-$name
logs=/tmp/publish-$(id -un)-$$; mkdir -p "$logs"
if [ ! -d "$pub" ]; then git -C /work worktree add -q --detach "$pub" "$commit" || exit 2; fi
cd "$pub" || exit 2
git checkout -q --detach "$commit" || exit 2

for i in $(seq 1 "$tries"); do
  echo "publish: attempt $i/$tries"
  git fetch -q origin
  if ! git rebase origin/main >"$logs/rebase.log" 2>&1; then
    echo "publish: REBASE CONFLICT (resolve it in your own worktree, then rerun):"; cat "$logs/rebase.log"
    git rebase --abort; exit 1
  fi
  if ! ./harness/run check --impl "$impl" --update >"$logs/check-$impl.log" 2>&1; then
    echo "publish: check --impl $impl FAILED (regressions?), not pushing. Tail of $logs/check-$impl.log:"
    tail -40 "$logs/check-$impl.log"; exit 1
  fi
  for o in ${also//,/ }; do
    [ -s "impl/$o/passing.txt" ] || continue
    if ! ./harness/run check --impl "$o" --ratchet-only >"$logs/check-$o.log" 2>&1; then
      echo "publish: ratchet of $o FAILED, not pushing. Tail of $logs/check-$o.log:"; tail -40 "$logs/check-$o.log"; exit 1
    fi
  done
  if ! git diff --quiet -- "impl/$impl/passing.txt"; then
    git add "impl/$impl/passing.txt" && git commit -qm "$impl: passing.txt" || exit 1
  fi
  git fetch -q origin
  if ! git merge-base --is-ancestor origin/main HEAD; then echo "publish: origin/main moved during the check; retrying"; continue; fi
  if git push -q origin HEAD:main; then
    git fetch -q origin
    if git merge-base --is-ancestor HEAD origin/main; then
      echo "publish: PUSHED $(git rev-parse --short HEAD) ($(git log --oneline origin/main -1 | cut -c1-80))"
      grep -i -A20 'newly passing' "$logs/check-$impl.log" | head -20
      exit 0
    fi
  fi
  echo "publish: push rejected or not visible on origin/main; retrying"
done
echo "publish: GAVE UP after $tries attempts"; exit 1
