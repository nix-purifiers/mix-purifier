# SPDX-License-Identifier: MIT
#
# Reads mix-purifier.lock.json, the lock `mix-purifier lock` writes beside
# mix.lock. It holds what mix.lock does not record:
#
#   {
#     "version": 1,
#     "hash": "sha256:<hex>",
#     "outputs": { … },
#     "git": {
#       "<key>": { "url": …, "rev": …, "submodules": false, "hash": "sha256-…" }
#     },
#     "hexRepos": { "<repo>": "<url>" }
#   }
#
# - `hash` is the SHA-256 of the rest of the file, as compact JSON with
#   sorted keys, which is the form `builtins.toJSON` writes. A file edited
#   by hand has a different hash from the one it records.
# - `outputs` has every output the project produces, as Mix reports it
#   (nix/lock-info.exs describes the fields).
# - `git` has the NAR hash of each git dependency's checkout. mix.lock pins
#   the commit but records no hash.
# - `hexRepos` has the URL of each Hex repository other than hexpm, as Hex
#   resolves it from the user's configuration. A tarball of `<repo>` is at
#   `<url>/tarballs/<name>-<version>.tar`.
#
# The result is { lock; problems; }: `lock` holds the fields above, empty
# where the file has none or cannot be used, and `problems` says why it
# cannot be used, each problem naming `mix-purifier lock`, which rewrites
# the file. A file that is not valid JSON fails at once, because Nix's
# JSON reader fails evaluation; its error context names the same command.
# `lockFile` is null for a project without the file.
{ lib }:
lockFile:
let
  supportedVersion = 1;
  file = toString lockFile;
  fix = "Run `mix-purifier lock` to rewrite it.";
  empty = {
    version = supportedVersion;
    git = { };
    hexRepos = { };
    outputs = null;
  };

  lock = builtins.addErrorContext "while reading ${file}, which is not valid JSON. ${fix}" (
    lib.importJSON lockFile
  );
  hash = "sha256:" + builtins.hashString "sha256" (builtins.toJSON (removeAttrs lock [ "hash" ]));

  problem =
    if !builtins.isAttrs lock || !(lock ? version) || !builtins.isInt lock.version then
      "mix-purifier: ${file} is malformed: it has no format version. ${fix}"
    else if lock.version != supportedVersion then
      "mix-purifier: ${file} has version ${toString lock.version}, but this mix-purifier reads version ${toString supportedVersion}. Run `mix-purifier lock` with this mix-purifier."
    else if !(lock ? hash) then
      "mix-purifier: ${file} has no hash of its content, so it is incomplete. ${fix}"
    else if lock.hash != hash then
      "mix-purifier: ${file} does not match the hash of its content, so it was edited after `mix-purifier lock` wrote it. ${fix}"
    else if
      !(builtins.isAttrs (lock.git or { }))
      || !(builtins.isAttrs (lock.hexRepos or { }))
      || !builtins.isAttrs (lock.outputs or { })
    then
      "mix-purifier: ${file} is malformed. ${fix}"
    else
      null;
in
if lockFile == null then
  {
    lock = empty;
    problems = [ ];
  }
else if problem != null then
  {
    lock = empty;
    problems = [ problem ];
  }
else
  {
    lock = {
      inherit (lock) version;
      git = lock.git or { };
      hexRepos = lock.hexRepos or { };
      outputs = lock.outputs or null;
    };
    problems = [ ];
  }
