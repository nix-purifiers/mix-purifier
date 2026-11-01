# SPDX-License-Identifier: MIT
#
# Reads mix-purifier.lock.json, the lock `mix-purifier lock` writes beside
# mix.lock. It holds what mix.lock leaves out:
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
#   by hand no longer matches it.
# - `outputs` has every output the project produces, as Mix reports it
#   (nix/lock-info.exs describes the fields). buildMixProject needs it, and
#   the dependency directory alone does not.
# - `git` has the NAR hash of each git dependency's checkout. mix.lock pins
#   the commit but records no hash.
# - `hexRepos` has the URL of each Hex repository other than hexpm, as Hex
#   resolves it from the user's configuration. A tarball of `<repo>` is at
#   `<url>/tarballs/<name>-<version>.tar`.
#
# Each problem with the file fails with a message that names
# `mix-purifier lock`, which rewrites it. The dependency directory of a
# project without the file uses hexpm only, with `lockFile` null.
{ lib }:
lockFile:
let
  supportedVersion = 1;
  file = toString lockFile;
  fix = "Run `mix-purifier lock` to rewrite it.";

  lock = builtins.addErrorContext "while reading ${file}, which is not valid JSON. ${fix}" (
    lib.importJSON lockFile
  );
  content = removeAttrs lock [ "hash" ];
  hash = "sha256:" + builtins.hashString "sha256" (builtins.toJSON content);

  checked =
    if !builtins.isAttrs lock || !(lock ? version) || !builtins.isInt lock.version then
      throw "mix-purifier: ${file} is malformed: it has no format version. ${fix}"
    else if lock.version != supportedVersion then
      throw "mix-purifier: ${file} has version ${toString lock.version}, but this mix-purifier reads version ${toString supportedVersion}. Run `mix-purifier lock` with this mix-purifier."
    else if !(lock ? hash) then
      throw "mix-purifier: ${file} has no hash of its content, so it is incomplete. ${fix}"
    else if lock.hash != hash then
      throw "mix-purifier: ${file} does not match the hash of its content, so it was edited after `mix-purifier lock` wrote it. ${fix}"
    else if
      !(builtins.isAttrs (lock.git or { }))
      || !(builtins.isAttrs (lock.hexRepos or { }))
      || !builtins.isAttrs (lock.outputs or { })
    then
      throw "mix-purifier: ${file} is malformed. ${fix}"
    else
      {
        inherit (lock) version;
        git = lock.git or { };
        hexRepos = lock.hexRepos or { };
        outputs = lock.outputs or null;
      };
in
if lockFile == null then
  {
    version = supportedVersion;
    git = { };
    hexRepos = { };
    outputs = null;
  }
else
  checked
