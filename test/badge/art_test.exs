defmodule Badge.ArtTest do
  use ExUnit.Case, async: true

  alias Badge.Art
  alias Badge.Icons

  describe "the set" do
    test "knows the share art, stored at half size" do
      assert Art.names() == [:badge_share]
      assert Art.size(:badge_share) == {72, 32}
      assert Art.scale() == 2
      assert Art.size(:nonesuch) == nil
    end
  end

  describe "image/2" do
    test "reads the file for each glyph tint from the assets" do
      for tint <- Icons.tints() do
        assert {:rgba8888, 72, 32, pixels} = Art.image(:badge_share, tint)
        assert byte_size(pixels) == 72 * 32 * 4
        assert <<r, g, b, _alpha, _rest::binary>> = pixels
        assert r * 0x10000 + g * 0x100 + b == tint
      end
    end

    test "is nil for art or a tint that does not exist" do
      assert Art.image(:nonesuch, 0xFFFFFF) == nil
      assert Art.image(:badge_share, 0x123456) == nil
    end
  end

  describe "item/4" do
    test "draws the whole picture at 2x, blended onto the background" do
      image = {:rgba8888, 72, 32, <<>>}

      assert Art.item(10, 20, 0xABCDEF, image) ==
               {:scaled_cropped_image, 10, 20, 144, 64, 0xABCDEF, 0, 0, 2, 2, [], image}
    end
  end
end
