# SPDX-License-Identifier: MIT
#
# Reads a project's application name and version from its mix.exs, for the
# package name and version a build takes when the caller gives none.
#
# mix.exs is Elixir code, so this reads only the common forms:
# `app: :name`, and `version: "x.y.z"` or `version: @version` with
# `@version "x.y.z"`. A project written otherwise, such as an umbrella
# root, gives `pname` and `version` to buildMixProject.
{ lib }:
mixExs:
let
  lines = lib.splitString "\n" (builtins.readFile mixExs);
  matching = regex: lib.filter (match: match != null) (map (builtins.match regex) lines);
  # The first capture of the first line that matches, or null.
  first =
    regex:
    let
      matches = matching regex;
    in
    if matches == [ ] then null else builtins.head (builtins.head matches);

  app = first " *app: :([a-z0-9_]+),?.*";
  literalVersion = first " *version: \"([^\"]+)\",?.*";
  attributeVersion =
    if matching " *version: @version,?.*" != [ ] then first " *@version \"([^\"]+)\".*" else null;
in
{
  inherit app;
  version = if literalVersion != null then literalVersion else attributeVersion;
}
