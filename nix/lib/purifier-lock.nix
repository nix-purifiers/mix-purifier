# SPDX-License-Identifier: MIT
#
# Reads mix-purifier.lock.json, the lock `mix-purifier lock` writes beside
# mix.lock. It holds what mix.lock leaves out:
#
#   {
#     "version": 1,
#     "git": {
#       "<key>": { "url": …, "rev": …, "submodules": false, "hash": "sha256-…" }
#     },
#     "hexRepos": { "<repo>": "<url>" }
#   }
#
# - `git` has the NAR hash of each git dependency's checkout. mix.lock pins
#   the commit but records no hash.
# - `hexRepos` has the URL of each Hex repository other than hexpm, as Hex
#   resolves it from the user's configuration. A tarball of `<repo>` is at
#   `<url>/tarballs/<name>-<version>.tar`.
#
# A project that uses only hexpm and no git dependency needs no such file,
# and `purifierLockFile` is then null.
{ lib }:
purifierLockFile:
let
  supportedVersion = 1;
  lock =
    if purifierLockFile == null then
      { version = supportedVersion; }
    else
      lib.importJSON purifierLockFile;
in
if lock.version != supportedVersion then
  throw "mix-purifier: ${toString purifierLockFile} has version ${toString lock.version}, but this mix-purifier reads version ${toString supportedVersion}. Run `mix-purifier lock` with this mix-purifier."
else
  {
    inherit (lock) version;
    git = lock.git or { };
    hexRepos = lock.hexRepos or { };
  }
