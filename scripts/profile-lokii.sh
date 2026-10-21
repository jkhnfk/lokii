#!/bin/bash
set -euo pipefail
pid=""
samples=10
interval=1
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pid) pid="$2" ;;
        --samples) samples="$2" ;;
        --interval) interval="$2" ;;
        --out) out="$2" ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift 2
done
[[ "$pid" =~ ^[0-9]+$ && "$samples" =~ ^[0-9]+$ && -n "$out" ]] || exit 2
for ((sample=0; sample<samples; sample++)); do
    summary=$(vmmap -summary "$pid")
    footprint=$(printf '%s\n' "$summary" | awk '/^Physical footprint:/ {print $3; exit}')
    [[ -n "$footprint" ]] || { echo "No physical footprint available" >&2; exit 1; }
    printf '%s\t%s\n' "$sample" "$footprint" >> "$out"
    sleep "$interval"
done
