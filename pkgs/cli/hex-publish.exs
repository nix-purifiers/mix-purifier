# SPDX-License-Identifier: MIT
#
# The Hex part of `mix-purifier publish`: publishes a package tarball and
# its documentation that Nix built, the way `mix hex.publish` publishes the
# ones it builds itself.
#
# `mix hex.publish` builds the package tarball in memory from the project's
# source, with the same code `mix hex.build` uses, and Hex builds tarballs
# reproducibly. So the tarball buildMixProject's `hexPackage` holds is the
# one `mix hex.publish` would send. This script sends it, and the docs that
# buildMixProject's `docs` holds, through Hex's own API calls, with the
# user's usual Hex credentials.
#
# Usage: elixir hex-publish.exs TARBALL [--docs DIR] [--organization ORG]
#                                       [--replace] [--yes]
# Hex itself must be on the code path (ERL_LIBS).

Mix.start()
Hex.start()

{opts, [tarball_path]} =
  OptionParser.parse!(System.argv(),
    strict: [docs: :string, organization: :string, replace: :boolean, yes: :boolean]
  )

tarball = File.read!(tarball_path)
%{metadata: metadata} = Hex.Tar.unpack!({:binary, tarball}, :memory)
name = metadata["name"]
version = metadata["version"]
organization = opts[:organization]
where = if organization, do: "the Hex organization #{organization}", else: "hexpm"

unless opts[:yes] || Mix.shell().yes?("Publish #{name} #{version} to #{where}?") do
  Mix.raise("Publishing cancelled")
end

auth = Hex.WorkloadIdentity.auth!(organization || "hexpm", name)
no_progress = fn _ -> nil end

case Hex.API.Release.publish(organization, tarball, auth, no_progress, opts[:replace] || false) do
  {:ok, {code, _headers, _body}} when code in 200..299 ->
    checksum = Base.encode16(:crypto.hash(:sha256, tarball), case: :lower)
    Hex.Shell.info("Published #{name} #{version} (#{checksum})")

  other ->
    Hex.Utils.print_error_result(other)
    Mix.raise("Publishing #{name} #{version} failed")
end

if docs = opts[:docs] do
  files =
    "#{docs}/**"
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&{String.to_charlist(Path.relative_to(&1, docs)), File.read!(&1)})

  {:ok, docs_tarball} = :mix_hex_tarball.create_docs(files)

  case Hex.API.ReleaseDocs.publish(organization, name, version, docs_tarball, auth, no_progress) do
    {:ok, {code, _headers, _body}} when code in 200..299 ->
      Hex.Shell.info("Published the documentation of #{name} #{version}")

    other ->
      Hex.Utils.print_error_result(other)
      Mix.raise("Publishing the documentation of #{name} #{version} failed")
  end
end
