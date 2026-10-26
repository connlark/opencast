"""The consumer-side parser of FeedPolling's `storage_phases` line (schema 2).

Every evidence class is computed from ONE row and exactly the inputs its table
names (row objects, root scalars, and the reader-joined platform metadata); a
class whose input is missing is "unknown", never silently false, except that
inside a present race an absent always-written member reads as the null the
Worker wrote (RACE_ALWAYS_WRITTEN). The C2
predicate is the same function for every caller. Recovery terms are reported
only where the fields carry them; everything else is "unknown". A
`storage_phases_overflow` line is unavailable evidence, never a zero row.

    python3 storage_phases_parse.py rows.jsonl [--platform platform.jsonl]

Each input line is a row (the line's JSON, optionally wrapped as
{"row": ..., "platform": {"wallTimeMs": ..., "requestId": ...}}); the output is one
JSON object per row with its tags, unknowns and recovery terms.
"""
import json
import sys

SCHEMA = 2
CLASSES = ('C0', 'C1', 'C2', 'C3', "C3'", 'C4', 'C5', 'C6', 'C7', 'U')
UNKNOWN = 'unknown'
# The CHOSEN triage threshold of C2 (not a derived one).
C2_SHARE = 0.75


class Rejected(ValueError):
    """A row the parser cannot read as schema 2."""


# An absent key, as against an explicit null: an absent input is unavailable
# evidence (unknown), while a null means what the schema says it means.
MISSING = object()

# The race members the Worker writes on every race, null when the race has
# none (Server/NotificationsWorker/src/storage_phases.rs:98-106: `opt(None)` and
# the `map_or(Value::Null, ..)` arms). The retained Workers Logs representation
# drops null-valued members, and trimming removes whole lists and objects, never
# one member of a race that survives: inside a PRESENT race, an absent member of
# this set is that null. Everything else keeps absent = unknown.
RACE_ALWAYS_WRITTEN = ('submitted', 'steps_total', 'steps_completed', 'gate_reply_at_ms', 'gate_wait_us', 'sqlstate')

# The objects every schema-2 row carries, and the ones that may be null.
OBJECTS = ('durations', 'ops', 'budget', 'summary', 'recovery')
NULLABLE_OBJECTS = ('primary', 'prior')


def parse(text):
    """One line → ('row', row) | ('unavailable', overflow) ; Rejected otherwise."""
    value = json.loads(text) if isinstance(text, str) else text
    if not isinstance(value, dict):
        raise Rejected('not an object')
    if value.get('event') == 'storage_phases_overflow':
        return 'unavailable', value
    if value.get('event') != 'storage_phases':
        raise Rejected('not a storage_phases line')
    if value.get('schema') != SCHEMA:
        raise Rejected('schema %r' % value.get('schema'))
    for key in ('handler', 'outcome', 'wall_ms', 'durations', 'ops', 'budget', 'summary', 'recovery'):
        if key not in value:
            raise Rejected('missing %s' % key)
    # The structure: an object where the schema has one. A nested key that is
    # absent is not a rejection; the classes that name it read it unknown.
    for key in OBJECTS:
        if not isinstance(value[key], dict):
            raise Rejected('%s is not an object' % key)
    for key in NULLABLE_OBJECTS:
        if key in value and value[key] is not None and not isinstance(value[key], dict):
            raise Rejected('%s is neither an object nor null' % key)
    primary = value.get('primary')
    if isinstance(primary, dict) and primary.get('race') is not None and not isinstance(primary['race'], dict):
        raise Rejected('primary.race is neither an object nor null')
    return 'row', value


def _get(row, *path):
    for key in path:
        if not isinstance(row, dict) or key not in row:
            return None
        row = row[key]
    return row


def _at(row, *path):
    """The value at `path`; MISSING when a key on the way is absent."""
    for key in path:
        if not isinstance(row, dict) or key not in row:
            return MISSING
        row = row[key]
    return row


def _member(race, key):
    """A member of a present race: an absent always-written member reads as null."""
    if isinstance(race, dict) and key not in race and key in RACE_ALWAYS_WRITTEN:
        return None
    return _at(race, key)


def _any(*values):
    """Three-valued OR: true decides, then unknown, then false."""
    if any(v is True for v in values):
        return True
    return UNKNOWN if any(v == UNKNOWN for v in values) else False


def _all(*values):
    """Three-valued AND: false decides, then unknown, then true."""
    if any(v is False for v in values):
        return False
    return UNKNOWN if any(v == UNKNOWN for v in values) else True


def _is(value, expected):
    """value == expected, unknown when the value is absent."""
    return UNKNOWN if value is MISSING else value == expected


def _race(row):
    """The primary's race: None when there is no primary or an explicit
    race-free one (neither can match a race class), MISSING when absent."""
    primary = _at(row, 'primary')
    if primary is MISSING:
        return MISSING
    if primary is None:
        return None
    return _at(primary, 'race')


def c2(row):
    """The ONE C2 predicate: the primary race was truncated by the authority below
    its own local cap, every earlier connect/read/transaction race completed within
    its local cap, and that earlier work is at least 75 % of the main budget. No
    primary, or an explicit race-free one, is never C2; an absent input is
    unknown."""
    race = _race(row)
    if race is MISSING:
        return UNKNOWN
    if race is None:
        return False
    limit = _at(race, 'limit')
    if limit is MISSING:
        return UNKNOWN
    if limit != 'authority_deadline':
        return False
    prior = _at(row, 'prior')
    if prior is MISSING or prior is None:
        return UNKNOWN
    validity = _at(prior, 'all_within_local_caps')
    if validity is MISSING or validity == UNKNOWN:
        return UNKNOWN
    if validity != 'true':
        return False
    main = _get(row, 'budget', 'handler_main_ms')
    before = _get(row, 'primary', 'local_cap_sum_before_ms')
    if not main or before is None:
        return UNKNOWN
    return before >= C2_SHARE * main


def _share(part, whole, share):
    if part is None or whole is None or part is MISSING or whole is MISSING:
        return UNKNOWN
    return whole > 0 and part >= share * whole


def _write_classes(race):
    """(C3, C3') from the primary race's named fields alone."""
    if race is MISSING:
        return UNKNOWN, UNKNOWN
    if race is None:
        return False, False
    write = _all(_is(_at(race, 'boundary'), 'transaction'), _is(_at(race, 'status'), 'timeout'),
                 _is(_member(race, 'submitted'), True))
    if write is not True:
        return write, write
    total, done = _member(race, 'steps_total'), _member(race, 'steps_completed')
    if total in (None, MISSING) or done in (None, MISSING):
        return UNKNOWN, UNKNOWN
    gate = _member(race, 'gate_reply_at_ms')
    # All but COMMIT complete, or the gate's reply never came after BEGIN's.
    lost = _any(done == total - 1, UNKNOWN if gate is MISSING else (gate is None and done >= 1))
    # The application statement never completed: BEGIN and the gate at most.
    slow = _all(UNKNOWN if lost == UNKNOWN else not lost, done <= 2)
    return slow, lost


def tags(row, platform=None):
    """{class: True | False | "unknown"} for a row with a primary or a non-ok outcome."""
    platform = platform or {}
    race = _race(row)
    out = {}
    lag = _at(row, 'scheduled_lag_ms')
    out['C0'] = UNKNOWN if lag is None or lag is MISSING else lag >= 5_000
    connect = _at(row, 'summary', 'connect', 'union_ms')
    storage = _at(row, 'durations', 'storage')
    dominant = _share(connect, storage, 0.5)
    if race is MISSING:
        timed_out = UNKNOWN
    elif race is None:
        timed_out = False
    else:
        timed_out = _all(_is(_at(race, 'boundary'), 'connect'), _is(_at(race, 'status'), 'timeout'))
    out['C1'] = _any(timed_out, dominant)
    out['C2'] = c2(row)
    out['C3'], out["C3'"] = _write_classes(race)
    wall = _at(row, 'wall_ms')
    out['C4'] = _share(_at(row, 'durations', 'r2'), wall, 0.3)
    gate = _at(row, 'summary', 'gate_wait_us_max')
    out['C5'] = UNKNOWN if gate is None or gate is MISSING else gate >= 1_000_000
    out['C6'] = _share(_at(row, 'durations', 'idle'), wall, 0.3)
    # A null overshoot means no race timed out (no C7); an absent one is unknown.
    primary = _at(row, 'primary')
    operands = [_at(row, 'summary', 'overshoot_ms_max')]
    if primary is MISSING or primary is not None:
        operands.append(MISSING if primary is MISSING else _at(primary, 'overshoot_ms'))
    out['C7'] = _any(*[UNKNOWN if v is MISSING else (v is not None and v >= 1_000) for v in operands])
    no_signature = not any(out[c] is True for c in CLASSES[:-1])
    ops_dropped = _at(row, 'ops', 'dropped')
    if ops_dropped is MISSING or primary is MISSING:
        dropped = UNKNOWN
    else:
        dropped = (ops_dropped or 0) > 0 and primary is None
    platform_wall = platform.get('wallTimeMs')
    if platform_wall is None or wall is MISSING or wall is None:
        late = UNKNOWN
    else:
        late = platform_wall - wall >= 1_000
    out['U'] = _any(no_signature, dropped, late)
    return out


def classified(row, platform=None):
    """The tag SET a reader keeps (never collapsed to one cause) and the unknowns.
    An ok row, or a refused one (a consume the environment brake answered
    before any storage call), without a primary is not a storage failure."""
    if row.get('primary') is None and row.get('outcome') in ('ok', 'refused'):
        return {'tags': [], 'unknown': [], 'classified': False}
    result = tags(row, platform)
    return {'tags': [c for c in CLASSES if result[c] is True],
            'unknown': [c for c in CLASSES if result[c] == UNKNOWN],
            'classified': True}


def page_repeated(row, defects=None):
    """Always "unknown" in production: any other value is a defect, counted, read unknown."""
    value = _get(row, 'recovery', 'page_repeated')
    if value != UNKNOWN and defects is not None:
        defects.append(('page_repeated', value))
    return UNKNOWN


def cursor_comparison(cancelled, resuming):
    """The reader's COARSE comparison of a cancelled row's last drain cursor with
    the resuming row's first: equal, unequal or null. Never page repetition."""
    last = _get(cancelled, 'recovery', 'last_action', 'end_checkpoint', 'candidate_cursor')
    if last is None:
        last = _get(cancelled, 'recovery', 'last_action', 'start_checkpoint', 'candidate_cursor')
    first = _get(resuming, 'recovery', 'first_action', 'start_checkpoint', 'candidate_cursor')
    if last is None or first is None:
        return None
    return 'equal' if last == first else 'unequal'


def checkpoint_outcome(row):
    """The last action's checkpoint status as the fields carry it. "unknown" is
    TERMINAL: no later row's phase reconciles it."""
    status = _get(row, 'recovery', 'last_action', 'end_checkpoint', 'status')
    return status if status in ('committed', 'uncommitted', UNKNOWN) else None


def retry_wait(rows):
    """{(digest, attempts): wait_ms | "unknown"} for every retained retry row.
    Exact ONLY between two retained rows of the same non-null digest with
    consecutive attempts k and k+1: (k+1).message_age − (k.message_age + k.wall)."""
    by_digest = {}
    for row in rows:
        chain = row.get('chain') or {}
        if chain.get('message_digest') is None:
            continue
        by_digest.setdefault(chain['message_digest'], {})[chain.get('attempts')] = row
    result = {}
    for row in rows:
        chain = row.get('chain') or {}
        attempts = chain.get('attempts') or 1
        if attempts < 2:
            continue
        digest = chain.get('message_digest')
        key = (digest, attempts)
        earlier = by_digest.get(digest, {}).get(attempts - 1) if digest is not None else None
        if earlier is None or row.get('message_age_ms') is None or earlier.get('message_age_ms') is None:
            result[key] = UNKNOWN
            continue
        result[key] = {'wait_ms': row['message_age_ms'] - (earlier['message_age_ms'] + earlier['wall_ms']),
                       'rows': [attempts - 1, attempts]}
    return result


def joins(rows, coverage_complete=True):
    """Classify every join (row n ← row n−1) by the precedence: retry; ambiguous
    (two or more retained senders of step n for {feed, generation}, or a single
    sender whose result is not ok, or incomplete cohort coverage); unknown (no
    sender retained); exact (one ok sender), with the ready-to-run wait."""
    senders = {}
    for row in rows:
        chain, sent = row.get('chain'), row.get('sent')
        if chain and sent:
            senders.setdefault((chain['feed'], chain['generation'], sent['step']), []).append(row)
    out = []
    for row in rows:
        chain = row.get('chain')
        if not chain or chain.get('step', 0) == 0:
            continue
        if (chain.get('attempts') or 1) > 1:
            out.append({'row': row, 'join': 'retry'})
            continue
        candidates = senders.get((chain['feed'], chain['generation'], chain['step']), [])
        if len(candidates) >= 2 or (len(candidates) == 1 and candidates[0]['sent']['result'] != 'ok') \
                or not coverage_complete:
            out.append({'row': row, 'join': 'ambiguous'})
        elif not candidates:
            out.append({'row': row, 'join': 'unknown'})
        else:
            age = row.get('message_age_ms')
            wait = None if age is None else age - 1_000 * candidates[0]['sent']['delay_s']
            out.append({'row': row, 'join': 'exact', 'ready_to_run_wait_ms': wait})
    return out


def historical_join():
    """A historical poll_delivery join carries no generation: always uncertain."""
    return 'uncertain'


def action_r2(row, name):
    """The per-action R2 evidence: the first action of `name`'s r2_calls and r2_ms,
    or "unavailable" when the action list was trimmed away."""
    for action in row.get('action') or []:
        if action.get('name') == name:
            return {'r2_calls': action.get('r2_calls'), 'r2_ms': action.get('r2_ms')}
    return 'unavailable'


def recovery(cancelled, resuming, rows=()):
    """The decomposition the fields carry for a cancelled row and its resumption;
    the rest is unknown, and a trimmed input is unavailable, never zero."""
    waits = retry_wait(list(rows) or [cancelled, resuming])
    chain = resuming.get('chain') or {}
    key = (chain.get('message_digest'), chain.get('attempts'))
    terms = {
        'retry_wait': waits.get(key, UNKNOWN),
        'admission_ms': _get(resuming, 'recovery', 'admission_ms'),
        'wait_remaining_s': _get(cancelled, 'recovery', 'wait_remaining_s'),
        'cancelled_last': _get(cancelled, 'recovery', 'last_action'),
        'resuming_first': _get(resuming, 'recovery', 'first_action'),
        'cursor_comparison': cursor_comparison(cancelled, resuming),
        'checkpoint_outcome': checkpoint_outcome(cancelled),
        'outbox_release': _get(cancelled, 'recovery', 'outbox_release'),
        'page_repeated': UNKNOWN,
        'prepare_redo': UNKNOWN,
        'skipped_rows': UNKNOWN,
    }
    for name in ('admission_ms', 'cancelled_last', 'resuming_first', 'outbox_release'):
        if terms[name] is None:
            terms[name] = 'unavailable'
    return terms


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    rejected = 0
    with open(argv[1], encoding='utf-8') as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            platform = entry.get('platform') if isinstance(entry, dict) and 'row' in entry else None
            row = entry['row'] if isinstance(entry, dict) and 'row' in entry else entry
            try:
                kind, value = parse(row)
            except Rejected as error:
                rejected += 1
                print(json.dumps({'line': number, 'rejected': str(error)}))
                continue
            if kind == 'unavailable':
                print(json.dumps({'line': number, 'evidence': 'unavailable'}))
                continue
            print(json.dumps({'line': number, 'handler': value['handler'], 'outcome': value['outcome'],
                              **classified(value, platform)}))
    return 1 if rejected else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
