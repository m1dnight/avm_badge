defmodule NanoCluster.Discovery do
  @moduledoc """
  Announces this node over UDP multicast and prints newly discovered peers.


  The process keeps track of 3 separate types of peers:
   - Active peers are ones we expected to be online and communicate with
     directly.
   - Pending peers are peers that are in the process of a handshake to be
     promoted to active peers.
   - Potential peers are ip addresses we know about, but keep as a backup if an
     active peer is expired.
  """
  use GenServer

  alias NanoCluster.Discovery.Packet
  alias NanoCluster.Mesh
  alias NanoCluster.Routing

  @typedoc "An eight-byte node token."
  @type id :: <<_::64>>

  @group {239, 255, 42, 99}
  @port 4573
  @interval 2000
  @peer_timeout 30_000
  @join_timeout 6000
  # Routes are re-advertised every tick; one not heard for this long is dropped.
  @route_timeout 10_000
  # Hops a message may take before it is dropped; bounds a message circling
  # while routing tables disagree.
  @message_ttl 16
  # Received messages kept for the API to show.
  @inbox_size 10

  @active_neighbours 2
  @potential_neighbours 2

  # A full node that receives a JOIN from a stranger normally rejects it. One
  # time in this many it instead evicts a random active neighbour and accepts.
  # A balanced mesh sends no JOINs to full nodes, so this never fires there; it
  # only moves links while some node has no room anywhere, so that a newcomer
  # or a rebooted node can work its way into a saturated mesh.
  @evict_one_in 8

  # A full node that keeps hearing a peer it has no route to is looking at a
  # partition: the peer is in another closed group. Once the peer has waited
  # longer than routes take to converge, one tick in this many the node evicts
  # an active neighbour and joins that peer, bridging the two groups. A whole
  # mesh has a route to every announcing peer, so this never fires there.
  @bridge_one_in 16
  @bridge_grace 10_000

  @spec start_link() :: GenServer.on_start()
  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "The UDP port discovery listens and announces on."
  @spec port() :: :inet.port_number()
  def port do
    @port
  end

  @doc "This node's id."
  @spec node() :: id()
  def node do
    GenServer.call(__MODULE__, :node)
  end

  @doc "Ids of every node with a known route, nearest first, excluding this one."
  @spec nodes() :: [id()]
  def nodes do
    GenServer.call(__MODULE__, :nodes)
  end

  @doc "Sends an opaque body to a node along the routing table. See `NanoCluster.Mesh`."
  @spec send_message(id(), binary()) :: :ok | {:error, :unreachable | :too_large}
  def send_message(destination, body) do
    GenServer.call(__MODULE__, {:send, destination, body})
  end

  @doc "The last few messages delivered to this node, newest first."
  @spec inbox() :: [map()]
  def inbox do
    GenServer.call(__MODULE__, :inbox)
  end

  @doc "Returns the routing table, including this node's own id and zero-hop entry."
  @spec routes() :: Routing.t()
  def routes do
    GenServer.call(__MODULE__, :routes)
  end

  @doc "Returns peers grouped into active, pending handshakes, and potential replacements."
  @spec peers() :: %{active: [map()], pending: [map()], potential: [map()]}
  def peers do
    GenServer.call(__MODULE__, :peers)
  end

  # ---------------------------------------------------------------------------#
  #                                Callbacks                                   #
  # ---------------------------------------------------------------------------#

  @impl GenServer
  def init(:ok) do
    token = :crypto.strong_rand_bytes(8)

    case open_socket() do
      {:ok, socket} ->
        # Listen before announcing so nodes starting together can hear each other.
        send(self(), :receive_packets)
        send(self(), :announce)

        state = %{
          socket: socket,
          token: token,
          evict_one_in: @evict_one_in,
          bridge_one_in: @bridge_one_in,
          peers: %{active: [], pending: [], potential: []},
          routes: Routing.new(token, :erlang.monotonic_time(:millisecond)),
          inbox: []
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:peers, _from, state) do
    {:reply, state.peers, state}
  end

  def handle_call(:routes, _from, state) do
    {:reply, state.routes, state}
  end

  def handle_call(:node, _from, state) do
    {:reply, state.token, state}
  end

  def handle_call(:nodes, _from, state) do
    nodes =
      state.routes
      |> Routing.destinations()
      |> Enum.reject(fn {id, _hops} -> id == state.token end)
      |> Enum.map(fn {id, _hops} -> id end)

    {:reply, nodes, state}
  end

  def handle_call(:inbox, _from, state) do
    {:reply, state.inbox, state}
  end

  def handle_call({:send, destination, body}, _from, state) do
    reply =
      if byte_size(body) > Packet.max_body() do
        {:error, :too_large}
      else
        packet = %Packet{
          token: state.token,
          type: :message,
          destination: destination,
          origin: state.token,
          ttl: @message_ttl,
          body: body
        }

        forward_message(state, packet)
      end

    {:reply, reply, state}
  end

  @impl GenServer
  def handle_info(:announce, state) do
    # garbage collect peers that are no longer live.
    state = garbage_collect_peers(state)

    # drop routes nobody advertised lately, and make sure every active peer is
    # in the table as a direct neighbour.
    state = garbage_collect_routes(state)

    # repeat the protocol message for the pending peers, in case the message was
    # lost before.
    Enum.each(state.peers.pending, fn peer ->
      type =
        case peer.phase do
          :joining -> :join
          :accepting -> :accept
        end

      send_packet(state, peer, type, peer.request)
    end)

    # Reconfirm each peer, and tell it what we can reach.
    Enum.each(state.peers.active, fn peer ->
      send_packet(state, peer, :confirm, peer.request)
      send_routes(state, peer)
    end)

    state = promote_peers(state)
    state = bridge_partition(state)

    send_packet(state, %{address: @group, port: @port}, :announce, <<0::32>>)
    :erlang.send_after(@interval, self(), :announce)
    {:noreply, state}
  end

  def handle_info(:receive_packets, state) do
    receive_packets(state, 16)
  end

  def handle_info({:"$socket", socket, :select, _ref}, %{socket: socket} = state) do
    receive_packets(state, 16)
  end

  def handle_info({:"$socket", socket, :abort, {_ref, reason}}, %{socket: socket} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :socket.close(state.socket)
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  # loop sover all the peers and expires ones that we have not seen in a timely manner.
  defp garbage_collect_peers(state) do
    now = :erlang.monotonic_time(:millisecond)

    peers = %{
      active: garbage_collect_peers(state.peers.active, @peer_timeout, now, state),
      pending: garbage_collect_peers(state.peers.pending, @join_timeout, now, state),
      potential: garbage_collect_peers(state.peers.potential, @peer_timeout, now, state)
    }

    # Expired active peers take their routes with them, now rather than after
    # the route timeout, so nothing is advertised or forwarded through a dead link.
    Enum.reduce(state.peers.active, %{state | peers: peers}, fn peer, acc ->
      if active_neighbour?(acc, peer.id) do
        acc
      else
        drop_neighbour_routes(acc, peer.id)
      end
    end)
  end

  # Forget every route that went through a neighbour whose link is gone.
  defp drop_neighbour_routes(state, id) do
    %{state | routes: Routing.remove_direct_neighbour(state.routes, id)}
  end

  defp garbage_collect_peers(peers, timeout, now, state) do
    {expired, live} = Enum.split_with(peers, fn peer -> now - peer.last_seen > timeout end)

    Enum.each(expired, fn peer ->
      {a, b, c, d} = peer.address
      :io.format(~c"Peer unreachable: ~B.~B.~B.~B:~B~n", [a, b, c, d, peer.port])

      if Map.has_key?(peer, :request) do
        send_packet(state, peer, :reject, peer.request)
      end
    end)

    live
  end

  # if we have room in the active peer set, and we have potential peers, promote
  # one potential to an active one.
  defp promote_peers(state) do
    if free_active_slots?(state) and state.peers.potential != [] do
      [peer | _] = state.peers.potential
      promote_peers(promote_peer(state, peer))
    else
      state
    end
  end

  # Start a handshake with a potential peer: send JOIN and reserve the slot.
  defp promote_peer(state, peer) do
    peer = %{peer | last_seen: :erlang.monotonic_time(:millisecond)}
    request = :crypto.strong_rand_bytes(4)
    send_packet(state, peer, :join, request)
    reserve(state, peer, request, :joining)
  end

  # If this full node has been hearing a peer it cannot route to for longer
  # than routes take to settle, the mesh is split. Roll the die; on a hit,
  # make room and join that peer to bridge the groups.
  defp bridge_partition(%{bridge_one_in: 0} = state) do
    state
  end

  defp bridge_partition(state) do
    now = :erlang.monotonic_time(:millisecond)

    stranded =
      Enum.find(state.peers.potential, fn peer ->
        now - peer.since >= @bridge_grace and
          Routing.proxy_for(state.routes, peer.id) == :unreachable
      end)

    <<random>> = :crypto.strong_rand_bytes(1)

    if stranded != nil and not free_active_slots?(state) and state.peers.active != [] and
         rem(random, state.bridge_one_in) == 0 do
      {a, b, c, d} = stranded.address
      :io.format(~c"Bridging to ~B.~B.~B.~B, no route to it~n", [a, b, c, d])

      state
      |> evict_random_active(stranded)
      |> promote_peer(stranded)
    else
      state
    end
  end

  # is there a free slot for an active peer (pending handshakes reserve a slot too)
  defp free_active_slots?(state) do
    length(state.peers.active) + length(state.peers.pending) < @active_neighbours
  end

  # is there a free slot for a potential peer
  defp free_potential_slots?(state) do
    length(state.peers.potential) < @potential_neighbours
  end

  # removes all stale routes from the routing table and updates the table with
  # our active peers.
  defp garbage_collect_routes(state) do
    now = :erlang.monotonic_time(:millisecond)
    routes = Routing.expire(state.routes, @route_timeout, now)

    routes =
      Enum.reduce(state.peers.active, routes, fn peer, acc ->
        Routing.add_direct_neighbour(acc, peer.id, now)
      end)

    %{state | routes: routes}
  end

  defp send_packet(state, peer, type, request) do
    deliver(state, peer, %Packet{token: state.token, type: type, request: request})
  end

  # Our routing advertisement for this neighbour, split horizon applied.
  defp send_routes(state, peer) do
    advertised = :lists.sublist(Routing.advertisement(state.routes, peer.id), Packet.max_routes())
    deliver(state, peer, %Packet{token: state.token, type: :routes, routes: advertised})
  end

  # Hands the packet to the active neighbour that proxies for its destination.
  defp forward_message(state, packet) do
    with {:ok, proxy} <- Routing.proxy_for(state.routes, packet.destination),
         %{} = peer <- Enum.find(state.peers.active, fn peer -> peer.id == proxy end) do
      deliver(state, peer, packet)
      :ok
    else
      _no_route_or_neighbour ->
        {:error, :unreachable}
    end
  end

  defp receive_message(state, packet) do
    entry = %{
      origin: packet.origin,
      hops: @message_ttl - packet.ttl,
      body: packet.body,
      received_at: :erlang.monotonic_time(:millisecond),
      delivered: Mesh.deliver(packet.body) == :ok
    }

    %{state | inbox: :lists.sublist([entry | state.inbox], @inbox_size)}
  end

  defp deliver(state, peer, packet) do
    :socket.sendto(state.socket, Packet.encode(packet), %{
      family: :inet,
      addr: peer.address,
      port: peer.port
    })
  end

  defp open_socket do
    with {:ok, socket} <- :socket.open(:inet, :dgram, :udp) do
      result =
        with :ok <- :socket.setopt(socket, {:socket, :reuseaddr}, true),
             :ok <- :socket.bind(socket, %{family: :inet, addr: {0, 0, 0, 0}, port: @port}) do
          :socket.setopt(socket, {:ip, :add_membership}, %{
            multiaddr: @group,
            interface: {0, 0, 0, 0}
          })
        end

      case result do
        :ok ->
          {:ok, socket}

        error ->
          :socket.close(socket)
          error
      end
    end
  end

  # Small batches allow announcements to run even while packets keep arriving.
  defp receive_packets(state, 0) do
    send(self(), :receive_packets)
    {:noreply, state}
  end

  # eats up all available packets on the socket and processes them. we process
  # them inline here to avoid building up a list of lots of packets and OOM-ing.
  defp receive_packets(state, remaining) do
    # Read an extra byte so oversized packets cannot look valid after truncation.
    case :socket.recvfrom(state.socket, Packet.max_size() + 1, :nowait) do
      {:ok, {source, data}} ->
        state =
          case Packet.decode(data) do
            {:ok, packet} ->
              handle_packet(state, source, packet)

            :error ->
              state
          end

        receive_packets(state, remaining - 1)

      {:select, _info} ->
        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  # Our own multicast announcements come back to us; ignore them.
  # Handling a packet follows the following rules.
  # - If the token is our own token, it's our own announce and we ignore it.
  # - If the packet is from another peer, we create a peer map and process the packet.
  defp handle_packet(%{token: token} = state, _source, %Packet{token: token}) do
    state
  end

  defp handle_packet(state, %{addr: address, port: port}, %Packet{} = packet) do
    peer = %{
      id: packet.token,
      address: address,
      port: port,
      last_seen: :erlang.monotonic_time(:millisecond)
    }

    state = apply_packet(packet, peer, state)
    promote_peers(state)
  end

  # Apply packet processes the incoming packet from another peer.
  # - If it's an announce message, we try to adopt the peer. This will put the
  #   peer in the potential, active, or pending peers.
  # - If it's a join message, the peer should be in the active+pending set.
  # - If it's an accept message, it's a peer we sent a join message to before.
  #   this means we can promote it to the active set.
  # - If it's a confirm message, the peer replied to our accept message and we
  #   are connected.
  # - If it's a reject, we can't connect to the peer and we remove it from all
  #   our active/pending sets.
  defp apply_packet(%Packet{type: :announce}, peer, state) do
    adopt_peer(state, peer)
  end

  # Messages only arrive from active neighbours, hop by hop. Ours are delivered
  # locally, the rest are forwarded along the routing table until the hop
  # budget runs out.
  defp apply_packet(%Packet{type: :message} = packet, peer, state) do
    cond do
      # if the message is not for an active neighbour of ours, drop it.
      not active_neighbour?(state, peer.id) ->
        state

      # if the message was sent to us, process it.
      packet.destination == state.token ->
        receive_message(state, packet)

      # if the message's TTL is 0, we don't want to deal with it anymore.
      packet.ttl <= 1 ->
        state

      # the message is forwarded to one of our neighbours to deal with it.
      true ->
        forward_message(state, %{packet | token: state.token, ttl: packet.ttl - 1})
        state
    end
  end

  # Only active neighbours are believed about what they can reach.
  defp apply_packet(%Packet{type: :routes, routes: advertised}, peer, state) do
    if active_neighbour?(state, peer.id) do
      now = :erlang.monotonic_time(:millisecond)
      %{state | routes: Routing.merge(state.routes, peer.id, advertised, now)}
    else
      state
    end
  end

  defp apply_packet(%Packet{type: :join, request: request}, peer, state) do
    case get_neighbour_info(state, peer.id) do
      # A repeat of a JOIN we already accepted: our ACCEPT was probably lost, so
      # send it again. This must not extend the reservation's timeout. The link
      # may already be active on our side if the repeat overtook the CONFIRM.
      %{request: ^request, phase: phase} when phase in [:accepting, :active] ->
        send_packet(state, peer, :accept, request)
        state

      # this node is pending and was alrady in the joining state, so we accept
      # their join. if this node is in our pending list, we also sent a join
      # reqauest. All nodes agree that the highest token will continue the
      # handshake. This avoids parallel handshakes.
      %{phase: :joining} when state.token > peer.id ->
        # Simultaneous joins: use the smaller node ID's request.
        accept_join(state, peer, request)

      # this neighbour was not known to us, so we were a potential peer and they
      # want to promote us to active. If we dont have an active slot available,
      # we reject the peer's join.
      nil ->
        cond do
          free_active_slots?(state) ->
            accept_join(state, peer, request)

          make_room?(state) ->
            state
            |> evict_random_active(peer)
            |> accept_join(peer, request)

          true ->
            send_packet(state, peer, :reject, request)
            state
        end

      _ ->
        send_packet(state, peer, :reject, request)
        state
    end
  end

  defp apply_packet(%Packet{type: :accept, request: request}, peer, state) do
    case get_neighbour_info(state, peer.id) do
      # The peer accepted our JOIN: confirm it and activate the link.
      %{request: ^request, phase: :joining} ->
        send_packet(state, peer, :confirm, request)
        promote_to_active_set(state, peer, request)

      # The link is already active on our side, but the peer repeats its ACCEPT
      # because our CONFIRM was lost. Send it again and refresh the link.
      %{request: ^request, phase: :active} ->
        send_packet(state, peer, :confirm, request)
        promote_to_active_set(state, peer, request)

      # Anything else is an ACCEPT we did not ask for: a stale one, or one for a
      # request where we are the acceptor ourselves. Only the initiator acts on ACCEPT.
      _ ->
        state
    end
  end

  defp apply_packet(%Packet{type: :confirm, request: request}, peer, state) do
    case get_neighbour_info(state, peer.id) do
      # We accepted the peer's JOIN and it confirms: the handshake is complete.
      %{request: ^request, phase: :accepting} ->
        promote_to_active_set(state, peer, request)

      # Active peers re-send CONFIRM every interval; this keeps the link alive.
      # The peer is added to the active set as if its a new one, which
      # implicitly updates its last seen state.
      %{request: ^request, phase: :active} ->
        promote_to_active_set(state, peer, request)

      # No reservation this CONFIRM can complete: we expired it, or we were never
      # the acceptor for this request. Tell the sender to drop its side of it.
      _ ->
        send_packet(state, peer, :reject, request)
        state
    end
  end

  defp apply_packet(%Packet{type: :reject, request: request}, peer, state) do
    case get_neighbour_info(state, peer.id) do
      %{request: ^request} ->
        peers = %{
          state.peers
          | active: remove_peer(state.peers.active, peer.id),
            pending: remove_peer(state.peers.pending, peer.id)
        }

        drop_neighbour_routes(%{state | peers: peers}, peer.id)

      _ ->
        state
    end
  end

  # Roll the eviction die for a JOIN that would otherwise be rejected. Needs an
  # active neighbour to evict; pending reservations are left to time out.
  defp make_room?(%{evict_one_in: 0}) do
    false
  end

  defp make_room?(state) do
    <<random>> = :crypto.strong_rand_bytes(1)
    state.peers.active != [] and rem(random, state.evict_one_in) == 0
  end

  # Drop one random active neighbour to make room for `joiner`: tell it with a
  # REJECT so it frees its slot at once, and keep it as a potential peer.
  defp evict_random_active(state, joiner) do
    <<random>> = :crypto.strong_rand_bytes(1)
    victim = :lists.nth(rem(random, length(state.peers.active)) + 1, state.peers.active)
    {a, b, c, d} = victim.address
    {e, f, g, h} = joiner.address
    :io.format(~c"Evicting ~B.~B.~B.~B to make room for ~B.~B.~B.~B~n", [a, b, c, d, e, f, g, h])
    send_packet(state, victim, :reject, victim.request)

    candidate = %{
      id: victim.id,
      address: victim.address,
      port: victim.port,
      last_seen: victim.last_seen,
      since: :erlang.monotonic_time(:millisecond)
    }

    potential = drop_random_peer(remove_peer(state.peers.potential, victim.id))

    peers = %{
      state.peers
      | active: remove_peer(state.peers.active, victim.id),
        potential: [candidate | potential]
    }

    drop_neighbour_routes(%{state | peers: peers}, victim.id)
  end

  defp accept_join(state, peer, request) do
    send_packet(state, peer, :accept, request)
    reserve(state, peer, request, :accepting)
  end

  defp reserve(state, peer, request, phase) do
    pending = Map.merge(peer, %{request: request, phase: phase})

    peers = %{
      state.peers
      | pending: [pending | remove_peer(state.peers.pending, peer.id)],
        potential: remove_peer(state.peers.potential, peer.id)
    }

    %{state | peers: peers}
  end

  # add the given peer to the active set and remove it from the pending set.
  # A new active link is routable at once, not from the next tick.
  defp promote_to_active_set(state, peer, request) do
    active = Map.merge(peer, %{request: request, phase: :active})

    peers = %{
      state.peers
      | active: [active | remove_peer(state.peers.active, peer.id)],
        pending: remove_peer(state.peers.pending, peer.id)
    }

    routes = Routing.add_direct_neighbour(state.routes, peer.id, peer.last_seen)
    %{state | peers: peers, routes: routes}
  end

  # returns the peer map from the active/pending set if it exists.
  defp get_neighbour_info(state, id) do
    Enum.find(state.peers.active ++ state.peers.pending, fn peer -> peer.id == id end)
  end

  defp active_neighbour?(state, id) do
    Enum.any?(state.peers.active, fn peer -> peer.id == id end)
  end

  defp pending_neighbour?(state, id) do
    Enum.any?(state.peers.pending, fn peer -> peer.id == id end)
  end

  defp potential_neighbour?(state, id) do
    Enum.any?(state.peers.potential, fn peer -> peer.id == id end)
  end

  defp remove_peer(peers, id) do
    Enum.reject(peers, fn peer -> peer.id == id end)
  end

  defp adopt_peer(state, peer) do
    active? = active_neighbour?(state, peer.id)
    pending? = pending_neighbour?(state, peer.id)
    potential? = potential_neighbour?(state, peer.id)

    cond do
      active? or pending? ->
        # Announcements cannot confirm a handshake or keep an active link alive.
        state

      # if the peer is already a potential peer, refresh its liveness, keeping
      # `since` so we know how long it has been waiting in the potential set.
      potential? ->
        known = Enum.find(state.peers.potential, fn known -> known.id == peer.id end)
        refreshed = Map.put(peer, :since, known.since)
        others = remove_peer(state.peers.potential, peer.id)
        %{state | peers: %{state.peers | potential: [refreshed | others]}}

      # this is a new peer, so we can add it to the set.
      # if the potential set is full, we drop a random peer and replace it with this peer.
      free_potential_slots?(state) or coin_flip?() ->
        {a, b, c, d} = peer.address
        :io.format(~c"Discovered peer ~B.~B.~B.~B:~B~n", [a, b, c, d, peer.port])

        potential_peers = drop_random_peer(state.peers.potential)
        adopted = Map.put(peer, :since, peer.last_seen)
        %{state | peers: %{state.peers | potential: [adopted | potential_peers]}}

      true ->
        state
    end
  end

  # remove a single peer from the list, unless there is already a free slot.
  defp drop_random_peer(peers) when length(peers) == @potential_neighbours do
    <<random>> = :crypto.strong_rand_bytes(1)
    victim = :lists.nth(rem(random, length(peers)) + 1, peers)
    :lists.delete(victim, peers)
  end

  defp drop_random_peer(peers) do
    peers
  end

  # 50% change of true.
  defp coin_flip? do
    <<random>> = :crypto.strong_rand_bytes(1)
    random < 128
  end
end
