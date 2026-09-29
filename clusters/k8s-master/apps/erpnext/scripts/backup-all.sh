#!/bin/bash
set -euo pipefail

NAMESPACE="erpnext"
CRONJOB="erpnext-prod-backup"
JOBNAME="manual-all-$(date +%s)"

echo "Triggering backup for ALL sites"

kubectl create job "$JOBNAME" --from=cronjob/"$CRONJOB" -n "$NAMESPACE"

echo "Job created: $JOBNAME"
echo "Watch it with:"
echo "  kubectl get pods -n $NAMESPACE -l job-name=$JOBNAME -w"
echo "Logs:"
echo "  kubectl logs -l job-name=$JOBNAME -c backup-sites -n $NAMESPACE"
echo "  kubectl logs -l job-name=$JOBNAME -c upload-to-s3 -n $NAMESPACE"
