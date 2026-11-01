# SPDX-License-Identifier: MIT
#
# Reads mix-purifier.lock.json, the lock `mix-purifier lock` writes beside
# mix.lock. It holds what mix.lock leaves out:
#
#   {
#     "version": 1,
#     "outputs": { … },
#     "git": {
#       "<key>": { "url": …, "rev": …, "submodules": false, "hash": "sha256-…" }
#     },
#     "hexRepos": { "<repo>": "<url>" }
#   }
#
# - `outputs` has every output the project produces, as Mix reports it
#   (nix/project-outputs.exs describes the fields). buildMixProject needs
#   it, and the dependency directory alone does not.
# - `git` has the NAR hash of each git dependency's checkout. mix.lock pins
#   the commit but records no hash.
# - `hexRepos` has the URL of each Hex repository other than hexpm, as Hex
#   resolves it from the user's configuration. A tarball of `<repo>` is at
#   `<url>/tarballs/<name>-<version>.tar`.
#
# The dependency directory of a project without the file uses hexpm only,
# with `purifierLockFile` null.
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
    outputs = lock.outputs or null;
  }
