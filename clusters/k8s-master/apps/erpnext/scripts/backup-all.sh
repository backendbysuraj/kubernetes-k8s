#!/bin/bash
set -euo pipefail
NAMESPACE="erpnext"
CRONJOB="erpnext-prod-backup"
JOBNAME="manual-all-$(date +%s)"
echo "Triggering backup for ALL sites"
kubectl create job "$JOBNAME" --from=cronjob/"$CRONJOB" -n "$NAMESPACE"
echo "Job created: $JOBNAME"
echo "Watch:  kubectl get pods -n $NAMESPACE -l job-name=$JOBNAME -w"
