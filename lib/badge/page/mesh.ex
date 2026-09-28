defmodule Badge.Page.Mesh do
  @moduledoc """
  The nano_cluster mesh: which badges this one has found on the network.

  Discovery runs only while the page shows. Entering starts it once wifi
  has an address and leaving stops it. Each row is a peer from
  `Badge.Mesh.Link.status/0` with the phase its handshake is in, and the
  routes row counts every node a message could reach through them.
  """

  use Badge.Page

  alias Badge.Mesh.Link
  alias Badge.Readout
  alias Badge.Theme

  @row_x 8

  # How much of a reason fits beside its label.
  @columns 24

  @state_y Theme.content_top()
  @node_y @state_y + Readout.pitch()
  @routes_y @node_y + Readout.pitch()
  @peers_y @routes_y + Readout.pitch() + 8
  @first_peer_y @peers_y + Readout.pitch()

  @impl true
  def title, do: "Mesh"

  @impl true
  def init, do: %{status: nil}

  # Hardware is only touched here, never from a key handler.
  @impl true
  def tick(state) do
    Link.open()

    %{state | status: Link.status()}
  end

  # Peers come and go at the announce interval, two seconds.
  @impl true
  def refresh(_state), do: 500

  # A page is not a process, so leaving is the link's only chance to be closed.
  @impl true
  def leave(_state), do: Link.close()

  @impl true
  def render(%{status: nil} = state), do: render(%{state | status: unknown()})

  def render(%{status: status}) do
    state_row(status) ++ node_row(status) ++ routes_row(status) ++ peer_rows(status)
  end

  defp unknown, do: %{state: :off, node: nil, reason: nil, routed: 0, peers: []}

  defp state_row(status) do
    Readout.right_row("mesh", state_text(status), @state_y, state_colour(status))
  end

  defp state_text(%{state: :off}), do: "starting"
  defp state_text(%{state: :waiting, reason: nil}), do: "waiting for wifi"
  defp state_text(%{state: :waiting, reason: reason}), do: clip(reason)
  defp state_text(%{state: :failed, reason: nil}), do: "failed"
  defp state_text(%{state: :failed, reason: reason}), do: clip(reason)
  defp state_text(_status), do: "up"

  defp state_colour(%{state: :off}), do: Theme.dim()
  defp state_colour(%{state: :waiting}), do: Theme.warn()
  defp state_colour(%{state: :failed}), do: Theme.alert()
  defp state_colour(_status), do: Theme.ok()

  defp node_row(%{node: nil}), do: []
  defp node_row(%{node: node}), do: Readout.right_row("id", node, @node_y, Theme.fg())

  defp routes_row(%{state: :up, routed: routed}) do
    Readout.right_row("routes", count(routed) <> " nodes", @routes_y, Theme.fg())
  end

  defp routes_row(_status), do: []

  defp peer_rows(%{state: :up, peers: []}) do
    Readout.right_row("peers", "nobody yet", @peers_y, Theme.dim())
  end

  defp peer_rows(%{state: :up, peers: peers}) do
    Readout.right_row("peers", count(length(peers)), @peers_y, Theme.select()) ++
      listed(peers, @first_peer_y, [])
  end

  defp peer_rows(_status), do: []

  defp listed([], _y, acc), do: :lists.reverse(acc)

  defp listed([peer | rest], y, acc) do
    phase = phase_text(peer.phase)

    items = [
      {:text, Readout.right_x(phase), y, :default16px, phase_colour(peer.phase), Theme.bg(),
       phase},
      {:text, @row_x, y, :default16px, Theme.fg(), Theme.bg(), peer.address}
    ]

    listed(rest, y + Readout.pitch(), items ++ acc)
  end

  defp phase_text(phase), do: :erlang.atom_to_binary(phase, :latin1)

  defp phase_colour(:active), do: Theme.ok()
  defp phase_colour(:potential), do: Theme.dim()
  defp phase_colour(_handshaking), do: Theme.warn()

  defp count(n), do: :erlang.integer_to_binary(n)

  # A reason can outrun the panel; the row has to stay on it.
  defp clip(text) when byte_size(text) <= @columns, do: text
  defp clip(<<head::binary-@columns, _rest::binary>>), do: head
end
