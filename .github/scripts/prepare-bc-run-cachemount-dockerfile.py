from pathlib import Path


def lines(*values):
    return "\n".join(values)


def replace_once(text, old, new):
    if old not in text:
        raise SystemExit(f"pattern not found:\n{old}")
    return text.replace(old, new, 1)


dockerfile = Path("upstream/Dockerfile")
text = dockerfile.read_text()

text = replace_once(
    text,
    "# ---------------------------------------------------------\n#\nFROM node:24.13.0-bookworm-slim AS frontend-build",
    lines(
        "# ---------------------------------------------------------",
        "#",
        "ARG BC_RUN_PREFIX=posthog-bc-run-cachemount-20260522a",
        "",
        "FROM ghcr.io/boringcache/base:bookworm AS boringcache-cli",
        "",
        "FROM node:24.13.0-bookworm-slim AS frontend-build",
    ),
)

text = replace_once(
    text,
    'FROM node:24.13.0-bookworm-slim AS frontend-build\nWORKDIR /code\nSHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]',
    lines(
        "FROM node:24.13.0-bookworm-slim AS frontend-build",
        "WORKDIR /code",
        'SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]',
        "ARG BC_RUN_PREFIX",
        "COPY --from=boringcache-cli /usr/local/bin/boringcache /usr/local/bin/boringcache",
    ),
)

text = replace_once(
    text,
    lines(
        "RUN --mount=type=cache,id=pnpm,target=/tmp/pnpm-store-v24 \\",
        "    corepack enable && pnpm --version && \\",
        "    CI=1 pnpm --filter=@posthog/frontend... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24",
    ),
    lines(
        "RUN --mount=type=secret,id=bc_token \\",
        "    --mount=type=cache,id=pnpm-frontend,target=/tmp/pnpm-store-v24 \\",
        '    set +e; step_start="$(date +%s)"; \\',
        "    boringcache run --no-git --force --fail-on-cache-error \\",
        "        boringcache/benchmark-posthog \\",
        '        "${BC_RUN_PREFIX}-pnpm-frontend:/tmp/pnpm-store-v24" \\',
        "        -- sh -lc 'corepack enable && pnpm --version && CI=1 pnpm --filter=@posthog/frontend... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24'; \\",
        '    step_status="$?"; step_end="$(date +%s)"; set -e; \\',
        '    echo "BC_RUN_STEP pnpm-frontend seconds=$((step_end-step_start)) status=${step_status}"; \\',
        '    exit "${step_status}"',
    ),
)

text = replace_once(
    text,
    'FROM node:24.13.0-bookworm-slim AS node-scripts-build\nWORKDIR /code\nSHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]',
    lines(
        "FROM node:24.13.0-bookworm-slim AS node-scripts-build",
        "WORKDIR /code",
        'SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]',
        "ARG BC_RUN_PREFIX",
        "COPY --from=boringcache-cli /usr/local/bin/boringcache /usr/local/bin/boringcache",
    ),
)

text = replace_once(
    text,
    lines(
        "RUN --mount=type=cache,id=pnpm,target=/tmp/pnpm-store-v24 \\",
        "    corepack enable && \\",
        '    NODE_OPTIONS="--max-old-space-size=4096" CI=1 pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24 && \\',
        '    NODE_OPTIONS="--max-old-space-size=4096" bin/turbo --filter=@posthog/plugin-transpiler build',
    ),
    lines(
        "RUN --mount=type=secret,id=bc_token \\",
        "    --mount=type=cache,id=pnpm-plugin,target=/tmp/pnpm-store-v24 \\",
        '    set +e; step_start="$(date +%s)"; \\',
        "    boringcache run --no-git --force --fail-on-cache-error \\",
        "        boringcache/benchmark-posthog \\",
        '        "${BC_RUN_PREFIX}-pnpm-plugin:/tmp/pnpm-store-v24" \\',
        """        -- sh -lc 'corepack enable && NODE_OPTIONS="--max-old-space-size=4096" CI=1 pnpm --filter=@posthog/plugin-transpiler... install --frozen-lockfile --store-dir /tmp/pnpm-store-v24 && NODE_OPTIONS="--max-old-space-size=4096" bin/turbo --filter=@posthog/plugin-transpiler build'; \\""",
        '    step_status="$?"; step_end="$(date +%s)"; set -e; \\',
        '    echo "BC_RUN_STEP pnpm-plugin seconds=$((step_end-step_start)) status=${step_status}"; \\',
        '    exit "${step_status}"',
    ),
)

text = replace_once(
    text,
    'WORKDIR /code\nSHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]\n\n# uv settings for Docker builds',
    lines(
        "WORKDIR /code",
        'SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]',
        "ARG BC_RUN_PREFIX",
        "COPY --from=boringcache-cli /usr/local/bin/boringcache /usr/local/bin/boringcache",
        "",
        "# uv settings for Docker builds",
    ),
)

text = replace_once(
    text,
    lines(
        "RUN --mount=type=cache,id=uv-libxmlsec1.2.37-2,target=/root/.cache/uv \\",
        "    --mount=type=bind,source=uv.lock,target=uv.lock \\",
        "    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \\",
        "    --mount=type=bind,source=tools/hogli,target=tools/hogli \\",
        "    uv sync --locked --no-dev --no-install-project --no-binary-package lxml --no-binary-package xmlsec",
    ),
    lines(
        "RUN --mount=type=secret,id=bc_token \\",
        "    --mount=type=cache,id=uv-libxmlsec1.2.37-2,target=/root/.cache/uv \\",
        "    --mount=type=bind,source=uv.lock,target=uv.lock \\",
        "    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \\",
        "    --mount=type=bind,source=tools/hogli,target=tools/hogli \\",
        '    set +e; step_start="$(date +%s)"; \\',
        "    boringcache run --no-git --force --fail-on-cache-error \\",
        "        boringcache/benchmark-posthog \\",
        '        "${BC_RUN_PREFIX}-uv-libxmlsec1-2-37-2:/root/.cache/uv" \\',
        "        -- sh -lc 'uv sync --locked --no-dev --no-install-project --no-binary-package lxml --no-binary-package xmlsec'; \\",
        '    step_status="$?"; step_end="$(date +%s)"; set -e; \\',
        '    echo "BC_RUN_STEP uv-libxmlsec seconds=$((step_end-step_start)) status=${step_status}"; \\',
        '    exit "${step_status}"',
    ),
)

text = replace_once(
    text,
    "ARG UNIT_GIT_TAG=1.35.0\nARG UNIT_GIT_REF=28404105810f53c570523c3e70006ad0ca210e58",
    lines(
        "ARG UNIT_GIT_TAG=1.35.0",
        "ARG UNIT_GIT_REF=28404105810f53c570523c3e70006ad0ca210e58",
        "ARG BC_RUN_PREFIX",
        "COPY --from=boringcache-cli /usr/local/bin/boringcache /usr/local/bin/boringcache",
    ),
)

text = replace_once(
    text,
    lines(
        "RUN --mount=type=cache,id=playwright-browsers,target=/tmp/playwright-cache,sharing=locked \\",
        "    PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-cache \\",
        "    /python-runtime/bin/python -m playwright install --with-deps chromium && \\",
        "    mkdir -p /ms-playwright && \\",
        "    cp -r /tmp/playwright-cache/* /ms-playwright/ && \\",
        "    chown -R posthog:posthog /ms-playwright",
    ),
    lines(
        "RUN --mount=type=secret,id=bc_token \\",
        "    --mount=type=cache,id=playwright-browsers,target=/tmp/playwright-cache,sharing=locked \\",
        '    set +e; step_start="$(date +%s)"; \\',
        "    boringcache run --no-git --force --fail-on-cache-error \\",
        "        boringcache/benchmark-posthog \\",
        '        "${BC_RUN_PREFIX}-playwright-browsers:/tmp/playwright-cache" \\',
        "        -- sh -lc 'PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-cache /python-runtime/bin/python -m playwright install --with-deps chromium'; \\",
        '    step_status="$?"; step_end="$(date +%s)"; set -e; \\',
        '    echo "BC_RUN_STEP playwright-browsers seconds=$((step_end-step_start)) status=${step_status}"; \\',
        '    if [[ "${step_status}" -ne 0 ]]; then exit "${step_status}"; fi; \\',
        "    mkdir -p /ms-playwright && \\",
        "    cp -r /tmp/playwright-cache/* /ms-playwright/ && \\",
        "    chown -R posthog:posthog /ms-playwright",
    ),
)

Path("upstream/Dockerfile.bc-run-cachemount").write_text(text)
