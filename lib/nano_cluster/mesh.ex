defmodule NanoCluster.Mesh do
  @moduledoc """
  Messaging between nodes over the mesh's active links. This is a
  not-entirely-drop-in replacement for the `Node` module.
  """

  alias NanoCluster.Discovery

  @typedoc "An eight-byte node id."
  @type node_id :: Discovery.id()

  @typedoc "A named process on a node, like `{:worker, node_id}`."
  @type destination :: {atom(), node_id()}

  @doc "This node's id, the mesh's counterpart of `node/0`."
  @spec node() :: Discovery.id()
  def node do
    Discovery.node()
  end

  @doc "Ids of every node this one can currently route to, nearest first."
  @spec nodes() :: [Discovery.id()]
  def nodes do
    Discovery.nodes()
  end

  @doc """
  Sends `message` to the process registered as `name` on node `node_id`.

  Returns `:ok` once the packet has left for the first hop, `{:error, :unreachable}`
  when no route is known, and `{:error, :too_large}` when the encoded message
  does not fit in one packet.
  """
  @spec send(destination(), term()) :: :ok | {:error, :unreachable | :too_large}
  def send({name, node_id}, message) when is_atom(name) do
    Discovery.send_message(node_id, encode(name, message))
  end

  @doc false
  @spec encode(atom(), term()) :: binary()
  def encode(name, message) do
    :erlang.term_to_binary({name, message})
  end

  @doc """
  Hands a received body to its local process. Returns `:ok`, or `:dropped`
  when the body does not decode or nothing is registered under the name.
  """
  @spec deliver(binary()) :: :ok | :dropped
  def deliver(body) do
    case decode(body) do
      {:ok, name, message} ->
        case :erlang.whereis(name) do
          :undefined ->
            :dropped

          pid ->
            :erlang.send(pid, message)
            :ok
        end

      :error ->
        :dropped
    end
  end

  @doc false
  @spec decode(binary()) :: {:ok, atom(), term()} | :error
  def decode(body) do
    case :erlang.binary_to_term(body) do
      {name, message} when is_atom(name) ->
        {:ok, name, message}

      _other ->
        :error
    end
  rescue
    _ -> :error
  end
end
