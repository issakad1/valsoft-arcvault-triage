# ArcVault Triage — Prompts & Schema Documentation

**Assessment:** Valsoft AI Engineer — ArcVault Intake & Triage Pipeline
**Production model:** Llama 3.3 70B Versatile via Groq (free tier, OpenAI-compatible API)
**Initial validation:** Google AI Studio playground (Gemini 2.5 Flash) — used to iterate prompt and schema before integration
**Schema enforcement:** Groq's `response_format: {type: "json_object"}` (production); Gemini's `response_schema` (initial validation)

> Note: The prompt and schema are LLM-agnostic. Both providers produced equivalent classifications on all 5 sample inputs. Switched to Groq during development for higher free-tier limits and faster inference (~5x). All output records in `output.json` and `escalation_queue.json` were produced by the live workflow using Groq.

---

## 1. System Instructions (final — as deployed in n8n HTTP Request node)

```
You are a support ticket triage assistant for ArcVault, a B2B SaaS company. For each inbound message, classify and enrich it. Return ONLY a JSON object matching this exact schema (no markdown, no preamble):

{
  "category": "Bug Report" | "Feature Request" | "Billing Issue" | "Technical Question" | "Incident/Outage",
  "priority": "Low" | "Medium" | "High",
  "confidence": number 0-1,
  "reasoning": "1-3 sentences naming runner-up category",
  "core_issue": "one sentence",
  "entities": {
    "account_id": string (optional),
    "invoice_number": string (optional),
    "error_code": string (optional),
    "dollar_amounts": [numbers] (optional),
    "affected_service": string (optional),
    "incident_time": string (optional),
    "integration_mentioned": string (optional),
    "urgency_keywords": [strings]
  },
  "suggested_queue": "Engineering" | "Billing" | "Product" | "IT/Security" | "Escalation",
  "summary": "2-3 sentences"
}

ENTITY EXTRACTION RULES:
Populate every entity field that applies. Omit any field not present in the message - do not invent values and do not emit empty strings.
- account_id: any user handle, email, or account URL. If a full URL is given in the message, extract the full URL (not just the handle).
- invoice_number: any invoice or transaction ID.
- error_code: HTTP codes, error numbers, stack trace codes.
- dollar_amounts: ALL monetary values mentioned, as numbers.
- affected_service: the product component or feature impacted (dashboard, login, API, audit logs, etc.).
- incident_time: when the issue started, verbatim from the message.
- integration_mentioned: third-party tools (Okta, Salesforce, Jira, etc.). Omit the field entirely if none mentioned - do NOT emit an empty string.
- urgency_keywords: ALWAYS include this field. 2-5 verbatim phrases signaling urgency or scope. Use an empty array [] if the tone is calm.

CONFIDENCE CALIBRATION (do not default to 1.0):
- 0.95-1.0: textbook, zero plausible alternative
- 0.85-0.94: clear with minor ambiguity
- 0.70-0.84: likely but reasonable alternatives
- 0.50-0.69: genuinely ambiguous
- below 0.50: guessing
A hedge like 'I am not sure if this is the right place' must lower confidence to 0.70 or below.

PRIORITY RULES:
- Incident/Outage is always High
- Billing discrepancies over $500 are High; $100-500 Medium; <$100 Low
- Login failures, data loss, security concerns are High
- Feature requests default to Medium unless critical
- Pre-sales/evaluation questions default to Low

QUEUE ROUTING (suggested_queue):
- Bug Report or Incident/Outage to Engineering
- Billing Issue to Billing
- Feature Request to Product
- Technical Question to IT/Security
- Override to Escalation if confidence<0.7 OR 'outage' keyword OR billing discrepancy>$500

Return ONLY valid JSON.
```

### Rationale
Structured a single prompt (rather than two-stage classification) because the task scope is small and the full context benefits category + entity + routing decisions simultaneously. Explicit confidence calibration bands with a dedicated `reasoning` field push the model to consider alternatives before committing — improved calibration during Gemini playground iteration (Sample 4 dropped from 1.0 → 0.75 after adding the reasoning field). Production Groq/Llama 3.3 70B now lands Sample 4 at **0.7**, matching the hedge rule; the routing override condition `confidence < 0.7` is strict, so the record stays in IT/Security rather than escalating. Priority and routing rules are encoded in the prompt rather than in downstream orchestration so the logic lives alongside the classification, keeping the n8n workflow simpler. **Entity normalization is enforced at the Code node** rather than relying on the LLM alone — Llama 3.3 follows "ALWAYS include" instructions inconsistently, so the Code node guarantees `urgency_keywords` is always an array and strips empty-string entity fields before the record is emitted.

**Tradeoffs made:**
- One LLM call instead of two: cheaper/faster, but a parsing or schema error breaks everything at once. With more time, would add a second validation pass or a pydantic-style retry loop.
- Hardcoded priority rules in the prompt instead of a separate rules engine: easier to demo, harder to version-control independently of prompt changes. Production: extract to a config file.
- Entity normalization in the Code node rather than strict schema enforcement (e.g., OpenAI `response_format: {type: "json_schema"}` with a JSON Schema): the normalization layer is more permissive and repairs malformed entities instead of rejecting them. Strict schema would be preferable in production; the current approach is a pragmatic choice given Groq's schema support is limited to generic `json_object`.

**What I would change with more time (per-prompt):**
The single biggest change would be adding 1–2 labeled few-shot examples per category inside this prompt, especially for the pre-sales-vs-Technical-Question edge case (Sample 4). Llama 3.3 follows rule-based instructions inconsistently — explicit examples ground the model better than rules. Second, I would split this into a two-call pattern: a cheap classification call followed by a category-conditioned entity-extraction call with per-category schema, eliminating the empty-entity / missing-field issues at the source rather than repairing them in the Code node. See §5 for the full forward-looking list.

---

## 2. JSON Schema (Structured Outputs)

In production (Groq), enforced via `response_format: {type: "json_object"}` plus the schema embedded in the system prompt. During initial playground validation (Gemini), enforced via the `response_schema` parameter (OpenAPI subset). Both approaches yielded identical structured output:

```json
{
  "type": "object",
  "properties": {
    "category": {
      "type": "string",
      "enum": ["Bug Report", "Feature Request", "Billing Issue", "Technical Question", "Incident/Outage"]
    },
    "priority": {
      "type": "string",
      "enum": ["Low", "Medium", "High"]
    },
    "confidence": {
      "type": "number",
      "minimum": 0,
      "maximum": 1
    },
    "reasoning": {
      "type": "string",
      "description": "Brief explanation of why this category, priority, and confidence were chosen. Mention any alternative category considered."
    },
    "core_issue": {
      "type": "string",
      "description": "One-sentence summary of the issue"
    },
    "entities": {
      "type": "object",
      "properties": {
        "account_id": { "type": "string" },
        "invoice_number": { "type": "string" },
        "error_code": { "type": "string" },
        "dollar_amounts": {
          "type": "array",
          "items": { "type": "number" }
        },
        "affected_service": {
          "type": "string",
          "description": "The product feature or component affected (e.g., dashboard, login, API)"
        },
        "incident_time": {
          "type": "string",
          "description": "Time the issue started if mentioned (e.g., '2pm EST', 'last Tuesday')"
        },
        "integration_mentioned": {
          "type": "string",
          "description": "Third-party tool or service mentioned (e.g., Okta, Salesforce)"
        },
        "urgency_keywords": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "suggested_queue": {
      "type": "string",
      "enum": ["Engineering", "Billing", "Product", "IT/Security", "Escalation"]
    },
    "summary": {
      "type": "string",
      "description": "2-3 sentence human-readable summary for the receiving team"
    }
  },
  "required": ["category", "priority", "confidence", "reasoning", "core_issue", "suggested_queue", "summary"]
}
```

### Rationale
Enum constraints on `category`, `priority`, and `suggested_queue` eliminate the most common class of LLM output errors (typos, hallucinated categories). `dollar_amounts` is an array of numbers rather than strings so downstream logic can do numeric comparisons without parsing. Optional entity fields (not in `required`) let the schema adapt to messages with no extractable entities without failing validation. Settled on a flat `entities` object rather than category-specific nested shapes because the downstream n8n routing only needs to read top-level fields.

---

## 3. Validated Baseline — 5 Sample Outputs

> The JSON blocks below are the `classification` payloads extracted directly from the shipped `output.json` / `escalation_queue.json` records — the same Groq run, not a separately captured re-run. They show the verbatim model output that the workflow produced and persisted. Wrapper fields (`record_id`, `routing`, `escalation_flag`, `escalation_reasons`) live in the shipped JSON files; `classification` is reproduced here for inline review.

### Sample 1 — Email — Bug Report

**Input:**
> Hi, I tried logging in this morning and keep getting a 403 error. My account is arcvault.io/user/jsmith. This started after your update last Tuesday.

**Output (Groq, Llama 3.3 70B):**
```json
{
  "category": "Bug Report",
  "priority": "High",
  "confidence": 0.9,
  "reasoning": "The runner-up category could be Technical Question, but the mention of a specific error code and a recent update points more strongly towards a Bug Report.",
  "core_issue": "The user is experiencing a 403 error when trying to log in after a recent update.",
  "entities": {
    "account_id": "arcvault.io/user/jsmith",
    "error_code": "403",
    "affected_service": "login",
    "incident_time": "this morning",
    "urgency_keywords": ["this morning", "keep getting"]
  },
  "suggested_queue": "Engineering",
  "summary": "The user is experiencing a 403 error when trying to log in, which started after the update last Tuesday. The user's account is arcvault.io/user/jsmith. The issue is preventing the user from accessing the service."
}
```

---

### Sample 2 — Web Form — Feature Request

**Input:**
> We'd love to see a bulk export feature for our audit logs. We're a compliance-heavy org and this would save us hours every month.

**Output (Groq, Llama 3.3 70B):**
```json
{
  "category": "Feature Request",
  "priority": "Medium",
  "confidence": 0.9,
  "reasoning": "The message clearly describes a desired functionality, with no plausible alternative categories, but the tone is polite and suggestive rather than imperative.",
  "core_issue": "The user needs a bulk export feature for audit logs to reduce manual work.",
  "entities": {
    "affected_service": "audit logs",
    "urgency_keywords": ["compliance-heavy", "save us hours"]
  },
  "suggested_queue": "Product",
  "summary": "The user is requesting a bulk export feature for audit logs to streamline their compliance processes. This feature would significantly reduce their monthly workload. The request is framed as a suggestion rather than a critical need."
}
```

---

### Sample 3 — Support Portal — Billing Issue

**Input:**
> Invoice #8821 shows a charge of $1,240 but our contract rate is $980/month. Can someone look into this?

**Output (Groq, Llama 3.3 70B):**
```json
{
  "category": "Billing Issue",
  "priority": "Medium",
  "confidence": 0.9,
  "reasoning": "The message could also be a Technical Question if the user is unsure about how to read the invoice, but the primary concern is a billing discrepancy.",
  "core_issue": "The user's invoice shows a higher charge than their expected contract rate.",
  "entities": {
    "invoice_number": "8821",
    "dollar_amounts": [1240, 980],
    "urgency_keywords": ["can someone look into this"]
  },
  "suggested_queue": "Billing",
  "summary": "The user is reporting a billing discrepancy with their current invoice, showing a charge of $1,240 instead of the expected $980 based on their contract. They are requesting someone to investigate this issue. The user is likely looking for a resolution to this discrepancy."
}
```

---

### Sample 4 — Email — Technical Question (ambiguous/pre-sales)

**Input:**
> I'm not sure if this is the right place to ask, but is there a way to set up SSO with Okta? We're evaluating switching our auth provider.

**Output (Groq, Llama 3.3 70B):**
```json
{
  "category": "Technical Question",
  "priority": "Low",
  "confidence": 0.7,
  "reasoning": "The user is asking about setting up SSO with Okta, but they mention they are evaluating switching their auth provider, which could also imply a potential feature request or billing discussion.",
  "core_issue": "The user is inquiring about setting up Single Sign-On with Okta for their organization.",
  "entities": {
    "integration_mentioned": "Okta",
    "urgency_keywords": []
  },
  "suggested_queue": "IT/Security",
  "summary": "The user is evaluating switching their authentication provider and is inquiring about setting up Single Sign-On with Okta. They are unsure if they are contacting the correct department. The user is seeking information on the possibility of integrating Okta with their current system."
}
```

**Note:** Sample 4 sits at the 0.7 calibration boundary. The prompt's hedge rule ("A hedge like 'I am not sure if this is the right place' must lower confidence to 0.70 or below") matches and the model returns 0.7. The escalation rule `confidence < 0.7` is strict inequality, so at 0.7 the record does **not** escalate — it routes to IT/Security. This is the calibration data point worth watching: the model detects the ambiguity, the threshold behavior is well-defined, and the pre-sales/evaluation priority rule assigns Low. In production, I would log all 0.65–0.80 cases and review weekly to tune the threshold empirically.

---

### Sample 5 — Web Form — Incident/Outage

**Input:**
> Your dashboard stopped loading for us around 2pm EST. Checked our end — it's definitely on yours. Multiple users affected.

**Output (Groq, Llama 3.3 70B):**
```json
{
  "category": "Incident/Outage",
  "priority": "High",
  "confidence": 0.95,
  "reasoning": "The issue is reported as a sudden stop in service, which aligns more closely with an incident or outage than other categories.",
  "core_issue": "The ArcVault dashboard stopped loading for multiple users.",
  "entities": {
    "affected_service": "dashboard",
    "incident_time": "around 2pm EST",
    "urgency_keywords": ["stopped loading", "Multiple users affected"]
  },
  "suggested_queue": "Engineering",
  "summary": "The ArcVault dashboard stopped loading for multiple users around 2pm EST, and the issue has been confirmed to be on the ArcVault end. The affected users are unable to access the dashboard, indicating a significant disruption in service."
}
```

**Note:** Escalation is triggered deterministically in the Code node via keyword match on "multiple users affected" in the raw message (the keyword list includes `outage`, `down for all users`, `all users affected`, and `multiple users affected`). The LLM's `suggested_queue` here is `Engineering` (following the QUEUE ROUTING rule for Incident/Outage → Engineering) — the Code node overrides this to `Escalation` because of the keyword match. The record's `routing.rule_and_llm_agree` is therefore `false`, which surfaces the disagreement: the LLM did category-level judgment, the Code node applied scope-amplifying escalation policy.

---

## 4. Summary of Validation

| # | Category | Priority | Confidence | Queue | Status |
|---|---|---|---|---|---|
| 1 | Bug Report | High | 0.9 | Engineering | ✅ |
| 2 | Feature Request | Medium | 0.9 | Product | ✅ |
| 3 | Billing Issue | Medium | 0.9 | Billing | ✅ |
| 4 | Technical Question | Low | 0.7 | IT/Security | ✅ (at threshold; rule is strict <) |
| 5 | Incident/Outage | High | 0.95 | Escalation | ✅ |

- 5/5 categorically correct
- 5/5 correct priority assignments (rules held)
- Confidence calibration validated on ambiguous case (Sample 4)
- Escalation triggered correctly on Sample 5
- Entity extraction produced structured, downstream-usable fields

## 5. What I Would Change With More Time

1. **Two-call pattern for critical cases.** If initial confidence < 0.85, run a second pass with a different framing to cross-check the classification. Would cost 2× tokens but catch subtle misclassifications.
2. **Few-shot examples in the prompt.** Add 1-2 labeled example messages per category to ground the model, especially for edge cases (pre-sales vs. technical question).
3. **Programmatic eval.** Build a small harness that scores each classification against a human-labeled ground truth, yielding precision/recall per category. The brief asks for 5 inputs, but real deployment needs ~100 labeled examples to tune thresholds empirically.
4. **Separate priority and category calls.** Keep category in one call (cheap, fast), priority in a second call with richer rules. Easier to iterate on priority logic without touching classification.
5. **Category-specific entity schemas.** A billing message's entities differ from an outage's. With more time, use conditional schema selection based on first-pass category.
