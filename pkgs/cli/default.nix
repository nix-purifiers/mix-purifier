# SPDX-License-Identifier: MIT
#
# The `mix-purifier` command.
#
# - `mix-purifier mix <args>` builds the project's deps/ directory from its
#   locks with Nix (nix/lib/deps.nix), copies each dependency that changed
#   into ./deps, and runs Mix with Hex offline. The Mix tasks that change
#   mix.lock (`deps.get`, `deps.update`, `deps.unlock`) run online instead.
#   With MIX_PURIFIER_DEPS naming a dependency directory Nix already built,
#   such as buildMixProject's `deps`, it copies that one instead.
# - `mix-purifier lock` writes mix-purifier.lock.json: the hash of each git
#   dependency's checkout, and the URL of each Hex repository other than
#   hexpm. It downloads the tarballs of those repositories with Hex and adds
#   them to the Nix store, so a build needs no Hex credentials.
# - `mix-purifier publish` builds the package tarball and documentation with
#   Nix (buildMixProject's `hexPackage` and `docs`) and publishes them with
#   Hex (nix/hex-publish.exs). MIX_PURIFIER_HEX_PACKAGE and
#   MIX_PURIFIER_DOCS name ones Nix already built.
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
  importNixpkgs = "import ${path} { config = { }; overlays = [ ]; }";
  # Builds the dependency directory of a project, given its lock files by
  # absolute path.
  depsExpression = builtins.toFile "mix-purifier-deps.nix" ''
    { lockFile, purifierLockFile }:
    let
      pkgs = ${importNixpkgs};
    in
    pkgs.callPackage ${nixLib}/lib/deps.nix { } {
      lockFile = /. + lockFile;
      purifierLockFile = if purifierLockFile == "" then null else /. + purifierLockFile;
    }
  '';
  # Reads a mix.lock, as JSON.
  mixLockExpression = builtins.toFile "mix-purifier-mix-lock.nix" ''
    { lockFile }:
    import ${nixLib}/lib/mix-lock.nix { lib = import ${path}/lib; } (/. + lockFile)
  '';
  # Builds a project's package tarball and documentation, from its directory
  # without what Mix and Nix leave in it.
  publishExpression = builtins.toFile "mix-purifier-publish.nix" ''
    { projectDir }:
    let
      pkgs = ${importNixpkgs};
      project = pkgs.callPackage ${nixLib}/lib/build-mix-project.nix { } {
        src = builtins.path {
          name = "source";
          path = /. + projectDir;
          filter =
            file: type:
            !(builtins.elem (baseNameOf file) [ "_build" "deps" ".git" "doc" ])
            && builtins.match "result.*" (baseNameOf file) == null;
        };
      };
    in
    {
      inherit (project) hexPackage docs;
    }
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
      mix-purifier mix <args>    Run Mix offline, with deps/ built from the locks
      mix-purifier lock          Write mix-purifier.lock.json
      mix-purifier publish [--organization ORG] [--replace] [--yes] [--no-docs]
                                 Publish the package and docs that Nix builds

    Run them in the directory of mix.exs. The Mix tasks deps.get, deps.update
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

    # Builds deps/ from the locks, unless MIX_PURIFIER_DEPS names one, and
    # copies each dependency whose marker (.hex for a Hex package, .git/HEAD
    # for a git dependency) changed into ./deps.
    sync_deps() {
      local purifier_lock="" built key src marker
      mkdir -p deps
      if [ -n "''${MIX_PURIFIER_DEPS-}" ]; then
        built=$MIX_PURIFIER_DEPS
      else
        if [ -f mix-purifier.lock.json ]; then
          purifier_lock="$PWD/mix-purifier.lock.json"
        fi
        mkdir -p _build/mix-purifier
        built=$(nix-build --no-build-output --out-link _build/mix-purifier/deps \
          --argstr lockFile "$PWD/mix.lock" \
          --argstr purifierLockFile "$purifier_lock" \
          ${depsExpression})
      fi
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

    # Locks the git dependencies: prints {"<key>": {url, rev, submodules,
    # hash}} for the entries given as JSON.
    lock_git() {
      local locked='{}' key url rev submodules hash
      while IFS=$'\t' read -r key url rev submodules; do
        echo "mix-purifier: locking $key at $rev" >&2
        local fetch_submodules=()
        if [ "$submodules" = true ]; then fetch_submodules=(--fetch-submodules); fi
        hash=$(nix-prefetch-git --quiet --url "$url" --rev "$rev" "''${fetch_submodules[@]}" | jq -r .hash)
        locked=$(jq --arg key "$key" --arg url "$url" --arg rev "$rev" \
          --argjson submodules "$submodules" --arg hash "$hash" \
          '.[$key] = {url: $url, rev: $rev, submodules: $submodules, hash: $hash}' <<<"$locked")
      done < <(jq -r '.[] | [.key, .url, .rev, (.submodules | tostring)] | @tsv' <<<"$1")
      printf '%s\n' "$locked"
    }

    # Resolves the Hex repositories other than hexpm and adds their locked
    # tarballs to the Nix store: prints {"<repo>": "<url>"}.
    lock_hex_repos() {
      local work entries resolved tarball
      work=$(mktemp -d)
      entries="$work/entries.json"
      printf '%s\n' "$1" > "$entries"
      mkdir "$work/tarballs"
      resolved=$(elixir ${nixLib}/hex-lock.exs "$entries" "$work/tarballs")
      while IFS= read -r tarball; do
        echo "mix-purifier: adding $(basename "$tarball") to the Nix store" >&2
        nix-store --add-fixed sha256 "$tarball" > /dev/null
      done < <(jq -r '.tarballs[]' <<<"$resolved")
      rm -rf "$work"
      jq '.hexRepos' <<<"$resolved"
    }

    lock() {
      require_lock
      local entries git_entries repo_entries git_locked='{}' hex_repos='{}'
      entries=$(nix-instantiate --eval --strict --json \
        --argstr lockFile "$PWD/mix.lock" ${mixLockExpression})
      git_entries=$(jq '.git' <<<"$entries")
      repo_entries=$(jq '[.hex[] | select(.repo != "hexpm")]' <<<"$entries")
      if [ "$(jq length <<<"$git_entries")" != 0 ]; then
        git_locked=$(lock_git "$git_entries")
      fi
      if [ "$(jq length <<<"$repo_entries")" != 0 ]; then
        hex_repos=$(lock_hex_repos "$repo_entries")
      fi
      if [ "$git_locked" = '{}' ] && [ "$hex_repos" = '{}' ]; then
        rm -f mix-purifier.lock.json
        echo "mix-purifier: mix.lock has no git dependency and uses only hexpm, so the project needs no mix-purifier.lock.json."
        return
      fi
      jq --sort-keys -n --argjson git "$git_locked" --argjson hexRepos "$hex_repos" \
        '{version: 1} + (if $git == {} then {} else {git: $git} end) + (if $hexRepos == {} then {} else {hexRepos: $hexRepos} end)' \
        > mix-purifier.lock.json
      echo "mix-purifier: wrote mix-purifier.lock.json"
    }

    publish() {
      local docs=true publish_args=() built
      while [ $# -gt 0 ]; do
        case "$1" in
          --no-docs) docs=false ;;
          --organization) publish_args+=(--organization "$2"); shift ;;
          --replace | --yes) publish_args+=("$1") ;;
          *) usage >&2; exit 2 ;;
        esac
        shift
      done
      require_lock
      mkdir -p _build/mix-purifier
      if [ -n "''${MIX_PURIFIER_HEX_PACKAGE-}" ]; then
        built=$MIX_PURIFIER_HEX_PACKAGE
      else
        built=$(nix-build --no-build-output --out-link _build/mix-purifier/hex-package \
          --argstr projectDir "$PWD" -A hexPackage ${publishExpression})
      fi
      if [ "$docs" = true ] && [ -n "''${MIX_PURIFIER_DOCS-}" ]; then
        publish_args+=(--docs "$MIX_PURIFIER_DOCS")
      elif [ "$docs" = true ]; then
        publish_args+=(--docs "$(nix-build --no-build-output --out-link _build/mix-purifier/docs \
          --argstr projectDir "$PWD" -A docs ${publishExpression})")
      fi
      elixir ${nixLib}/hex-publish.exs "$built/package.tar" "''${publish_args[@]}"
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
      publish)
        shift
        publish "$@"
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
