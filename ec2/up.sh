#!/usr/bin/env bash
# Runs `terraform init` + `terraform apply` in every Terraform sub-folder next to this script.
#
# Usage:
#   ./up.sh                 # apply all sub-folders
#   ./up.sh ec2-01 ec2-05     # apply only the named sub-folders
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

if [ "$#" -gt 0 ]; then
  DIRS=("$@")
else
  DIRS=()
  for d in */; do
    d="${d%/}"
    ls "$d"/*.tf >/dev/null 2>&1 && DIRS+=("$d")
  done
fi

ok=(); failed=()
for d in "${DIRS[@]}"; do
  echo
  echo "==================== UP: $d ===================="
  if (cd "$ROOT/$d" && terraform init -input=false && terraform apply -input=false -auto-approve); then
    ok+=("$d")
  else
    failed+=("$d")
  fi
done

echo
echo "==================== SUMMARY ===================="
echo "Applied (${#ok[@]}):  ${ok[*]:-none}"
echo "Failed  (${#failed[@]}):  ${failed[*]:-none}"
[ "${#failed[@]}" -eq 0 ]
