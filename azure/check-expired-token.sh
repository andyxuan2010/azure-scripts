#!/bin/bash

# Usage: ./check_expired_secrets.sh [days] [-o csv]
DAYS_THRESHOLD=${1:-3}
OUTPUT_FORMAT=$2

NOW=$(date -u +%s)

if [[ $DAYS_THRESHOLD -ge 0 ]]; then
    MODE="future"
    CUTOFF=$(date -u -d "+$DAYS_THRESHOLD days" +%s)
else
    MODE="past"
    CUTOFF=$(date -u -d "$DAYS_THRESHOLD days" +%s)  # Will be earlier than NOW
fi

CSV_FILE="expired_secrets.csv"

if [[ "$OUTPUT_FORMAT" == "-o" && "$3" == "csv" ]]; then
    TO_CSV=true
    echo "App Name,App ID,Status,Secret End Date" > $CSV_FILE
else
    TO_CSV=false
    echo "Checking Azure AD apps for secrets ${MODE} (within $DAYS_THRESHOLD day(s))..."
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

    secrets=$(az ad app credential list --id "$app_id" --query "[].{endDateTime:endDateTime}" -o json)

    for sec in $(echo "${secrets}" | jq -r '.[] | @base64'); do
        end_date=$(echo "${sec}" | base64 --decode | jq -r '.endDateTime')
        end_sec=$(date -u -d "$end_date" +%s 2>/dev/null)

        if [ -z "$end_sec" ]; then
            [ "$TO_CSV" = true ] && echo "\"$app_name\",\"$app_id\",\"Invalid date format\",\"$end_date\"" >> $CSV_FILE || echo "❓ $app_name ($app_id): Invalid secret end date format: $end_date"
            continue
        fi

        if [[ "$MODE" == "future" ]]; then
            if [ "$end_sec" -ge "$NOW" ] && [ "$end_sec" -lt "$CUTOFF" ]; then
                [ "$TO_CSV" = true ] && echo "\"$app_name\",\"$app_id\",\"Expiring Soon\",\"$end_date\"" >> $CSV_FILE || echo "⚠️  $app_name ($app_id): Secret expiring soon on $end_date"
            fi
        else
            if [ "$end_sec" -lt "$NOW" ] && [ "$end_sec" -ge "$CUTOFF" ]; then
                [ "$TO_CSV" = true ] && echo "\"$app_name\",\"$app_id\",\"Recently Expired\",\"$end_date\"" >> $CSV_FILE || echo "❌ $app_name ($app_id): Secret expired on $end_date"
            fi
        fi
    done
done

if [ "$TO_CSV" = true ]; then
    echo "✅ Output written to $CSV_FILE"
else
    echo "Done."
fi
