# SPDX-License-Identifier: MIT
#
# The toolchain `mix-purifier prefetch` keeps alive in a project, for the
# everyday loop and the editor with no network:
#
# - `mix` runs Mix with Hex offline, Hex on the code path and rebar3 for
#   Erlang dependencies. When Mix fails, it names `mix-purifier lock`, which
#   brings mix.lock and mix-purifier.lock.json up to date when Mix needs a
#   dependency they do not have.
# - `elixir`, `iex`, `erl` and `rebar3` as they come.
# - `elixir-ls`, the language server, with Hex on its code path.
{
  symlinkJoin,
  writeShellScriptBin,
  beamPackages,
  elixir-ls,
}:
let
  environment = ''
    export ERL_LIBS=${beamPackages.hex}/lib/erlang/lib''${ERL_LIBS:+:$ERL_LIBS}
    export MIX_REBAR3=${beamPackages.rebar3}/bin/rebar3
  '';
  mix = writeShellScriptBin "mix" ''
    ${environment}
    dir="$PWD"
    while [ ! -e "$dir/mix-purifier.lock.json" ] && [ "$dir" != / ]; do
      dir=$(dirname "$dir")
    done
    lock="''${MIX_PURIFIER_LOCKFILE:-$dir/mix-purifier.lock.json}"
    if [ ! -e "$lock" ]; then
      echo "mix-purifier: warning: no mix-purifier.lock.json found; running mix impurely. Run \`mix-purifier lock\` to use Nix-resolved dependencies." >&2
      exec ${beamPackages.elixir}/bin/mix "$@"
    fi
    export HEX_OFFLINE=1
    status=0
    ${beamPackages.elixir}/bin/mix "$@" || status=$?
    if [ "$status" != 0 ]; then
      echo "mix-purifier: if Mix needs a dependency that mix.lock or mix-purifier.lock.json does not have, run \`mix-purifier lock\`." >&2
    fi
    exit "$status"
  '';
  languageServer = writeShellScriptBin "elixir-ls" ''
    ${environment}
    exec ${elixir-ls}/bin/elixir-ls "$@"
  '';
in
# The wrappers come first, so their `mix` and `elixir-ls` win.
symlinkJoin {
  name = "mix-purifier-toolchain";
  paths = [
    mix
    languageServer
    beamPackages.elixir
    beamPackages.erlang
    beamPackages.rebar3
  ];
}
