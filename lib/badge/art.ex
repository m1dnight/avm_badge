defmodule Badge.Art do
  @moduledoc """
  Large monochrome pictures, read from the assets partition and drawn at 2x.

  Each picture in `assets/art` is stored at half size once per glyph tint,
  named `<name>@<width>x<height>.<rrggbb>.rgba`, made by `tools/icons.py`
  from `assets/src/art`. Names and sizes are fixed at compile time; the
  bytes come from the assets partition when `image/2` is called, so it is
  `nil` on a badge without one. The same trick as the splash logo: a quarter
  of the bytes for the same picture on screen.
  """

  alias Badge.Icons

  @compile {:no_warn_undefined, :atomvm}

  @dir Path.expand("../../assets/art", __DIR__)

  # The directory itself, so adding or removing art recompiles this module.
  @external_resource @dir

  @files Enum.sort(Path.wildcard(Path.join(@dir, "*.rgba")))

  @files != [] || raise "no art in #{@dir} — run tools/icons.py"

  for file <- @files do
    @external_resource file
  end

  @scale 2

  # Parsed and checked on the host, where the full standard library is available.
  @parsed (for path <- @files do
             base = Path.basename(path, ".rgba")

             {name, width, height, tint} =
               with [stem, tint] <- String.split(base, "."),
                    [name, dimensions] <- String.split(stem, "@"),
                    [width, height] <- String.split(dimensions, "x") do
                 {String.to_atom(name), String.to_integer(width), String.to_integer(height),
                  String.to_integer(tint, 16)}
               else
                 _ -> raise "art #{base}: expected <name>@<width>x<height>.<rrggbb>"
               end

             size = byte_size(File.read!(path))

             size == width * height * 4 ||
               raise "art #{base}: #{size} bytes, expected #{width * height * 4}"

             {name, width, height, tint, ~c"art/" ++ String.to_charlist(Path.basename(path))}
           end)

  @art Enum.reduce(@parsed, %{}, fn {name, width, height, tint, path}, acc ->
         {^width, ^height, tints} = Map.get(acc, name, {width, height, %{}})
         Map.put(acc, name, {width, height, Map.put(tints, tint, path)})
       end)

  for {name, {_width, _height, tints}} <- @art, tint <- Icons.tints() do
    Map.has_key?(tints, tint) ||
      raise "art #{name}: no file for tint #{Integer.to_string(tint, 16)} — run tools/icons.py"
  end

  @names Enum.sort(Map.keys(@art))

  @doc "Every picture's name, sorted."
  def names, do: @names

  @doc "How many screen pixels one stored pixel is drawn as."
  def scale, do: @scale

  @doc "The picture's `{width, height}` as stored, or nil if there is no such picture."
  def size(name)

  for {name, {width, height, _tints}} <- @art do
    def size(unquote(name)), do: {unquote(width), unquote(height)}
  end

  def size(_name), do: nil

  @doc "The picture as an AtomGL image in `tint`, one of `Badge.Icons.tints/0`, or `nil`."
  @spec image(atom, integer) :: {:rgba8888, pos_integer, pos_integer, binary} | nil
  def image(name, tint)

  for {name, {width, height, tints}} <- @art, {tint, path} <- tints do
    def image(unquote(name), unquote(tint)) do
      image(read(unquote(path)), unquote(width), unquote(height))
    end
  end

  def image(_name, _tint), do: nil

  defp image(bytes, width, height) when is_binary(bytes), do: {:rgba8888, width, height, bytes}
  defp image(_absent, _width, _height), do: nil

  defp read(path) do
    :atomvm.read_priv(:assets, path)
  catch
    _kind, _error -> :undefined
  end

  @doc "A display item drawing `image` at 2x with its top-left corner at `x, y`, blended onto `bg`."
  @spec item(integer, integer, integer, tuple) :: tuple
  def item(x, y, bg, {:rgba8888, width, height, _bytes} = image) do
    {:scaled_cropped_image, x, y, width * @scale, height * @scale, bg, 0, 0, @scale, @scale, [],
     image}
  end
end
