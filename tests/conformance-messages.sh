#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The messages of the conformance checks: evaluates buildMixProject with a
# stale, a tampered, an incomplete and a malformed mix-purifier.lock.json,
# and fails unless each evaluation fails with a message that names
# `mix-purifier lock`. The flake's conformance-* checks show that each one
# fails; a check in the sandbox cannot read the message, and the malformed
# file here is not valid JSON, which only an evaluation outside the sandbox
# reports.
#
# Run it from the repository root, with Nix and jq on the PATH.
set -euo pipefail

root=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# A lockfile with the hash of its content, as `mix-purifier lock` writes it.
rehash() {
  local content hash
  content=$(jq -S 'del(.hash)')
  hash="sha256:$(jq -cjS . <<<"$content" | sha256sum | cut -d ' ' -f 1)"
  jq -S --arg hash "$hash" '. + {hash: $hash}' <<<"$content"
}

jq '.outputs.definitionFiles["mix.exs"] = "0000"' tests/fixtures/basic/mix-purifier.lock.json | rehash > "$work/stale.json"
jq '.git.decimal.hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' tests/fixtures/git/mix-purifier.lock.json > "$work/tampered.json"
jq 'del(.git)' tests/fixtures/git/mix-purifier.lock.json | rehash > "$work/missing.json"
printf '{"version": 1, "outputs": ' > "$work/malformed.json"

expect_failure() {
  local name=$1 fixture=$2 attribute=$3 output
  if output=$(nix eval --impure --json --expr "
      let
        flake = builtins.getFlake \"path:$root\";
        pkgs = import flake.inputs.nixpkgs {
          system = builtins.currentSystem;
          overlays = [ flake.overlays.default ];
        };
        project = pkgs.buildMixProject {
          src = $root/tests/fixtures/$fixture;
          lockFile = $work/$name.json;
        };
      in
      builtins.deepSeq project.$attribute true
    " 2>&1); then
    echo "conformance-$name: the evaluation succeeded, but it should fail" >&2
    exit 1
  fi
  if ! grep -q 'mix-purifier lock' <<<"$output"; then
    echo "conformance-$name: the evaluation failed without naming \`mix-purifier lock\`:" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "conformance-$name: fails, naming \`mix-purifier lock\`" >&2
}

expect_failure stale basic outputs
expect_failure tampered git fetches
expect_failure missing git fetches
expect_failure malformed basic outputs
