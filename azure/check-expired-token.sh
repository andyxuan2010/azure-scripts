#!/bin/bash

# Usage: ./check_expired_secrets.sh [days] [-o csv]
EXPIRY_THRESHOLD_DAYS=${1:-3}
OUTPUT_FORMAT=$2
NOW=$(date -u +%s)
CUTOFF=$(date -u -d "+$EXPIRY_THRESHOLD_DAYS days" +%s)

CSV_FILE="expired_secrets.csv"

if [[ "$OUTPUT_FORMAT" == "-o" && "$3" == "csv" ]]; then
    TO_CSV=true
    echo "App Name,App ID,Status,Secret End Date" > $CSV_FILE
else
    TO_CSV=false
    echo "Checking Azure AD apps for secrets expired or expiring in the next $EXPIRY_THRESHOLD_DAYS day(s)..."
    echo "-------------------------------------------------------------"
fi

# Get all App Registrations
app_ids=$(az ad app list --query "[].{appId:appId, name:displayName}" -o json)

for row in $(echo "${app_ids}" | jq -r '.[] | @base64'); do
    _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
    }

    app_id=$(_jq '.appId')
    app_name=$(_jq '.name')

    # Use correct field: endDateTime
    secrets=$(az ad app credential list --id "$app_id" --query "[].{endDateTime:endDateTime}" -o json)

    for sec in $(echo "${secrets}" | jq -r '.[] | @base64'); do
        end_date=$(echo "${sec}" | base64 --decode | jq -r '.endDateTime')
