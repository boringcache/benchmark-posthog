#!/usr/bin/env bash

# Prepare a Docker-reachable cache-mount publish helper image for local or
# unreleased CLI dogfood runs. Released CLI versions normally use the matching
# ghcr.io/boringcache/base:bookworm-v* image, so this helper is a no-op when
# BORINGCACHE_DOCKER_CACHE_MOUNT_PUBLISH_HELPER_IMAGE is already set.

prepare_boringcache_cache_mount_publish_helper_image() {
  local cli_binary="${1:-/usr/local/bin/boringcache}"
  if [[ -n "${BORINGCACHE_DOCKER_CACHE_MOUNT_PUBLISH_HELPER_IMAGE:-}" ]]; then
    return 0
  fi
  if [[ ! -x "$cli_binary" ]]; then
    echo "Missing executable boringcache binary for cache-mount publish helper: $cli_binary" >&2
    return 1
  fi

  BORINGCACHE_CACHE_MOUNT_HELPER_REGISTRY_NAME="${BORINGCACHE_CACHE_MOUNT_HELPER_REGISTRY_NAME:-boringcache-cache-mount-helper-$$}"
  docker rm -f "$BORINGCACHE_CACHE_MOUNT_HELPER_REGISTRY_NAME" >/dev/null 2>&1 || true
  docker run -d \
    --name "$BORINGCACHE_CACHE_MOUNT_HELPER_REGISTRY_NAME" \
    -p 127.0.0.1::5000 \
    public.ecr.aws/docker/library/registry:2 >/dev/null

  local registry_endpoint=""
  for _ in $(seq 1 30); do
    registry_endpoint="$(docker port "$BORINGCACHE_CACHE_MOUNT_HELPER_REGISTRY_NAME" 5000/tcp 2>/dev/null | head -n1 || true)"
    if [[ -n "$registry_endpoint" ]] && curl -fsS "http://${registry_endpoint}/v2/" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if [[ -z "$registry_endpoint" ]]; then
    echo "Failed to start local Docker cache-mount publish helper registry" >&2
    return 1
  fi

  local cli_version helper_image
  cli_version="$("$cli_binary" --version | sed 's/.* //; s/[^A-Za-z0-9_.-]/-/g')"
  helper_image="${registry_endpoint}/boringcache/cache-mount-publish-helper:${cli_version}-$$"
  BORINGCACHE_CACHE_MOUNT_HELPER_CONTEXT_DIR="$(mktemp -d)"
  install -m 0755 "$cli_binary" "$BORINGCACHE_CACHE_MOUNT_HELPER_CONTEXT_DIR/boringcache"
  cat >"$BORINGCACHE_CACHE_MOUNT_HELPER_CONTEXT_DIR/Dockerfile" <<'DOCKERFILE'
FROM public.ecr.aws/docker/library/debian:bookworm-slim
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y ca-certificates && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
COPY boringcache /usr/local/bin/boringcache
RUN chmod +x /usr/local/bin/boringcache && boringcache --version
DOCKERFILE

  docker build -t "$helper_image" "$BORINGCACHE_CACHE_MOUNT_HELPER_CONTEXT_DIR"
  docker push "$helper_image" >/dev/null
  export BORINGCACHE_DOCKER_CACHE_MOUNT_PUBLISH_HELPER_IMAGE="$helper_image"
  echo "Using local Docker cache-mount publish helper image $helper_image"
}

cleanup_boringcache_cache_mount_publish_helper_image() {
  if [[ -n "${BORINGCACHE_CACHE_MOUNT_HELPER_REGISTRY_NAME:-}" ]]; then
    docker rm -f "$BORINGCACHE_CACHE_MOUNT_HELPER_REGISTRY_NAME" >/dev/null 2>&1 || true
  fi
  if [[ -n "${BORINGCACHE_CACHE_MOUNT_HELPER_CONTEXT_DIR:-}" ]]; then
    rm -rf "$BORINGCACHE_CACHE_MOUNT_HELPER_CONTEXT_DIR"
  fi
}
