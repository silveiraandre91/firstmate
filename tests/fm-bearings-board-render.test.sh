#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state - never on the
# template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  # A build starts a listener for the board it publishes. Registered with
  # tests/lib.sh, not with a shell array: make_home runs inside a command
  # substitution, where an array append never reaches the caller.
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  # The build proves the board session is live before it arms anything, so the
  # stub reports the opened shape the real lavish-axi emits. This suite is about
  # what the template renders, not about session liveness, which
  # tests/fm-bearings-board.test.sh owns.
  cat > "$fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  --version) printf '0.1.61\n' ;;
  '')
    printf 'sessions[1]{file,status,url,pending_prompts}:\n'
    [ ! -s "$FM_HOME/lavish-open" ] \
      || printf '  %s,open,"http://127.0.0.1/session/render",0\n' "$(cat "$FM_HOME/lavish-open")"
    ;;
  poll)
    # Bounded, so a listener that escapes its test stops on its own.
    while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
    exit 75
    ;;
  *)
    real=$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")
    printf '%s\n' "$real" > "$FM_HOME/lavish-open"
    printf 'session:\n  status: opened\n'
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/lavish-axi"
  printf '%s\n' "$home"
}

# Build the board from <underway-json> plus <charted-json> and return what the
# renderer produced.
render_board() {  # <home> <underway-json> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 underway=$2 charted=$3 more=${4:-0} warning_more=${5:-0} data="$1/payload.json"
  jq -n --argjson underway "$underway" --argjson charted "$charted" \
    --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:$underway, landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$data"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$data" >/dev/null || fail "the board did not build"
  node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> alone and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  render_board "$1" '[]' "$2" "${3:-0}" "${4:-0}"
}

# Build the board from an arbitrary payload and print the built board path, so a
# test can drive the renderer or one of its captain controls.
build_payload() {  # <home> <payload-json>
  local home=$1 payload=$2
  printf '%s\n' "$payload" > "$home/payload.json"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$home/payload.json" >/dev/null || fail "the board did not build"
  printf '%s\n' "$home/.lavish/bearings-board.html"
}

render_payload() {  # <home> <payload-json>
  local home=$1
  node "$HARNESS" "$(build_payload "$home" "$2")" || fail "the built board could not be rendered"
}

surface_payload() {  # <extra-jq-object>
  jq -n --argjson extra "$1" '
    {schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-09-17T00:00:00Z",
     prs_live:false, captains_call:[], underway:[], landed:[], charted:[]} + $extra'
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}

test_a_long_decision_text_renders_in_full() {
  local home out long payload
  home=$(make_home long-decision-text)
  long=$(printf 'x%.0s' $(seq 1 600))
  payload=$(surface_payload "$(jq -n --arg t "$long" --arg r "$long" '{charted:[{id:"long",repo:"sample",title:$t,reason:$r,dispatchable:true}]}')")
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e --arg t "$long" --arg r "$long" '
    (.charted | length) == 1
      and .charted[0].title == $t
      and (.charted[0].sub | startswith($r))
      and (.charted[0].title | contains("…") | not)
      and (.charted[0].sub | contains("…") | not)
  ' >/dev/null || fail "a long decision text was clipped: $out"
  pass "a long charted title and reason render in full, with no ellipsis"
}

test_a_stopped_worker_renders_why_and_how_it_continues() {
  local home out payload
  home=$(make_home adrift)
  payload=$(surface_payload '{"stalled":[
    {"id":"stopped-1","kind":"dead","name":"Stopped worker","repo":"sample",
     "started":"2026-09-17T13:54:45Z","last_state":"working","why":"the worker process is gone",
     "next":"resume the worker on its existing copy","resumable":true},
    {"id":"paused-1","kind":"paused","name":"Paused worker","repo":null,
     "last_state":"paused","why":"waiting for an upstream release","next":"recheck later","resumable":false}
  ]}')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.stalled | length) == 2
      and (.stalled[0]
        | .title == "Stopped worker"
          and [.badges[] | .text] == ["dead"]
          and [.badges[0].tone] == ["danger"]
          and (.why | test("worker process is gone"))
          and (.next | test("resume the worker"))
          and (.sub | test("last state: working")) and (.sub | test("started 2026-09-17"))
          and .ticket == "#stopped-1" and .resume == true)
      and (.stalled[1]
        | [.badges[] | .text] == ["paused"]
          and [.badges[0].tone] == ["warn"]
          and .resume == false)
  ' >/dev/null || fail "a stopped worker did not render its state, reason, and continuation: $out"
  pass "a stopped worker shows why it stopped, how it continues, and a resume control only when it can resume"
}

test_my_take_renders_the_critique_with_pros_cons_and_a_recommendation() {
  local home out payload
  home=$(make_home my-take)
  payload=$(surface_payload '{"advice":[
    {"id":"advice-1","title":"Speed up CI","verdict":"CI is the bottleneck",
     "pros":["cheap to try","reversible"],"cons":["one flaky lane"],
     "recommendation":"Split the slow lane first","effort":"medium","risk":"low"}
  ]}')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.advice | length) == 1
      and (.advice[0]
        | .title == "Speed up CI"
          and (.verdict | test("bottleneck"))
          and .pros == ["cheap to try","reversible"]
          and .cons == ["one flaky lane"]
          and (.recommendation | test("Split the slow lane"))
          and ([.badges[] | .text] | index("effort medium") != null)
          and ([.badges[] | .text] | index("risk low") != null))
  ' >/dev/null || fail "My Take did not render the critique, pros, cons, and recommendation: $out"
  pass "My Take renders the verdict, pros, cons, and recommendation distinctly"
}

test_a_question_card_numbers_its_options_and_waits_on_the_captain() {
  local home out payload
  home=$(make_home question-card)
  payload=$(surface_payload '{"grill":[
    {"ticket":"ticket-1","prompt":"Which runner?","waiting_on":"captain",
     "options":[{"value":"a","label":"GitHub"},{"value":"b","label":"Local","hint":"no quota"}]}
  ]}')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.grill | length) == 1
      and (.grill[0]
        | .num == "G1" and .ticket == "#ticket-1"
          and (.prompt | test("Which runner"))
          and .options == ["(a) GitHub","(b) Local"]
          and .wait == "awaiting you")
  ' >/dev/null || fail "a question card did not render its number, ticket, and lettered options: $out"
  pass "a question card numbers its options and names who is waiting"
}

test_a_delivery_never_renders_as_concluded_and_carries_the_approval_box() {
  local home out payload
  home=$(make_home delivered)
  payload=$(surface_payload '{"landed":[],"delivered":[
    {"ticket":"ticket-9","repo":"sample","what":"Fix the parser","result":"all tests green",
     "delivered_at":"2026-09-17T13:00:00Z","report_url":"https://example.test/report"}
  ]}')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.landed | length) == 0
      and (.delivered | length) == 1
      and (.delivered[0]
        | .title == "Fix the parser" and .kasten == true and .ticket == "#ticket-9"
          and (.sub | test("all tests green")) and (.sub | test("delivered 2026-09-17T13:00:00Z"))
          and .wait == "awaiting you")
  ' >/dev/null || fail "a delivery rendered as concluded or without its approval box: $out"
  pass "a delivery stays awaiting the captain, never concluded, and carries the approval box"
}

test_the_kanban_renders_every_state_and_keeps_a_resolved_card_as_history() {
  local home out payload
  home=$(make_home kanban)
  payload=$(surface_payload '{"tickets":[
    {"id":"t-captain","title":"Decide the runner","state":"captain","repo":"proj","owner":"firstmate",
     "summary":"needs your call","opened_at":"2026-09-17T14:10:00Z","updated_at":"2026-09-17T14:12:00Z",
     "history":["14:10 ticket opened from your message"],"learnings":["the old runner costs 32 minutes"],
     "questions":[{"prompt":"Which runner?","options":[{"value":"a","label":"GitHub"}]}]},
    {"id":"t-doing","title":"Build it","state":"doing","repo":"proj","owner":"agent ship"},
    {"id":"t-blocked","title":"Blocked one","state":"blocked","repo":"proj","summary":"waiting on access"},
    {"id":"t-delivered","title":"Handed over","state":"delivered","repo":"proj","summary":"awaiting your approval"},
    {"id":"t-done","title":"Resolved matter","state":"closed","repo":null,
     "history":["14:30 approved by you"]}
  ]}')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    [.kanban[].label] == ["Waiting for you","In progress","Blocked","Delivered - awaiting you","Resolved by you"]
      and [.kanban[].count] == ["1","1","1","1","1"]
      and (.kanban[0].cards[0]
        | .ticket == "#t-captain" and .questions == 1
          and (.meta | test("who: firstmate")) and (.meta | test("opened 2026-09-17T14:10:00Z"))
          and .history == ["14:10 ticket opened from your message"]
          and .learnings == ["the old runner costs 32 minutes"])
      and (.kanban[3].cards[0] | .kasten == true)
      and (.kanban[4].cards[0] | .ticket == "#t-done" and .history == ["14:30 approved by you"])
  ' >/dev/null || fail "the kanban did not render every state with its card detail: $out"
  pass "the kanban renders every state, card history, learnings, and the approval box on a delivered card"
}

test_the_kanban_folds_in_the_standalone_delivered_and_question_sections() {
  local home out payload
  home=$(make_home kanban-fold)
  payload=$(surface_payload '{
    "delivered":[{"ticket":"d1","repo":"sample","what":"Handed over"}],
    "grill":[{"ticket":"g1","prompt":"Q?","options":[{"value":"a","label":"A"}]}],
    "tickets":[{"id":"d1","title":"Handed over","state":"delivered","repo":"sample",
      "questions":[{"prompt":"Q?","options":[{"value":"a","label":"A"}]}]}]
  }')
  out=$(render_payload "$home" "$payload")
  printf '%s' "$out" | jq -e '
    (.kanban | length) == 5
      and (.delivered | length) == 0 and (.grill | length) == 0
      and (.kanban[3].cards[0] | .kasten == true and .questions == 1)
  ' >/dev/null || fail "the kanban did not absorb the standalone delivered and question sections: $out"
  pass "the kanban owns the delivered and question cards when it is present"
}

test_each_execution_control_orders_its_own_key_not_a_decision() {
  local home board spec act key out payload
  home=$(make_home execution-controls)
  payload=$(surface_payload '{
    "captains_call":[{"key":"dec1","type":"decision","repo":"sample","title":"Pick A",
      "options":[{"value":"a","label":"A"}],"ticket":"dec1","waiting_on":"captain"}],
    "charted":[{"id":"c1","repo":"sample","title":"Queued work","reason":"gated","dispatchable":true}],
    "stalled":[{"id":"s1","kind":"dead","name":"Stopped","repo":"sample","last_state":"working",
      "why":"gone","next":"resume","resumable":true}],
    "delivered":[{"ticket":"d1","repo":"sample","what":"Handed over"}],
    "grill":[{"ticket":"g1","prompt":"Which DB?","options":[{"value":"a","label":"Postgres"}]}]
  }')
  board=$(build_payload "$home" "$payload")
  for spec in "dispatch-now:dispatch.c1" "resume:resume.s1" "approve:approve.d1" "answer:dec1" "grill:grill.1.g1"; do
    act=${spec%%:*}; key=${spec#*:}
    out=$(FM_HARNESS_ACTION="$act" FM_HARNESS_ANSWER=a node "$HARNESS" "$board") \
      || fail "the harness could not fire $act"
    printf '%s' "$out" | jq -e --arg key "$key" '
      .action.found == true and .action.error == ""
        and (.action.queued | length) == 1
        and .action.queued[0].data.question == $key
        and .action.queued[0].data.selection != ""
        and ([.underway[] | select(.badges[0].text == "accepted")] | length) == 1
        and ([.underway[] | select(.badges[0].text == "accepted")][0].ticket | length) > 1
    ' >/dev/null || fail "the $act control did not order $key and show it accepted in Underway: $out"
  done
  pass "every execution control orders its own key and shows the choice accepted in Underway"
}

test_a_kanban_card_orders_its_question_and_its_approval() {
  local home board out payload
  home=$(make_home kanban-controls)
  payload=$(surface_payload '{"tickets":[
    {"id":"t-ask","title":"Decide the runner","state":"captain","repo":"proj",
     "questions":[{"prompt":"Which runner?","options":[{"value":"a","label":"GitHub"}]}]},
    {"id":"t-delivered","title":"Handed over","state":"delivered","repo":"proj"}
  ]}')
  board=$(build_payload "$home" "$payload")
  out=$(FM_HARNESS_ACTION=card-question FM_HARNESS_ANSWER=a node "$HARNESS" "$board")
  printf '%s' "$out" | jq -e '
    .action.found == true and .action.queued[0].data.question == "grill.1.t-ask"
      and ([.underway[] | select(.badges[0].text == "accepted")] | length) == 1
  ' >/dev/null || fail "a kanban question did not order its own key: $out"
  out=$(FM_HARNESS_ACTION=card-approve node "$HARNESS" "$board")
  printf '%s' "$out" | jq -e '
    .action.found == true and .action.queued[0].data.question == "approve.t-delivered"
      and .action.queued[0].data.selection == "approve"
      and ([.underway[] | select(.badges[0].text == "accepted")] | length) == 1
  ' >/dev/null || fail "a kanban approval did not order the close of its ticket: $out"
  pass "a kanban card orders its question and its approval over the same channel"
}

test_the_board_notices_a_rebuild_without_a_reload_and_sounds_when_asked() {
  local home other board1 board2 out payload1 payload2
  home=$(make_home live-notice)
  other=$(make_home live-notice-next)
  payload1=$(surface_payload '{"delivered":[{"ticket":"d1","repo":"sample","what":"First"}]}')
  payload2=$(surface_payload '{"delivered":[{"ticket":"d1","repo":"sample","what":"First"},{"ticket":"d2","repo":"sample","what":"Second"}]}')
  board1=$(build_payload "$home" "$payload1")
  board2=$(build_payload "$other" "$payload2")
  out=$(FM_HARNESS_LIVE=1 FM_HARNESS_NEXT_HTML="$board2" FM_HARNESS_LIVE_REFRESH=1 FM_HARNESS_LIVE_SOUND=1 \
    node "$HARNESS" "$board1") || fail "the live harness failed"
  printf '%s' "$out" | jq -e '
    .live.available == true
      and .live.bannerHidden == false
      and .live.bannerTitle == "Board updated"
      and (.live.banner | test("delivered, awaiting you: 1"))
      and .live.chimes == 1
      and .live.intervalArmed == true
      and (.delivered | length) == 2
  ' >/dev/null || fail "a rebuilt board was not noticed live, or the re-render appended instead of replacing: $out"
  pass "the board re-renders in place on a rebuild, announces what changed, and chimes only when sound is on"
}

test_a_notice_survives_a_reload_because_it_is_stored_per_board_path() {
  local home other board1 board2 out payload1 payload2
  home=$(make_home live-f5)
  other=$(make_home live-f5-next)
  payload1=$(surface_payload '{"delivered":[{"ticket":"d1","repo":"sample","what":"First"}]}')
  payload2=$(surface_payload '{"delivered":[{"ticket":"d1","repo":"sample","what":"First"},{"ticket":"d2","repo":"sample","what":"Second"}]}')
  board1=$(build_payload "$home" "$payload1")
  board2=$(build_payload "$other" "$payload2")
  out=$(FM_HARNESS_LIVE=1 FM_HARNESS_SEED_SEEN_HTML="$board1" node "$HARNESS" "$board2") \
    || fail "the F5 harness failed"
  printf '%s' "$out" | jq -e '
    .live.bannerHidden == false
      and .live.bannerTitle == "Changed while you were away"
      and (.live.banner | test("delivered, awaiting you: 1"))
      and .live.chimes == 0
  ' >/dev/null || fail "a change made while the board was closed was not carried across a reload: $out"
  pass "a change that happened while the board was closed survives a reload, and does not sound without the toggle"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status() {
  local home out
  home=$(make_home underway-name)
  out=$(render_board "$home" '[
    {"id":"fm-board-name-r1","repo":"firstmate","name":"Show task names on the board",
     "state":"working","kind":"ship","doing":"no-mistakes: review round 2"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "Show task names on the board"
          and (.sub | test("no-mistakes: review round 2"))
          and (.sub | test("ship")) and (.sub | test("firstmate"))
          and [.badges[] | .text] == ["working"])
  ' >/dev/null || fail "an underway row did not lead with the task name: $out"
  pass "an underway row leads with the task name and still reports its run status"
}

test_an_underway_identifier_label_is_not_replaced_by_run_status() {
  local home out
  home=$(make_home underway-identifier)
  out=$(render_board "$home" '[
    {"id":"mate/child-1","repo":null,"name":"mate/child-1",
     "state":"working","kind":"secondmate","doing":"fixing the failing check"}
  ]' '[]')
  printf '%s' "$out" | jq -e '
    (.underway | length) == 1
      and (.underway[0]
        | .title == "mate/child-1"
          and (.sub | startswith("fixing the failing check · "))
          and (.title != "fixing the failing check"))
  ' >/dev/null || fail "an identifier-labelled underway row rendered as status-only: $out"
  pass "an underway identifier label is not replaced by run status"
}

test_charted_next_reads_newest_filed_first() {
  local home out
  home=$(make_home charted-order)
  out=$(render_board "$home" '[]' '[
    {"id":"oldest","repo":"sample","title":"Filed in June","reason":"queued","dispatchable":true,"filed":"2026-06-01"},
    {"id":"newest","repo":"sample","title":"Filed in August","reason":"queued","dispatchable":true,"filed":"2026-08-14T09:30:00Z"},
    {"id":"middle","repo":"sample","title":"Filed in July","reason":"queued","dispatchable":true,"filed":"2026-07-22"}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Filed in August", "Filed in July", "Filed in June"]
  ' >/dev/null || fail "charted next was not ordered newest filed first: $out"
  pass "charted next renders the most recently filed work first"
}

test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order() {
  local home out
  home=$(make_home charted-undated)
  out=$(render_board "$home" '[]' '[
    {"id":"undated-first","repo":"sample","title":"Undated one","reason":"queued","dispatchable":true},
    {"id":"dated","repo":"sample","title":"Dated","reason":"queued","dispatchable":true,"filed":"2026-07-22"},
    {"id":"undated-second","repo":"sample","title":"Undated two","reason":"queued","dispatchable":true,"filed":null}
  ]')
  printf '%s' "$out" | jq -e '
    [.charted[] | .title] == ["Dated", "Undated one", "Undated two"]
  ' >/dev/null || fail "undated charted rows did not keep a stable trailing order: $out"
  pass "charted rows with no filed date follow the dated rows in payload order"
}

test_an_underway_row_leads_with_the_task_name_and_keeps_its_run_status
test_an_underway_identifier_label_is_not_replaced_by_run_status
test_charted_next_reads_newest_filed_first
test_charted_rows_without_a_filed_date_follow_the_dated_rows_in_payload_order
test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_a_long_decision_text_renders_in_full
test_a_stopped_worker_renders_why_and_how_it_continues
test_my_take_renders_the_critique_with_pros_cons_and_a_recommendation
test_a_question_card_numbers_its_options_and_waits_on_the_captain
test_a_delivery_never_renders_as_concluded_and_carries_the_approval_box
test_the_kanban_renders_every_state_and_keeps_a_resolved_card_as_history
test_the_kanban_folds_in_the_standalone_delivered_and_question_sections
test_each_execution_control_orders_its_own_key_not_a_decision
test_a_kanban_card_orders_its_question_and_its_approval
test_the_board_notices_a_rebuild_without_a_reload_and_sounds_when_asked
test_a_notice_survives_a_reload_because_it_is_stored_per_board_path
