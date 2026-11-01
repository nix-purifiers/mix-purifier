# SPDX-License-Identifier: MIT
#
# Reads mix-purifier.lock.json, the lock `mix-purifier lock` writes beside
# mix.lock. mix.lock pins a git dependency to a commit but records no hash
# of its checkout, so this file holds the NAR hash of each checkout:
#
#   {
#     "version": 1,
#     "git": {
#       "<key>": { "url": …, "rev": …, "submodules": false, "hash": "sha256-…" }
#     }
#   }
#
# A project whose mix.lock has no git dependency needs no such file, and
# `purifierLockFile` is then null.
{ lib }:
purifierLockFile:
let
  supportedVersion = 1;
  lock =
    if purifierLockFile == null then
      {
        version = supportedVersion;
        git = { };
      }
    else
      lib.importJSON purifierLockFile;
in
if lock.version != supportedVersion then
  throw "mix-purifier: ${toString purifierLockFile} has version ${toString lock.version}, but this mix-purifier reads version ${toString supportedVersion}. Run `mix-purifier lock` with this mix-purifier."
else
  lock
