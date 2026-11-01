# SPDX-License-Identifier: MIT
#
# The part of `mix-purifier lock` that asks Mix about the project in the
# current directory. It prints, as JSON, what the lock run records and what
# it fetches:
#
#   {
#     "outputs": {
#       "app": "<app>" | null,           the root application; null for an umbrella
#       "version": "<version>" | null,   the root project's version
#       "apps": {"<app>": {"path": "<dir>", "version": "<version>"}},
#                                        the project's own applications
#       "releases": ["<name>", …],       what `mix release` builds
#       "escripts": ["<name>", …],       what `mix escript.build` builds
#       "package": {"name": …, "version": …} | null,
#                                        what `mix hex.build` builds
#       "definitionFiles": {"<path>": "<sha256>"}
#                                        each mix.exs read, so a build can tell
#                                        that one changed since the lock
#     },
#     "git": [{"key", "url", "rev", "submodules"}, …],
#                                        the git dependencies in mix.lock
#     "hexRepoPackages": [{"key", "name", "version", "repo", "outerChecksum"}, …]
#                                        the Hex packages from repositories
#                                        other than hexpm
#   }
#
# mix.exs and mix.lock are Elixir code, and Nix reads only JSON and TOML, so
# the lock run records the outputs in mix-purifier.lock.json, and
# buildMixProject exposes one attribute per output from it.
#
# Run it with MIX_ENV set to the environment the builds use.

Mix.start()

sha256 = fn path -> Base.encode16(:crypto.hash(:sha256, File.read!(path)), case: :lower) end

info =
  Mix.Project.in_project(:mix_purifier_project, ".", fn _module ->
    config = Mix.Project.config()
    umbrella? = Mix.Project.umbrella?()

    apps =
      if umbrella? do
        for {app, path} <- Mix.Project.apps_paths(), into: %{} do
          version =
            Mix.Project.in_project(app, path, fn _module -> Mix.Project.config()[:version] end)

          {app, %{path: Path.relative_to_cwd(path), version: version}}
        end
      else
        %{config[:app] => %{path: ".", version: config[:version]}}
      end

    releases =
      case Keyword.keys(config[:releases] || []) do
        [] when not umbrella? -> [config[:app]]
        names -> names
      end

    escripts =
      case config[:escript] do
        nil -> []
        escript -> [escript[:name] || config[:app]]
      end

    package =
      if not umbrella? and (config[:package] || config[:description]) do
        %{name: (config[:package] || [])[:name] || config[:app], version: config[:version]}
      end

    definition_files =
      for {_app, %{path: path}} <- apps, path != ".", into: %{"mix.exs" => sha256.("mix.exs")} do
        file = Path.join(path, "mix.exs")
        {file, sha256.(file)}
      end

    lock = Mix.Dep.Lock.read()

    git =
      for {key, {:git, url, rev, opts}} <- lock do
        %{key: key, url: url, rev: rev, submodules: Keyword.get(opts, :submodules, false)}
      end

    hex_repo_packages =
      for {key, {:hex, name, version, _inner, _managers, _deps, repo, outer}} <- lock,
          repo != "hexpm" do
        %{key: key, name: name, version: version, repo: repo, outerChecksum: outer}
      end

    %{
      outputs: %{
        app: if(umbrella?, do: nil, else: config[:app]),
        version: config[:version],
        apps: apps,
        releases: releases,
        escripts: escripts,
        package: package,
        definitionFiles: definition_files
      },
      git: git,
      hexRepoPackages: hex_repo_packages
    }
  end)

IO.puts(JSON.encode!(info))
