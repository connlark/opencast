"""Decision-model ad-break pipeline prototype (eval only, policy
`decision_ad_breaks_v4_proto`). Nothing here runs in the Worker; `src/**` is
frozen and only read (constants, prompt sentence) by the drift tests.

Decision ("System One") models take a `state` plus typed questions and return
calibrated probabilities. They emit no spans, no quotes and no text, so the v3
safety mechanism (boundary receipts the validator verifies) does not transfer.
Every span this package produces carries `evidence_quote: ""` and a `decision`
object holding the probabilities it was derived from. No quote is ever
fabricated.

What replaces quote receipts:

* The harness defines every chunk and segment. A chunk is a contiguous range of
  the request's segment array (array order, never id arithmetic; synthetic
  fixtures use sparse ids) and a question names a harness label, so a model
  cannot translate an id wrongly: id-translation errors are structurally
  impossible.
* The remaining risk is semantic: the model answering yes on program content.
  It is covered by (1) the content facet with dual thresholds (a run enters
  only at p_ad >= t_on with p_content <= 0.3 and ends when the facet says the
  chunk is more likely the program than not), (2) the per-span confirmation
  question in the two-stage design (">= 0.8 that the entire passage is a
  continuous advertising break with no program content"), (3) the structural
  guards ported from the Rust validator (600 s per break, the episode ad
  budget, the 80 % covers-request check), where any violation fails the whole
  episode closed (`complete = false, spans = []`, a `decision_*` warning) like
  v3, and (4) the eval's junk-zone, editorial-run and negative-hit
  classifications, which are the actual safety measurement.

Modules: questions (state and question rendering, versioned), chunking,
derive (probabilities -> spans, pure), guards, hybrid (H1: a decision
localiser plus the unchanged v3 generative path on neighbourhoods),
run_decision (driver and archive), rederive, oracle (E0), jitter, frontier.
"""
