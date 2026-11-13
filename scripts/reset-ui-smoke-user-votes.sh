#!/bin/zsh

# Resets the UI smoke-test user's recent Yea/Nay votes to Abstain in the production
# UserFeedback table. Dry run by default: it lists what would change and writes nothing.
#
#   AWS_PROFILE=<profile> ALLOWED_ACCOUNT_ID=<account> ./scripts/reset-ui-smoke-user-votes.sh             # preview
#   AWS_PROFILE=<profile> ALLOWED_ACCOUNT_ID=<account> DRY_RUN=0 ./scripts/reset-ui-smoke-user-votes.sh   # apply
#
# AWS_PROFILE and ALLOWED_ACCOUNT_ID (the 12-digit AWS account that holds the table) are both required, with no
# default: the script refuses to run unless AWS_PROFILE resolves to exactly that account.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env.ui-tests"
AMPLIFY_CONFIG="$ROOT_DIR/Billboard/Billboard/amplifyconfiguration.json"
FEEDBACK_TABLE="${FEEDBACK_TABLE:-UserFeedback}"
ALLOWED_ACCOUNT_ID="${ALLOWED_ACCOUNT_ID:-}"

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required."
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
fi

if [ -z "${BB_UI_TEST_EMAIL:-}" ]; then
  echo "Missing BB_UI_TEST_EMAIL."
  echo "Set it in $ENV_FILE before resetting smoke-test votes."
  exit 1
fi

if [ -z "$ALLOWED_ACCOUNT_ID" ]; then
  echo "Missing ALLOWED_ACCOUNT_ID."
  echo "Set it to the 12-digit AWS account that holds the $FEEDBACK_TABLE table; the script refuses any other account."
  exit 1
fi

if [[ ! "$ALLOWED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ALLOWED_ACCOUNT_ID must be a 12-digit AWS account ID."
  exit 1
fi

if [ -z "${AWS_PROFILE:-}" ]; then
  echo "Missing AWS_PROFILE."
  echo "Name the profile explicitly; this script targets the $FEEDBACK_TABLE table in account $ALLOWED_ACCOUNT_ID."
  exit 1
fi

export DAYS_BACK="${DAYS_BACK:-365}"
DRY_RUN="${DRY_RUN:-1}"

if [ "$DRY_RUN" != "0" ] && [ "$DRY_RUN" != "1" ]; then
  echo "DRY_RUN must be 1 (preview, the default) or 0 (write). Got: $DRY_RUN"
  exit 1
fi

# --profile on every call: an explicit profile takes precedence over any exported
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, so the account checked below is the one written to.
aws_cli() {
  aws --profile "$AWS_PROFILE" "$@"
}

CALLER_ACCOUNT_ID="$(aws_cli sts get-caller-identity --query Account --output text)"
if [ "$CALLER_ACCOUNT_ID" != "$ALLOWED_ACCOUNT_ID" ]; then
  echo "AWS_PROFILE=$AWS_PROFILE resolves to account $CALLER_ACCOUNT_ID, expected $ALLOWED_ACCOUNT_ID. Nothing was read or changed."
  exit 1
fi
echo "Using AWS_PROFILE=$AWS_PROFILE (account $CALLER_ACCOUNT_ID)."

USER_POOL_REGION="$(jq -r '.auth.plugins.awsCognitoAuthPlugin.CognitoUserPool.Default.Region' "$AMPLIFY_CONFIG")"
USER_POOL_ID="$(jq -r '.auth.plugins.awsCognitoAuthPlugin.CognitoUserPool.Default.PoolId' "$AMPLIFY_CONFIG")"

if [ -z "$USER_POOL_REGION" ] || [ "$USER_POOL_REGION" = "null" ] || [ -z "$USER_POOL_ID" ] || [ "$USER_POOL_ID" = "null" ]; then
  echo "Could not read Cognito config from $AMPLIFY_CONFIG."
  exit 1
fi

UPDATED_AFTER="$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
import os
days = int(os.environ.get("DAYS_BACK", "365"))
dt = datetime.now(timezone.utc) - timedelta(days=days)
print(dt.isoformat(timespec="milliseconds").replace("+00:00", "Z"))
PY
)"

USER_JSON="$(aws_cli cognito-idp admin-get-user \
  --region "$USER_POOL_REGION" \
  --user-pool-id "$USER_POOL_ID" \
  --username "$BB_UI_TEST_EMAIL")"

USER_ID="$(printf '%s' "$USER_JSON" | jq -r '
  .UserAttributes[]
  | select(.Name == "sub")
  | .Value
')"

if [ -z "$USER_ID" ] || [ "$USER_ID" = "null" ]; then
  echo "Could not resolve Cognito sub for $BB_UI_TEST_EMAIL."
  exit 1
fi

QUERY_JSON="$(aws_cli dynamodb query \
  --region "$USER_POOL_REGION" \
  --table-name "$FEEDBACK_TABLE" \
  --key-condition-expression "userId = :u" \
  --filter-expression "votedAt >= :cutoff AND (feedback = :yea OR feedback = :nay)" \
  --expression-attribute-values "{
    \":u\":{\"S\":\"$USER_ID\"},
    \":cutoff\":{\"S\":\"$UPDATED_AFTER\"},
    \":yea\":{\"S\":\"Yea\"},
    \":nay\":{\"S\":\"Nay\"}
  }")"

VOTED_IDS_FILE="$(mktemp)"
trap 'rm -f "$VOTED_IDS_FILE"' EXIT

printf '%s' "$QUERY_JSON" | jq -r '
  .Items[]
  | .billId.S
  | select(type == "string" and length > 0)
' | sort -u > "$VOTED_IDS_FILE"

TOTAL_VOTED="$(wc -l < "$VOTED_IDS_FILE" | tr -d ' ')"
echo "Resolved smoke-test userId: $USER_ID"
echo "Found $TOTAL_VOTED counted vote(s) in $FEEDBACK_TABLE for the last $DAYS_BACK days."

if [ "$TOTAL_VOTED" -eq 0 ]; then
  echo "No counted votes needed resetting."
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run: would set feedback = Abstain on these $TOTAL_VOTED item(s) (userId $USER_ID):"
  sed 's/^/  /' "$VOTED_IDS_FILE"
  echo "No votes were changed. Re-run with DRY_RUN=0 to apply."
  exit 0
fi

RESET_COUNT=0
while IFS= read -r bill_id; do
  [ -n "$bill_id" ] || continue
  aws_cli dynamodb update-item \
    --region "$USER_POOL_REGION" \
    --table-name "$FEEDBACK_TABLE" \
    --key "{\"userId\":{\"S\":\"$USER_ID\"},\"billId\":{\"S\":\"$bill_id\"}}" \
    --update-expression "SET feedback = :abstain" \
    --expression-attribute-values '{":abstain":{"S":"Abstain"}}' >/dev/null
  RESET_COUNT=$((RESET_COUNT + 1))
done < "$VOTED_IDS_FILE"

echo "Reset $RESET_COUNT vote(s) to Abstain for $BB_UI_TEST_EMAIL."
