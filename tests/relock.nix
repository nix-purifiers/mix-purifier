# SPDX-License-Identifier: MIT
#
# The lock run, in the sandbox: copies a project, with its committed
# mix-purifier.lock.json if it has one, and runs `mix-purifier lock
# --offline` on it. The offline lock run asks Mix for the outputs again and
# reuses the recorded git hashes and repository URLs, so the result is the
# lockfile the online lock run writes for an unchanged mix.lock.
#
# `relocked` is the lockfile it writes. `reproduces` checks that it is the
# committed lockfile, byte for byte. `root` is the directory of mix.exs
# inside `src`, as buildMixProject takes it.
{ pkgs, cli }:
let
  relocked =
    {
      name,
      src,
      root ? ".",
      lockFile,
    }:
    pkgs.runCommand "mix-purifier-relock-${name}"
      {
        nativeBuildInputs = [ pkgs.beamPackages.elixir ];
        LANG = "C.UTF-8";
      }
      ''
        export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
        cp -r ${src} source
        chmod -R u+w source
        cd source/${root}
        ${pkgs.lib.optionalString (lockFile != null) "install -m 644 ${lockFile} mix-purifier.lock.json"}
        ${cli}/bin/mix-purifier lock --offline
        cp mix-purifier.lock.json $out
      '';
in
{
  inherit relocked;

  reproduces =
    args:
    let
      result = relocked args;
    in
    pkgs.runCommand "mix-purifier-test-${args.name}-relock" { } ''
      if ! cmp ${result} ${args.lockFile}; then
        diff ${result} ${args.lockFile} >&2 || true
        echo "relocking ${args.name} changed its mix-purifier.lock.json" >&2
        exit 1
      fi
      touch $out
    '';
}
