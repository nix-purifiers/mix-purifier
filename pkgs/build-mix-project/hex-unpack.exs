# SPDX-License-Identifier: MIT
#
# Unpacks one Hex package from mix.lock into a dependency directory, the way
# `mix deps.get` does, without Hex's registry.
#
# Hex's checkout checks a tarball's checksums against the registry, so it
# needs the registry offline. This script checks them against the lock
# entry instead, which holds both checksums. It unpacks with Hex's own
# tarball code and writes the same `.hex` marker that Hex writes, so Mix
# sees a dependency that `mix deps.get` fetched.
#
# Usage: elixir hex-unpack.exs TARBALL DEST NAME VERSION INNER OUTER REPO
# Hex itself must be on the code path (ERL_LIBS).

[tarball, dest, name, version, inner_checksum, outer_checksum, repo] = System.argv()

unpacked = Hex.Tar.unpack!(tarball, dest)

for {kind, expected, actual} <- [
      {"inner", inner_checksum, unpacked.inner_checksum},
      {"outer", outer_checksum, unpacked.outer_checksum}
    ] do
  actual = Base.encode16(actual, case: :lower)

  if actual != expected do
    raise "#{name} #{version}: the #{kind} checksum is #{actual}, but mix.lock locks #{expected}"
  end
end

managers =
  unpacked.metadata
  |> Hex.SCM.guess_build_tools()
  |> Enum.map(&String.to_atom/1)
  |> Enum.sort()

manifest = %{
  name: name,
  version: version,
  inner_checksum: inner_checksum,
  outer_checksum: outer_checksum,
  repo: repo,
  managers: managers
}

# Hex compares markers by their decoded term. The deterministic encoding
# sorts the map's keys, so the marker's bytes are the same on every machine.
File.write!(
  Path.join(dest, ".hex"),
  :erlang.term_to_binary({{:hex, 2, 0}, manifest}, [:deterministic])
)
