defmodule NanoCluster.Discovery.Packet do
  @moduledoc """
  Discovery packet: `"NCD"`, version 2, type, eight-byte node token, and
  four-byte request ID. Announcements use a zero request ID.

  Handshake packets are exactly that 17-byte header. A `:routes` packet, sent
  between active neighbours, follows the header with a routing advertisement:
  one nine-byte pair per destination, its eight-byte token and one byte of hop
  count. A `:message` packet follows the header with the destination token,
  the origin token, one byte of hops left, and an opaque body; the header
  token is the neighbour that forwarded it. Any other type with trailing bytes
  is invalid.
  """

  alias NanoCluster.Discovery.Packet

  @enforce_keys [:token]
  defstruct [
    :token,
    type: :announce,
    request: <<0::32>>,
    routes: [],
    destination: nil,
    origin: nil,
    ttl: 0,
    body: <<>>
  ]

  @types {:announce, :join, :accept, :reject, :confirm, :routes, :message}
  @codes %{announce: 0, join: 1, accept: 2, reject: 3, confirm: 4, routes: 5, message: 6}

  @header_size 17
  @route_size 9
  # Bounds both the packet and the work of decoding one. Nowhere near a datagram
  # limit: 64 routes are 593 bytes.
  @max_routes 64
  # destination + origin + ttl
  @message_header_size 17
  # Keeps a message inside one datagram on any link: 17 + 17 + 1024 bytes.
  @max_body 1024

  @type kind :: :announce | :join | :accept | :reject | :confirm | :routes | :message
  @type route :: {<<_::64>>, 0..255}
  @type t :: %Packet{
          token: <<_::64>>,
          type: kind(),
          request: <<_::32>>,
          routes: [route()],
          destination: <<_::64>> | nil,
          origin: <<_::64>> | nil,
          ttl: 0..255,
          body: binary()
        }

  @doc "Size of the fixed header, which is the whole packet for handshake types."
  @spec header_size() :: pos_integer()
  def header_size do
    @header_size
  end

  @doc "Size of the largest valid packet: a message with a full body."
  @spec max_size() :: pos_integer()
  def max_size do
    max(@header_size + @max_routes * @route_size, @header_size + @message_header_size + @max_body)
  end

  @doc "Largest message body that fits in one packet."
  @spec max_body() :: pos_integer()
  def max_body do
    @max_body
  end

  @doc "Maximum routes a peer can advertise"
  @spec max_routes() :: pos_integer()
  def max_routes do
    @max_routes
  end

  # ---------------------------------------------------------------------------#
  #                                Encoding                                    #
  # ---------------------------------------------------------------------------#

  @doc """
  Encodes a packet into a binary.
  """
  @spec encode(t()) :: binary()
  def encode(%Packet{token: <<_::64>> = token, type: :routes, request: <<_::32>> = request, routes: routes})
      when length(routes) <= @max_routes do
    <<"NCD", 2, @codes.routes, token::binary, request::binary, encode_routes(routes)::binary>>
  end

  def encode(%Packet{type: :message} = packet) do
    %{token: <<_::64>> = token, request: <<_::32>> = request} = packet
    %{destination: <<_::64>> = destination, origin: <<_::64>> = origin, ttl: ttl, body: body} = packet
    true = ttl in 0..255 and byte_size(body) <= @max_body

    <<"NCD", 2, @codes.message, token::binary, request::binary, destination::binary, origin::binary, ttl, body::binary>>
  end

  def encode(%Packet{token: <<_::64>> = token, type: type, request: <<_::32>> = request})
      when type != :message do
    code = Map.fetch!(@codes, type)
    <<"NCD", 2, code, token::binary, request::binary>>
  end

  # ---------------------------------------------------------------------------#
  #                                Decoding                                    #
  # ---------------------------------------------------------------------------#

  @spec decode(binary()) :: {:ok, t()} | :error
  def decode(<<"NCD", 2, code, token::binary-size(8), request::binary-size(4), rest::binary>>)
      when code < tuple_size(@types) do
    packet = %Packet{token: token, type: elem(@types, code), request: request}

    case {packet.type, rest} do
      {:routes, _payload} ->
        decode_routes(rest, packet, 0)

      {:message, <<destination::binary-size(8), origin::binary-size(8), ttl, body::binary>>}
      when byte_size(body) <= @max_body ->
        {:ok, %{packet | destination: destination, origin: origin, ttl: ttl, body: body}}

      {:message, _short_or_oversized} ->
        :error

      {_handshake, <<>>} ->
        {:ok, packet}

      {_handshake, _trailing} ->
        :error
    end
  end

  def decode(_data) do
    :error
  end

  # ---------------------------------------------------------------------------#
  #                                Helpers                                     #
  # ---------------------------------------------------------------------------#

  defp encode_routes(routes) do
    Enum.reduce(routes, <<>>, fn {<<_::64>> = id, hops}, acc when hops in 0..255 ->
      <<acc::binary, id::binary, hops>>
    end)
  end

  defp decode_routes(<<>>, packet, _count) do
    {:ok, %{packet | routes: Enum.reverse(packet.routes)}}
  end

  defp decode_routes(_rest, _packet, @max_routes) do
    :error
  end

  defp decode_routes(<<id::binary-size(8), hops, rest::binary>>, packet, count) do
    decode_routes(rest, %{packet | routes: [{id, hops} | packet.routes]}, count + 1)
  end

  defp decode_routes(_partial, _packet, _count) do
    :error
  end
end
