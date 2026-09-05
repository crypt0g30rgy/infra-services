#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Cloudflare Multi-Zone Tunnel Registration
#
# One API token -> many Cloudflare zones -> one Tunnel
#
# Requirements:
#   - curl
#   - jq
#   - Cloudflare API token
#   - Cloudflare Account ID
#
# Required API permissions:
#
#   Account
#     Cloudflare Tunnel: Edit
#
#   Zone
#     DNS: Edit
#
# Usage:
#
#   export CF_API_TOKEN="cfat_..."
#   export CF_ACCOUNT_ID="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
#
#   ./cf-tunnel-register.sh my-tunnel example.com example.net
#
# ============================================================

API="https://api.cloudflare.com/client/v4"

: "${CF_API_TOKEN:?ERROR: CF_API_TOKEN is not set}"
: "${CF_ACCOUNT_ID:?ERROR: CF_ACCOUNT_ID is not set}"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required"
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required"
    exit 1
fi

if [[ $# -lt 2 ]]; then
    echo
    echo "Usage:"
    echo
    echo "  $0 <tunnel-name> <domain> [domain ...]"
    echo
    echo "Example:"
    echo
    echo "  $0 production-tunnel example.com example.net example.org"
    echo
    exit 1
fi

TUNNEL_NAME="$1"
shift

DOMAINS=("$@")

AUTH_HEADER="Authorization: Bearer ${CF_API_TOKEN}"
CONTENT_HEADER="Content-Type: application/json"

# NOTE: no -f here. With -f, curl exits non-zero on HTTP 4xx/5xx and
# discards the response body, which means check_response() never gets
# a chance to show Cloudflare's actual error JSON before set -e kills
# the script. We rely on check_response()'s `.success` check instead.
api() {
    curl -sS \
        -H "$AUTH_HEADER" \
        -H "$CONTENT_HEADER" \
        "$@"
}

check_response() {
    local response="$1"

    if [[ "$(jq -r '.success' <<< "$response")" != "true" ]]; then
        echo
        echo "Cloudflare API error:"
        jq '.errors' <<< "$response"
        exit 1
    fi
}

echo
echo "============================================================"
echo " Cloudflare Multi-Zone Tunnel Registration"
echo "============================================================"
echo
echo "Tunnel : $TUNNEL_NAME"
echo "Account: ${CF_ACCOUNT_ID}"
echo
echo "Domains:"
printf '  - %s\n' "${DOMAINS[@]}"
echo

# ------------------------------------------------------------
# 1. Find existing tunnel
# ------------------------------------------------------------

echo "[1/5] Checking for existing tunnel..."

TUNNEL_LIST="$(
    api \
    "${API}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=$(printf '%s' "$TUNNEL_NAME" | jq -sRr @uri)&is_deleted=false"
)"

check_response "$TUNNEL_LIST"

TUNNEL_ID="$(
    jq -r --arg NAME "$TUNNEL_NAME" '
        .result[]
        | select(.name == $NAME)
        | .id
    ' <<< "$TUNNEL_LIST" | head -n1
)"

# ------------------------------------------------------------
# 2. Create tunnel if it doesn't exist
# ------------------------------------------------------------

if [[ -z "$TUNNEL_ID" ]]; then

    echo "Tunnel does not exist."
    echo "Creating tunnel..."

    CREATE_RESPONSE="$(
        api \
        -X POST \
        "${API}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
        --data "$(jq -n \
            --arg name "$TUNNEL_NAME" \
            '{
                name: $name,
                config_src: "cloudflare"
            }'
        )"
    )"

    check_response "$CREATE_RESPONSE"

    TUNNEL_ID="$(jq -r '.result.id' <<< "$CREATE_RESPONSE")"

    echo "Created tunnel:"
    echo "  ID: $TUNNEL_ID"

else

    echo "Existing tunnel found:"
    echo "  ID: $TUNNEL_ID"

fi

# The CNAME target for Cloudflare Tunnel only depends on the tunnel ID,
# not on any particular domain, so compute it once here.
TARGET="${TUNNEL_ID}.cfargotunnel.com"

echo

# ------------------------------------------------------------
# 3. Process every Cloudflare zone
# ------------------------------------------------------------

echo "[2/5] Processing DNS zones..."
echo

for DOMAIN in "${DOMAINS[@]}"; do

    echo "------------------------------------------------------------"
    echo "Domain: $DOMAIN"
    echo "------------------------------------------------------------"

    # Find the Cloudflare zone.
    ZONE_RESPONSE="$(
        api \
        "${API}/zones?name=${DOMAIN}&status=active"
    )"

    check_response "$ZONE_RESPONSE"

    ZONE_ID="$(
        jq -r '.result[0].id // empty' <<< "$ZONE_RESPONSE"
    )"

    ZONE_NAME="$(
        jq -r '.result[0].name // empty' <<< "$ZONE_RESPONSE"
    )"

    if [[ -z "$ZONE_ID" ]]; then
        echo "ERROR: Cloudflare zone not found for ${DOMAIN}"
        echo
        echo "Make sure:"
        echo "  1. The domain is added to this Cloudflare account."
        echo "  2. The domain is active."
        echo
        exit 1
    fi

    echo "Zone ID: $ZONE_ID"
    echo "Zone:    $ZONE_NAME"
    echo

    # --------------------------------------------------------
    # DNS record creation
    #
    # The CNAME target for Cloudflare Tunnel is:
    #
    #   <TUNNEL_ID>.cfargotunnel.com
    #
    # Existing records are detected before creation.
    # --------------------------------------------------------

    create_dns_record() {

        local RECORD_NAME="$1"

        echo "Checking DNS record: ${RECORD_NAME}"

        EXISTING="$(
            api \
            "${API}/zones/${ZONE_ID}/dns_records?type=CNAME&name=${RECORD_NAME}"
        )"

        check_response "$EXISTING"

        RECORD_ID="$(
            jq -r '.result[0].id // empty' <<< "$EXISTING"
        )"

        if [[ -n "$RECORD_ID" ]]; then

            CURRENT_TARGET="$(
                jq -r '.result[0].content' <<< "$EXISTING"
            )"

            echo "  Existing CNAME found."
            echo "  Target: ${CURRENT_TARGET}"

            if [[ "$CURRENT_TARGET" != "$TARGET" ]]; then

                echo "  Updating target..."

                UPDATE="$(
                    api \
                    -X PUT \
                    "${API}/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
                    --data "$(jq -n \
                        --arg name "$RECORD_NAME" \
                        --arg target "$TARGET" \
                        '{
                            type: "CNAME",
                            name: $name,
                            content: $target,
                            ttl: 1,
                            proxied: true
                        }'
                    )"
                )"

                check_response "$UPDATE"

                echo "  Updated."

            else

                echo "  Already points to this tunnel."

            fi

        else

            echo "  Creating CNAME..."

            CREATE_DNS="$(
                api \
                -X POST \
                "${API}/zones/${ZONE_ID}/dns_records" \
                --data "$(jq -n \
                    --arg name "$RECORD_NAME" \
                    --arg target "$TARGET" \
                    '{
                        type: "CNAME",
                        name: $name,
                        content: $target,
                        ttl: 1,
                        proxied: true
                    }'
                )"
            )"

            check_response "$CREATE_DNS"

            echo "  Created."

        fi
    }

    # Root
    create_dns_record "$ZONE_NAME"

    # Wildcard
    create_dns_record "*.${ZONE_NAME}"

    echo
done

# ------------------------------------------------------------
# 4. Get tunnel token
# ------------------------------------------------------------

echo
echo "[3/5] Retrieving tunnel token..."

TOKEN_RESPONSE="$(
    api \
    "${API}/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token"
)"

check_response "$TOKEN_RESPONSE"

TUNNEL_TOKEN="$(jq -r '.result' <<< "$TOKEN_RESPONSE")"

if [[ -z "$TUNNEL_TOKEN" || "$TUNNEL_TOKEN" == "null" ]]; then
    echo "ERROR: Cloudflare returned no tunnel token."
    exit 1
fi

# ------------------------------------------------------------
# 5. Generate output
# ------------------------------------------------------------

OUTPUT_DIR="./cloudflare-${TUNNEL_NAME}"

mkdir -p "$OUTPUT_DIR"

TOKEN_FILE="${OUTPUT_DIR}/tunnel-token"

printf '%s\n' "$TUNNEL_TOKEN" > "$TOKEN_FILE"

chmod 600 "$TOKEN_FILE"

echo
echo "[4/5] Saving token..."
echo "Token saved to:"
echo "  ${TOKEN_FILE}"

echo
echo "[5/5] Complete."
echo
echo "============================================================"
echo " Tunnel"
echo "============================================================"
echo
echo "Name:"
echo "  ${TUNNEL_NAME}"
echo
echo "ID:"
echo "  ${TUNNEL_ID}"
echo
echo "Tunnel hostname:"
echo "  ${TARGET}"
echo

echo "Domains:"
for DOMAIN in "${DOMAINS[@]}"; do
    echo "  https://${DOMAIN}"
    echo "  https://*.${DOMAIN}"
done

echo
echo "============================================================"
echo " Kubernetes / cloudflared"
echo "============================================================"
echo
echo "Run:"
echo
echo "  cloudflared tunnel run --token \$(cat ${TOKEN_FILE})"
echo
echo "Or create a Kubernetes Secret:"
echo
echo "  kubectl create secret generic cloudflared-token \\"
echo "    --from-file=token=${TOKEN_FILE} \\"
echo "    --namespace=cloudflared"
echo
echo "============================================================"
echo
echo "IMPORTANT:"
echo "The API token was NOT written to disk."
echo "The tunnel token is stored with permissions 600."
echo