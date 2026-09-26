# MailTriageWorker

An [Email Worker](https://developers.cloudflare.com/email-routing/email-workers/)
that sits behind an Email Routing rule for a support address. It forwards
**every** message to the inbox the rule used to forward to, tags the forwarded
copy with the result, and sends one push through an operator alert webhook when
the message looks worth reading. Nothing is dropped and nothing is stored.

Classification uses [Jev](https://developers.cloudflare.com/ai/models/typesafe/jev/)
on Workers AI, a classifier that answers a typed `choice` question with
calibrated probabilities instead of generated text.

## Flow

```
MX → Email Routing rule → email()
  0. rawSize > 4 MiB?   → skip parsing, header-only verdict
  1. read raw once → MIME parse          ┐ any failure ⇒
  2. Jev via AI Gateway, 15 s deadline   ┘ header-only verdict
  3. forward(FORWARD_TO, X-Mail-Triage* headers)   ← a failure here is rethrown
  4. verdict notify → one push (never throws, idempotent per Message-ID)
  5. one `mail_triaged` log line
```

Forwarding runs after classification so the tags can ride on the forwarded
copy. Classification can never prevent the forward: it is wrapped, cancelled by
a real deadline, and skipped for oversized mail. A failed forward is rethrown so
Email Routing reports it to the sending server, and no push is sent.

## Categories

Jev answers one `choice` question over six categories (criteria text in
`src/classify.ts`). The junk mass, `p(outreach) + p(marketing) + p(spam)`,
decides the action: at or above `JUNK_THRESHOLD` the message is quiet; below
it, it pushes. The label is the most likely category. Outreach is quiet on
purpose: it is worth reading, but not worth an interruption.

| Category    | Meaning                                                       | Action | Push level |
|-------------|---------------------------------------------------------------|--------|------------|
| `support`   | Help with the app: bug, crash, sync, playback, account, purchase | notify | active     |
| `feedback`  | Praise, suggestion, feature request                           | notify | active     |
| `outreach`  | Individually written press, podcaster or partnership mail     | quiet  | —          |
| `automated` | Platform notices, receipts, bounces, auto-replies, codes      | notify | passive    |
| `marketing` | Newsletters, promotions, templated cold pitches               | quiet  | —          |
| `spam`      | Scams, phishing, lures, malware, gibberish                    | quiet  | —          |

A message labeled `outreach`, `marketing` or `spam` whose junk mass stays
under the threshold still pushes, at the passive level.

When Jev cannot answer (timeout, error, malformed answer, exhausted balance,
parse failure, oversized mail), a header-only verdict applies:
`List-Unsubscribe` or `Precedence: bulk|list` stays quiet, `Auto-Submitted` or
a null return path pushes passively as `automated`, and everything else pushes
as `unclassified`. An outage never silences real mail.

Every forwarded copy carries:

| Header                   | Value                                         |
|--------------------------|-----------------------------------------------|
| `X-Mail-Triage`          | the label, or `unclassified`                  |
| `X-Mail-Triage-Decision` | `notify` or `quiet`                           |
| `X-Mail-Triage-Junk`     | junk mass to three places, or `n/a`           |
| `X-Mail-Triage-Source`   | `jev`, or `fallback; <reason>`                |

## Configuration

Vars (`wrangler.jsonc`, repeated per lane):

- `LANE`: `development` enables the local `POST /__triage` route; any other
  value serves 404 for every request.
- `AI_GATEWAY_ID`: the AI Gateway every Jev call goes through. Create it with
  logs off and authentication on. Third-party Workers AI models bill through
  AI Gateway credits, and a credit-billed call through an unauthenticated
  gateway fails with `2049 Invalid User Credentials`.
- `INBOX_CONTEXT`: a phrase describing the inbox, used in the question.
- `JUNK_THRESHOLD`: junk mass at which a message goes quiet (default `0.7`).

Secrets (`wrangler secret put NAME --env production`):

- `FORWARD_TO`: a verified Email Routing destination address. Without it the
  Worker refuses every message instead of accepting mail that goes nowhere.
- `ALERT_WEBHOOK_URL`, `ALERT_CREDENTIAL`, `ALERT_RECIPIENT`: the push webhook
  (HTTPS only), its bearer credential and the recipient key. Alerting is off
  unless all three are set. The request body is `{recipient, draft}` with a
  schema-1 notification draft, and an `Idempotency-Key` header derived from the
  Message-ID so a redelivered message never pushes twice.

## Routing

Deploy the Worker, put the secrets, then point a rule at it. A throwaway
address makes a safe canary before the real one moves:

```sh
yarn wrangler deploy -c Server/MailTriageWorker/wrangler.jsonc --env production
yarn wrangler email routing rules create example.com --name "mail triage canary" \
  --enabled true --match-type literal --match-field to \
  --match-value triage-test@example.com \
  --action-type worker --action-value your-mail-triage-worker-production
```

Then update the real rule to `--action-type worker` with the same name,
priority and matcher. Rolling back is the same update with
`--action-type forward --action-value <destination>`.

## Build, test, eval

From the repository root:

```sh
yarn workspace opencast-mail-triage-worker typecheck
yarn workspace opencast-mail-triage-worker test
yarn wrangler deploy -c Server/MailTriageWorker/wrangler.jsonc --dry-run --outdir /tmp/mail-triage-dev
yarn wrangler deploy -c Server/MailTriageWorker/wrangler.jsonc --env production --dry-run --outdir /tmp/mail-triage-production
```

Tests run in plain Node with a stubbed AI binding and a fake
`ForwardableEmailMessage`; the fixtures are synthetic.

The eval runs the synthetic cases in `eval/cases` against the real classifier.
Copy `.dev.vars.example` to `.dev.vars` (a `wrangler login` token cannot reach
AI Gateway, so local runs leave `AI_GATEWAY_ID` empty), then:

```sh
cd Server/MailTriageWorker && yarn wrangler dev    # terminal 1
yarn workspace opencast-mail-triage-worker eval     # terminal 2
yarn workspace opencast-mail-triage-worker eval --dir /path/to/exported/mail
```

A directory with its own `expected.json` (`{"file.eml": {"side": "ping"|"quiet"}}`)
is checked; one without is printed unchecked. To drive `email()` itself:

```sh
curl -X POST 'localhost:8787/cdn-cgi/handler/email?from=a@example.com&to=support@example.com' \
  --data-binary @test/fixtures/support.eml
```

## Dependencies

[postal-mime](https://github.com/postalsys/postal-mime) parses MIME: the
Workers runtime has no MIME parser, and postal-mime is MIT-0 with no
dependencies of its own. It is pinned to an exact version.

## Privacy

- Jev sees the sender, reply-to, subject, the first 6,000 characters of the
  body, and header-derived signals. Nothing else leaves the Worker.
- The AI Gateway runs with logging off. Invocation logs are off, because they
  would record the envelope sender and recipient.
- The `mail_triaged` log line carries the label, decision, scores, sizes and
  alert outcome. It never carries a subject, body or address. Workers Logs
  still attach the envelope sender to every event as `$metadata.trigger`; turn
  observability off entirely if that is unacceptable.
- The push carries the sender's display name, the subject and a short excerpt,
  since reading those is its purpose.
