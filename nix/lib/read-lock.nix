# SPDX-License-Identifier: MIT
#
# lib.mix-purifier.readLock: reads a Mix project's locks, mix.lock and
# mix-purifier.lock.json, into the lock in memory of the purifier contract
# (CONTRACT.md in github:nix-purifiers/purifier):
#
#   {
#     purifier = "mix-purifier";
#     entries  = [ … ];  # the downloads, as purifier library entries
#     outputs  = { … };  # every output, by the name buildMixProject gives it
#     problems = [ … ];  # why the locks cannot be used, each naming the fix
#     record   = { … };  # the outputs as mix-purifier.lock.json records them
#   }
#
# The entries are needed on every system, so none carries `systems`:
#
# - A Hex package is a file entry `{ path, url, mirrors, hash }`, read from
#   mix.lock. Its hash is the outer checksum there, which is the SHA-256 of
#   the tarball. Each tarball has one URL, so `mirrors` is empty.
# - A git dependency is a git entry `{ path, git = { url, rev, submodules,
#   leaveDotGit, commitObject }, hash }`, without a real .git, so
#   `leaveDotGit` is false and `commitObject` is null. Its hash comes from
#   mix-purifier.lock.json, because mix.lock pins only the commit.
#
# Each entry keeps the mix.lock fields the dependency directory needs,
# under `mix`.
#
# `outputs` names each output the way buildMixProject names its result:
# `release-<name>`, `escript-<name>`, `app-<name>` and `docs`, and
# `release` for the Hex package of a project that has one.
#
# A problem is reported, rather than thrown, for a mix-purifier.lock.json
# that is missing, stale, tampered or incomplete, for a git dependency or
# Hex repository it does not record, and for a mix.lock entry this reader
# cannot read. lib.purifier.checkLock fails evaluation with them.
{ lib }:
{
  src,
  root ? ".",
  lockFile ?
    if builtins.pathExists (src + "/${root}/mix-purifier.lock.json") then
      src + "/${root}/mix-purifier.lock.json"
    else
      null,
  mixLock ? src + "/${root}/mix.lock",
  # The URL that serves hexpm's tarballs. A mirror serves the same files,
  # so the locked hashes still hold.
  hexMirror ? "https://repo.hex.pm",
}:
let
  projectDir = src + "/${root}";
  fix = "Run `mix-purifier lock`.";
  mixLockEntries = import ./mix-lock.nix { inherit lib; } mixLock;
  read = import ./purifier-lock.nix { inherit lib; } lockFile;
  purifierLock = read.lock;

  # A private repository, such as a Hex organization, needs credentials
  # that never enter Nix: `mix-purifier lock` downloads its tarballs with
  # Hex and adds each to the store under the path this fetch produces, so
  # the fetch finds it there.
  repoUrl =
    entry: if entry.repo == "hexpm" then hexMirror else purifierLock.hexRepos.${entry.repo} or null;

  hexEntries = lib.filter (entry: repoUrl entry != null) mixLockEntries.hex;
  hexProblems = map (
    entry:
    "mix-purifier: ${entry.key} comes from the Hex repository ${entry.repo}, but mix-purifier.lock.json has no URL for it. ${fix}"
  ) (lib.filter (entry: repoUrl entry == null) mixLockEntries.hex);

  hexDownload = entry: {
    path = "${entry.repo}/${entry.name}-${entry.version}.tar";
    url = "${repoUrl entry}/tarballs/${entry.name}-${entry.version}.tar";
    mirrors = [ ];
    hash = builtins.convertHash {
      hash = entry.outerChecksum;
      hashAlgo = "sha256";
      toHashFormat = "sri";
    };
    mix = entry;
  };

  gitLocked = entry: purifierLock.git.${entry.key} or null;
  gitCurrent =
    entry:
    let
      locked = gitLocked entry;
    in
    locked != null
    && locked.url == entry.url
    && locked.rev == entry.rev
    && locked.submodules == entry.submodules;
  gitEntries = lib.filter gitCurrent mixLockEntries.git;
  gitProblems = map (
    entry:
    if gitLocked entry == null then
      "mix-purifier: mix.lock has the git dependency ${entry.key}, but mix-purifier.lock.json does not lock it. ${fix}"
    else
      "mix-purifier: mix-purifier.lock.json locks ${entry.key} at ${(gitLocked entry).url} ${(gitLocked entry).rev}, but mix.lock has ${entry.url} ${entry.rev}. ${fix}"
  ) (lib.filter (entry: !gitCurrent entry) mixLockEntries.git);

  # The dependency directory writes its own minimal .git (deps.nix), so the
  # checkout needs no real one.
  gitDownload = entry: {
    path = "git/${entry.key}";
    git = {
      inherit (entry) url rev submodules;
      leaveDotGit = false;
      commitObject = null;
    };
    inherit (gitLocked entry) hash;
    mix = entry;
  };

  unreadableProblems = map (
    line:
    "mix-purifier: ${toString mixLock} has an entry mix-purifier cannot read: ${line}. Restore mix.lock from version control, or run `mix-purifier lock`, which rewrites it with `mix deps.get`."
  ) mixLockEntries.unreadable;

  record = purifierLock.outputs;
  changed =
    if record == null then
      [ ]
    else
      lib.attrNames (
        lib.filterAttrs (
          file: hash: builtins.hashFile "sha256" (projectDir + "/${file}") != hash
        ) record.definitionFiles
      );
  outputProblems =
    if lockFile == null || (read.problems == [ ] && record == null) then
      [
        "mix-purifier: ${toString projectDir} has no mix-purifier.lock.json with the project's outputs. ${fix}"
      ]
    else if changed != [ ] then
      [
        "mix-purifier: ${lib.concatStringsSep ", " changed} changed since mix-purifier.lock.json was written. ${fix}"
      ]
    else
      [ ];

  prefixed =
    prefix: names: kind:
    lib.listToAttrs (map (name: lib.nameValuePair "${prefix}-${name}" { inherit kind name; }) names);
  outputs =
    if record == null then
      { }
    else
      prefixed "release" record.releases "release"
      // prefixed "escript" record.escripts "escript"
      // lib.mapAttrs' (
        app: value: lib.nameValuePair "app-${app}" (value // { kind = "app"; })
      ) record.apps
      // {
        docs.kind = "docs";
      }
      // lib.optionalAttrs (record.package != null) {
        release = record.package // {
          kind = "hex-package";
        };
      };
in
{
  purifier = "mix-purifier";
  entries = map hexDownload hexEntries ++ map gitDownload gitEntries;
  inherit outputs record;
  problems = read.problems ++ outputProblems ++ hexProblems ++ gitProblems ++ unreadableProblems;
}
