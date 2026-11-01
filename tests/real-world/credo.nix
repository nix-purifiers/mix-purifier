# SPDX-License-Identifier: MIT
#
# credo, the Elixir static analysis tool, as a real-world project: release
# v1.7.19, pinned by commit and hash. Its repository has no
# mix-purifier.lock.json, so the one beside this file stands in for it;
# `relock` checks that the lock run writes exactly that file.
#
# credo has an escript, a Hex package, and dependencies for prod (bunt,
# file_system, jason), dev (ex_doc and its parsers) and test (inch_ex,
# mix_test_watch). Its test suite runs offline through `mix-purifier mix
# test`, the way a developer runs it. Its docs are not checked: at this
# commit its mix.exs gives ExDoc `assets: "guides/assets"`, which the
# ex_doc 0.40.3 its own mix.lock pins rejects, so `mix docs` fails there
# with or without mix-purifier.
{
  pkgs,
  buildMixProject,
  cli,
  relock,
}:
let
  src = builtins.fetchTarball {
    url = "https://github.com/rrrene/credo/archive/d4a88d49619ee354a61667841adf1d2fa0292127.tar.gz";
    sha256 = "14kzwk5gyyvqcnx9317hjciyfnpp3j020j3yy7613icc84q4sdhs";
  };
  lockFile = ./credo/mix-purifier.lock.json;
  credo = buildMixProject {
    inherit src;
    purifierLockFile = lockFile;
  };
in
{
  inherit src credo;

  checks = {
    credo-relock = relock.reproduces {
      name = "credo";
      inherit src lockFile;
    };

    # The escript runs, and checks credo's own source.
    credo-escript = pkgs.runCommand "mix-purifier-test-credo-escript" { } ''
      test "$(${credo.escripts.credo}/bin/credo --version)" = 1.7.19
      cp -r ${src}/lib lib
      ${credo.escripts.credo}/bin/credo --mute-exit-status lib > report
      grep -q 'Analysis took' report
      touch $out
    '';

    credo-release = credo;
    credo-app = pkgs.runCommand "mix-purifier-test-credo-app" { } ''
      test -f ${credo.apps.credo}/ebin/credo.app
      touch $out
    '';
    credo-hex-package = pkgs.runCommand "mix-purifier-test-credo-hex-package" { } ''
      tar -xOf ${credo.hexPackage}/package.tar metadata.config > metadata.config
      grep -q '<<"1.7.19">>' metadata.config
      touch $out
    '';

    # The everyday loop, offline: compile and run the test suite through
    # `mix-purifier mix`, with the test environment's dependencies.
    credo-test =
      pkgs.runCommand "mix-purifier-test-credo-test"
        {
          nativeBuildInputs = [
            pkgs.beamPackages.elixir
            pkgs.git
          ];
          MIX_PURIFIER_DEPS = credo.deps;
          LANG = "C.UTF-8";
        }
        ''
          export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
          cp -r ${src} project
          chmod -R u+w project
          cp ${lockFile} project/mix-purifier.lock.json
          cd project
          ${cli}/bin/mix-purifier mix test --max-failures 1
          touch $out
        '';
  };
}
