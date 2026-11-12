# SPDX-License-Identifier: MIT
#
# The `mix-purifier` command, with the commands of the purifier contract.
# Each takes `--lockfile <path>` (or MIX_PURIFIER_LOCKFILE) for a
# mix-purifier.lock.json kept outside the project, and `--tool-lockfile
# <path>` (or MIX_PURIFIER_TOOL_LOCKFILE) for a mix.lock kept outside it.
# The defaults are the files beside mix.exs.
#
# - `mix-purifier lock` runs `mix deps.get`, which brings mix.lock up to
#   date with mix.exs, then writes mix-purifier.lock.json: the project's
#   outputs as Mix reports them (pkgs/cli/lock-info.exs), the hash of each git
#   dependency's checkout, the URL of each Hex repository other than hexpm,
#   and the hash of its own content. It downloads the tarballs of those
#   repositories with Hex and adds them to the Nix store, so a build needs
#   no Hex credentials. With `--offline` it runs no `mix deps.get` and
#   reuses the recorded hashes and URLs.
# - `mix-purifier update [<package>...]` updates the named dependencies, or
#   every one, with Mix's own `mix deps.update`, then runs the lock run on
#   the result. `lock` keeps mix.lock as Mix resolved it, adding only what
#   mix.exs asks for and mix.lock lacks.
# - `mix-purifier prefetch` builds the project's deps/ directory from the
#   locks (pkgs/build-mix-project/deps.nix), copies each dependency that changed into
#   ./deps, and keeps it and the toolchain (pkgs/toolchain) alive with
#   garbage-collector roots under _build/mix-purifier. It also starts the
#   toolchain's language server once, so it fetches its own files. After
#   it, the toolchain's `mix` and `elixir-ls` work with no network.
#   MIX_PURIFIER_DEPS names a dependency directory Nix already built, such
#   as buildMixProject's `deps`, to copy instead.
# - `mix-purifier publish` builds the package tarball and documentation with
#   Nix (buildMixProject's `release` and `packages.docs`) and publishes them
#   with Hex (pkgs/cli/hex-publish.exs). MIX_PURIFIER_RELEASE and
#   MIX_PURIFIER_DOCS name ones Nix already built.
#
# Each command checks the lockfile first, and fails with a message that
# names `mix-purifier lock` when it is missing, not valid JSON, of another
# version, edited by hand, or older than a mix.exs it records.
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
  toolchain,
  version,
}:
let
  nixLib = ./.;
  importNixpkgs = "import ${path} { config = { }; overlays = [ ]; }";
  # This flake's own `lib`, which holds the library of each project the
  # flake lists, the purifier library among them. The flake and its locked
  # inputs are in the store already, because Nix evaluated them to build
  # this command.
  flakeLib = "(builtins.getFlake \"path:${../..}\").lib";
  # Builds the dependency directory of a project, given its directory and
  # its lockfile by absolute path, from the entries of its lock for this
  # system.
  depsExpression = builtins.toFile "mix-purifier-deps.nix" ''
    { projectDir, lockFile }:
    let
      pkgs = ${importNixpkgs};
      lib = ${flakeLib};
      lock = lib.mix-purifier.readLock {
        src = /. + projectDir;
        lockFile = /. + lockFile;
      };
    in
    pkgs.callPackage ${../..}/pkgs/build-mix-project/deps.nix { fetchEntry = lib.purifier.fetchEntry { inherit pkgs; }; } (
      lib.purifier.entriesFor pkgs.stdenv.hostPlatform.system lock
    )
  '';
  # Builds a project's release and documentation, from its directory
  # without what Mix and Nix leave in it.
  publishExpression = builtins.toFile "mix-purifier-publish.nix" ''
    { projectDir, lockFile }:
    let
      pkgs = import ${path} {
        config = { };
        overlays = [ (builtins.getFlake "path:${../..}").overlays.default ];
      };
      project = pkgs.mix-purifier.buildMixProject {
        lockFile = /. + lockFile;
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
      release =
        if project.release == null then
          throw "mix-purifier: ''${projectDir}/mix.exs has no package metadata, so there is no Hex package to publish."
        else
          project.release;
      docs = project.packages.docs;
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
      mix-purifier lock [--offline]
          Resolve mix.lock and write mix-purifier.lock.json
      mix-purifier update [PACKAGE...]
          Update the dependencies with mix deps.update, then lock
      mix-purifier prefetch [--no-editor]
          Make the everyday loop and the editor work with no network
      mix-purifier publish [--organization ORG] [--replace] [--yes] [--no-docs]
          Publish the package and docs that Nix builds

    Every command takes --lockfile PATH (or MIX_PURIFIER_LOCKFILE) for a
    mix-purifier.lock.json kept outside the project, and --tool-lockfile PATH
    (or MIX_PURIFIER_TOOL_LOCKFILE) for a mix.lock kept outside it.

    Run them in the directory of mix.exs. After `mix-purifier prefetch`, run
    Mix as _build/mix-purifier/toolchain/bin/mix, or put that directory first
    on PATH.
    EOF
    }

    export ERL_LIBS=${beamPackages.hex}/lib/erlang/lib''${ERL_LIBS:+:$ERL_LIBS}
    export MIX_REBAR3=${beamPackages.rebar3}/bin/rebar3

    lockfile=$(realpath -m "''${MIX_PURIFIER_LOCKFILE:-$PWD/mix-purifier.lock.json}")
    tool_lockfile=''${MIX_PURIFIER_TOOL_LOCKFILE:+$(realpath -m "$MIX_PURIFIER_TOOL_LOCKFILE")}

    fail() {
      echo "mix-purifier: $1" >&2
      exit 1
    }

    # A mix.lock kept outside the project. While a command runs, the file
    # named by --tool-lockfile or MIX_PURIFIER_TOOL_LOCKFILE is the project's
    # mix.lock, so Mix and the Nix expressions read it there. When the
    # command ends, the project's own mix.lock is back as it was, or absent
    # if the project had none. A command that writes mix.lock, `lock` and
    # `update`, saves the result to the outside path first, and starts from
    # the project's copy when the outside file does not exist yet.
    saved_tree_lock=""
    tree_lock_existed=false

    use_tool_lockfile() {
      [ -n "$tool_lockfile" ] || return 0
      if [ "$tool_lockfile" = "$PWD/mix.lock" ]; then
        tool_lockfile=""
        return 0
      fi
      saved_tree_lock=$(mktemp)
      if [ -e mix.lock ]; then
        cp -p mix.lock "$saved_tree_lock"
        tree_lock_existed=true
      fi
      trap restore_tree_lock EXIT
      # install replaces the file, so a read-only copy, such as one from the
      # Nix store, becomes a file that Mix can write.
      if [ -e "$tool_lockfile" ]; then
        install -m 644 "$tool_lockfile" mix.lock
      fi
    }

    restore_tree_lock() {
      [ -n "$saved_tree_lock" ] || return 0
      if [ "$tree_lock_existed" = true ]; then
        install -m 644 "$saved_tree_lock" mix.lock
        chmod --reference="$saved_tree_lock" mix.lock
      else
        rm -f mix.lock
      fi
      rm -f "$saved_tree_lock"
      saved_tree_lock=""
    }

    save_tool_lockfile() {
      [ -n "$tool_lockfile" ] || return 0
      mkdir -p "$(dirname "$tool_lockfile")"
      install -m 644 mix.lock "$tool_lockfile"
      echo "mix-purifier: wrote $tool_lockfile" >&2
    }

    require_mix_lock() {
      [ -f mix.lock ] || fail "there is no mix.lock in $PWD. Run \`mix-purifier lock\`."
    }

    # The hash a lockfile records of its own content: the SHA-256 of the
    # rest of the file as compact JSON with sorted keys, the form Nix's
    # builtins.toJSON writes.
    content_hash() {
      echo "sha256:$(jq -cjS 'del(.hash)' | sha256sum | cut -d ' ' -f 1)"
    }

    # Fails, naming `mix-purifier lock`, unless the lockfile is one that
    # command wrote for the project as it is.
    check_lock() {
      local fix="Run \`mix-purifier lock\` to rewrite it." file hash
      [ -f "$lockfile" ] || fail "there is no $lockfile. Run \`mix-purifier lock\`."
      jq empty "$lockfile" 2>/dev/null || fail "$lockfile is not valid JSON. $fix"
      [ "$(jq '.version' "$lockfile")" = 1 ] \
        || fail "$lockfile is not of format version 1, which this mix-purifier reads. $fix"
      [ "$(jq -r '.hash // empty' "$lockfile")" = "$(content_hash < "$lockfile")" ] \
        || fail "$lockfile does not match the hash of its content, so it was edited after \`mix-purifier lock\` wrote it. $fix"
      while IFS=$'\t' read -r file hash; do
        if [ ! -f "$file" ] || [ "$(sha256sum "$file" | cut -d ' ' -f 1)" != "$hash" ]; then
          fail "$file changed since $lockfile was written. Run \`mix-purifier lock\`."
        fi
      done < <(jq -r '.outputs.definitionFiles // {} | to_entries[] | [.key, .value] | @tsv' "$lockfile")
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

    # The offline lock run: prints what the current lockfile records in
    # SECTION (git or hexRepos) for the mix.lock entries given as JSON. It
    # fails, naming the online lock run, when the lockfile does not record
    # one of them as mix.lock has it.
    reuse_locked() {
      local section=$1 entries=$2 previous='{}' wanted missing
      if [ -f "$lockfile" ]; then
        previous=$(jq ".$section // {}" "$lockfile")
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
        fail "$lockfile does not record $(tr '\n' ' ' <<<"$missing")as mix.lock has it, and --offline cannot look it up. Run \`mix-purifier lock\` online."
      fi
      jq --argjson previous "$previous" 'with_entries(.value = $previous[.key])' <<<"$wanted"
    }

    lock() {
      local offline=$1 info outputs git_entries repo_entries git_locked='{}' hex_repos='{}' content hash
      if [ "$offline" = false ]; then
        # Mix resolves what mix.exs asks for, online, and leaves mix.lock
        # untouched when it already covers mix.exs.
        echo "mix-purifier: resolving mix.lock with \`mix deps.get\`" >&2
        mix deps.get
      fi
      require_mix_lock
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
      content=$(jq --sort-keys -n --argjson outputs "$outputs" \
        --argjson git "$git_locked" --argjson hexRepos "$hex_repos" \
        '{version: 1, outputs: $outputs} + (if $git == {} then {} else {git: $git} end) + (if $hexRepos == {} then {} else {hexRepos: $hexRepos} end)')
      hash=$(content_hash <<<"$content")
      jq --sort-keys --arg hash "$hash" '. + {hash: $hash}' <<<"$content" > "$lockfile"
      echo "mix-purifier: wrote $lockfile"
    }

    # Keeps TARGET alive with a garbage-collector root at LINK, or links it
    # where Nix cannot register roots, such as the sandbox.
    keep_alive() {
      local target=$1 link=$2
      if command -v nix-store > /dev/null; then
        nix-store --realise "$target" --add-root "$link" --indirect > /dev/null
      else
        ln -sfn "$target" "$link"
      fi
    }

    prefetch() {
      local editor=$1 built key src marker
      require_mix_lock
      check_lock
      mkdir -p deps _build/mix-purifier
      if [ -n "''${MIX_PURIFIER_DEPS-}" ]; then
        built=$MIX_PURIFIER_DEPS
      else
        built=$(nix-build --no-build-output --out-link _build/mix-purifier/deps \
          --argstr projectDir "$PWD" \
          --argstr lockFile "$lockfile" \
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
      keep_alive ${toolchain} _build/mix-purifier/toolchain
      if [ "$editor" = true ]; then
        # The language server fetches its own files when it first starts;
        # at the end of its input it stops again.
        echo "mix-purifier: starting the language server once, so it fetches its own files" >&2
        timeout 600 _build/mix-purifier/toolchain/bin/elixir-ls < /dev/null > /dev/null \
          || fail "the language server did not start. Run \`mix-purifier prefetch\` again with the network, or with --no-editor."
      fi
      echo "mix-purifier: the dependencies and toolchain are in place. Run Mix as _build/mix-purifier/toolchain/bin/mix, and point the editor at _build/mix-purifier/toolchain/bin/elixir-ls."
    }

    publish() {
      local docs=$1 built
      shift
      require_mix_lock
      check_lock
      mkdir -p _build/mix-purifier
      if [ -n "''${MIX_PURIFIER_RELEASE-}" ]; then
        built=$MIX_PURIFIER_RELEASE
      else
        built=$(nix-build --no-build-output --out-link _build/mix-purifier/release \
          --argstr projectDir "$PWD" --argstr lockFile "$lockfile" -A release ${publishExpression})
      fi
      local publish_args=("$@")
      if [ "$docs" = true ] && [ -n "''${MIX_PURIFIER_DOCS-}" ]; then
        publish_args+=(--docs "$MIX_PURIFIER_DOCS")
      elif [ "$docs" = true ]; then
        publish_args+=(--docs "$(nix-build --no-build-output --out-link _build/mix-purifier/docs \
          --argstr projectDir "$PWD" --argstr lockFile "$lockfile" -A docs ${publishExpression})")
      fi
      elixir ${nixLib}/hex-publish.exs "$built/package.tar" "''${publish_args[@]}"
    }

    # Updates the named dependencies, or every one, through Mix's own
    # `mix deps.update`, then writes mix-purifier.lock.json for the result.
    update() {
      if [ $# -eq 0 ]; then
        echo "mix-purifier: updating every dependency with \`mix deps.update --all\`" >&2
        mix deps.update --all
      else
        echo "mix-purifier: updating $* with \`mix deps.update\`" >&2
        mix deps.update "$@"
      fi
      lock false
    }

    command=''${1-}
    [ $# -gt 0 ] && shift
    offline=false editor=true docs=true hex_args=() packages=()
    while [ $# -gt 0 ]; do
      case "$command:$1" in
        *:--lockfile) lockfile=$(realpath -m "$2"); shift ;;
        *:--tool-lockfile) tool_lockfile=$(realpath -m "$2"); shift ;;
        update:-*) usage >&2; exit 2 ;;
        update:*) packages+=("$1") ;;
        lock:--offline) offline=true ;;
        prefetch:--no-editor) editor=false ;;
        publish:--no-docs) docs=false ;;
        publish:--organization) hex_args+=(--organization "$2"); shift ;;
        publish:--replace | publish:--yes) hex_args+=("$1") ;;
        *) usage >&2; exit 2 ;;
      esac
      shift
    done

    case "$command" in
      lock | update | prefetch | publish) use_tool_lockfile ;;
    esac

    case "$command" in
      lock)
        lock "$offline"
        save_tool_lockfile
        ;;
      update)
        update "''${packages[@]}"
        save_tool_lockfile
        ;;
      prefetch) prefetch "$editor" ;;
      publish) publish "$docs" "''${hex_args[@]}" ;;
      -h | --help | help | "") usage ;;
      *) usage >&2; exit 2 ;;
    esac
  '';
}
