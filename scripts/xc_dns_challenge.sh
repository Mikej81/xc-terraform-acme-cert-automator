#!/usr/bin/env bash
#
# xc_dns_challenge.sh — Manage ACME DNS-01 challenge TXT records via F5 XC DNS API.
#
# Called by lego's "exec" DNS provider during acme_certificate operations.
#
# The Volterra Terraform provider has dns_zone and dns_zone_record resources,
# but DNS-01 challenges need ephemeral TXT records created and deleted within a
# single terraform apply -- that can't be modeled as a declarative resource.
# This script calls the XC DNS RRSet API directly using an API token.
# If lego gains a native f5xc provider, this script can be retired.
#
# Arguments (set by lego exec provider):
#   $1 = "present" or "cleanup"
#   $2 = FQDN (e.g. "_acme-challenge.example.com.")
#   $3 = challenge token value
#   $4 = domain (e.g. "example.com.")
#
# Required environment variables (set automatically by Terraform):
#   XC_TENANT_URL   — XC tenant URL (e.g. https://tenant.console.ves.volterra.io)
#   XC_API_TOKEN    — XC API token with DNS zone record permissions
#   XC_DNS_ZONES    — Comma-separated list of DNS zone names in XC
#   XC_GROUP_NAME   — DNS record group name (default: "default")
#
set -euo pipefail

ACTION="${1:?missing action (present or cleanup)}"
FQDN="${2:?missing FQDN}"
TOKEN="${3:?missing token}"

GROUP_NAME="${XC_GROUP_NAME:-default}"

# Validate required env vars
for var_name in XC_TENANT_URL XC_API_TOKEN XC_DNS_ZONES; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: $var_name is not set" >&2
    exit 1
  fi
done

# Strip trailing /api if present
TENANT_URL="${XC_TENANT_URL%/api}"
TENANT_URL="${TENANT_URL%/}"

# FQDN comes with trailing dot, e.g. "_acme-challenge.example.com."
FQDN_CLEAN="${FQDN%.}"

# ── Find the matching zone for this FQDN ──────────────────────────
# Iterate zones and pick the longest match (most specific zone wins).
# e.g. for FQDN "_acme-challenge.sub.example.com":
#   zone "example.com" matches, zone "sub.example.com" also matches
#   => pick "sub.example.com" as it is more specific
MATCHED_ZONE=""
IFS=',' read -ra ZONES <<< "$XC_DNS_ZONES"
for ZONE in "${ZONES[@]}"; do
  ZONE=$(echo "$ZONE" | xargs)  # trim whitespace
  ZONE="${ZONE%.}"               # strip trailing dot if present
  [[ -z "$ZONE" ]] && continue

  # Check if FQDN ends with .zone or equals zone
  if [[ "$FQDN_CLEAN" == *".${ZONE}" || "$FQDN_CLEAN" == "$ZONE" ]]; then
    # Pick the longest (most specific) match
    if [[ ${#ZONE} -gt ${#MATCHED_ZONE} ]]; then
      MATCHED_ZONE="$ZONE"
    fi
  fi
done

if [[ -z "$MATCHED_ZONE" ]]; then
  echo "Error: FQDN '$FQDN_CLEAN' does not belong to any configured zone: $XC_DNS_ZONES" >&2
  exit 1
fi

# Extract the record name (everything before the zone)
# e.g. "_acme-challenge.example.com" with zone "example.com" => "_acme-challenge"
RECORD_NAME="${FQDN_CLEAN%.${MATCHED_ZONE}}"

API_BASE="${TENANT_URL}/api/config/dns/namespaces/system/dns_zones/${MATCHED_ZONE}/rrsets/${GROUP_NAME}"
AUTH_HEADER="Authorization: APIToken ${XC_API_TOKEN}"

# ── Present: create or update TXT record ───────────────────────────
if [[ "$ACTION" == "present" ]]; then
  TMPDIR_WORK=$(mktemp -d)
  trap 'rm -rf "$TMPDIR_WORK"' EXIT

  # Check if the record already exists
  HTTP_CODE=$(curl -s -o "$TMPDIR_WORK/get_response.json" -w "%{http_code}" \
    -H "$AUTH_HEADER" \
    "${API_BASE}/${RECORD_NAME}/TXT" 2>/dev/null) || true

  if [[ "$HTTP_CODE" == "200" ]]; then
    # Record exists — append the new token to existing values and replace
    EXISTING_VALUES=$(jq -r '[.rrset.txt_record.values[]?]' "$TMPDIR_WORK/get_response.json" 2>/dev/null) || EXISTING_VALUES="[]"

    MERGED_VALUES=$(echo "$EXISTING_VALUES" | jq -c --arg token "$TOKEN" '. + [$token] | unique')

    PAYLOAD=$(jq -n -c \
      --arg zone "$MATCHED_ZONE" \
      --arg group "$GROUP_NAME" \
      --arg name "$RECORD_NAME" \
      --argjson values "$MERGED_VALUES" \
      '{
        dns_zone_name: $zone,
        group_name: $group,
        type: "TXT",
        rrset: {
          description: "ACME DNS-01 challenge",
          ttl: 120,
          txt_record: {
            name: $name,
            values: $values
          }
        }
      }')

    curl -s --fail-with-body \
      -H "$AUTH_HEADER" \
      -H "Content-Type: application/json" \
      -X PUT \
      -d "$PAYLOAD" \
      "${API_BASE}/${RECORD_NAME}/TXT" >/dev/null 2>&1
  else
    # Record does not exist — create it
    PAYLOAD=$(jq -n -c \
      --arg zone "$MATCHED_ZONE" \
      --arg group "$GROUP_NAME" \
      --arg name "$RECORD_NAME" \
      --arg token "$TOKEN" \
      '{
        dns_zone_name: $zone,
        group_name: $group,
        rrset: {
          description: "ACME DNS-01 challenge",
          ttl: 120,
          txt_record: {
            name: $name,
            values: [$token]
          }
        }
      }')

    curl -s --fail-with-body \
      -H "$AUTH_HEADER" \
      -H "Content-Type: application/json" \
      -X POST \
      -d "$PAYLOAD" \
      "$API_BASE" >/dev/null 2>&1
  fi

# ── Cleanup: delete TXT record ─────────────────────────────────────
elif [[ "$ACTION" == "cleanup" ]]; then
  curl -s --fail-with-body \
    -H "$AUTH_HEADER" \
    -X DELETE \
    "${API_BASE}/${RECORD_NAME}/TXT" >/dev/null 2>&1 || true

else
  echo "Error: unknown action '$ACTION' (expected 'present' or 'cleanup')" >&2
  exit 1
fi
