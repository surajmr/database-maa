#!/usr/bin/env bash
set -Eeuo pipefail
kubectl delete namespace ai-fsdr-lab --ignore-not-found=true
