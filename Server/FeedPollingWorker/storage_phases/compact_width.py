# The compact form's encoded-width model (schema 2), computed rather than summed: every integer at its
# 12-digit maximum, every enumeration at its longest member, every nullable field at its wider alternative.
# It prints 6349; test_storage_phases_parse.py checks that number and that the model's property paths equal
# compact_keys.json, which the Rust emitter's own compact line must match too.
import json
I = 999999999999            # 12 digits
S = -999999999999           # signed 12 digits (date_vs_perf_ms only)
op = "x" * 32; res = "x" * 24; name = "settle"  # name ≤ 6 ("prepare" is 7: use the longest)
name = "prepare"
cp = {"kind": "prepare", "phase": I, "candidate_cursor": I, "status": "uncommitted"}   # status: committed|uncommitted|unknown
race = {"boundary": "transaction", "limit": "authority_deadline", "budget_ms": I, "authority_remaining_ms": I,
        "authority_scope": "bookkeeping", "start_ms": I, "end_ms": I, "status": "cancelled", "submitted": False,
        "steps_total": I, "steps_completed": I, "gate_reply_at_ms": I, "gate_wait_us": I, "sqlstate": "XXXXX",
        "overshoot_ms": I}
fail = {"ordinal": I, "op": op, "role": "interactive", "parent": I, "status": "dropped", "kind": "TlsUnavailable",
        "phase": "transaction", "outcome": "NotApplicable", "sqlstate": "XXXXX", "race": race, "overshoot_ms": I,
        "local_cap_sum_before_ms": I}
action = {"ordinal": I, "name": name, "result": res, "start_ms": I, "end_ms": I, "status": "cancelled",
          "ops_from": I, "ops_to": I, "r2_calls": I, "r2_ms": I, "start_checkpoint": cp, "end_checkpoint": cp,
          "wait_remaining_s": I, "outbox_release": {"acknowledged_txns": I, "attempted_txns": I, "unknown_txns": I},
          "affected_rows": I, "rows_returned": I}
line = {
 "schema": 2, "event": "storage_phases", "handler": "dead_letter", "outcome": "cancelled",  # ok|failed|cancelled|refused
 "wall_ms": I, "scheduled_lag_ms": I, "date_vs_perf_ms": S, "identity": "unreadable",
 "durations": {k: I for k in ["storage","r2","service","alert","publisher","queue","idle"]},
 "ops": {k: I for k in ["total","reads","writes","readbacks","identity","interactive","after_primary","dropped","detailed","omitted"]},
 "budget": {"handler_main_ms": I, "scope": "bookkeeping", "source": "DISPATCH_MAIN_MS"},
 "prior": {"taken_at_ordinal": I, "noncompleted_count": I, "over_local_cap_count": I, "close_failures": I,
           "lost_records": I, "all_within_local_caps": "unknown"},
 "recovery": {"admission_ms": I, "wait_remaining_s": I,
              "first_action": {"name": name, "start_checkpoint": cp, "end_checkpoint": cp},
              "last_action": {"name": name, "start_checkpoint": cp, "end_checkpoint": cp},
              "outbox_release": {"acknowledged_txns": I, "attempted_txns": I, "unknown_txns": I},
              "page_repeated": "unknown"},
 "summary": {"races": {k: I for k in ["total","completed","timeout","cancelled","driver","database","dropped"]},
             "connect": {"union_ms": I, "max_ms": I, "timeouts": I}, "read": {"max_ms": I, "timeouts": I},
             "transaction": {"max_ms": I, "timeouts": I}, "close": {"sum_ms": I, "max_ms": I}, "rollback": {"sum_ms": I},
             "gate_wait_us_max": I, "gate_reply_ms_max": I, "overshoot_ms_max": I, "budget_min_ms": I,
             "budget_min_limit": "authority_deadline", "local_cap_sum_ms": I, "affected_rows": I, "rows_returned": I},
 "primary": fail, "failures": [fail, fail], "failures_truncated": I,
 "action": [action, action], "actions_truncated": I,
 "chain": {"feed": "f" * 64, "generation": I, "step": I, "attempts": I, "message_digest": "a" * 16},
 "message_age_ms": I, "sent": {"step": I, "delay_s": I, "result": "uncertain"},
 "posts": {"n": I, "accepted": I, "retried": I},
 "truncated": {k: True for k in ["op_detail","op_races","actions","slowest","failures"]},
 "bytes_policy": "compact",
}
encoded = json.dumps(line, separators=(",", ":")) + "\n"
print(len(encoded.encode("utf-8")))
