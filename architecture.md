# ArcVault Triage — Architecture

**Author:** Issa Kadri
**Date:** April 2026
**Stack:** n8n (self-hosted via Docker) + Llama 3.3 70B via Groq + JSON file outputs

---

## 1. System Design

### Workflow topology

```
[HTTP POST]
    ↓
[n8n Webhook]  ──→  [HTTP Request]  ──→  [Code]  ──→  [Respond to Webhook]
                    (Groq API)         (routing +      (returns full record
                                          escalation)     to caller)
```

### How the pieces connect

The workflow is an **automatic intake pipeline** triggered by HTTP POST. In production, ArcVault's web form, email gateway, and support portal would all forward inbound messages to the webhook URL — for the assessment, a bash script (`run_all_samples.sh`) simulates these production sources by POSTing the 5 sample payloads.

| Node | Role | Notes |
|---|---|---|
| Webhook | Ingestion | Configured with `Respond: Using 'Respond to Webhook' Node` so the caller receives the full classified record synchronously |
| HTTP Request | LLM call | Direct call to Groq's OpenAI-compatible chat completions endpoint with `responseMimeType: application/json` to enforce structured output |
| Code (JavaScript) | Entity normalization + routing + escalation | Strips empty-string entity fields, guarantees `urgency_keywords` is an array (Step 3 compliance), maps category → queue deterministically, and applies escalation rules |
| Respond to Webhook | Synchronous response | Returns the full enriched record to the caller |

### Where state is held

The workflow is **stateless** — each request is independent. Persistence happens at the caller (the bash script) which collects responses into `output.json` and `escalation_queue.json`. This decoupling means:
- The workflow can be horizontally scaled without coordination
- Storage backend can be swapped (file → DB → message queue) without touching the pipeline
- Failed processing can be retried by the caller without orphaning records

For production, state would move to a queue (RabbitMQ/SQS) feeding the webhook, with results written to a database (Postgres) — but the same workflow shape applies.

---

## 2. Routing Logic

### Category → Queue mapping

| Category | Queue | Reasoning |
|---|---|---|
| Bug Report | Engineering | Code-level defect, needs developer eyes |
| Incident/Outage | Engineering | Same root team; severity differentiated by escalation rules |
| Billing Issue | Billing | Domain-specific finance team |
| Feature Request | Product | Product management owns roadmap intake |
| Technical Question | IT/Security | Integration/auth questions go to ops/security |
| (low confidence or escalation triggered) | Escalation | Human-in-the-loop fallback |

### Why these mappings

Mapping is deterministic and lives in the **Code node**, separate from the LLM. Rationale:
- **Auditability** — routing rules are pure functions, version-controlled, and trivially testable
- **Tunability** — swapping a queue assignment is a one-line code change; no prompt re-tuning needed
- **Separation of concerns** — the LLM does *judgment* (classification); deterministic code does *policy* (routing)

The LLM also outputs its own `suggested_queue` — but this is treated as a **signal field** logged alongside the rule-derived `queue`, not the source of truth. The output's `routing.rule_and_llm_agree` boolean exposes disagreement for monitoring. In production, this disagreement rate becomes a calibration signal: persistent disagreement on a category suggests either the prompt or the routing rules need tuning.

---

## 3. Escalation Logic

### Criteria

Escalation triggers when **any** of these conditions are met:

1. **Confidence < 0.7** — model is uncertain; let a human review rather than mis-route
2. **Outage keyword match** — message contains `outage`, `down for all users`, `all users affected`, or `multiple users affected` — these signal scope-amplifying incidents
3. **Billing discrepancy > $500** — computed as `max(dollar_amounts) - min(dollar_amounts)` when 2+ amounts are extracted

Each fired condition is appended to `escalation_reasons` (an array, not a boolean), so downstream consumers can prioritize:
- A confidence-only escalation is lower priority than an outage-keyword + multi-user-affected escalation

### Why these specific criteria

- **Confidence threshold of 0.7** comes directly from the brief; chosen as the inflection point in the prompt's calibration bands (0.70–0.84 = "likely, but reasonable alternatives exist"). Setting the threshold here means we escalate the genuinely-uncertain cases, not the merely-cautious ones.
- **Outage keywords** match the brief's examples and capture the cases where false negatives (missing a real outage) are far costlier than false positives (escalating a false alarm).
- **Billing discrepancy as max-min** is interpretation-aware — the brief says "billing error > $500", which refers to the dispute amount, not the invoice total. A $1240 invoice with a $260 dispute does not warrant escalation; a $260 invoice with a $980 dispute would.

### Validated behavior

In testing, all 5 sample inputs produced the expected escalation outcomes:

| Sample | Confidence | Escalation reasons | Queue |
|---|---|---|---|
| 1 (403 login) | 0.9 | none | Engineering |
| 2 (bulk export) | 0.9 | none | Product |
| 3 ($260 invoice dispute) | 0.9 | none (discrepancy < $500) | Billing |
| 4 (SSO inquiry) | 0.7 | none (at threshold; rule is strict `< 0.7`) | IT/Security |
| 5 (multi-user dashboard outage) | 0.95 | `outage_or_multi_user_keyword_match` (matched on "multiple users affected") | Escalation |

Sample 4 sits at the calibration boundary — confidence lands at 0.7, which matches the prompt's hedge rule ("A hedge like 'I am not sure if this is the right place' must lower confidence to 0.70 or below"). The Code node's escalation rule is strict `< 0.7`, so the record routes to IT/Security rather than Escalation. In production, I would log all 0.65–0.80 cases and review weekly to tune the threshold empirically; a sample sitting at the boundary warrants monitoring for bounce behavior across runs.

---

## 4. Production-Scale Considerations

What I would change for a real ArcVault deployment processing thousands of messages per day:

### Reliability
- **Retry + dead-letter queue** for Groq transient failures (we hit 503s during development; production needs structured retry with exponential backoff)
- **Schema validation** after the LLM call — catch malformed responses before they hit downstream queues
- **Idempotency keys** on the webhook so retries from upstream (form submissions retried by users) don't create duplicate records
- **Structured error workflow** in n8n catching all node failures and routing to a `failed_processing.json` for manual triage

### Cost
- **Token-aware caching** on system prompt (currently ~800 tokens per call × 1000s of calls = real money). Groq does not yet offer context caching at this tier; OpenAI's caching cuts this to ~50 tokens per call after the first warm hit.
- **Two-tier classification**: cheap model (Flash-Lite) for confident cases, escalate to Llama 3.3 70B only for low-confidence rerun. Reduces per-record cost by ~70%.
- **Batch processing window** for non-urgent messages — process every 5 min instead of per-request.

### Latency
- **Async response pattern** — return 202 Accepted immediately, fire downstream classification on a queue worker. Groq calls are typically <1s due to LPU acceleration; making the user wait synchronously is unnecessary for ticket intake.
- **Two-call pattern with category-conditioned entity schemas** — split classification (cheap, fast) and entity extraction (richer, category-specific schema) into a sequential chain. This *adds* latency rather than reducing it, so it's a quality/auditability tradeoff, not a latency win — worth it when entity richness matters more than wall time.
- **Groq endpoint selection** to reduce round-trip time.

### Observability
- **Per-record processing duration**, **token counts**, **prompt version hash**, and **model version** logged with every record (we partially do this — production needs all of it).
- **Confidence histogram** monitoring to detect prompt drift over time.
- **Disagreement rate** between LLM-suggested queue and rule-derived queue as a calibration signal.

### Security
- **PII scrubbing** before logging or analytics export — raw messages may contain emails, account IDs, or worse.
- **Rate limiting** on the inbound webhook to prevent abuse.
- **Auth token** on the webhook (currently no auth — fine for assessment, dangerous for production).

---

## 5. Phase 2

If I had another week, I would add:

1. **Eval harness** with a labeled fixture set (~100 historical tickets) — every prompt change runs through it; surface accuracy/precision/recall per category. This is the single biggest gap between "works on 5 inputs" and "trustworthy in production."

2. **Human feedback loop** — when an escalation is reviewed by a human, capture their corrected category + queue decision. Feed back as few-shot examples in the prompt or as a fine-tuning signal.

3. **Tool use / retrieval-augmented classification** for ambiguous cases — when confidence is below 0.85, the LLM could call a `search_similar_tickets()` tool to look at how comparable past tickets were classified, then re-classify with that context.

4. **A/B testing framework** for prompts and models — run two prompt variants in parallel for 1000 messages, compare downstream resolution time per queue. Empirical model selection, not vibes.

5. **Per-category entity schemas** — billing messages care about dollar amounts and invoice numbers; outage messages care about affected services and start times. Conditional schema selection based on first-pass category would yield richer entity extraction.

6. **SLA tracking & alerting** — record the queue assignment timestamp; alert if any record sits in a queue beyond its SLA (e.g., outages: 15 min, bugs: 24 hr, features: 7 days).

7. **Customer-facing acknowledgment** — auto-reply with "Your ticket has been routed to {queue} — expected response within {SLA}." Closes the loop with the user immediately.

---

## What I'd do differently if starting over

- **Build the prompt in a playground first** (which I did — this saved hours on iteration). Validating the prompt before touching n8n separated the creative work from the orchestration work.
- **Use HTTP Request directly** for the LLM call rather than n8n's bundled provider nodes. Direct API calls gave full transparency over the request body and faster debug cycles. As a bonus, switching providers mid-development (Gemini → Groq) was a single URL + body-format change rather than a full node rewrite.
- **Pick a provider with generous free-tier limits during development.** I started on Gemini's free tier and exhausted the daily quota within ~2 hours of iteration. Switched to Groq's Llama 3.3 70B — same classification quality, ~5x faster inference, and free-tier headroom that made batch testing trivial. Provider choice for production should be based on accuracy benchmarks against labeled data, not free-tier convenience — but for development, the tier matters more than I initially appreciated.
- **Treat the LLM-suggested queue as a signal, not a decision.** Routing rules belong in code where they're auditable; the LLM is a judgment engine, not a policy engine. Keeping these separate made it easy to iterate on routing logic without re-tuning the prompt.
