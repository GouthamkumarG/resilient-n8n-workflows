# Setup and run guide

How to get these four workflows running on your own machine, and how to lift the patterns into your own builds.

Throughout, `<COMPANY>` is a placeholder. Replace it with whatever you like, or leave it. Nothing depends on the value.

---

## 1. What you need

| Workflow | Needs |
|---|---|
| 01 Onboarding Notify | n8n. Google Sheets optional. |
| 02 Resilient Delivery | n8n. Google Sheets optional. |
| 03 Timesheet Extraction | n8n + an Anthropic API key. Google Sheets optional. |
| 04 Overdue Payments Report | n8n + any PostgreSQL database. |

Workflows 1 and 2 run end to end with **no accounts at all**. Every send points at `postman-echo.com`, a public endpoint that accepts any POST and echoes it back. If you disconnect the Google Sheets node, both still run and still return correct responses. Start there.

---

## 2. Get n8n running

Docker is the quickest:

```bash
docker run -it --rm \
  -p 5678:5678 \
  -v n8n_data:/home/node/.n8n \
  docker.n8n.io/n8nio/n8n
```

Then open `http://localhost:5678`.

Or with npm:

```bash
npx n8n
```

The named volume matters. Workflow 1 stores its duplicate-suppression state in n8n's own storage, so without a persistent volume that state is lost every restart.

---

## 3. Import the workflows

In n8n: **Workflows → Import from File**, then pick a file from `workflows/`.

Import them one at a time. Each is standalone and none of them call each other.

---

## 4. Credentials

### Anthropic (workflow 3 only)

1. Get a key from console.anthropic.com.
2. In n8n: **Credentials → New → Anthropic**, paste the key.
3. Open the **Call Claude API** node and select it.

If the Anthropic credential type isn't in your n8n version, switch the node's Authentication to **Generic → Header Auth** with name `x-api-key` and your key as the value.

The node is a plain HTTP Request rather than n8n's built-in Anthropic node on purpose. It is the only way to send `tools` and `tool_choice`, which is what forces a structured reply instead of prose.

### Google Sheets (optional, workflows 1, 2, 3)

**Use a service account, not OAuth.** OAuth needs a redirect URL that Google will accept, and Google rejects bare IP addresses and plain HTTP. If you are running n8n on anything other than a proper HTTPS domain, OAuth will not work and a service account will.

1. In Google Cloud Console, create a project and enable the **Google Sheets API**.
2. **IAM → Service Accounts → Create**, then **Keys → Add key → JSON**. Download it.
3. In n8n: **Credentials → New → Google Service Account**, paste the JSON contents.
4. **Open your spreadsheet and share it with the service account's email address**, the one ending `@...iam.gserviceaccount.com`, with Editor access.

Step 4 is the one everyone misses. Without it every write returns **403 Forbidden** even though the credential is valid. A service account is a separate identity and the sheet has to be shared with it exactly like sharing with a person.

Then create these tabs with the headers in row 1:

| Tab | Headers |
|---|---|
| `Onboarding_Audit` | see the sticky note in workflow 1 |
| `Dead_Letter` | see the sticky note in workflow 2 |
| `Timesheets` | see the sticky note in workflow 3 |

**Type the headers across with Tab. Do not paste a comma-separated string.** Trailing spaces in a header silently break column mapping, and the failure looks like the data simply not arriving.

Finally, replace `YOUR_GOOGLE_SHEET_ID` in the **Set Runtime Config** node of each workflow. The ID is the long string in your sheet's URL between `/d/` and `/edit`.

### PostgreSQL (workflow 4 only)

Any Postgres will do, local or hosted. Then:

```bash
psql "<your connection string>" -f sql/seed-contractors.sql
```

That creates the `contractors` table and twelve rows with dates relative to today, including one sitting exactly on the seven day boundary so the off-by-one case is testable.

In n8n: **Credentials → New → Postgres**, fill in host, database, user, password, port 5432, SSL as required by your provider. Select it on the **Query Overdue Pending Payments** node.

**Set the workflow timezone.** Workflow Settings → Timezone → `Europe/London` or wherever you are. Left on the instance default the schedule drifts by an hour when the clocks change, and if your database stores UTC the day boundary can shift a record by one day.

---

## 5. Run them

Import the matching collection from `postman/` into Postman. Each collection has a `baseUrl` variable already pointing at `http://localhost:5678/...`.

**Workflows must be Published (activated) for the production webhook URL to work.** In test mode you have to click Execute Workflow before each request, and workflow static data is not persisted, so the duplicate-suppression demo in workflow 1 will not work.

| Workflow | Run order | What to look for |
|---|---|---|
| 01 | 1, then 1 again, then 2, 3, 4, 5 | The second send of request 1 returns `duplicate_suppressed` with the original correlation ID |
| 02 | 1, 2, 3, 4a, 4b | Request 2 forces four failed attempts, then `retries_exhausted` with `dead_letter_written: true` |
| 03 | 1 through 6 in order | Request 1 is flagged for a missing year. Request 2 auto-approves. Request 5 is a prompt injection attempt and is rejected on the numbers, not by the model |
| 04 | Click **Manual Trigger - Run Now** on the canvas | Six contractors, oldest around 29 days. The contractor exactly on the 7 day boundary must NOT appear |

Two things to try after that, because they are where the design actually shows:

- In workflow 4, run `UPDATE contractors SET status = 'active' WHERE status = 'pending';` then run it again. You get a "nothing to action today" message rather than silence.
- Then break the Postgres credential password and run it again. You get an alert saying the report **did not run**, which is louder than a normal report.

---

## 6. Building your own from these

The four workflows are really five reusable patterns. If you are lifting anything, lift these.

**Config in one node.** Every workflow's second node is `Set Runtime Config`, a Code node returning a plain object that rides along on every item. Endpoints, thresholds and limits live there as readable values. Secrets never do, they stay in n8n's credential store. Changing behaviour becomes editing one number in one place instead of hunting through nodes.

**Claim before you act.** Anything that sends a message, charges a card or writes to a downstream system should check whether it already happened *before* doing it, not after. Workflow 1 claims the ID in workflow static data with a time window. Release the claim only when you are certain the action did not happen. If you are unsure, keep it, because a retry that double-sends is worse than a retry that does nothing.

**Retry visibly, and classify first.** Turn off the node's built-in Retry On Fail and build the loop on the canvas: attempt, evaluate, decide, wait, loop. It costs four extra nodes and you get a retry policy anyone can read and an execution log that shows every attempt. Classify before retrying, since retrying a 400 is pure waste. Add jitter to the wait, or every stalled execution wakes at the same instant.

**Give failure somewhere to go.** A dead letter row, a table, anything durable. Then check whether that write itself worked, and say so honestly in the response if it did not. Keep the alert on an allowlist of failures worth waking someone for. An alert channel people mute is worse than no alerts.

**Let the model extract, never decide.** Force structured output with `tool_choice`, and make the model return the exact source text behind every value. Then verify in ordinary code that the quote is in the document and the value is in the quote. Keep every threshold deterministic and outside the model. The model's own confidence is an input, not a verdict.

And the rule underneath all of them:

**Silence must never be ambiguous.** A report with nothing to say still sends a message. A failed run says it failed rather than reporting zero. `onError` is always `continueErrorOutput`, never `continueRegularOutput`, because regular output on error means the node reports success and hands an error object downstream as if it were data.

---

## 7. Troubleshooting

**Every Google Sheets write returns 403.** The sheet is not shared with the service account's email address. See section 4.

**Data reaches the Sheets node but no row appears, or extra columns get created.** A header in row 1 has a trailing space, or the node is set to auto-map and your items carry fields that are not columns. Rebuild row 1 by typing across with Tab, and emit exactly the column set.

**Workflow 1 never reports a duplicate.** You are running in test mode. Static data only persists on production executions. Publish the workflow and use the production URL.

**Workflow 1 reports a duplicate on the very first send.** That contractor ID was used within the last seven days. Use a fresh ID.

**Workflow 3 returns 400 from the API.** Usually the tool schema. If you add `strict: true`, note that it changes what the model returns and can cause the evidence field to come back empty, which silently disables the grounding check. There is a comment in the node about this.

**Workflow 4 returns rows you did not expect, off by one day.** Timezone. The database stores UTC and your threshold is being evaluated against local midnight. Set the workflow timezone explicitly and re-check.

**A workflow starts, the first node runs, then nothing.** Open the execution and read the item count on each connection. The first connection showing zero items is nearly always the answer, and it is usually an empty result set rather than a broken wire, because n8n does not run a node with no input items. If an empty result should still continue, switch on Always Output Data.
