# SPDX-License-Identifier: MIT
#
# Unit tests of the lock readers: how nix/lib/mix-lock.nix reads mix.lock
# lines, and how nix/lib/downloads.nix turns them into download entries,
# with each entry's path and URL. Each test is an evaluation-time
# assertion; the check that holds them builds nothing else.
{ pkgs }:
let
  inherit (pkgs) lib;

  readMixLock =
    text: import ../nix/lib/mix-lock.nix { inherit lib; } (builtins.toFile "mix.lock" text);
  downloadsOf =
    {
      mixLock,
      purifierLock ? null,
      hexMirror ? "https://repo.hex.pm",
    }:
    import ../nix/lib/downloads.nix { inherit lib; } {
      lockFile = builtins.toFile "mix.lock" mixLock;
      purifierLockFile =
        if purifierLock == null then null else builtins.toFile "lock.json" (builtins.toJSON purifierLock);
      inherit hexMirror;
    };

  jasonLine = ''"jason": {:hex, :jason, "1.4.5", "2e3a008590b0b8d7388c20293e9dcc9cf3e5d642fd2a114e4cbbb52e595d940a", [:mix], [{:decimal, "~> 1.0 or ~> 2.0 or ~> 3.0", [hex: :decimal, repo: "hexpm", optional: true]}], "hexpm", "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684"},'';
  # A dependency whose application name differs from its Hex package, from
  # a Hex organization.
  renamedLine = ''"acme_client": {:hex, :client, "2.0.0", "0000000000000000000000000000000000000000000000000000000000000001", [:rebar3], [], "hexpm:acme", "0000000000000000000000000000000000000000000000000000000000000002"},'';
  gitLine = ''"decimal": {:git, "https://github.com/ericmj/decimal.git", "592d59ac4474933f91cdc3e8e037f137f7e008b0", [tag: "v2.3.0"]},'';
  gitSubmodulesLine = ''"nested": {:git, "https://example.org/nested.git", "0123456789abcdef0123456789abcdef01234567", [branch: "main", submodules: true]},'';
  gitNoOptionsLine = ''"plain": {:git, "https://example.org/plain.git", "89abcdef0123456789abcdef0123456789abcdef", []},'';

  lockOf = lines: "%{\n" + lib.concatStringsSep "\n" lines + "\n}\n";

  parsed = readMixLock (lockOf [
    jasonLine
    renamedLine
    gitLine
    gitSubmodulesLine
    gitNoOptionsLine
  ]);
  jason = builtins.head parsed.hex;
  renamed = builtins.elemAt parsed.hex 1;
  git = builtins.head parsed.git;
  gitSubmodules = builtins.elemAt parsed.git 1;
  gitNoOptions = builtins.elemAt parsed.git 2;

  hexpmDownload = builtins.head (downloadsOf { mixLock = lockOf [ jasonLine ]; }).hex;
  mirroredDownload =
    builtins.head
      (downloadsOf {
        mixLock = lockOf [ jasonLine ];
        hexMirror = "https://hexpm.example.org";
      }).hex;
  organizationDownload =
    builtins.head
      (downloadsOf {
        mixLock = lockOf [ renamedLine ];
        purifierLock = {
          version = 1;
          hexRepos."hexpm:acme" = "https://repo.hex.pm/repos/acme";
        };
      }).hex;
  gitDownload =
    builtins.head
      (downloadsOf {
        mixLock = lockOf [ gitSubmodulesLine ];
        purifierLock = {
          version = 1;
          git.nested = {
            url = "https://example.org/nested.git";
            rev = "0123456789abcdef0123456789abcdef01234567";
            submodules = true;
            hash = lib.fakeHash;
          };
        };
      }).git;

  cases = {
    "a Hex entry keeps the application name, package, version, checksums and repository" =
      jason == {
        kind = "hex";
        key = "jason";
        name = "jason";
        version = "1.4.5";
        innerChecksum = "2e3a008590b0b8d7388c20293e9dcc9cf3e5d642fd2a114e4cbbb52e595d940a";
        outerChecksum = "b0c823996102bcd0239b3c2444eb00409b72f6a140c1950bc8b457d836b30684";
        repo = "hexpm";
      };
    "a renamed dependency keeps its application name apart from its package" =
      renamed.key == "acme_client" && renamed.name == "client" && renamed.repo == "hexpm:acme";
    "a git entry keeps its URL and commit" =
      git == {
        kind = "git";
        key = "decimal";
        url = "https://github.com/ericmj/decimal.git";
        rev = "592d59ac4474933f91cdc3e8e037f137f7e008b0";
        submodules = false;
      };
    "a git entry with submodules: true fetches its submodules" = gitSubmodules.submodules;
    "a git entry with no options reads" = gitNoOptions.key == "plain" && !gitNoOptions.submodules;
    "a hexpm package is fetched from repo.hex.pm by its outer checksum" =
      hexpmDownload.path == "hexpm/jason-1.4.5.tar"
      && hexpmDownload.url == "https://repo.hex.pm/tarballs/jason-1.4.5.tar"
      && hexpmDownload.mirrors == [ ]
      && hexpmDownload.hash == "sha256-sMgjmWECvNAjmzwkROsAQJty9qFAwZULyLRX2DazBoQ=";
    "hexMirror replaces repo.hex.pm" =
      mirroredDownload.url == "https://hexpm.example.org/tarballs/jason-1.4.5.tar";
    "an organization's package is fetched by package name from the recorded URL" =
      organizationDownload.path == "hexpm:acme/client-2.0.0.tar"
      && organizationDownload.url == "https://repo.hex.pm/repos/acme/tarballs/client-2.0.0.tar";
    "a git dependency becomes a git entry without a real .git" =
      gitDownload.path == "git/nested"
      &&
        gitDownload.git == {
          url = "https://example.org/nested.git";
          rev = "0123456789abcdef0123456789abcdef01234567";
          submodules = true;
          leaveDotGit = false;
          commitObject = null;
        };
  };

  failing = lib.attrNames (lib.filterAttrs (_: passed: !passed) cases);
in
assert lib.assertMsg (failing == [ ]) "unit tests failed: ${lib.concatStringsSep "; " failing}";
pkgs.runCommand "mix-purifier-test-unit" { } "touch $out"
