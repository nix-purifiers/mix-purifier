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
  # package that rebar3 builds. The project has a release and an escript.
  basic = buildMixProject { src = ./fixtures/basic; };

  # A git dependency (decimal, locked in mix-purifier.lock.json) beside a
  # Hex package (jason).
  git = buildMixProject { src = ./fixtures/git; };

  # An umbrella of two applications, one depending on the other with
  # `in_umbrella`, and a release of both.
  umbrella = buildMixProject { src = ./fixtures/umbrella; };

  # A path dependency beside the project (`path: "../helper"`), with a Hex
  # dependency of its own that the project's mix.lock locks.
  pathdep = buildMixProject {
    src = ./fixtures/pathdep;
    root = "app";
  };

  # jason from a Hex repository named `mirror` rather than hexpm. The lock
  # run recorded the repository's URL in mix-purifier.lock.json.
  hexrepo = buildMixProject { src = ./fixtures/hexrepo; };

  # A package with metadata and ex_doc, for `hexPackage`, `docs` and
  # publishing.
  publishable = buildMixProject { src = ./fixtures/publish; };

  beam = {
    nativeBuildInputs = [
      pkgs.beamPackages.elixir
      pkgs.git
    ];
    ERL_LIBS = "${pkgs.beamPackages.hex}/lib/erlang/lib";
    LANG = "C.UTF-8";
  };

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
    pkgs.runCommand "mix-purifier-test-${name}-deps-accepted" (beam // { HEX_OFFLINE = 1; }) ''
      export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
      cp -r ${src} project
      chmod -R u+w project
      cp -r ${release.deps} project/deps
      chmod -R u+w project/deps
      cd project
      mix deps.loadpaths --no-compile
      touch $out
    '';

  # The offline interactive mode: `mix-purifier mix` copies the dependency
  # directory into a copy of the git fixture and compiles it with Hex
  # offline. A second run copies nothing, because no marker changed.
  interactive = pkgs.runCommand "mix-purifier-test-interactive" beam ''
    export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
    export MIX_PURIFIER_DEPS=${git.deps}
    cp -r ${./fixtures/git} project
    chmod -R u+w project
    cd project
    ${cli}/bin/mix-purifier mix compile
    test -f _build/dev/lib/decimal/ebin/decimal.app
    test -f _build/dev/lib/jason/ebin/jason.app
    touch deps/jason/marker-of-this-check
    ${cli}/bin/mix-purifier mix compile
    test -f deps/jason/marker-of-this-check
    touch $out
  '';

  # The publish step: `mix-purifier publish` sends the package tarball and
  # documentation Nix built to a stand-in for the Hex API, which receives
  # exactly the tarball buildMixProject's `hexPackage` holds, with the
  # configured API key, and a docs tarball holding the docs' index.html.
  publish =
    pkgs.runCommand "mix-purifier-test-publish"
      (
        beam
        // {
          nativeBuildInputs = beam.nativeBuildInputs ++ [ pkgs.python3 ];
          MIX_PURIFIER_HEX_PACKAGE = publishable.hexPackage;
          MIX_PURIFIER_DOCS = publishable.docs;
        }
      )
      ''
        export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
        mkdir received
        python3 ${./hex-api.py} received &
        while [ ! -s received/port ]; do sleep 0.1; done
        export HEX_API_URL=http://127.0.0.1:$(cat received/port) HEX_API_KEY=mix-purifier-test-key
        cp -r ${./fixtures/publish} project
        chmod -R u+w project
        cd project
        ${cli}/bin/mix-purifier publish --yes
        cd ..
        cmp received/release.tar ${publishable.hexPackage}/package.tar
        test "$(cat received/authorization)" = mix-purifier-test-key
        tar -tzf received/docs.tar.gz | grep -qx index.html
        tar -tf ${publishable.hexPackage}/package.tar | grep -qx metadata.config
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
    }
  );
  unreadableMixLock = builtins.toFile "mix.lock" ''
    %{
      "odd": {:svn, "https://example.org/odd", "1"},
    }
  '';
  submoduleMixLock = builtins.toFile "mix.lock" ''
    %{
      "nested": {:git, "https://example.org/nested.git", "0123456789abcdef0123456789abcdef01234567", [branch: "main", submodules: true]},
    }
  '';
  submoduleLock = builtins.toFile "mix-purifier.lock.json" (
    builtins.toJSON {
      version = 1;
      git.nested = {
        url = "https://example.org/nested.git";
        rev = "0123456789abcdef0123456789abcdef01234567";
        submodules = true;
        hash = lib.fakeHash;
      };
    }
  );

  # A git dependency with `submodules: true` is fetched with its submodules.
  readsSubmodules =
    let
      downloads = downloadsOf {
        lockFile = submoduleMixLock;
        purifierLockFile = submoduleLock;
      };
      entry = builtins.head downloads.git;
    in
    assert entry.git.submodules;
    assert (import ../nix/lib/fetch.nix { inherit (pkgs) fetchurl fetchgit; } entry).fetchSubmodules;
    pkgs.runCommand "mix-purifier-test-reads-submodules" { } "touch $out";

  # Nix knows every output by name when it evaluates, from the lock alone:
  # the releases, the project's own applications, the escripts and the Hex
  # package.
  outputsKnown =
    assert lib.attrNames basic.releases == [ "basic" ];
    assert lib.attrNames basic.escripts == [ "basic" ];
    assert basic.hexPackage == null;
    assert lib.attrNames umbrella.releases == [ "umbrella" ];
    assert
      lib.attrNames umbrella.apps == [
        "greeter"
        "shouter"
      ];
    assert umbrella.pname == "umbrella";
    assert publishable.hexPackage != null;
    assert publishable.outputs.package.name == "mix_purifier_publish_fixture";
    pkgs.runCommand "mix-purifier-test-outputs-known" { } "touch $out";

  # The escript runs.
  basicEscript = pkgs.runCommand "mix-purifier-test-basic-escript" { } ''
    out_text=$(${basic.escripts.basic}/bin/basic nix)
    test "$out_text" = '{"event":"nix"}'
    touch $out
  '';

  # Each of the umbrella's applications is compiled on its own.
  umbrellaApps = pkgs.runCommand "mix-purifier-test-umbrella-apps" { } ''
    test -f ${umbrella.apps.greeter}/ebin/greeter.app
    test -f ${umbrella.apps.shouter}/ebin/shouter.app
    touch $out
  '';

  # A mix.exs that changed since the lock fails the evaluation, and so does
  # a project with no lock of its outputs.
  staleMixExsLock = builtins.toFile "mix-purifier.lock.json" (
    builtins.toJSON (
      lib.recursiveUpdate (lib.importJSON ./fixtures/basic/mix-purifier.lock.json) {
        outputs.definitionFiles."mix.exs" = lib.fakeSha256;
      }
    )
  );

  # The command runs, and its usage names every subcommand.
  command = pkgs.runCommand "mix-purifier-test-command" { } ''
    for subcommand in 'mix <args>' lock publish; do
      ${cli}/bin/mix-purifier --help | grep -q "mix-purifier $subcommand"
    done
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
  umbrella-release = umbrella;
  umbrella-runs =
    runs "umbrella" umbrella ''IO.puts(Shouter.shout("nix"))''
      ''{"GREETING":"HELLO, NIX"}'';
  umbrella-deps-accepted = depsAccepted "umbrella" ./fixtures/umbrella umbrella;
  pathdep-release = pathdep;
  pathdep-runs = runs "pathdep" pathdep "IO.puts(PathdepApp.run())" "helped";
  hexrepo-release = hexrepo;
  hexrepo-runs =
    runs "hexrepo" hexrepo ''IO.puts(Hexrepo.encode(%{repo: "mirror"}))''
      ''{"repo":"mirror"}'';
  hexrepo-deps-accepted = depsAccepted "hexrepo" ./fixtures/hexrepo hexrepo;
  inherit interactive publish;
  stale-git-lock = fails "stale-git-lock" (downloadsOf {
    lockFile = ./fixtures/git/mix.lock;
    purifierLockFile = staleGitLock;
  });
  missing-git-lock = fails "missing-git-lock" (downloadsOf {
    lockFile = ./fixtures/git/mix.lock;
  });
  missing-hex-repo = fails "missing-hex-repo" (downloadsOf {
    lockFile = ./fixtures/hexrepo/mix.lock;
  });
  future-lock-version = fails "future-lock-version" (downloadsOf {
    lockFile = ./fixtures/basic/mix.lock;
    purifierLockFile = futureLock;
  });
  unreadable-mix-lock = fails "unreadable-mix-lock" (downloadsOf {
    lockFile = unreadableMixLock;
  });
  reads-submodules = readsSubmodules;
  outputs-known = outputsKnown;
  basic-escript = basicEscript;
  umbrella-apps = umbrellaApps;
  stale-mix-exs =
    fails "stale-mix-exs"
      (buildMixProject {
        src = ./fixtures/basic;
        purifierLockFile = staleMixExsLock;
      }).outputs;
  missing-outputs =
    fails "missing-outputs"
      (buildMixProject {
        src = ./fixtures/basic;
        purifierLockFile = null;
      }).outputs;
  inherit command;
}
