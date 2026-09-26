# Resilient n8n Workflows

Four production-pattern n8n workflows for contractor onboarding, message delivery, AI document extraction and scheduled reporting.

Built as a practical exercise in one question: **what should an automation do when something goes wrong?**

Anything can fail. A provider goes down, a document is malformed, a database is unreachable, a model invents a value. None of that is interesting on its own. What matters is whether the failure is visible, whether the record survives it, and whether the caller is told the truth about what happened.

Every workflow here is built around that. There are no swallowed errors, no blind retries, and no success responses for work that did not succeed.

All names and data are fictional. `<COMPANY>` is a placeholder you can replace with anything, and the email addresses use `example.com`, a domain reserved for documentation.

**→ [SETUP.md](SETUP.md) has the full install, credentials and run guide, plus the patterns to lift into your own builds.**

---

## Run the first two in five minutes

Workflows 1 and 2 need **no accounts and no API keys**.

```bash
docker run -it --rm -p 5678:5678 -v n8n_data:/home/node/.n8n docker.n8n.io/n8nio/n8n
```

Open `http://localhost:5678`, then **Workflows → Import from File** and pick `workflows/01-onboarding-notify.json`. Disconnect the Google Sheets node if you don't want to configure one. Import `postman/01-onboarding-notify.postman_collection.json` and send the requests.

Every send endpoint points at `postman-echo.com`, a public endpoint that accepts any POST and echoes it back. That is deliberate: the workflows run immediately with no setup, nobody real gets messaged, and the full request body is visible in the execution log. They are still real HTTP calls over the real network, so the retry and error paths are genuinely exercised rather than mocked. Swapping in SendGrid or a WhatsApp provider is a URL and a credential, not a rebuild.

---

## The four workflows

### 01 Onboarding Notify

A contractor is signed up. Tell them, once, by two channels, and record it.

Picks one of two messages depending on whether their documents are verified, sends by email and SMS independently, and writes one audit row per event.

- **Idempotency before sending.** The contractor ID is claimed in workflow static data with a seven day window. A repeated event replies `duplicate_suppressed` with the original correlation ID and nobody is messaged twice. The check runs before the irreversible step, not after it.
- **Three delivery states, not two.** Accepted, rejected, and *uncertain*. A timeout is not a failure, it is an absence of information. Both accepted returns 200. One accepted returns 207 and says `degraded` rather than pretending it was clean. Uncertain returns 502 and **keeps** the claim so a retry cannot double send. Only a send known to have failed releases the claim.

### 02 Resilient Delivery

Send something. If it fails, retry properly. If it keeps failing, lose nothing and tell a human.

- **The retry loop is on the canvas, not in a node setting.** n8n's built-in Retry On Fail is switched off deliberately. A hidden retry retries everything, including failures that can never succeed, and leaves no trace of what it did. Here every attempt is a visible execution step and the policy is four numbers in a config.
- **Classify before retrying.** Transport errors, 5xx and 429 are retried. Other 4xx go straight to the dead letter, because a malformed request will be just as malformed on the fourth attempt.
- **Exponential backoff with jitter.** 1s, 2s, 4s, capped at 8s, plus a small random offset. Without the jitter, every stalled execution wakes at the same instant and knocks the recovering provider over again.
- **The alert uses an allowlist.** Only `retries_exhausted` and `permanent_failure` page anyone. A denylist rots: every new failure type alerts by default until somebody remembers to exclude it, and an alert channel that cries wolf gets muted.
- **The failure response is honest about the dead letter.** If the dead letter write itself failed, the response says so loudly rather than claiming the record is safe.

### 03 Timesheet Extraction

Pull structured fields out of a free-text timesheet using the Anthropic Messages API, then verify the model did not invent them.

- **Forced tool use, not "reply with JSON".** `tool_choice` pins the model to one tool with a declared input schema, so the reply comes back as structured arguments rather than prose that has to be parsed out of a paragraph.
- **The grounding check is the point.** For every field the model must return the exact source text it read the value from. Plain JavaScript then verifies that the quote really appears in the document *and* that the value really appears inside the quote. An invented employer fails because its quote is not in the source. A total that was calculated rather than read fails because the number is not inside the quote. This is the only rule that catches a confident hallucination.
- **The model extracts, it does not decide.** Every approval rule is deterministic: type checks, a real-date round trip so the 30th of February is rejected, a 60 hour ceiling, and a confidence floor. The model's own confidence is one input among five, never the verdict.
- **Omission is a valid answer.** A timesheet dated "3 Sep" with no year should leave the date empty and be flagged, not helpfully assume the current year and pay someone for the wrong week.
- Prompt injection is handled by wrapping the document in delimiters and treating its contents as data. Every approval rule sits outside the model.

### 04 Overdue Payments Report

Every weekday at 08:00, find contractors whose payment has been pending more than seven days and email the list, grouped by agency.

Small workflow, and nearly all the thinking is about the two boring cases:

- **Zero results still sends a message.** "Nothing to action today" and a broken scheduler look identical in an inbox. One of those is fine and one is a disaster, so the ambiguity is worth removing for the price of one email.
- **A failed query alerts louder than a full report.** A report that did not run gets read as an all clear, so the failure message says explicitly that the report did not run and the overdue list is unknown.
- `alwaysOutputData` is on for the query. Without it an empty result set produces no items, the branch simply stops, and zero rows becomes invisible instead of testable.
- The threshold is passed as a parameter and cast, never concatenated into the SQL string.

---

## Conventions used throughout

- **Config in one node.** Every workflow's second node is `Set Runtime Config`, holding non-secret settings as plain values. Credentials stay in n8n's credential store.
- **Correlation IDs on everything.** Every response and every audit row carries one, so a caller's request can be tied to an execution without matching on timestamps.
- **`onError: continueErrorOutput`, never `continueRegularOutput`.** Regular output on error means the node reports success and emits an item containing an error field, which downstream nodes then treat as data. That is the silent failure this repo exists to avoid.
- **Sticky notes on every canvas** covering setup, design decisions and known limits, so the reasoning travels with the workflow instead of living in a document nobody opens.

---

## Known limits

Stated plainly, because a portfolio piece that claims no limits is not credible.

- **Workflow 3 does not hold at volume.** One API call per document, each holding a webhook execution open for a couple of seconds. At roughly 500 documents an hour this shape breaks. The fix is queue mode with several workers, accepting the webhook and returning 202 immediately rather than holding the connection, then batching into the API with a concurrency cap that respects the account rate limit. The cheaper fix first: route unambiguous documents through a deterministic parser and only send the messy ones to a model.
- **Google Sheets is the wrong store for a real audit trail.** It is readable and fine for demonstrating that the evidence exists, but it has no schema, will not take volume, and is editable by anyone with the link. In production this is a table.
- **Workflows 1 and 2 share a front door.** Webhook, config, validate, fork. That duplication exists because each workflow had to import and run standalone. In production it belongs in one sub-workflow the others call.
- **Idempotency uses workflow static data**, which is per workflow and only persists on production executions. Across multiple workflows or instances this belongs in Redis or a table.
- **The webhooks are unauthenticated** so the workflows can be imported and tested immediately. In production they would sit behind header auth and an IP allowlist.

---

## Stack

n8n (self-hosted) · JavaScript (Code nodes) · Anthropic Messages API · PostgreSQL · Google Sheets API · REST and webhooks · Postman

## Licence

MIT. See [LICENSE](LICENSE).
