defmodule Badge.Mesh.Link do
  @moduledoc """
  Runs nano_cluster's peer discovery while the Mesh page shows.

  `open/0` starts `NanoCluster.Discovery` once wifi has an address and
  `close/0` stops it, so a badge on the home grid holds no UDP socket. A
  ticker copies the peer table out once a second, which is what `status/0`
  answers the render loop with.
  """

  use GenServer

  alias Badge.Wifi
  alias NanoCluster.Discovery

  @tick 1_000

  # More peers than discovery keeps, so a fuller table still fits the panel.
  @shown 6

  def start_link(:ok), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts discovery, once wifi has an address."
  @spec open() :: :ok
  def open, do: GenServer.cast(__MODULE__, :open)

  @doc "Stops discovery and forgets every peer."
  @spec close() :: :ok
  def close, do: GenServer.cast(__MODULE__, :close)

  @doc "Where discovery is, this node's id, and the peers it has found."
  @spec status() :: %{
          state: atom,
          node: binary | nil,
          reason: binary | nil,
          routed: non_neg_integer,
          peers: [map]
        }
  def status, do: GenServer.call(__MODULE__, :status)

  # Discovery is linked here, so its death has to arrive as a message rather
  # than take the page and `Badge.UI` down with it.
  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    start_ticker()

    {:ok, %{want: false, state: :off, pid: nil, node: nil, reason: nil, routed: 0, peers: []}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    reply = %{
      state: state.state,
      node: state.node,
      reason: state.reason,
      routed: state.routed,
      peers: state.peers
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_cast(:open, %{want: true} = state), do: {:noreply, state}

  def handle_cast(:open, state) do
    {:noreply, start(%{state | want: true, state: :waiting, reason: nil})}
  end

  def handle_cast(:close, %{want: false} = state), do: {:noreply, state}

  def handle_cast(:close, state), do: {:noreply, stop(%{state | want: false})}

  @impl true
  def handle_info(:tick, %{want: true, state: :up} = state), do: {:noreply, read(state)}

  def handle_info(:tick, %{want: true} = state), do: {:noreply, start(state)}

  def handle_info(:tick, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    :io.format(~c"Mesh: discovery exited ~p~n", [reason])

    {:noreply, failed(%{state | pid: nil, peers: [], routed: 0}, reason)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    :io.format(~c"Mesh: unhandled ~p~n", [message])

    {:noreply, state}
  end

  @doc "What keeps discovery from starting, given `Badge.Wifi.status/0`, or `nil`."
  @spec blocker(map) :: binary | nil
  def blocker(%{radio: :connected, ip: ip}) when is_binary(ip), do: nil
  def blocker(%{radio: :connected}), do: "waiting for an address"
  def blocker(%{radio: :connecting}), do: "wifi connecting"
  def blocker(%{radio: :failed}), do: "wifi failed"
  def blocker(_wifi), do: "wifi off"

  @doc """
  The peer table as rows for the panel: active peers, then pending, then potential.

  Each row carries a short `id`, a dotted `address`, the `port` and the
  `phase` of its handshake.
  """
  @spec peers(%{active: [map], pending: [map], potential: [map]}) :: [map]
  def peers(table) do
    rows =
      :lists.map(&row(&1, :active), table.active) ++
        :lists.map(&row(&1, :pending), table.pending) ++
        :lists.map(&row(&1, :potential), table.potential)

    :lists.sublist(rows, @shown)
  end

  defp row(peer, group) do
    %{
      id: short(peer.id),
      address: Wifi.address(peer.address),
      port: peer.port,
      phase: Map.get(peer, :phase, group)
    }
  end

  @doc "The first four bytes of a node id, in hex."
  @spec short(binary) :: binary
  def short(<<head::binary-size(4), _rest::binary>>), do: hex(head)
  def short(id), do: hex(id)

  @doc "Bytes as upper-case hex."
  @spec hex(binary) :: binary
  def hex(bytes), do: :erlang.iolist_to_binary(for <<byte <- bytes>>, do: digits(byte))

  defp digits(byte) when byte < 16, do: ["0", :erlang.integer_to_binary(byte, 16)]
  defp digits(byte), do: :erlang.integer_to_binary(byte, 16)

  defp start(state) do
    case blocker(Wifi.status()) do
      nil -> launch(state)
      reason -> %{state | state: :waiting, reason: reason}
    end
  end

  defp launch(state) do
    case Discovery.start_link() do
      {:ok, pid} -> up(state, pid)
      {:error, {:already_started, pid}} -> up(state, pid)
      {:error, reason} -> failed(state, reason)
    end
  catch
    kind, reason -> failed(state, {kind, reason})
  end

  defp up(state, pid) do
    :io.format(~c"Mesh: discovery up~n")

    read(%{state | state: :up, pid: pid, reason: nil, node: short(Discovery.node())})
  end

  # Discovery answers from its own process, so a table read cannot stall the render loop.
  defp read(state) do
    %{state | peers: peers(Discovery.peers()), routed: length(Discovery.nodes())}
  catch
    kind, reason -> failed(state, {kind, reason})
  end

  defp stop(%{pid: pid} = state) do
    case pid do
      nil -> :ok
      _running -> halt(pid)
    end

    %{state | state: :off, pid: nil, node: nil, reason: nil, routed: 0, peers: []}
  end

  # Stopped rather than killed, so terminate/2 closes the socket and the port is free next time.
  defp halt(pid) do
    :io.format(~c"Mesh: discovery down~n")
    :gen_server.stop(pid)
  catch
    _kind, _reason -> :ok
  end

  defp failed(state, reason) do
    :io.format(~c"Mesh: could not run discovery ~p~n", [reason])

    %{state | state: :failed, reason: describe(reason)}
  end

  defp describe(term) when is_binary(term), do: term
  defp describe(term) when is_atom(term), do: :erlang.atom_to_binary(term, :latin1)
  defp describe(term), do: :erlang.iolist_to_binary(:io_lib.format(~c"~p", [term]))

  defp start_ticker do
    link = self()

    spawn_link(fn -> tick_loop(link) end)
  end

  defp tick_loop(link) do
    Process.sleep(@tick)
    send(link, :tick)
    tick_loop(link)
  end
end
