# SPDX-License-Identifier: MIT
#
# The Hex part of `mix-purifier lock`: resolves each Hex repository other
# than hexpm, and downloads its locked tarballs with Hex.
#
# Hex resolves a repository from the user's own configuration (`mix
# hex.repo`, `mix hex.organization`), with the user's credentials. This
# script prints, as JSON, each repository's URL and the path of each
# tarball it downloaded and checked against mix.lock:
#
#   {"hexRepos": {"<repo>": "<url>"}, "tarballs": ["<dir>/<name>-<version>.tar", …]}
#
# `mix-purifier lock` records the URLs in mix-purifier.lock.json and adds
# the tarballs to the Nix store, so a build fetches nothing that needs the
# credentials.
#
# Usage: elixir hex-lock.exs ENTRIES_JSON DIR
# ENTRIES_JSON is the list of Hex entries of mix.lock that nix/lib/mix-lock.nix
# reads. Hex itself must be on the code path (ERL_LIBS).

[entries_json, dir] = System.argv()

Mix.start()
Hex.start()

entries =
  entries_json
  |> File.read!()
  |> JSON.decode!()
  |> Enum.reject(&(&1["repo"] == "hexpm"))

repo_url = fn repo ->
  config = Hex.Repo.get_repo(repo)

  case config[:repo_organization] do
    nil -> config.url
    organization -> config.url <> "/repos/" <> organization
  end
end

hex_repos = Map.new(entries, &{&1["repo"], repo_url.(&1["repo"])})

tarballs =
  for entry <- entries do
    %{"repo" => repo, "name" => name, "version" => version} = entry
    path = Path.join(dir, "#{name}-#{version}.tar")
    cached = Hex.SCM.cache_path(repo, name, version)

    tarball =
      if File.regular?(cached) do
        File.read!(cached)
      else
        case Hex.Repo.get_tarball(repo, name, version) do
          {:ok, {200, _headers, body}} ->
            body

          other ->
            Hex.Utils.print_error_result(other)
            Mix.raise("Downloading #{name} #{version} from the Hex repository #{repo} failed")
        end
      end

    checksum = Base.encode16(:crypto.hash(:sha256, tarball), case: :lower)

    if checksum != entry["outerChecksum"] do
      Mix.raise(
        "#{name} #{version} from #{repo} has the checksum #{checksum}, " <>
          "but mix.lock locks #{entry["outerChecksum"]}"
      )
    end

    File.write!(path, tarball)
    path
  end

IO.puts(JSON.encode!(%{hexRepos: hex_repos, tarballs: tarballs}))
