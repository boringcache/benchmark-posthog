# Larger runner accounting - 2026-07-07

This records the PostHog larger-runner seed benchmark from July 7, 2026.

The primary comparison uses commit `dc26e8ddc569ef4ee02d3ff7d7711e0e2146c232`
(`Use BuildKit mountcache for PostHog canary lane`). All primary runs used the
rolling benchmark lane with fresh suffixes so cache scopes and artifacts stayed
separate.

## Runs

| Cohort | Run | Runner label | Suffix |
| --- | --- | --- | --- |
| 16c r1 | [28862923122](https://github.com/boringcache/benchmark-posthog/actions/runs/28862923122) | `ubuntu-latest-l` | `-large16c-r2-20260707` |
| 16c r2 | [28863185201](https://github.com/boringcache/benchmark-posthog/actions/runs/28863185201) | `ubuntu-latest-l` | `-large16c-r3-20260707` |
| 8c r1 | [28862923092](https://github.com/boringcache/benchmark-posthog/actions/runs/28862923092) | `ubuntu-latest-8c-amd` | `-8c-r1-20260707` |
| 8c r2 | [28862923078](https://github.com/boringcache/benchmark-posthog/actions/runs/28862923078) | `ubuntu-latest-8c-amd` | `-8c-r2-20260707` |

An earlier 16c run, [28862412330](https://github.com/boringcache/benchmark-posthog/actions/runs/28862412330),
is listed separately below because it used the previous commit
`8a760477af0c71ae188e54c80bc8815714a09b39` and the older six-lane matrix.

## Measured benchmark seconds

Measured seconds come from the uploaded benchmark JSON artifacts, not GitHub
job wall time.

| Runner | Sample | Strategy | Measured seconds | Build seconds | Setup seconds | Export seconds | Storage MiB | Cache status |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 16c | r1 | GHA | 1083 | 1075 | 8 | 825.8 | 15438.94 | unknown |
| 16c | r2 | GHA | 1148 | 1139 | 9 | 889.5 | 19792.63 | unknown |
| 16c | r1 | BC OCI | 626 | 604 | 22 | 348.2 | 7002.65 | `bootstrap_miss` |
| 16c | r2 | BC OCI | 671 | 647 | 24 | 384.9 | 7002.52 | `bootstrap_miss` |
| 16c | r1 | ECR | 651 | 636 | 15 | 385.6 | 7002.62 | `missing` |
| 16c | r2 | ECR | 642 | 627 | 15 | 383.6 | 7002.60 | `missing` |
| 16c | r1 | BC BuildKit Backend | 306 | 285 | 21 | 12.6 | 5901.47 | `bootstrap_miss` |
| 16c | r2 | BC BuildKit Backend | 308 | 284 | 24 | 12.9 | 5901.83 | `bootstrap_miss` |
| 8c | r1 | GHA | 1125 | 1110 | 15 | 834.2 | 15438.94 | unknown |
| 8c | r2 | GHA | 1148 | 1140 | 8 | 859.6 | 15438.94 | unknown |
| 8c | r1 | BC OCI | 704 | 679 | 25 | 387.0 | 7002.60 | `bootstrap_miss` |
| 8c | r2 | BC OCI | 711 | 685 | 26 | 393.5 | 7002.63 | `bootstrap_miss` |
| 8c | r1 | ECR | 722 | 708 | 14 | 433.5 | 7002.58 | `missing` |
| 8c | r2 | ECR | 736 | 720 | 16 | 442.0 | 7002.59 | `missing` |
| 8c | r1 | BC BuildKit Backend | 364 | 341 | 23 | 5.8 | 5901.81 | `bootstrap_miss` |
| 8c | r2 | BC BuildKit Backend | 341 | 319 | 22 | 7.8 | 5901.94 | `bootstrap_miss` |

## Averages

| Strategy | 16c avg seconds | 8c avg seconds | 16c speedup vs 8c |
| --- | ---: | ---: | ---: |
| GHA | 1115.5 | 1136.5 | 1.8% |
| BC OCI | 648.5 | 707.5 | 8.3% |
| ECR | 646.5 | 729.0 | 11.3% |
| BC BuildKit Backend | 307.0 | 352.5 | 12.9% |

The 16c runner is materially faster for the cache lanes, especially ECR and
the BuildKit backend. It barely moves the GHA lane in this sample.

## Cost assumptions

Pricing checked on July 7, 2026:

- GitHub Actions larger runners:
  [Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing)
  lists Linux 8-core at `$0.022/min` and Linux 16-core at `$0.042/min`.
  GitHub rounds partial job minutes up to the nearest whole minute. GitHub's
  Actions billing docs say included minutes cannot be used for larger runners.
- Depot GitHub Actions runners:
  [Depot pricing](https://depot.dev/pricing) lists GitHub Actions 8c at
  `$0.016/min` and 16c at `$0.032/min`, tracked per second with no one-minute
  minimum. Depot plan-included minutes can apply before overage; the estimates
  below use marginal overage rates only.

These estimates include runner time only. They do not include GitHub artifact
or cache storage, Depot cache storage, base subscription fees, or any product
value from retained caches.

## Runner-time accounting

GitHub estimate uses rounded billable job minutes. Depot estimate uses exact
job wall seconds from the GitHub jobs API and Depot's per-second billing.

| Runner | Sample | Job wall seconds | GitHub billable minutes | GitHub estimate | Depot estimate |
| --- | --- | ---: | ---: | ---: | ---: |
| 16c | r1 | 2868 | 49 | $2.058 | $1.530 |
| 16c | r2 | 2993 | 53 | $2.226 | $1.596 |
| 16c | average | 2930.5 | 51.0 | $2.142 | $1.563 |
| 8c | r1 | 3157 | 55 | $1.210 | $0.842 |
| 8c | r2 | 3148 | 54 | $1.188 | $0.839 |
| 8c | average | 3152.5 | 54.5 | $1.199 | $0.841 |

Depot is cheaper on the same runner sizes at marginal rates:

| Runner | GitHub avg estimate | Depot avg estimate | Depot savings |
| --- | ---: | ---: | ---: |
| 16c | $2.142 | $1.563 | 27.0% |
| 8c | $1.199 | $0.841 | 29.9% |

The 16c GitHub runner reduces elapsed benchmark time, but its rate is about
1.91x the 8c rate. In these fresh seed runs, 8c is still the cheaper GitHub
larger-runner choice. Depot's GitHub Actions runner pricing would be cheaper
than GitHub larger runners for both 8c and 16c on runner time alone.

## Previous-SHA 16c reference

Run [28862412330](https://github.com/boringcache/benchmark-posthog/actions/runs/28862412330)
used commit `8a760477af0c71ae188e54c80bc8815714a09b39` and the older six-lane
matrix, so keep it out of the same-SHA average above.

| Strategy | Measured seconds | Build seconds | Setup seconds | Export seconds | Storage MiB | Cache status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| GHA | 1095 | 1084 | 11 | 828.4 | 12802.24 | unknown |
| BC OCI | 627 | 602 | 25 | 344.5 | 7005.91 | `bootstrap_miss` |
| ECR | 689 | 665 | 24 | 418.7 | 7002.57 | `missing` |
| BC BuildKit Backend | 291 | 267 | 24 | 12.8 | 6215.20 | `bootstrap_miss` |
| BC OCI + toolcache | 610 | 603 | 7 | 345.4 | 7002.60 | `not_found` |
| BC BuildKit Backend + toolcache | 300 | 300 | 0 | 12.7 | 6215.84 | `no_reuse` |

## Recreate extraction

Download a run's artifacts:

```sh
gh run download RUN_ID --repo boringcache/benchmark-posthog --dir /tmp/posthog-benchmark-results/RUN_ID
```

Extract benchmark JSON rows:

```sh
find /tmp/posthog-benchmark-results/RUN_ID -maxdepth 4 -name '*.json' -type f -print |
  while read -r file; do
    jq -r --arg run "RUN_ID" '
      def n($x): if $x == null then "" else ($x|tostring) end;
      [$run,.benchmark,.strategy,.strategy_label,.lane,
       n(.runs.cold_seconds),n(.runs.cold_build_seconds),
       n(.runs.cold_restore_or_setup_seconds),
       n(.docker_cache.import_seconds),n(.docker_cache.export_seconds),
       n(.docker_cache.prepare_seconds),n(.docker_cache.send_seconds),
       n(.cache.storage_mib),n(.classification.cache_import_status),
       n(.classification.prior_cache_state)] | @tsv
    ' "$file"
  done
```
