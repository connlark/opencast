# Ad-break evaluation

The native Rust bridge renders the **same prompt, windows, schema, and validation**
used by the Worker. Python only handles providers, a shared spend ledger, and
segment/time scoring. No Worker credentials, private podcast captures, or model
answers are included. `fixtures/promo-carousel.json` is original synthetic text,
not an independent real-episode benchmark.

From this directory's parent, build and test before any paid run:

```sh
cargo build --locked --example eval_bridge
python3 -m unittest discover -s eval -p 'test_*.py'
```

Example (substitute a local secret file; output should be private/ignored):

```sh
python3 eval/run.py --manifest eval/fixtures/manifest.json \
  --out /private/tmp/my-ad-eval --key-file /path/to/gemini-secret \
  --model gemini-3.8-flash --policy promo_ad_breaks_v3 --thinking medium \
  --repair --repeats 3 --tag carousel-v3 --max-spend 15
```

Use **one output root / ledger for the whole experiment**, including other
providers, retries, and staging calls. Never reset the ledger to bypass its cap.
Reservations cover counted input and maximum output (including reasoning).
Ambiguous dispatches retain their full reservation. Prices are frozen and must
be reverified before reuse; Gemini 3.8 promotional prices expire 2026-12-31.
The default $15 cap is an experiment limit, not a production quota. The current
authorized maximum is $25. Increasing an existing ledger requires an explicit
authorization recorded atomically, not a fresh ledger. For an authorized change:

```sh
python3 eval/budget.py --ledger /private/tmp/my-ad-eval/budget-ledger.json \
  --previous-cap 20 --new-cap 25 --authorization 'Describe the explicit approval'
```

Continue every runner/probe/smoke with `--max-spend 25` after that migration.
All prior charges and ambiguous reservations remain counted. Cap increases are
rejected while calls are actively reserved; a stale-cap process cannot reserve.

Raw requests, responses, initial/repaired validation, fixture hashes, native
binary hash, token usage, latency, and installed results are archived per run.
The runner refuses stale/replaced native binaries and output overwrites. Do not
edit Worker source during a paid batch. Input text is sent to the selected
provider; OpenAI uses standard tier, no tools, `store: false`.

Manifest ground truth uses inclusive **segment IDs**, not array indexes:

- `pods`: required uninterrupted ad cores.
- `optional`: mixed/ambiguous boundaries or optional house promos, excluded
  from false-skip penalties. These are **not guaranteed safe audio**.
- `negatives`: explicit editorial intervals that must not be skipped.

Score unioned installed spans at the app's confidence floor (0.8) and one-second
zone merge. Report missed ad seconds, false-skip seconds outside allowed regions,
negative overlap, and zones per pod—not just ad count. V2 installs surviving
spans after validation losses; v3 installs nothing on unresolved validation.
`complete` means structurally valid, **not certified semantic recall**. A model
can still omit an entire ad or emit a plausible wrong boundary without warning.

Private corpora should freeze labels before inference and record provenance,
audio/transcript hashes, mixed-boundary uncertainty, and revisions. Alternative
ASR transcripts of one recording and concatenated long-window tests are not
additional independent episodes. Never grade against a newly fetched dynamic-ad
audio variant and call it a replay of the listener's bytes.

`boundary_probe.py` is an exploratory, **non-serving** follow-up: a case file
supplies a request path, one proposed interval, and scoring labels. The model
sees only the two boundary neighborhoods and the fallible proposal, never the
labels. This measures review of known candidates, not independent discovery or
held-out accuracy. It shares the same ledger and provider adapter as `run.py`.
`--blind-proposal` withholds the candidate IDs and uses explicit two-sided
transition instructions. This combined variant does not isolate proposal bias
alone, and its neighborhoods are still selected from known candidates.

`recall_audit.py` independently scans the entire transcript for promotional
occurrences using a separate cue-discovery prompt. Neither the primary detector's
spans nor ground truth enter its input. It validates each cue against its exact
source segment; cue anchors are leads to inspect, **not skip boundaries**, and
are never automatically installed. This measures incremental missed-promotion
discovery, not human ground truth or guaranteed completeness. It shares the
same ledger, including when audits and detector runs execute concurrently.

`staging_smoke.py` exercises async submit/poll/cache against an explicitly
confirmed staging host (`--staging-host`, matched exactly against `--url`).
Operators must confirm that the host is not production. It reserves the entire bounded Worker retry ladder and retains that
amount because HTTP response usage cannot prove whether a timed-out upstream
attempt was also billed. It never targets the production hostname.
