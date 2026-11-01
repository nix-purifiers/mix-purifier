#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update check: in a copy of the update fixture, whose
# mix.lock pins jason 1.4.0 though mix.exs allows any 1.x from 1.4, runs
# `mix-purifier update jason` with the network. It then checks that
# mix.lock moved jason forward, that the command accepts the new
# mix-purifier.lock.json, and that readLock reports no problems with the
# two locks together.
#
# Run it from the repository root, with Nix on the PATH.
set -euo pipefail

root=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HEX_HOME=$work/hex MIX_HOME=$work/mix
mkdir -p "$HEX_HOME" "$MIX_HOME"

cli=$(nix build --no-link --print-out-paths .#cli)/bin/mix-purifier
cp -r tests/fixtures/update "$work/project"
chmod -R u+w "$work/project"
cd "$work/project"

"$cli" update jason
if grep -q '"jason": {:hex, :jason, "1.4.0"' mix.lock; then
  echo "conformance-update: mix.lock still pins jason 1.4.0" >&2
  exit 1
fi
"$cli" prefetch --no-editor

problems=$(nix eval --impure --json --expr "
  let
    flake = builtins.getFlake \"path:$root\";
  in
  (flake.lib.mix-purifier.readLock { src = $work/project; }).problems
")
if [ "$problems" != "[]" ]; then
  echo "conformance-update: readLock reports problems after the update: $problems" >&2
  exit 1
fi
echo "conformance-update: jason updated to $(grep -o '"jason": {:hex, :jason, "[^"]*"' mix.lock | grep -o '[0-9.]*"$' | tr -d '"'), and both locks are current" >&2
