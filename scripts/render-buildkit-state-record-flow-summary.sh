#!/usr/bin/env bash
set -euo pipefail

result="${1:?usage: render-buildkit-state-record-flow-summary.sh RESULT_JSON}"

jq -r '
  def display_scalar:
    if type == "string" or type == "number" or type == "boolean" then
      tostring
    else
      "n/a"
    end;
  def display_description:
    if type == "string" and length > 0 then . else "<invalid>" end;
  def markdown_cell:
    tostring | gsub("[\\r\\n]"; " ") | gsub("\\|"; " / ");
  .phases[]
  | (try .state.state_record_flow catch {}) as $candidate
  | (if ($candidate | type) == "object" then $candidate else {} end) as $flow
  | [
      (.phase | display_scalar),
      (if .checks.state_record_flow_valid == true then "yes" else "no" end),
      ([$flow.total_records, $flow.eligible_records, $flow.created_during_build]
        | map(display_scalar)
        | join(" / ")),
      ([$flow.local_source_records, $flow.local_sources_created_during_build]
        | map(display_scalar)
        | join(" / ")),
      (($flow.local_source_groups
        | if type == "array" then . else [] end)
        | map(
            if type == "object" then
              ((.description | display_description)
                + ": " + (.total | display_scalar)
                + "/" + (.created_during_build | display_scalar))
            else
              "<invalid group>"
            end
          )
        | join("; ")
        | markdown_cell),
      (($flow.created_local_sources
        | if type == "array" then . else [] end)
        | map(
            if type == "object" then
              (.description | display_description)
            else
              "<invalid record>"
            end
          )
        | join("; ")
        | markdown_cell)
    ]
  | "| " + join(" | ") + " |"
' "$result"
