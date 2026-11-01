# SPDX-License-Identifier: MIT
#
# Fetches one download entry. A file entry is fetched with fetchurl from
# its URL, then from its mirrors, and a git entry with fetchgit, so the
# hash of a git entry is the one nix-prefetch-git reports.
{ fetchurl, fetchgit }:
entry:
if entry ? url then
  fetchurl {
    urls = [ entry.url ] ++ entry.mirrors;
    inherit (entry) hash;
    name = baseNameOf entry.path;
  }
else
  fetchgit {
    inherit (entry.git) url rev;
    fetchSubmodules = entry.git.submodules;
    inherit (entry.git) leaveDotGit;
    inherit (entry) hash;
  }
