#!/bin/bash
set -euo pipefail

SITE="${1:?Usage: backup-site.sh <site-name>}"
NAMESPACE="erpnext"
CRONJOB="erpnext-prod-backup"
JOBNAME="manual-site-$(date +%s)"

echo "Triggering backup for site: $SITE"

kubectl create job "$JOBNAME" \
  --from=cronjob/"$CRONJOB" \
  -n "$NAMESPACE" \
  --dry-run=client -o json \
| jq --arg site "$SITE" '
    .spec.template.spec.initContainers[0].env = [{"name":"SITE_NAME","value":$site}] |
    .spec.template.spec.containers[0].env = [{"name":"SITE_NAME","value":$site}]
  ' \
| kubectl apply -f -

echo "Job created: $JOBNAME"
echo "Watch it with:"
echo "  kubectl get pods -n $NAMESPACE -l job-name=$JOBNAME -w"
echo "Logs:"
echo "  kubectl logs -l job-name=$JOBNAME -c backup-sites -n $NAMESPACE"
echo "  kubectl logs -l job-name=$JOBNAME -c upload-to-s3 -n $NAMESPACE"
