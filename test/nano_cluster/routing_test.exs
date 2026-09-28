defmodule NanoCluster.RoutingTest do
  use ExUnit.Case

  alias NanoCluster.Routing

  @a "node000A"
  @b "node000B"
  @c "node000C"
  @d "node000D"

  test "a new table knows only itself" do
    table = Routing.new(@a, 0)
    assert Routing.destinations(table) == [{@a, 0}]
    assert Routing.proxy_for(table, @a) == {:ok, @a}
    assert Routing.proxy_for(table, @b) == :unreachable
  end

  test "an active neighbour is one hop away and refreshes on repeat" do
    table = @a |> Routing.new(0) |> Routing.add_direct_neighbour(@b, 10)
    assert %{next_hop: @b, hops: 1, last_seen: 10} = table.routes[@b]

    table = Routing.add_direct_neighbour(table, @b, 20)
    assert %{next_hop: @b, hops: 1, last_seen: 20} = table.routes[@b]
  end

  test "a line A-B-C converges: A reaches C through B in two hops" do
    a = @a |> Routing.new(0) |> Routing.add_direct_neighbour(@b, 0)

    b =
      @b
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@a, 0)
      |> Routing.add_direct_neighbour(@c, 0)

    c = @c |> Routing.new(0) |> Routing.add_direct_neighbour(@b, 0)

    # one tick: everyone advertises to their neighbours
    a = Routing.merge(a, @b, Routing.advertisement(b, @a), 1)
    c = Routing.merge(c, @b, Routing.advertisement(b, @c), 1)
    b = Routing.merge(b, @a, Routing.advertisement(a, @b), 1)
    b = Routing.merge(b, @c, Routing.advertisement(c, @b), 1)

    assert Routing.proxy_for(a, @c) == {:ok, @b}
    assert Routing.destinations(a) == [{@a, 0}, {@b, 1}, {@c, 2}]
    assert Routing.proxy_for(c, @a) == {:ok, @b}
    assert Routing.destinations(b) == [{@b, 0}, {@a, 1}, {@c, 1}]
  end

  test "split horizon: routes are not advertised back to the neighbour they go through" do
    a =
      @a
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@b, 0)
      |> Routing.merge(@b, [{@c, 1}], 0)

    assert Routing.proxy_for(a, @c) == {:ok, @b}

    to_b = Routing.advertisement(a, @b)
    assert {@a, 0} in to_b
    refute List.keymember?(to_b, @b, 0)
    refute List.keymember?(to_b, @c, 0)

    # a different neighbour hears about everything
    to_d = Routing.advertisement(a, @d)
    assert Enum.sort(to_d) == Enum.sort([{@a, 0}, {@b, 1}, {@c, 2}])
  end

  test "a cheaper path replaces a longer one, a longer path from elsewhere is ignored" do
    a =
      @a
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@b, 0)
      |> Routing.add_direct_neighbour(@d, 0)
      |> Routing.merge(@b, [{@c, 3}], 0)

    assert %{next_hop: @b, hops: 4} = a.routes[@c]

    a = Routing.merge(a, @d, [{@c, 1}], 1)
    assert %{next_hop: @d, hops: 2} = a.routes[@c]

    a = Routing.merge(a, @b, [{@c, 2}], 2)
    assert %{next_hop: @d, hops: 2, last_seen: 1} = a.routes[@c]
  end

  test "a worse path from the current next hop is believed" do
    a =
      @a
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@b, 0)
      |> Routing.merge(@b, [{@c, 1}], 0)

    a = Routing.merge(a, @b, [{@c, 5}], 1)
    assert %{next_hop: @b, hops: 6, last_seen: 1} = a.routes[@c]
  end

  test "unreachable from the current next hop drops the route, from anyone else is ignored" do
    a =
      @a
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@b, 0)
      |> Routing.merge(@b, [{@c, 1}], 0)

    a = Routing.merge(a, @d, [{@c, Routing.max_hops()}], 1)
    assert Routing.proxy_for(a, @c) == {:ok, @b}

    a = Routing.merge(a, @b, [{@c, Routing.max_hops() - 1}], 2)
    assert Routing.proxy_for(a, @c) == :unreachable
  end

  test "we never learn a route to ourselves" do
    a =
      @a
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@b, 0)
      |> Routing.merge(@b, [{@a, 1}], 0)

    assert %{next_hop: @a, hops: 0} = a.routes[@a]
  end

  test "losing a neighbour drops every route through it at once" do
    a =
      @a
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@b, 0)
      |> Routing.add_direct_neighbour(@d, 0)
      |> Routing.merge(@b, [{@c, 1}], 0)

    a = Routing.remove_direct_neighbour(a, @b)
    assert Routing.destinations(a) == [{@a, 0}, {@d, 1}]
  end

  test "stale routes expire, refreshed ones and ourselves stay" do
    a =
      @a
      |> Routing.new(0)
      |> Routing.add_direct_neighbour(@b, 0)
      |> Routing.merge(@b, [{@c, 1}], 0)

    a = Routing.add_direct_neighbour(a, @b, 80)

    a = Routing.expire(a, 30, 100)
    assert Routing.destinations(a) == [{@a, 0}, {@b, 1}]

    a = Routing.expire(a, 30, 1000)
    assert Routing.destinations(a) == [{@a, 0}]
  end
end
