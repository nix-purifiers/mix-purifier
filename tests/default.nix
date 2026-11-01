# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The flake's default package overlay, which adds buildMixProject.
  overlay,
  cli,
}:
let
  # Every fixture builds the way a consumer's package does: through
  # buildMixProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildMixProject;
  inherit (pkgs) lib;

  # Hex packages only: jason, an Elixir package, and telemetry, an Erlang
  # package that rebar3 builds. mix.exs gives the version as @version.
  basic = buildMixProject { src = ./fixtures/basic; };

  # A git dependency (decimal, locked in mix-purifier.lock.json) beside a
  # Hex package (jason).
  git = buildMixProject { src = ./fixtures/git; };

  # Runs a release's `eval` and compares what it prints. mixRelease keeps
  # the release cookie out of the store, so the release takes it from
  # RELEASE_COOKIE.
  runs =
    name: release: expression: expected:
    pkgs.runCommand "mix-purifier-test-${name}-runs" { RELEASE_COOKIE = "mix-purifier-test"; } ''
      out_text=$(${release}/bin/${release.pname} eval ${lib.escapeShellArg expression})
      if [ "$out_text" != ${lib.escapeShellArg expected} ]; then
        echo "${name} printed '$out_text'" >&2
        exit 1
      fi
      touch $out
    '';

  # Mix accepts the dependency directory as fetched and locked: in a copy
  # of the project with the directory as deps/, `mix deps.loadpaths` checks
  # every dependency against mix.lock, offline and without Hex's registry,
  # and fails if any is missing or does not match.
  depsAccepted =
    name: src: release:
    pkgs.runCommand "mix-purifier-test-${name}-deps-accepted"
      {
        nativeBuildInputs = [
          pkgs.beamPackages.elixir
          pkgs.git
        ];
        ERL_LIBS = "${pkgs.beamPackages.hex}/lib/erlang/lib";
        HEX_OFFLINE = 1;
        LANG = "C.UTF-8";
      }
      ''
        export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
        cp -r ${src} project
        chmod -R u+w project
        cp -r ${release.deps} project/deps
        chmod -R u+w project/deps
        cd project
        mix deps.loadpaths --no-compile
        touch $out
      '';

  # A lock reader fails on input it cannot trust, rather than building with
  # a dependency left out or unpinned.
  fails =
    name: value:
    let
      result = builtins.tryEval (builtins.deepSeq value value);
    in
    assert lib.assertMsg (!result.success) "${name} evaluated, but it should fail";
    pkgs.runCommand "mix-purifier-test-${name}" { } "touch $out";

  downloadsOf =
    args:
    import ../nix/lib/downloads.nix { inherit lib; } (
      {
        purifierLockFile = null;
        hexMirror = "https://repo.hex.pm";
      }
      // args
    );

  staleGitLock = builtins.toFile "mix-purifier.lock.json" (
    builtins.toJSON {
      version = 1;
      git.decimal = {
        url = "https://github.com/ericmj/decimal.git";
        rev = "0000000000000000000000000000000000000000";
        submodules = false;
        hash = lib.fakeHash;
      };
    }
  );
  futureLock = builtins.toFile "mix-purifier.lock.json" (
    builtins.toJSON {
      version = 999;
      git = { };
    }
  );
  unreadableMixLock = builtins.toFile "mix.lock" ''
    %{
      "odd": {:svn, "https://example.org/odd", "1"},
    }
  '';

  readsMixExs =
    let
      read = import ../nix/lib/mix-project.nix { inherit lib; };
      basicProject = read ./fixtures/basic/mix.exs;
      gitProject = read ./fixtures/git/mix.exs;
    in
    assert
      basicProject == {
        app = "basic";
        version = "0.1.0";
      };
    assert
      gitProject == {
        app = "git_dep";
        version = "0.2.0";
      };
    pkgs.runCommand "mix-purifier-test-reads-mix-exs" { } "touch $out";

  # The command runs, and its usage names both subcommands.
  command = pkgs.runCommand "mix-purifier-test-command" { } ''
    ${cli}/bin/mix-purifier --help | grep -q 'mix-purifier mix <args>'
    ${cli}/bin/mix-purifier --help | grep -q 'mix-purifier lock'
    touch $out
  '';
in
{
  basic-release = basic;
  basic-runs = runs "basic" basic ''IO.puts(Basic.event_json("nix"))'' ''{"event":"nix"}'';
  basic-deps-accepted = depsAccepted "basic" ./fixtures/basic basic;
  git-release = git;
  git-runs =
    runs "git" git ''IO.puts(GitDep.sum_json(Decimal.new("1.5"), Decimal.new("2.25")))''
      ''{"sum":"3.75"}'';
  git-deps-accepted = depsAccepted "git" ./fixtures/git git;
  stale-git-lock = fails "stale-git-lock" (downloadsOf {
    lockFile = ./fixtures/git/mix.lock;
    purifierLockFile = staleGitLock;
  });
  missing-git-lock = fails "missing-git-lock" (downloadsOf {
    lockFile = ./fixtures/git/mix.lock;
  });
  future-lock-version = fails "future-lock-version" (downloadsOf {
    lockFile = ./fixtures/basic/mix.lock;
    purifierLockFile = futureLock;
  });
  unreadable-mix-lock = fails "unreadable-mix-lock" (downloadsOf {
    lockFile = unreadableMixLock;
  });
  reads-mix-exs = readsMixExs;
  inherit command;
}
