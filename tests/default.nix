# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads. The `conformance-*`
# checks are those of the purifier contract (CONTRACT.md in
# github:nix-purifiers/purifier).
{
  pkgs,
  cli,
  toolchain,
  # The flake's default package overlay, which adds buildMixProject.
  overlay,
  # The `mix-purifier` library namespace, with readLock.
  mixPurifier,
  # The shared purifier library.
  purifier,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer builds: through the
  # buildMixProject that the overlay adds to the package set.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildMixProject;
  build = buildMixProject;

  relock = import ./relock.nix { inherit pkgs cli; };
  credo = import ./real-world/credo.nix {
    inherit
      pkgs
      build
      cli
      relock
      ;
  };

  # Hex packages only: jason, an Elixir package, and telemetry, an Erlang
  # package that rebar3 builds. The project has a release and an escript.
  basic = build { src = ./fixtures/basic; };

  # A git dependency (decimal, locked in mix-purifier.lock.json) beside a
  # Hex package (jason), and an ExUnit test.
  git = build { src = ./fixtures/git; };

  # An umbrella of two applications, one depending on the other with
  # `in_umbrella`, and a release of both.
  umbrella = build { src = ./fixtures/umbrella; };

  # A path dependency beside the project (`path: "../helper"`), with a Hex
  # dependency of its own that the project's mix.lock locks.
  pathdep = build {
    src = ./fixtures/pathdep;
    root = "app";
  };

  # jason from a Hex repository named `mirror` rather than hexpm. The lock
  # run recorded the repository's URL in mix-purifier.lock.json.
  hexrepo = build { src = ./fixtures/hexrepo; };

  # A package with metadata and ex_doc, for `release`, `packages.docs` and
  # publishing.
  publishable = build { src = ./fixtures/publish; };

  # The basic fixture without its mix-purifier.lock.json, as a project whose
  # author keeps none, built from the lockfile kept outside it.
  external = build {
    src = builtins.path {
      name = "basic-without-lockfile";
      path = ./fixtures/basic;
      filter = file: _: baseNameOf file != "mix-purifier.lock.json";
    };
    lockFile = ./fixtures/basic/mix-purifier.lock.json;
  };

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
    name: src: project:
    pkgs.runCommand "mix-purifier-test-${name}-deps-accepted" (beam // { HEX_OFFLINE = 1; }) ''
      export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
      cp -r ${src} project
      chmod -R u+w project
      cp -r ${project.deps} project/deps
      chmod -R u+w project/deps
      cd project
      mix deps.loadpaths --no-compile
      touch $out
    '';

  # A lockfile with the hash of its content, as `mix-purifier lock` writes
  # it.
  hashed =
    name: content:
    builtins.toFile name (
      builtins.toJSON (
        content // { hash = "sha256:" + builtins.hashString "sha256" (builtins.toJSON content); }
      )
    );
  committed = path: removeAttrs (lib.importJSON path) [ "hash" ];

  # Evaluation fails, rather than building with a dependency left out or
  # unpinned. The CI job conformance-messages checks the message of each.
  fails =
    name: value:
    let
      result = builtins.tryEval (builtins.deepSeq value value);
    in
    assert lib.assertMsg (!result.success) "${name} evaluated, but it should fail";
    pkgs.runCommand "mix-purifier-test-${name}" { } "touch $out";

  # readLock of a fixture, the basic one unless `src` names another.
  lockOf = args: mixPurifier.readLock ({ src = ./fixtures/basic; } // args);

  # The lock has problems, each naming `mix-purifier lock`, and checkLock,
  # which the builder calls, refuses it.
  refuses =
    name: lock:
    assert lib.assertMsg (lock.problems != [ ]) "${name} has no problems, but it should";
    assert lib.assertMsg (lib.all (lib.hasInfix "mix-purifier lock") lock.problems)
      "${name} has a problem that does not name `mix-purifier lock`: ${lib.concatStringsSep "; " lock.problems}";
    assert lib.assertMsg (
      !(builtins.tryEval (builtins.deepSeq (purifier.checkLock lock) true)).success
    ) "checkLock accepted ${name}";
    pkgs.runCommand "mix-purifier-test-${name}" { } "touch $out";

  # Two builds of the same release, told apart by a variable no build step
  # reads, give the same files once the second build's store path is
  # replaced by the first build's store path.
  rebuild =
    let
      first = basic.packages.release-basic;
      second = first.overrideAttrs { MIX_PURIFIER_SECOND_BUILD = "1"; };
    in
    pkgs.runCommand "mix-purifier-test-conformance-rebuild" { } ''
      cp -r ${first} first
      cp -r ${second} second
      chmod -R u+w first second
      find second -type f -exec sed -i 's|${builtins.baseNameOf second}|${builtins.baseNameOf first}|g' {} +
      diff -r first second
      touch $out
    '';

  # After `mix-purifier prefetch`, the everyday loop of the git fixture
  # works with no network: the toolchain's `mix` compiles the project and
  # runs its test. With a dependency missing from deps/, the toolchain's
  # `mix` fails and names `mix-purifier lock`.
  offline =
    pkgs.runCommand "mix-purifier-test-conformance-offline" (beam // { MIX_PURIFIER_DEPS = git.deps; })
      ''
        export HOME=$TMPDIR MIX_HOME=$TMPDIR/mix HEX_HOME=$TMPDIR/hex
        cp -r ${./fixtures/git} project
        chmod -R u+w project
        cd project
        ${cli}/bin/mix-purifier prefetch --no-editor
        test "$(readlink _build/mix-purifier/toolchain)" = ${toolchain}
        _build/mix-purifier/toolchain/bin/mix compile
        _build/mix-purifier/toolchain/bin/mix test
        rm -rf deps/jason
        if _build/mix-purifier/toolchain/bin/mix compile 2> missing.log; then
          echo "mix compiled with jason missing" >&2
          exit 1
        fi
        grep -q 'run `mix-purifier lock`' missing.log
        touch $out
      '';

  # The publish step: `mix-purifier publish` sends the release and the
  # documentation Nix built to a stand-in for the Hex API, which receives
  # exactly the tarball the project's `release` holds, with the configured
  # API key, and a docs tarball holding the docs' index.html.
  publish =
    pkgs.runCommand "mix-purifier-test-publish"
      (
        beam
        // {
          nativeBuildInputs = beam.nativeBuildInputs ++ [ pkgs.python3 ];
          MIX_PURIFIER_RELEASE = publishable.release;
          MIX_PURIFIER_DOCS = publishable.packages.docs;
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
        cmp received/release.tar ${publishable.release}/package.tar
        test "$(cat received/authorization)" = mix-purifier-test-key
        tar -tzf received/docs.tar.gz > docs-files
        grep -qx index.html docs-files
        tar -tf ${publishable.release}/package.tar > package-files
        grep -qx metadata.config package-files
        touch $out
      '';

  # A mix.lock whose inner checksum for jason was edited: the tarball still
  # matches its outer checksum, so it downloads, and unpacking it fails
  # with a message that names the checksum mix.lock locks.
  tamperedInnerChecksum =
    let
      tampered = builtins.toFile "mix.lock" (
        builtins.replaceStrings
          [ "2e3a008590b0b8d7388c20293e9dcc9cf3e5d642fd2a114e4cbbb52e595d940a" ]
          [ "0000000000000000000000000000000000000000000000000000000000000000" ]
          (builtins.readFile ./fixtures/basic/mix.lock)
      );
      failure =
        pkgs.testers.testBuildFailure
          (build {
            src = ./fixtures/basic;
            mixLock = tampered;
          }).deps.hexPackages.jason;
    in
    pkgs.runCommand "mix-purifier-test-tampered-inner-checksum" { } ''
      grep -q 'the inner checksum is 2e3a0085.*but mix.lock locks 00000000' ${failure}/testBuildFailure.log
      touch $out
    '';

  # A package written for callPackage takes the builder by name, as a
  # package in an overlay does, and builds what the builder builds.
  consumerPackage =
    let
      withConsumer = withOverlay.extend (
        final: prev: {
          example = final.callPackage (
            { buildMixProject }: (buildMixProject { src = ./fixtures/basic; }).packages.release-basic
          ) { };
        }
      );
    in
    assert withConsumer.example.drvPath == basic.packages.release-basic.drvPath;
    pkgs.runCommand "mix-purifier-test-consumer-package" { } "touch $out";

  # `buildMixProject.override` replaces what the builder takes from the
  # package set: a marker rebar3 in the Erlang and Elixir package set
  # reaches the release.
  builderOverride =
    let
      markerRebar3 = pkgs.runCommand "marker-rebar3" { } "mkdir -p $out/bin; touch $out/bin/rebar3";
      overridden = buildMixProject.override {
        beamPackages = pkgs.beamPackages.overrideScope (_: _: { rebar3 = markerRebar3; });
      };
      release = (overridden { src = ./fixtures/basic; }).packages.release-basic;
    in
    assert release.drvPath != basic.packages.release-basic.drvPath;
    pkgs.runCommand "mix-purifier-test-builder-override" { } "touch $out";

  # Nix knows every output by name when it evaluates, from the lock alone.
  outputsKnown =
    assert
      lib.attrNames basic.packages == [
        "app-basic"
        "docs"
        "escript-basic"
        "release-basic"
      ];
    assert basic.release == null;
    assert
      lib.attrNames umbrella.packages == [
        "app-greeter"
        "app-shouter"
        "docs"
        "release-umbrella"
      ];
    assert publishable.release != null;
    assert
      map (entry: entry.path) git.fetches == [
        "hexpm/jason-1.4.5.tar"
        "git/decimal"
      ];
    pkgs.runCommand "mix-purifier-test-outputs-known" { } "touch $out";

  # A git dependency with `submodules: true` is fetched with its submodules.
  readsSubmodules =
    let
      lock = lockOf {
        mixLock = builtins.toFile "mix.lock" ''
          %{
            "nested": {:git, "https://example.org/nested.git", "0123456789abcdef0123456789abcdef01234567", [branch: "main", submodules: true]},
          }
        '';
        lockFile = hashed "mix-purifier.lock.json" {
          version = 1;
          git.nested = {
            url = "https://example.org/nested.git";
            rev = "0123456789abcdef0123456789abcdef01234567";
            submodules = true;
            hash = lib.fakeHash;
          };
        };
      };
      entry = builtins.head (lib.filter (entry: entry ? git) lock.entries);
    in
    assert entry.git.submodules;
    assert (purifier.fetchEntry { inherit pkgs; } entry).fetchSubmodules;
    pkgs.runCommand "mix-purifier-test-reads-submodules" { } "touch $out";

  # The command runs, and its usage names every command.
  command = pkgs.runCommand "mix-purifier-test-command" { } ''
    for subcommand in lock prefetch publish; do
      ${cli}/bin/mix-purifier --help | grep -q "mix-purifier $subcommand"
    done
    touch $out
  '';

  basicLock = committed ./fixtures/basic/mix-purifier.lock.json;
  gitLock = committed ./fixtures/git/mix-purifier.lock.json;

  relockChecks = lib.listToAttrs (
    map
      (
        {
          name,
          root ? ".",
        }:
        lib.nameValuePair "${name}-relock" (
          relock.reproduces {
            inherit name root;
            src = ./fixtures + "/${name}";
            lockFile = ./fixtures + "/${name}/${root}/mix-purifier.lock.json";
          }
        )
      )
      [
        { name = "git"; }
        { name = "umbrella"; }
        {
          name = "pathdep";
          root = "app";
        }
        { name = "hexrepo"; }
        { name = "publish"; }
        { name = "update"; }
      ]
  );
in
{
  # The checks of the purifier contract.
  conformance-stale = refuses "conformance-stale" (lockOf {
    lockFile = hashed "mix-purifier.lock.json" (
      lib.recursiveUpdate basicLock { outputs.definitionFiles."mix.exs" = lib.fakeSha256; }
    );
  });
  conformance-tampered = refuses "conformance-tampered" (lockOf {
    src = ./fixtures/git;
    lockFile = builtins.toFile "mix-purifier.lock.json" (
      builtins.toJSON (
        lib.recursiveUpdate (lib.importJSON ./fixtures/git/mix-purifier.lock.json) {
          git.decimal.hash = lib.fakeHash;
        }
      )
    );
  });
  conformance-missing = refuses "conformance-missing" (lockOf {
    src = ./fixtures/git;
    lockFile = hashed "mix-purifier.lock.json" (removeAttrs gitLock [ "git" ]);
  });
  # A lockfile that is valid JSON but not of this format. A lockfile that is
  # not valid JSON fails Nix's JSON reader at once, which the CI job
  # conformance-messages checks.
  conformance-malformed = refuses "conformance-malformed" (lockOf {
    lockFile = builtins.toFile "mix-purifier.lock.json" (builtins.toJSON { outputs = [ ]; });
  });
  conformance-relock = relock.reproduces {
    name = "basic";
    src = ./fixtures/basic;
    lockFile = ./fixtures/basic/mix-purifier.lock.json;
  };
  conformance-rebuild = rebuild;
  conformance-offline = offline;
  conformance-external =
    runs "external" external.packages.release-basic ''IO.puts(Basic.event_json("nix"))''
      ''{"event":"nix"}'';

  basic-release = basic.packages.release-basic;
  basic-runs =
    runs "basic" basic.packages.release-basic ''IO.puts(Basic.event_json("nix"))''
      ''{"event":"nix"}'';
  basic-escript = pkgs.runCommand "mix-purifier-test-basic-escript" { } ''
    test "$(${basic.packages.escript-basic}/bin/basic nix)" = '{"event":"nix"}'
    touch $out
  '';
  basic-deps-accepted = depsAccepted "basic" ./fixtures/basic basic;
  git-runs =
    runs "git" git.packages.release-git_dep
      ''IO.puts(GitDep.sum_json(Decimal.new("1.5"), Decimal.new("2.25")))''
      ''{"sum":"3.75"}'';
  git-tests = git.tests;
  git-deps-accepted = depsAccepted "git" ./fixtures/git git;
  umbrella-runs =
    runs "umbrella" umbrella.packages.release-umbrella ''IO.puts(Shouter.shout("nix"))''
      ''{"GREETING":"HELLO, NIX"}'';
  umbrella-apps = pkgs.runCommand "mix-purifier-test-umbrella-apps" { } ''
    test -f ${umbrella.packages.app-greeter}/ebin/greeter.app
    test -f ${umbrella.packages.app-shouter}/ebin/shouter.app
    touch $out
  '';
  umbrella-deps-accepted = depsAccepted "umbrella" ./fixtures/umbrella umbrella;
  pathdep-runs =
    runs "pathdep" pathdep.packages.release-pathdep_app "IO.puts(PathdepApp.run())"
      "helped";
  hexrepo-runs =
    runs "hexrepo" hexrepo.packages.release-hexrepo ''IO.puts(Hexrepo.encode(%{repo: "mirror"}))''
      ''{"repo":"mirror"}'';
  hexrepo-deps-accepted = depsAccepted "hexrepo" ./fixtures/hexrepo hexrepo;
  inherit publish command;

  stale-git-lock = refuses "stale-git-lock" (lockOf {
    src = ./fixtures/git;
    lockFile = hashed "mix-purifier.lock.json" (
      lib.recursiveUpdate gitLock {
        git.decimal.rev = "0000000000000000000000000000000000000000";
      }
    );
  });
  missing-hex-repo = refuses "missing-hex-repo" (lockOf {
    src = ./fixtures/hexrepo;
    lockFile = hashed "mix-purifier.lock.json" (
      removeAttrs (committed ./fixtures/hexrepo/mix-purifier.lock.json) [ "hexRepos" ]
    );
  });
  missing-outputs = refuses "missing-outputs" (lockOf {
    lockFile = null;
  });
  future-lock-version = refuses "future-lock-version" (lockOf {
    lockFile = hashed "mix-purifier.lock.json" (basicLock // { version = 999; });
  });
  unreadable-mix-lock = refuses "unreadable-mix-lock" (lockOf {
    mixLock = builtins.toFile "mix.lock" ''
      %{
        "odd": {:svn, "https://example.org/odd", "1"},
      }
    '';
  });
  # The builder refuses a lock with problems, through checkLock.
  builder-refuses =
    fails "builder-refuses"
      (build {
        src = ./fixtures/basic;
        lockFile = null;
      }).packages;
  tampered-inner-checksum = tamperedInnerChecksum;
  consumer-package = consumerPackage;
  builder-override = builderOverride;
  outputs-known = outputsKnown;
  reads-submodules = readsSubmodules;
  unit = import ./unit.nix { inherit pkgs; };
}
// relockChecks
// credo.checks
