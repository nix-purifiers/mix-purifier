#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The online lock run on every fixture: runs `mix-purifier lock`, with the
# network, in each fixture of the checkout, and fails if any mix.lock or
# mix-purifier.lock.json changed. The flake's checks rerun the offline lock
# run in the sandbox; this covers what only the online one does, which is
# `mix deps.get`, hashing git checkouts and resolving Hex repositories.
#
# Run it from the repository root, with git and Nix on the PATH. It uses a
# Hex home of its own, with the fixture repository `mirror` registered.
set -euo pipefail

root=$PWD
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HEX_HOME=$work/hex MIX_HOME=$work/mix
# The hexrepo fixture's `mirror` serves repo.hex.pm under another name, so
# its registry records name hexpm.
export HEX_NO_VERIFY_REPO_ORIGIN=1

cli=$(nix build --no-link --print-out-paths .#cli)/bin/mix-purifier
elixir=$(nix build --no-link --print-out-paths 'nixpkgs#beamPackages.elixir')/bin
hex=$(nix build --no-link --print-out-paths 'nixpkgs#beamPackages.hex')/lib/erlang/lib

ERL_LIBS=$hex "$elixir/elixir" -e \
  'File.write!(System.fetch_env!("HEX_HOME") <> "/hexpm.pem", Hex.Repo.default_hexpm_repo().public_key)'
(cd tests/fixtures/hexrepo && ERL_LIBS=$hex PATH=$elixir:$PATH \
  mix hex.repo add mirror https://repo.hex.pm --public-key "$HEX_HOME/hexpm.pem")

for fixture in basic git umbrella pathdep/app hexrepo publish; do
  echo "relocking $fixture" >&2
  (cd "tests/fixtures/$fixture" && "$cli" lock)
done

find tests/fixtures -type d \( -name deps -o -name _build \) -prune -exec rm -rf {} +
cd "$root"
git diff --exit-code -- tests/fixtures
echo "every fixture relocked to the committed lockfiles" >&2
