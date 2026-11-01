# SPDX-License-Identifier: MIT
#
# The downloads a Mix project's dependencies need, as download entries in
# the shape of the shared purifier library:
#
# - A Hex package is a file entry `{ path, url, mirrors, hash }`. Its hash
#   is the outer checksum from mix.lock, which is the SHA-256 of the
#   tarball. Each tarball has one URL, so `mirrors` is empty.
# - A git dependency is a git entry `{ path, git = { url, rev, submodules,
#   leaveDotGit, commitObject }, hash }`, without a real .git, so
#   `leaveDotGit` is false and `commitObject` is null. Its hash comes from
#   mix-purifier.lock.json.
#
# Each entry keeps the mix.lock fields the dependency directory needs, under
# `mix`.
{ lib }:
{
  lockFile,
  purifierLockFile,
  # The URL that serves hexpm's tarballs. A mirror serves the same files,
  # so the locked hashes still hold.
  hexMirror,
}:
let
  mixLock = import ./mix-lock.nix { inherit lib; } lockFile;
  purifierLock = import ./purifier-lock.nix { inherit lib; } purifierLockFile;

  # A private repository, such as a Hex organization, needs credentials
  # that never enter Nix: `mix-purifier lock` downloads its tarballs with
  # Hex and adds each to the store under the path this fetch produces, so
  # the fetch finds it there.
  repoUrl =
    entry:
    if entry.repo == "hexpm" then
      hexMirror
    else
      purifierLock.hexRepos.${entry.repo}
        or (throw "mix-purifier: ${entry.key} comes from the Hex repository ${entry.repo}, but mix-purifier.lock.json has no URL for it. Run `mix-purifier lock`.");

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

  gitDownload =
    entry:
    let
      locked =
        purifierLock.git.${entry.key}
          or (throw "mix-purifier: mix.lock has the git dependency ${entry.key}, but mix-purifier.lock.json does not lock it. Run `mix-purifier lock`.");
    in
    if locked.url != entry.url || locked.rev != entry.rev || locked.submodules != entry.submodules then
      throw "mix-purifier: mix-purifier.lock.json locks ${entry.key} at ${locked.url} ${locked.rev}, but mix.lock has ${entry.url} ${entry.rev}. Run `mix-purifier lock`."
    else
      {
        path = "git/${entry.key}";
        # The dependency directory writes its own minimal .git (deps.nix),
        # so the checkout needs no real one.
        git = {
          inherit (entry) url rev submodules;
          leaveDotGit = false;
          commitObject = null;
        };
        inherit (locked) hash;
        mix = entry;
      };
in
# The purifier lock's version is checked even when mix.lock has no git
# dependency, so a lock from another mix-purifier never passes unread.
builtins.seq purifierLock {
  hex = map hexDownload mixLock.hex;
  git = map gitDownload mixLock.git;
}
