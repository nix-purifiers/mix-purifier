# SPDX-License-Identifier: MIT
#
# The `mix-purifier` command.
#
# - `mix-purifier mix <args>` builds the project's deps/ directory from its
#   locks with Nix (nix/lib/deps.nix), copies each dependency that changed
#   into ./deps, and runs Mix with Hex offline. The Mix tasks that change
#   mix.lock (`deps.get`, `deps.update`, `deps.unlock`) run online instead.
# - `mix-purifier lock` writes mix-purifier.lock.json, which holds the hash
#   of each git dependency's checkout.
#
# The Erlang, Elixir, Hex and rebar3 the command runs are those of
# `beamPackages`, so `.override { beamPackages = beam27Packages; }` runs
# another set. Nix itself comes from the PATH.
{
  path,
  writeShellApplication,
  beamPackages,
  coreutils,
  git,
  jq,
  nix-prefetch-git,
  version,
}:
let
  nixLib = ../../nix;
  # Builds the dependency directory of a project, given its lock files by
  # absolute path.
  depsExpression = builtins.toFile "mix-purifier-deps.nix" ''
    { lockFile, purifierLockFile }:
    let
      pkgs = import ${path} { config = { }; overlays = [ ]; };
    in
    pkgs.callPackage ${nixLib}/lib/deps.nix { } {
      lockFile = /. + lockFile;
      purifierLockFile = if purifierLockFile == "" then null else /. + purifierLockFile;
    }
  '';
  # Lists the git dependencies in a mix.lock as JSON.
  gitEntriesExpression = builtins.toFile "mix-purifier-git-entries.nix" ''
    { lockFile }:
    (import ${nixLib}/lib/mix-lock.nix { lib = import ${path}/lib; } (/. + lockFile)).git
  '';
in
writeShellApplication {
  name = "mix-purifier";
  runtimeInputs = [
    beamPackages.elixir
    beamPackages.erlang
    coreutils
    git
    jq
    nix-prefetch-git
  ];
  derivationArgs.passthru = { inherit version; };
  text = ''
    usage() {
      cat <<'EOF'
    mix-purifier ${version}

    Usage:
      mix-purifier mix <args>   Run Mix offline, with deps/ built from the locks
      mix-purifier lock         Lock the git dependencies in mix-purifier.lock.json

    Run both in the directory of mix.exs. The Mix tasks deps.get, deps.update
    and deps.unlock change mix.lock, so `mix-purifier mix` runs them online.
    EOF
    }

    export ERL_LIBS=${beamPackages.hex}/lib/erlang/lib''${ERL_LIBS:+:$ERL_LIBS}
    export MIX_REBAR3=${beamPackages.rebar3}/bin/rebar3

    require_lock() {
      if [ ! -f mix.lock ]; then
        echo "mix-purifier: there is no mix.lock in $PWD. Run \`mix-purifier mix deps.get\` first." >&2
        exit 1
      fi
    }

    # Builds deps/ from the locks and copies each dependency whose marker
    # (Hex's .hex, or .git/HEAD for a git dependency) changed into ./deps.
    sync_deps() {
      local purifier_lock="" built key src marker
      if [ -f mix-purifier.lock.json ]; then
        purifier_lock="$PWD/mix-purifier.lock.json"
      fi
      mkdir -p _build/mix-purifier deps
      built=$(nix-build --no-build-output --out-link _build/mix-purifier/deps \
        --argstr lockFile "$PWD/mix.lock" \
        --argstr purifierLockFile "$purifier_lock" \
        ${depsExpression})
      for src in "$built"/*; do
        [ -e "$src" ] || continue
        key=$(basename "$src")
        if [ -f "$src/.hex" ]; then marker=.hex; else marker=.git/HEAD; fi
        if cmp -s "$src/$marker" "deps/$key/$marker"; then
          continue
        fi
        rm -rf "deps/$key"
        cp -r "$src" "deps/$key"
        chmod -R u+w "deps/$key"
      done
    }

    lock() {
      require_lock
      local entries
      entries=$(nix-instantiate --eval --strict --json \
        --argstr lockFile "$PWD/mix.lock" ${gitEntriesExpression})
      if [ "$(jq length <<<"$entries")" = 0 ]; then
        rm -f mix-purifier.lock.json
        echo "mix-purifier: mix.lock has no git dependencies, so the project needs no mix-purifier.lock.json."
        return
      fi
      local locked='{}' key url rev submodules hash
      while IFS=$'\t' read -r key url rev submodules; do
        echo "mix-purifier: locking $key at $rev" >&2
        local fetch_submodules=()
        if [ "$submodules" = true ]; then fetch_submodules=(--fetch-submodules); fi
        hash=$(nix-prefetch-git --quiet --url "$url" --rev "$rev" "''${fetch_submodules[@]}" | jq -r .hash)
        locked=$(jq --arg key "$key" --arg url "$url" --arg rev "$rev" \
          --argjson submodules "$submodules" --arg hash "$hash" \
          '.[$key] = {url: $url, rev: $rev, submodules: $submodules, hash: $hash}' <<<"$locked")
      done < <(jq -r '.[] | [.key, .url, .rev, (.submodules | tostring)] | @tsv' <<<"$entries")
      jq --sort-keys '{version: 1, git: .}' <<<"$locked" > mix-purifier.lock.json
      echo "mix-purifier: wrote mix-purifier.lock.json"
    }

    run_mix() {
      case "''${1-}" in
        deps.get | deps.update | deps.unlock)
          exec mix "$@"
          ;;
      esac
      require_lock
      sync_deps
      HEX_OFFLINE=1 exec mix "$@"
    }

    case "''${1-}" in
      mix)
        shift
        run_mix "$@"
        ;;
      lock)
        lock
        ;;
      -h | --help | help | "")
        usage
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac
  '';
}
