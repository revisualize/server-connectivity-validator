#!/usr/bin/env bash
# Path:     test/run_all_tests.sh
# Project:  server-connectivity-validator
# Revision: 1
# Updated:  2026-09-26
# Purpose:  The single test entry point for this repository. CI runs exactly
#           this command, and so can you, from any directory:
#
#               bash test/run_all_tests.sh;
#
#           Exits 0 only when every suite below passed. Each suite reports
#           how many tests it executed, and a suite that executed none fails
#           the run, here and in CI alike. When TESTS_EXECUTED_FILE is set, as
#           CI sets it, each suite also appends "<label><TAB><count>" to that
#           file. Scratch output goes to one temporary directory, removed on
#           exit.
#
# Suites:
#           bats test/, counted with bats --count before it runs.
set -euo pipefail;

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)";
cd "${project_root}";
work_directory="$(mktemp -d "${TMPDIR:-/tmp}/revisualized_tests.XXXXXX")";
trap 'rm -rf -- "${work_directory}"' EXIT;

fail() {
  echo "FAIL: ${1}" >&2;
  exit 1;
};

# Refuses a count of zero or a count that is not a number. A suite that ran
# nothing has not passed.
record_tests_executed() {
  local label="${1}";
  local count="${2}";
  if ! [[ "${count}" =~ ^[0-9]+$ ]] || [ "${count}" -eq 0 ]; then
    fail "suite '${label}' reported '${count}' tests executed";
  fi;
  echo "  executed: ${label}: ${count}";
  if [ -n "${TESTS_EXECUTED_FILE:-}" ]; then
    printf '%s\t%s\n' "${label}" "${count}" >> "${TESTS_EXECUTED_FILE}";
  fi;
};

run_bats_suite() {
  local test_count;
  command -v bats > /dev/null 2>&1 || fail "bats is not installed; this repository's suite is written for bats";
  echo "== bats test/ ($(bats --version))";
  test_count="$(bats --count test/)";
  bats test/;
  record_tests_executed "bats test/" "${test_count}";
};

run_bats_suite;

echo "All suites passed.";
