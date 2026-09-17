#!/usr/bin/env bash
# Regression tests for the Treehouse recorded-path spelling (teardown-treehouse-path).
#
# `treehouse return --force <path>` does not resolve the path it is handed: it
# matches that text against the string Treehouse wrote into
# <pool>/treehouse-state.json and refuses every other spelling with "worktree
# <path> is not managed by treehouse". The two spellings diverge whenever the
# pool root is reached through a symlink - here $HOME/.treehouse is a symlink
# onto /workspace/treehouse - so a finished worker's slot could never be
# returned and the task stranded unclosed (observed 2026-09-17).
#
# These cases pin the fix: the spelling the pool itself recorded is what gets
# handed back, resolved by directory identity, while a worktree this pool does
# not record keeps the path it already had - so Treehouse's own refusal still
# stands and no other slot's name is ever borrowed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-treehouse-path)

# The fake Treehouse reproduces the behaviour under test: it accepts only the
# exact string its pool recorded and refuses everything else the way the real
# binary does. A teardown that hands it the resolved path therefore fails
# exactly as it did in production.
FAKE_TREEHOUSE=$(cat <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
if [ "${1:-}" = return ]; then
  last=${!#}
  if [ "$last" != "${FM_FAKE_TREEHOUSE_RECORDED:-}" ]; then
    printf 'worktree %s is not managed by treehouse\n' "$last" >&2
    exit 1
  fi
fi
exit 0
SH
)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/project" "$TMP_ROOT/$dir/store/pool/1"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  printf '%s\n' "$FAKE_TREEHOUSE" > "$TMP_ROOT/$dir/fakebin/treehouse"
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

# The pool root spelling a symlinked root produces, and the two names that reach
# it: <case>/root is a symlink onto <case>/store, exactly like
# /root/.treehouse onto /workspace/treehouse.
pool_paths() {  # <case>
  local dir=$1
  RECORDED_SPELLING="$dir/root/pool/1/project"
  RESOLVED_SPELLING="$dir/store/pool/1/project"
  ln -sfn "$dir/store" "$dir/root"
  # What this case's pool recorded; the fake Treehouse refuses everything else,
  # exactly like the real binary.
  export FM_FAKE_TREEHOUSE_RECORDED="$RECORDED_SPELLING"
}

mark_pool_slot() {  # <case> <recorded-path> [recorded-slot-worktree]
  local dir=$1 recorded=$2 worktree=${3:-}
  [ -n "$worktree" ] || worktree="$dir/store/pool/1/project"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$recorded" \
    > "$dir/store/pool/treehouse-state.json"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

recorded_path_of() {  # <case> <path>
  local dir=$1 path=$2
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    bash -c '. "$1"; fm_treehouse_recorded_slot_path "$2"' _ "$WAKE_LIB" "$path"
}

test_symlinked_pool_root_returns_the_recorded_spelling() {
  local dir id=spelled-slot

  dir=$(make_case symlinked-root)
  pool_paths "$dir"
  mark_pool_slot "$dir" "$RECORDED_SPELLING"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$RESOLVED_SPELLING" "project=$dir/project" "kind=scout"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a symlinked-pool task failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "teardown left the finished task's record behind"
  grep -Fq "treehouse <return> <--force> <$RECORDED_SPELLING>" "$dir/runtime.log" \
    || fail "teardown did not hand Treehouse the spelling its pool recorded: $(cat "$dir/runtime.log")"
  assert_not_contains "$(cat "$dir/runtime.log")" "<$RESOLVED_SPELLING>" \
    "teardown handed Treehouse the resolved spelling its pool refuses"

  pass "fm-teardown: a pool root reached through a symlink is returned under the spelling Treehouse recorded"
}

test_recorded_lookup_is_keyed_on_the_directory_not_the_spelling() {
  local dir resolved other_repo

  dir=$(make_case lookup-identity)
  pool_paths "$dir"
  mark_pool_slot "$dir" "$RECORDED_SPELLING"
  resolved=$(cd "$RECORDED_SPELLING" && pwd -P) || fail "fixture slot is uninspectable"

  assert_equals "$RECORDED_SPELLING" "$(recorded_path_of "$dir" "$resolved")" \
    "the resolved spelling did not resolve to the spelling the pool recorded"
  assert_equals "$RECORDED_SPELLING" "$(recorded_path_of "$dir" "$RECORDED_SPELLING")" \
    "the recorded spelling did not round-trip"
  assert_equals "$dir/project" "$(recorded_path_of "$dir" "$dir/project")" \
    "a path outside any pool was rewritten instead of kept as given"

  # Another repository's worktree is a different directory: the pool lists this
  # one slot, so nothing may be returned in its name.
  other_repo="$dir/other-project"
  fm_git_init_commit "$dir/other-project"
  assert_equals "$other_repo" "$(recorded_path_of "$dir" "$other_repo")" \
    "a worktree of another repository was rewritten to a recorded slot"

  pass "fm-teardown: recorded-spelling lookup follows the directory, never the text or a neighbouring slot"
}

test_unrecorded_worktree_is_never_returned_under_another_slots_name() {
  local dir id=unrecorded-slot rc

  dir=$(make_case unrecorded-slot)
  pool_paths "$dir"
  mark_pool_slot "$dir" "$RECORDED_SPELLING"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$RESOLVED_SPELLING" "project=$dir/project" "kind=scout"

  # A record this pool does not hold: no entry matches, so Treehouse keeps
  # being the one that refuses it, and the record survives the refusal.
  printf '{"worktrees":[{"name":"2","path":"%s"}]}\n' "$dir/root/pool/2/project" \
    > "$dir/store/pool/treehouse-state.json"
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown returned a worktree its pool never recorded"
  assert_present "$dir/home/state/$id.meta" "refused teardown removed the task record"
  assert_contains "$(cat "$dir/stderr")" "teardown aborted" \
    "refusal did not report the failed Treehouse return"
  assert_present "$dir/home/state/$id.meta" "refused teardown discarded the record it could not return"

  pass "fm-teardown: a worktree the pool does not record is refused, never returned under another slot's name"
}

test_symlinked_pool_root_returns_the_recorded_spelling
test_recorded_lookup_is_keyed_on_the_directory_not_the_spelling
test_unrecorded_worktree_is_never_returned_under_another_slots_name
