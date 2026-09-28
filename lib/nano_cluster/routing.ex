defmodule NanoCluster.Routing do
  @moduledoc """
  Distance-vector routing table over the mesh's active links.

  If we have a network like A -> B -> C, the table for A will look like this:

  ```
  %{
    "A" => %{next_hop: "A", hops: 0},
    "B" => %{next_hop: "B", hops: 1},
    "C" => %{next_hop: "B", hops: 2}
  }
  ```
  """

  # Hop counts at or past this are "unreachable". It bounds count-to-infinity
  # if a loop ever forms, and no sane mesh of ESP32s is this deep.
  @max_hops 16

  @typedoc "An eight-byte node token."
  @type id :: <<_::64>>

  @typedoc "One entry: which neighbour to send to, how far, and when it was last confirmed."
  @type route :: %{next_hop: id(), hops: non_neg_integer(), last_seen: integer()}

  @typedoc "What a neighbour tells us, and what we tell a neighbour."
  @type advertisement :: [{id(), non_neg_integer()}]

  @type t :: %__MODULE__{self: id(), routes: %{id() => route()}}

  @enforce_keys [:self]
  defstruct [:self, routes: %{}]

  @spec max_hops() :: pos_integer()
  def max_hops do
    @max_hops
  end

  @doc "A table that knows only this node, at zero hops from itself."
  @spec new(id(), integer()) :: t()
  def new(self, now) do
    %__MODULE__{self: self, routes: %{self => %{next_hop: self, hops: 0, last_seen: now}}}
  end

  @doc """
  Records a direct link to an active neighbour. Idempotent, so the caller can
  do this every tick for every active peer: it also refreshes the entry.
  """
  @spec add_direct_neighbour(t(), id(), integer()) :: t()
  def add_direct_neighbour(%__MODULE__{} = table, id, now) do
    store_route(table, id, %{next_hop: id, hops: 1, last_seen: now})
  end

  @doc """
  Forgets everything that went through a neighbour whose link is gone. If a
  neighbour had routes to a list of nodes, all routes that have the next hop
  value of this node are dropped.
  """
  @spec remove_direct_neighbour(t(), id()) :: t()
  def remove_direct_neighbour(%__MODULE__{} = table, id) do
    routes =
      Enum.reduce(table.routes, %{}, fn {dest, route}, kept ->
        if route.next_hop == id do
          kept
        else
          Map.put(kept, dest, route)
        end
      end)

    %{table | routes: routes}
  end

  @doc """
  Merge an advertised table with our own table.

   - If the advertised table announces a node that is too far away, we delete
     the route to that device that goes through the new announcement. E.g., Z
     was reachable via B using 10 hops. If B announces Z takes 11 hops now, we
     delete the path to Z via B.
   - If we had a route to another node via a proxy, we update it with the
     announced table. Maybe that proxy had its table rebuilt.
   - If we had a faster route already, we ignore the entry.
   - Otherwise we put the new route in.
  """
  @spec merge(t(), id(), advertisement(), integer()) :: t()
  def merge(%__MODULE__{} = table, from, advertised, now) do
    Enum.reduce(advertised, table, fn {dest, hops}, acc ->
      learn(acc, from, dest, hops + 1, now)
    end)
  end

  defp learn(%__MODULE__{self: self} = table, _from, self, _cost, _now) do
    table
  end

  defp learn(table, from, dest, cost, _now) when cost >= @max_hops do
    case table.routes do
      %{^dest => %{next_hop: ^from}} ->
        %{table | routes: Map.delete(table.routes, dest)}

      _other_or_none ->
        table
    end
  end

  defp learn(table, from, dest, cost, now) do
    case table.routes do
      %{^dest => %{next_hop: ^from}} ->
        store_route(table, dest, %{next_hop: from, hops: cost, last_seen: now})

      %{^dest => %{hops: current}} when current <= cost ->
        table

      _better_or_new ->
        store_route(table, dest, %{next_hop: from, hops: cost, last_seen: now})
    end
  end

  @doc """
  The table we want to send to `to`. It will contain all destination we know,
  except the ones that go through `to`.
  """
  @spec advertisement(t(), id()) :: advertisement()
  def advertisement(%__MODULE__{} = table, to) do
    Enum.reduce(table.routes, [], fn {dest, route}, acc ->
      if route.next_hop == to and dest != table.self do
        acc
      else
        [{dest, route.hops} | acc]
      end
    end)
  end

  @doc """
  Garbage collects routes that have not been refreshed in time.
  """
  @spec expire(t(), non_neg_integer(), integer()) :: t()
  def expire(%__MODULE__{self: self} = table, timeout, now) do
    routes =
      Enum.reduce(table.routes, %{}, fn {dest, route}, kept ->
        if dest != self and now - route.last_seen > timeout do
          kept
        else
          Map.put(kept, dest, route)
        end
      end)

    %{table | routes: routes}
  end

  @doc "The neighbour to hand a message for `dest` to, or `:unreachable`."
  @spec proxy_for(t(), id()) :: {:ok, id()} | :unreachable
  def proxy_for(%__MODULE__{} = table, dest) do
    case table.routes do
      %{^dest => %{next_hop: next_hop}} ->
        {:ok, next_hop}

      _unknown ->
        :unreachable
    end
  end

  @doc "Every known destination with its hop count, nearest first."
  @spec destinations(t()) :: [{id(), non_neg_integer()}]
  def destinations(%__MODULE__{} = table) do
    # :lists.sort rather than Enum.sort_by, which AtomVM's Elixir lib lacks.
    table.routes
    |> Enum.map(fn {dest, route} -> {route.hops, dest} end)
    |> :lists.sort()
    |> Enum.map(fn {hops, dest} -> {dest, hops} end)
  end

  defp store_route(table, dest, route) do
    %{table | routes: Map.put(table.routes, dest, route)}
  end
end
