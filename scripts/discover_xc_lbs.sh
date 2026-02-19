#!/usr/bin/env bash
#
# discover_xc_lbs.sh — Discover internet-facing HTTPS load balancers from F5 XC
#                       and generate the xc_certificates Terraform variable.
#
# Run once during migration. The output is a .auto.tfvars.json file that
# Terraform loads automatically on every apply for renewal.
#
# Usage:
#   bash scripts/discover_xc_lbs.sh \
#     --p12-file /path/to/api-credential.p12 \
#     --p12-pass yourpassword \
#     --tenant-url https://tenant.console.ves.volterra.io/api \
#     --namespaces ns1,ns2 \
#     [--domain-filter example.com,other.com]
#
# Output: certificates.auto.tfvars.json (written to current directory)
#
set -euo pipefail

# ── Parse CLI arguments ──────────────────────────────────────────────
P12_FILE=""
P12_PASS=""
TENANT_URL=""
NAMESPACES=""
DOMAIN_FILTER=""

usage() {
  echo "Usage: $0 --p12-file FILE --p12-pass PASS --tenant-url URL --namespaces NS[,NS...] [--domain-filter SUFFIX[,SUFFIX...]]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --p12-file)     P12_FILE="$2";      shift 2 ;;
    --p12-pass)     P12_PASS="$2";      shift 2 ;;
    --tenant-url)   TENANT_URL="$2";    shift 2 ;;
    --namespaces)   NAMESPACES="$2";    shift 2 ;;
    --domain-filter) DOMAIN_FILTER="$2"; shift 2 ;;
    -h|--help)      usage ;;
    *)              echo "Unknown argument: $1" >&2; usage ;;
  esac
done

# ── Validate required arguments ──────────────────────────────────────
for var_name in P12_FILE P12_PASS TENANT_URL NAMESPACES; do
  val="${!var_name}"
  if [[ -z "$val" ]]; then
    echo "Error: --$(echo "$var_name" | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required." >&2
    usage
  fi
done

if [[ ! -f "$P12_FILE" ]]; then
  echo "Error: P12 file not found: $P12_FILE" >&2
  exit 1
fi

# ── Extract cert + key from P12 ────────────────────────────────────
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

CERT_FILE="$TMPDIR_WORK/cert.pem"
KEY_FILE="$TMPDIR_WORK/key.pem"

# Try with -legacy first (OpenSSL 3.x), fall back without it
if openssl pkcs12 -in "$P12_FILE" -passin "pass:$P12_PASS" -clcerts -nokeys -out "$CERT_FILE" -legacy 2>/dev/null; then
  openssl pkcs12 -in "$P12_FILE" -passin "pass:$P12_PASS" -nocerts -nodes -out "$KEY_FILE" -legacy 2>/dev/null
else
  openssl pkcs12 -in "$P12_FILE" -passin "pass:$P12_PASS" -clcerts -nokeys -out "$CERT_FILE" 2>/dev/null
  openssl pkcs12 -in "$P12_FILE" -passin "pass:$P12_PASS" -nocerts -nodes -out "$KEY_FILE" 2>/dev/null
fi

# Strip trailing /api if present, we add our own paths
TENANT_URL="${TENANT_URL%/api}"
TENANT_URL="${TENANT_URL%/}"

# ── Build domain filter array for jq ────────────────────────────────
if [[ -n "$DOMAIN_FILTER" ]]; then
  FILTER_JSON=$(echo "$DOMAIN_FILTER" | tr ',' '\n' | jq -R . | jq -sc .)
else
  FILTER_JSON="[]"
fi

# ── Query each namespace ────────────────────────────────────────────
RESULT="{}"
SUCCESS_COUNT=0
TOTAL_NS=0

IFS=',' read -ra NS_ARRAY <<< "$NAMESPACES"
for NS in "${NS_ARRAY[@]}"; do
  NS=$(echo "$NS" | xargs)  # trim whitespace
  [[ -z "$NS" ]] && continue

  ((TOTAL_NS++)) || true

  API_URL="${TENANT_URL}/api/config/namespaces/${NS}/http_loadbalancers?report_fields"

  echo "Querying namespace: $NS ..." >&2
  RESPONSE=$(curl -s --fail-with-body \
    --cert "$CERT_FILE" \
    --key "$KEY_FILE" \
    "$API_URL" 2>/dev/null) || { echo "  FAILED — skipping $NS" >&2; continue; }

  ((SUCCESS_COUNT++)) || true

  # The ?report_fields query param returns the full spec under .get_spec.
  # Filter: must have https (manual cert) AND (advertise_on_public or advertise_on_public_default_vip)
  # We skip https_auto_cert LBs -- those already have ACME certs managed by XC.
  # Then apply domain filter if provided.
  FILTERED=$(echo "$RESPONSE" | jq -c --arg ns "$NS" --argjson filter "$FILTER_JSON" '
    [.items[]? | select(
      (.get_spec.https != null and .get_spec.https_auto_cert == null)
      and
      (.get_spec.advertise_on_public != null or .get_spec.advertise_on_public_default_vip != null)
    ) | {
      namespace: $ns,
      name: .name,
      domains: [.get_spec.domains[]? // []]
    } | select(.domains | length > 0)
    # Apply domain filter: all domains must match at least one filter suffix
    | select(
        ($filter | length) == 0
        or
        (.domains | all(. as $d | $filter | any(. as $f | $d == $f or ($d | endswith(".\($f)")))))
      )
    ]
  ' 2>/dev/null) || continue

  LB_COUNT=$(echo "$FILTERED" | jq 'length')
  echo "  Found $LB_COUNT matching LB(s) in $NS" >&2

  # Merge into RESULT map
  RESULT=$(echo "$RESULT" | jq -c --argjson filtered "$FILTERED" '
    . + (
      [$filtered[] | {key: "\(.namespace)/\(.name)", value: .}]
      | from_entries
    )
  ')
done

# If all namespaces failed, exit with error
if [[ $TOTAL_NS -gt 0 && $SUCCESS_COUNT -eq 0 ]]; then
  echo "Error: XC API unreachable for all $TOTAL_NS namespace(s). Check P12 credentials and tenant URL." >&2
  exit 1
fi

TOTAL_LBS=$(echo "$RESULT" | jq 'length')
echo "Total: $TOTAL_LBS LB(s) discovered across $SUCCESS_COUNT namespace(s)" >&2

# ── Write certificates.auto.tfvars.json ──────────────────────────────
OUTPUT_FILE="certificates.auto.tfvars.json"
echo "$RESULT" | jq '{ xc_certificates: . }' > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE ($TOTAL_LBS certificates)" >&2
