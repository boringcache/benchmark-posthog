#!/usr/bin/env bash
set -euo pipefail

required_gb="${BORINGCACHE_MIN_FREE_DISK_GB:-70}"
required_kb=$((required_gb * 1024 * 1024))

available_kb() {
  df -Pk / | awk 'NR == 2 { print $4 }'
}

print_disk() {
  df -h /
  docker system df || true
}

before_kb="$(available_kb)"
if (( before_kb >= required_kb )); then
  echo "Free disk is already at least ${required_gb}GiB; skipping cleanup."
  print_disk
  exit 0
fi

echo "Free disk below ${required_gb}GiB; reclaiming hosted-runner tool caches."
print_disk

sudo rm -rf \
  /opt/az \
  /opt/ghc \
  /opt/hostedtoolcache \
  /opt/microsoft \
  /usr/lib/google-cloud-sdk \
  /usr/local/.ghcup \
  /usr/local/lib/android \
  /usr/local/share/boost \
  /usr/local/share/powershell \
  /usr/share/dotnet \
  /usr/share/miniconda \
  /usr/share/swift

sudo docker system prune --all --volumes --force

after_kb="$(available_kb)"
after_gb=$((after_kb / 1024 / 1024))
echo "Runner free disk after cleanup: ${after_gb}GiB"
print_disk

if (( after_kb < required_kb )); then
  echo "Warning: free disk is still below ${required_gb}GiB after cleanup." >&2
fi
