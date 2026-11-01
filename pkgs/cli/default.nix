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
# - `mix-purifier lock` runs `mix deps.get`, which brings mix.lock up to date
#   with mix.exs, then writes mix-purifier.lock.json: the project's outputs
#   as Mix reports them (nix/lock-info.exs), the hash of each git
#   dependency's checkout, and the URL of each Hex repository other than
#   hexpm. It downloads the tarballs of those repositories with Hex and adds
#   them to the Nix store, so a build needs no Hex credentials. With
#   `--offline` it runs no `mix deps.get` and reuses the recorded hashes and
#   URLs, so it rewrites the outputs without the network.
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
  # The shared purifier library, from this flake's own `lib`, which holds
  # the library of each project the flake lists. The flake and its locked
  # inputs are in the store already, because Nix evaluated them to build
  # this command.
  purifierLib = "(builtins.getFlake \"path:${../..}\").lib.purifier";
  # Builds the dependency directory of a project, given its lock files by
  # absolute path.
  depsExpression = builtins.toFile "mix-purifier-deps.nix" ''
    { lockFile, purifierLockFile }:
    let
      pkgs = ${importNixpkgs};
    in
    pkgs.callPackage ${nixLib}/lib/deps.nix { fetchEntry = ${purifierLib}.fetchEntry { inherit pkgs; }; } {
      lockFile = /. + lockFile;
      purifierLockFile = if purifierLockFile == "" then null else /. + purifierLockFile;
    }
  '';
  # Builds a project's package tarball and documentation, from its directory
  # without what Mix and Nix leave in it.
  publishExpression = builtins.toFile "mix-purifier-publish.nix" ''
    { projectDir }:
    let
      pkgs = ${importNixpkgs};
      project = pkgs.callPackage ${nixLib}/lib/build-mix-project.nix { purifier = ${purifierLib}; } {
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
      mix-purifier lock [--offline]
                                 Resolve mix.lock and write mix-purifier.lock.json
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
        echo "mix-purifier: there is no mix.lock in $PWD. Run \`mix-purifier lock\` first." >&2
        exit 1
      fi
    }

    # Warns about each mix.exs that changed since mix-purifier.lock.json
    # recorded it, which a Nix build of the project refuses.
    warn_stale_lock() {
      local file hash
      [ -f mix-purifier.lock.json ] || return 0
      while IFS=$'\t' read -r file hash; do
        if [ ! -f "$file" ] || [ "$(sha256sum "$file" | cut -d ' ' -f 1)" != "$hash" ]; then
          echo "mix-purifier: $file changed since mix-purifier.lock.json was written. Run \`mix-purifier lock\` before a Nix build." >&2
        fi
      done < <(jq -r '.outputs.definitionFiles // {} | to_entries[] | [.key, .value] | @tsv' mix-purifier.lock.json)
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

    # The offline lock run: prints what the current mix-purifier.lock.json
    # records in SECTION (git or hexRepos) for the mix.lock entries given as
    # JSON. It fails, naming the online lock run, when the lock does not
    # record one of them as mix.lock has it.
    reuse_locked() {
      local section=$1 entries=$2 previous='{}' wanted missing
      if [ -f mix-purifier.lock.json ]; then
        previous=$(jq ".$section // {}" mix-purifier.lock.json)
      fi
      if [ "$section" = git ]; then
        wanted=$(jq 'map({key: .key, value: {url, rev, submodules}}) | from_entries' <<<"$entries")
        missing=$(jq -r --argjson previous "$previous" \
          'to_entries[] | .value as $wanted | select((($previous[.key] // {}) | {url, rev, submodules}) != $wanted) | .key' <<<"$wanted")
      else
        wanted=$(jq '[.[].repo] | unique | map({key: ., value: null}) | from_entries' <<<"$entries")
        missing=$(jq -r --argjson previous "$previous" 'keys[] | select($previous[.] == null)' <<<"$wanted")
      fi
      if [ -n "$missing" ]; then
        echo "mix-purifier: mix-purifier.lock.json does not record $(tr '\n' ' ' <<<"$missing")as mix.lock has it, and --offline cannot look it up. Run \`mix-purifier lock\` online." >&2
        exit 1
      fi
      jq --argjson previous "$previous" 'with_entries(.value = $previous[.key])' <<<"$wanted"
    }

    lock() {
      local offline=false info outputs git_entries repo_entries git_locked='{}' hex_repos='{}'
      case "''${1-}" in
        --offline) offline=true ;;
        "") ;;
        *) usage >&2; exit 2 ;;
      esac
      if [ "$offline" = false ]; then
        # Mix resolves what mix.exs asks for, online, and leaves mix.lock
        # untouched when it already covers mix.exs.
        echo "mix-purifier: resolving mix.lock with \`mix deps.get\`" >&2
        mix deps.get
      fi
      require_lock
      # The builds use MIX_ENV=prod, so the outputs are those of prod.
      info=$(MIX_ENV=prod elixir ${nixLib}/lock-info.exs)
      outputs=$(jq '.outputs' <<<"$info")
      git_entries=$(jq '.git' <<<"$info")
      repo_entries=$(jq '.hexRepoPackages' <<<"$info")
      if [ "$(jq length <<<"$git_entries")" != 0 ]; then
        if [ "$offline" = true ]; then
          git_locked=$(reuse_locked git "$git_entries")
        else
          git_locked=$(lock_git "$git_entries")
        fi
      fi
      if [ "$(jq length <<<"$repo_entries")" != 0 ]; then
        if [ "$offline" = true ]; then
          hex_repos=$(reuse_locked hexRepos "$repo_entries")
        else
          hex_repos=$(lock_hex_repos "$repo_entries")
        fi
      fi
      jq --sort-keys -n --argjson outputs "$outputs" \
        --argjson git "$git_locked" --argjson hexRepos "$hex_repos" \
        '{version: 1, outputs: $outputs} + (if $git == {} then {} else {git: $git} end) + (if $hexRepos == {} then {} else {hexRepos: $hexRepos} end)' \
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
          mix "$@"
          echo "mix-purifier: run \`mix-purifier lock\` to record the change in mix-purifier.lock.json." >&2
          return
          ;;
      esac
      require_lock
      warn_stale_lock
      sync_deps
      HEX_OFFLINE=1 exec mix "$@"
    }

    case "''${1-}" in
      mix)
        shift
        run_mix "$@"
        ;;
      lock)
        shift
        lock "$@"
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
