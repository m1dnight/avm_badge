defmodule Mix.Tasks.Badge.Fit do
  @shortdoc "Fails if a packed image outgrows its partition"

  @moduledoc """
  Checks `avm_badge.avm` against the `main.avm` slot and, when it exists,
  `assets.avm` against the assets partition. The flash alias runs it after
  packing, since esptool writes past a partition without complaint and the
  badge then boot-loops.

      mix badge.fit
  """

  use Mix.Task

  # Partition sizes from the base image's table, listed in README.md.
  @slots [{"avm_badge.avm", "main.avm", 0xA4000}, {"assets.avm", "assets.avm", 0x40000}]

  @impl Mix.Task
  def run(_args) do
    for {file, label, size} <- @slots, File.exists?(file) do
      used = File.stat!(file).size

      Mix.shell().info("#{file}: #{used} of #{size} bytes in #{label}, #{size - used} free")

      if used > size, do: Mix.raise("#{file} overflows #{label} by #{used - size} bytes")
    end

    :ok
  end
end
