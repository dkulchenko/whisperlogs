#!/usr/bin/env bash
# Reports the High and Critical vulnerabilities in WhisperLogs that can be
# fixed now, and exits non-zero when there are any. A finding counts when:
#   - it is in mix.lock and a fixed version exists;
#   - it is in Erlang/OTP and OTP's advisories name a patched release newer
#     than the Dockerfile's;
#   - it is an OS package in the newest released image and a newer Debian base
#     exists than the one that release was built on.
# npm packages and GitHub Actions are left to Dependabot.
#
# Needs grype, crane, gh, and jq. Run from the repository root with full history.
set -euo pipefail

summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
actionable=0
failed=0

# fixable SOURCE JQ_CONDITION prints "id<TAB>package<TAB>installed<TAB>fixed in"
# for each fixable High or Critical match that satisfies JQ_CONDITION.
fixable() {
  grype "$1" --only-fixed -o json -q > "$work/scan.json" || return 1
  jq -r "
    .matches[]
    | select(.vulnerability.severity == \"High\" or .vulnerability.severity == \"Critical\")
    | select($2)
    | [.vulnerability.id, .artifact.name, .artifact.version, (.vulnerability.fix.versions | join(\", \"))]
    | @tsv" "$work/scan.json" | sort -u
}

# report WHERE FIX ROWS adds a section for ROWS, if any, and marks the run as
# having something to act on.
report() {
  [ -n "$3" ] || return 0
  actionable=1
  {
    echo "### ${1}"
    echo
    echo "Fix: ${2}"
    echo
    echo "| Vulnerability | Package | Installed | Fixed in |"
    echo "|---|---|---|---|"
    while IFS=$'\t' read -r id package installed fixed; do
      echo "| ${id} | ${package} | ${installed} | ${fixed} |"
    done <<< "$3"
    echo
  } >> "$summary"
}

scan_failed() {
  failed=1
  echo "- Could not check ${1}." >> "$summary"
}

version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

echo "## Vulnerabilities to act on" >> "$summary"
echo >> "$summary"

if rows=$(fixable file:mix.lock true); then
  report "mix.lock" "update the dependency and publish a release" "$rows"
else
  scan_failed "mix.lock"
fi

# The newest release's image, against the Debian base it was built on: a
# rebuild on a newer base also reinstalls the packages the Dockerfile adds.
if release=$(gh release view --json tagName --jq .tagName) &&
  runner=$(git show "${release}:Dockerfile" | sed -n 's/^ARG RUNNER_IMAGE="\(.*\)"$/\1/p') &&
  [ -n "$runner" ]; then
  base=${runner%@*}
  pinned=${runner#*@}
  base_tag=${base##*:}
  pattern=$(sed -E 's/[.]/\\./g; s/[0-9]+/[0-9]+/g' <<< "$base_tag")
  if newest=$(crane ls "${base%:*}" | grep -E "^${pattern}\$" | sort -V | tail -1) &&
    digest=$(crane digest "${base%:*}:${newest}"); then
    if [ "$digest" != "$pinned" ]; then
      if rows=$(fixable "registry:ghcr.io/dkulchenko/whisperlogs:${release}" '.artifact.type == "deb"'); then
        report "Docker image ${release}: OS packages" \
          "move RUNNER_IMAGE to ${base%:*}:${newest}, if main hasn't already, and publish a release" "$rows"
      else
        scan_failed "the ${release} image"
      fi
    fi
  else
    scan_failed "newer Debian bases than ${base}"
  fi
else
  scan_failed "the newest release's image"
fi

# Erlang/OTP. Advisories name a patched release for each supported major
# version and the first affected version as ">= VERSION". With no patch for our
# major, we are affected only if the fix went to a newer major: a newer major
# than every patched one already contains the fix.
otp_version=$(sed -n 's/^ARG BUILDER_IMAGE=".*-erlang-\([0-9.]*\)-debian-.*$/\1/p' Dockerfile)
otp_major=${otp_version%%.*}
if [ -n "$otp_version" ] && advisories=$(gh api --paginate 'repos/erlang/otp/security-advisories?per_page=100' --jq '
  .[]
  | select(.severity == "high" or .severity == "critical")
  | .ghsa_id as $id
  | .vulnerabilities[]
  | select(.package.name == "OTP")
  | [$id, .vulnerable_version_range, .patched_versions]
  | @tsv'); then
  rows=""
  while IFS=$'\t' read -r id range patched; do
    [ -n "$id" ] || continue
    if [[ $range =~ ^\>=\ *([0-9.]+)$ ]] && version_lt "$otp_version" "${BASH_REMATCH[1]}"; then
      continue
    fi
    patch=""
    newer_major=""
    for fixed_release in ${patched//,/ }; do
      if [ "${fixed_release%%.*}" = "$otp_major" ]; then
        patch=$fixed_release
      elif [ "${fixed_release%%.*}" -gt "$otp_major" ]; then
        newer_major=$fixed_release
      fi
    done
    if { [ -n "$patch" ] && version_lt "$otp_version" "$patch"; } || { [ -z "$patch" ] && [ -n "$newer_major" ]; }; then
      rows+="${id}"$'\t'"Erlang/OTP"$'\t'"${otp_version}"$'\t'"${patch:-$newer_major}"$'\n'
    fi
  done <<< "$advisories"
  report "Erlang/OTP" "raise the builder image's OTP version and publish a release" "${rows%$'\n'}"
else
  scan_failed "Erlang/OTP advisories"
fi

if [ "$actionable" = 0 ] && [ "$failed" = 0 ]; then
  echo "Nothing to act on." >> "$summary"
fi
exit $((actionable || failed))
