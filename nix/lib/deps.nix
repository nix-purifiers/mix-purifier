# SPDX-License-Identifier: MIT
#
# The deps/ directory of a Mix project, built from the entries of its lock
# (read-lock.nix): what `mix deps.get` leaves behind, made without the
# network and without Hex's registry.
#
# Each Hex package is unpacked by nix/hex-unpack.exs, which uses Hex's own
# tarball code and writes Hex's `.hex` marker. Each git dependency is its
# checkout with a minimal `.git` directory: a `HEAD` naming the locked
# commit and a `config` naming the origin. Those are the two things Mix
# asks git when it checks that a git dependency matches mix.lock, so
# `mix deps` reports every dependency as locked and fetched.
#
# buildMixProject passes this directory to nixpkgs' mixRelease, and
# `mix-purifier prefetch` copies it into a project's deps/.
{
  lib,
  runCommand,
  beamPackages,
  # The shared purifier library's fetchEntry, given its package set: it
  # turns one download entry into a store path.
  fetchEntry,
}:
# The lock's entries for this system, from lib.purifier.entriesFor.
entries:
let
  hexEntries = lib.filter (entry: entry ? url) entries;
  gitEntries = lib.filter (entry: entry ? git) entries;

  hexPackage =
    entry:
    let
      inherit (entry) mix;
    in
    runCommand "mix-purifier-hex-${mix.name}-${mix.version}"
      {
        nativeBuildInputs = [ beamPackages.elixir ];
        ERL_LIBS = "${beamPackages.hex}/lib/erlang/lib";
        LANG = "C.UTF-8";
      }
      ''
        elixir ${../hex-unpack.exs} ${fetchEntry entry} $out \
          ${lib.escapeShellArgs [
            mix.name
            mix.version
            mix.innerChecksum
            mix.outerChecksum
            mix.repo
          ]}
      '';

  copyHex = entry: ''
    cp -r ${hexPackage entry} "$out"/${lib.escapeShellArg entry.mix.key}
  '';

  copyGit =
    entry:
    let
      dest = "$out/" + lib.escapeShellArg entry.mix.key;
    in
    ''
      cp -r ${fetchEntry entry} ${dest}
      chmod -R u+w ${dest}
      mkdir -p ${dest}/.git/objects ${dest}/.git/refs
      printf '%s\n' ${lib.escapeShellArg entry.mix.rev} > ${dest}/.git/HEAD
      printf '[remote "origin"]\n\turl = %s\n' ${lib.escapeShellArg entry.mix.url} > ${dest}/.git/config
    '';
in
runCommand "mix-purifier-deps"
  {
    # Each Hex package, unpacked, by its key in mix.lock.
    passthru.hexPackages = lib.listToAttrs (
      map (entry: lib.nameValuePair entry.mix.key (hexPackage entry)) hexEntries
    );
  }
  ''
    mkdir $out
    ${lib.concatMapStrings copyHex hexEntries}
    ${lib.concatMapStrings copyGit gitEntries}
  ''
