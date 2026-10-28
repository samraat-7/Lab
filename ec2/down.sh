#!/usr/bin/env bash
# Runs `terraform destroy` in every Terraform sub-folder next to this script.
#
# Usage:
#   ./down.sh               # destroy all sub-folders (asks for confirmation)
#   ./down.sh -y            # destroy all sub-folders without asking
#   ./down.sh ec2-01 ec2-05   # destroy only the named sub-folders
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

YES=0
ARGS=()
for a in "$@"; do
  if [ "$a" = "-y" ] || [ "$a" = "--yes" ]; then YES=1; else ARGS+=("$a"); fi
done

if [ "${#ARGS[@]}" -gt 0 ]; then
  DIRS=("${ARGS[@]}")
else
  DIRS=()
  for d in */; do
    d="${d%/}"
    ls "$d"/*.tf >/dev/null 2>&1 && DIRS+=("$d")
  done
fi

echo "This will DESTROY all resources in: ${DIRS[*]}"
if [ "$YES" -ne 1 ]; then
  read -r -p "Type 'yes' to continue: " answer
  [ "$answer" = "yes" ] || { echo "Aborted."; exit 1; }
fi

ok=(); failed=()
# Destroy in reverse order of creation.
for (( i=${#DIRS[@]}-1; i>=0; i-- )); do
  d="${DIRS[$i]}"
  echo
  echo "==================== DOWN: $d ===================="
  if (cd "$ROOT/$d" && terraform init -input=false && terraform destroy -input=false -auto-approve); then
    ok+=("$d")
  else
    failed+=("$d")
  fi
done

echo
echo "==================== SUMMARY ===================="
echo "Destroyed (${#ok[@]}):  ${ok[*]:-none}"
echo "Failed    (${#failed[@]}):  ${failed[*]:-none}"
[ "${#failed[@]}" -eq 0 ]
