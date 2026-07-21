#!/usr/bin/env bash
# Cleanly remove all Spike S1 containers, the network, and (optionally) images.
# Idempotent: safe to run repeatedly, never errors if things are already gone.
set -u
cd "$(dirname "$0")"

echo "==> Stopping & removing containers + network + volumes (compose down)"
docker compose down --remove-orphans --volumes 2>/dev/null || true

# Belt-and-suspenders: kill any stragglers by explicit name.
NAMES=(conn-ubuntu22 conn-ubuntu24 conn-debian12 conn-centos7 conn-alpine conn-bastion conn-internal)
for n in "${NAMES[@]}"; do
  if docker ps -aq -f "name=^${n}$" | grep -q .; then
    echo "==> Removing stray container ${n}"
    docker rm -f "$n" >/dev/null 2>&1 || true
  fi
done

# Remove the user-defined network if it survived.
docker network rm conn-s1-net >/dev/null 2>&1 || true

if [[ "${1:-}" == "--images" ]]; then
  echo "==> Removing built images (conn-s1/*)"
  docker rmi -f conn-s1/ubuntu22 conn-s1/ubuntu24 conn-s1/debian12 \
                conn-s1/centos7 conn-s1/alpine conn-s1/bastion \
                conn-s1/internal >/dev/null 2>&1 || true
fi

echo "==> Done. Remaining conn-* containers:"
docker ps -a --filter "name=conn-" --format '  {{.Names}} ({{.Status}})' || true
echo "(none above => fully torn down)"
