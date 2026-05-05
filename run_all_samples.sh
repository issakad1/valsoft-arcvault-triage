#!/bin/bash
# Runs all 5 ArcVault sample messages through the n8n triage workflow
# and writes results to output.json + escalation_queue.json

set -e
cd "$(dirname "$0")"

WEBHOOK_URL="http://localhost:5678/webhook/arcvault-triage"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# 5 sample inputs (from the assessment brief)
declare -A SAMPLES
SAMPLES[1]='{"source":"Email","raw_message":"Hi, I tried logging in this morning and keep getting a 403 error. My account is arcvault.io/user/jsmith. This started after your update last Tuesday."}'
SAMPLES[2]='{"source":"Web Form","raw_message":"We'\''d love to see a bulk export feature for our audit logs. We'\''re a compliance-heavy org and this would save us hours every month."}'
SAMPLES[3]='{"source":"Support Portal","raw_message":"Invoice #8821 shows a charge of $1,240 but our contract rate is $980/month. Can someone look into this?"}'
SAMPLES[4]='{"source":"Email","raw_message":"I'\''m not sure if this is the right place to ask, but is there a way to set up SSO with Okta? We'\''re evaluating switching our auth provider."}'
SAMPLES[5]='{"source":"Web Form","raw_message":"Your dashboard stopped loading for us around 2pm EST. Checked our end — it'\''s definitely on yours. Multiple users affected."}'

echo "Running 5 sample messages through ArcVault triage..."
echo "(Groq free tier; minimal delays)"
echo

for i in 1 2 3 4 5; do
  echo "→ Sample $i..."
  RESPONSE=$(curl -s -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "${SAMPLES[$i]}")
  echo "$RESPONSE" > "$TMPDIR/sample-$i.json"

  # Validate it's a proper triage record
  QUEUE=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('routing',{}).get('queue','?'))" 2>/dev/null || echo "PARSE_FAIL")
  ESCALATED=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('escalation_flag','?'))" 2>/dev/null || echo "PARSE_FAIL")

  if [ "$QUEUE" = "PARSE_FAIL" ] || [ "$QUEUE" = "?" ]; then
    echo "  ⚠ FAILED. Raw response (first 200 chars):"
    echo "$RESPONSE" | head -c 200
    echo
  else
    echo "  ✓ queue: $QUEUE | escalated: $ESCALATED"
  fi
  sleep 1  # tiny delay; Groq free tier handles 30 RPM easily
done

echo
echo "Aggregating results..."

python3 - <<PYEOF
import json, glob, os

records = []
failed = 0
for f in sorted(glob.glob("$TMPDIR/sample-*.json")):
    try:
        with open(f) as fh:
            data = json.load(fh)
            if "escalation_flag" in data:
                records.append(data)
            else:
                failed += 1
                print(f"  ⚠ {os.path.basename(f)} parsed but missing fields")
    except json.JSONDecodeError:
        failed += 1
        print(f"  ⚠ {os.path.basename(f)} not valid JSON")

non_escalated = [r for r in records if not r["escalation_flag"]]
escalated = [r for r in records if r["escalation_flag"]]

with open("output.json", "w") as fh:
    json.dump(non_escalated, fh, indent=2)
with open("escalation_queue.json", "w") as fh:
    json.dump(escalated, fh, indent=2)

print(f"  output.json: {len(non_escalated)} records")
print(f"  escalation_queue.json: {len(escalated)} records")
if failed:
    print(f"  ⚠ {failed} sample(s) failed - re-run if needed")
PYEOF

echo
echo "Done. Files written to $(pwd):"
ls -la output.json escalation_queue.json
