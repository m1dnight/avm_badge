defmodule Badge.Page.MeshTest do
  use ExUnit.Case, async: true

  alias Badge.Page.Mesh
  alias Badge.Theme

  defp status(overrides) do
    Map.merge(%{state: :off, node: nil, reason: nil, routed: 0, peers: []}, overrides)
  end

  defp page(overrides), do: %{Mesh.init() | status: status(overrides)}

  defp up(overrides \\ %{}) do
    page(Map.merge(%{state: :up, node: "4E43443A", routed: 1}, overrides))
  end

  defp peer(address, phase) do
    %{id: "A1B2C3D4", address: address, port: 4573, phase: phase}
  end

  defp bodies(state) do
    for {:text, _x, _y, _f, _c, _b, body} <- Mesh.render(state), do: body
  end

  defp says?(state, text) do
    :lists.any(fn body -> :binary.match(body, text) != :nomatch end, bodies(state))
  end

  describe "identity" do
    test "names itself for the home grid" do
      assert Mesh.title() == "Mesh"
    end

    test "starts with nothing known, so the first tick fills it in" do
      assert Mesh.init().status == nil
    end

    test "renders before the first tick rather than crashing" do
      assert says?(Mesh.init(), "starting")
    end
  end

  describe "state" do
    test "says what wifi is doing while it waits" do
      assert says?(page(%{state: :waiting, reason: "wifi connecting"}), "wifi connecting")
    end

    test "says discovery is up once it runs" do
      assert says?(up(), "up")
    end

    test "shows a failure reason" do
      assert says?(page(%{state: :failed, reason: "eaddrinuse"}), "eaddrinuse")
    end

    test "clips a reason too long for the panel" do
      state = page(%{state: :failed, reason: :binary.copy("x", 60)})

      assert :lists.all(fn body -> byte_size(body) <= 30 end, bodies(state))
    end
  end

  describe "the node" do
    test "shows its own id, so it can be told apart on another badge" do
      assert says?(up(), "4E43443A")
    end

    test "counts the nodes it can route to" do
      assert says?(up(%{routed: 4}), "4 nodes")
    end

    test "has no id or routes to show while discovery is down" do
      refute says?(page(%{}), "nodes")
    end
  end

  describe "peers" do
    test "says so when nobody has been found yet" do
      assert says?(up(), "nobody yet")
    end

    test "lists each peer's address and the phase of its handshake" do
      state = up(%{peers: [peer("192.168.1.23", :active), peer("192.168.1.24", :potential)]})

      assert says?(state, "2")
      assert says?(state, "192.168.1.23")
      assert says?(state, "active")
      assert says?(state, "192.168.1.24")
      assert says?(state, "potential")
    end

    test "puts each phase on its address's row" do
      state = up(%{peers: [peer("192.168.1.23", :active), peer("192.168.1.24", :joining)]})

      rows =
        for {:text, _x, y, _f, _c, _b, body} <- Mesh.render(state),
            body == "192.168.1.24" or body == "joining",
            do: y

      assert [y, y] = rows
    end

    test "lists nothing while discovery is down" do
      refute says?(page(%{peers: [peer("192.168.1.23", :active)]}), "192.168.1.23")
    end
  end

  describe "keys" do
    test "ignores every key, so the arrows and escape still navigate" do
      assert Mesh.handle_key({:move, :up}, up()) == :ignore
      assert Mesh.handle_key({:char, ?a}, up()) == :ignore
      assert Mesh.handle_key({:nav, :home}, up()) == :ignore
    end
  end

  describe "chrome" do
    test "draws nothing above the content top" do
      state = up(%{peers: [peer("192.168.1.23", :active)]})

      for {:text, _x, y, _f, _c, _b, _body} <- Mesh.render(state) do
        assert y >= Theme.content_top()
      end
    end
  end
end
