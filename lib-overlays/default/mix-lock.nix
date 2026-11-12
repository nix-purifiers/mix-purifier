# SPDX-License-Identifier: MIT
#
# Reads mix.lock at evaluation time, without import-from-derivation.
#
# Mix writes one lock entry per line, as an Elixir term. A Hex entry is
#
#   "key": {:hex, :name, "version", "inner", [managers], [deps], "repo", "outer"},
#
# and a git entry is
#
#   "key": {:git, "url", "rev", [options]},
#
# `key` is the dependency's application name, which names its directory
# under deps/. `name` is the Hex package, which names its tarball. `outer`
# is the SHA-256 of the tarball and `inner` the checksum of its contents.
#
# The result is { hex = [ … ]; git = [ … ]; unreadable = [ <line> ]; }.
# readLock reports each unreadable line as a problem, so a build stops at a
# lock this reader cannot read.
{ lib }:
lockFile:
let
  lines = lib.filter (line: line != "" && line != "%{" && line != "}") (
    lib.splitString "\n" (builtins.readFile lockFile)
  );

  hexEntry = builtins.match " *\"([^\"]+)\": \\{:hex, :\"?([^,\"]+)\"?, \"([^\"]+)\", \"([0-9a-f]{64})\", .*, \"([^\"]+)\", \"([0-9a-f]{64})\"},?";
  gitEntry = builtins.match " *\"([^\"]+)\": \\{:git, \"([^\"]+)\", \"([0-9a-f]{40})\", \\[(.*)]},?";

  parse =
    line:
    let
      hex = hexEntry line;
      git = gitEntry line;
    in
    if hex != null then
      {
        kind = "hex";
        key = builtins.elemAt hex 0;
        name = builtins.elemAt hex 1;
        version = builtins.elemAt hex 2;
        innerChecksum = builtins.elemAt hex 3;
        repo = builtins.elemAt hex 4;
        outerChecksum = builtins.elemAt hex 5;
      }
    else if git != null then
      {
        kind = "git";
        key = builtins.elemAt git 0;
        url = builtins.elemAt git 1;
        rev = builtins.elemAt git 2;
        submodules = builtins.match ".*submodules: true.*" (builtins.elemAt git 3) != null;
      }
    else
      {
        kind = "unreadable";
        inherit line;
      };

  entries = map parse lines;
in
{
  hex = lib.filter (entry: entry.kind == "hex") entries;
  git = lib.filter (entry: entry.kind == "git") entries;
  unreadable = map (entry: entry.line) (lib.filter (entry: entry.kind == "unreadable") entries);
}
