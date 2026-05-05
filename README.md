# Valsoft AI Engineer Assessment — ArcVault Triage

## What this is
An end-to-end AI workflow that ingests inbound customer messages from ArcVault (a fictional B2B SaaS), classifies them with an LLM, enriches with extracted entities, routes to the correct queue, and flags escalations. Built per the assessment brief (Feb/Apr 2026).

## Stack
- **Orchestration:** n8n (self-hosted via Docker) — chosen for visual auditability of the workflow and its strong webhook + HTTP + Code-node primitives, all on the free self-hosted tier.
- **LLM:** Llama 3.3 70B via Groq (free tier, OpenAI-compatible API) — chosen over Gemini after iteration: same classification quality on the 5 samples, ~5× faster inference on Groq's LPUs, and a generous free-tier rate limit that made batch testing trivial. Production model selection should be benchmarked on labeled data; for this assessment, free-tier headroom and inference speed mattered more than marginal accuracy differences.
- **Output:** JSON files (`output.json` for non-escalated records, `escalation_queue.json` for escalated)

## Files in this folder

| File | Purpose |
|---|---|
| `architecture.md` | Architecture write-up — system design, routing logic, escalation logic, production considerations, Phase 2 |
| `prompts.md` | Full system prompt, JSON schema, all 5 validated playground outputs, rationale for each prompt decision |
| `output.json` | 4 non-escalated triage records (Bug Report, Feature Request, Billing, Technical Question) |
| `escalation_queue.json` | 1 escalated record (Outage with multi-user impact) |
| `workflow.json` | Exported n8n workflow (4 nodes: Webhook → HTTP Request → Code → Respond to Webhook) |
| `run_all_samples.sh` | Bash script that POSTs all 5 sample messages to the webhook and aggregates results |
| `README.md` | This file |

## How to run

### Prerequisites
- Docker
- A Groq API key

### Setup
```bash
# Start n8n
docker run -d --name n8n -p 5678:5678 -v ~/.n8n:/home/node/.n8n n8nio/n8n

# Open editor
# Browser: http://localhost:5678
```

### Import the workflow
1. In n8n, top-right `...` menu → Import from file
2. Select `workflow.json`
3. Replace the placeholder `YOUR_GROQ_API_KEY_HERE` in the HTTP Request node Authorization header with your own Groq API key (get one free at console.groq.com)
4. Click **Publish** to activate

### Run all 5 samples
```bash
./run_all_samples.sh
```

The script POSTs each sample to `http://localhost:5678/webhook/arcvault-triage`, aggregates results, and writes them to `output.json` and `escalation_queue.json`.

## Workflow at a glance

```
[POST]  →  Webhook  →  HTTP Request (Groq)  →  Code (entity normalization + routing + escalation)  →  Respond to Webhook
```

| Node | Role |
|---|---|
| Webhook | Receives `{source, raw_message}` POSTs |
| HTTP Request | Direct call to Groq's OpenAI-compatible chat completions endpoint with `response_format: json_object` for structured output |
| Code (JavaScript) | Entity normalization (guarantees `urgency_keywords` array, strips empty-string entities), deterministic routing, escalation rules; produces final record with metadata |
| Respond to Webhook | Returns the enriched record to the caller for downstream persistence |

## Output record shape

Every record includes:
- `record_id`, `source`, `raw_message`, `processed_at`, `model`, `prompt_version`
- `classification` (category, priority, confidence, reasoning, core_issue, entities, suggested_queue, summary)
- `routing` (queue, llm_suggested_queue, rule_and_llm_agree)
- `escalation_flag`, `escalation_reasons`

## Validation summary

| # | Source | Category | Queue | Escalated? |
|---|---|---|---|---|
| 1 | Email | Bug Report | Engineering | No |
| 2 | Web Form | Feature Request | Product | No |
| 3 | Support Portal | Billing Issue | Billing | No (discrepancy $260 < $500) |
| 4 | Email | Technical Question | IT/Security | No (confidence 0.7 at threshold; rule is strict `< 0.7`) |
| 5 | Web Form | Incident/Outage | Escalation | Yes (`outage_or_multi_user_keyword_match` — message contains "multiple users affected") |

## Screenshots (workflow-running proof, deliverable 4.1)

| # | File | What it shows |
|---|---|---|
| 1 | [screenshots/01-workflow-canvas.png](screenshots/01-workflow-canvas.png) | n8n canvas — 4 nodes wired up, workflow Published (active) |
| 2 | [screenshots/02-executions-overview.png](screenshots/02-executions-overview.png) | Executions tab — multiple successful runs with per-node success checkmarks + timing |
| 3 | [screenshots/03-code-node-output.png](screenshots/03-code-node-output.png) | Code node I/O on a single execution — Groq API response on the left, final enriched record on the right (classification + entities + routing + escalation) |
| 4 | [screenshots/04-terminal-run.png](screenshots/04-terminal-run.png) | Terminal output of `bash run_all_samples.sh` — all 5 samples processed, queues + escalation flag shown per sample |

## Notes

- `prompts.md` documents every prompt and schema decision with rationale and tradeoffs, per assessment deliverable 4.3.
- `architecture.md` covers all 5 required subsections from deliverable 4.4.
