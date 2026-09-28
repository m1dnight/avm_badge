defmodule NanoCluster.Discovery.PacketTest do
  use ExUnit.Case, async: true

  alias NanoCluster.Discovery.Packet

  test "handshake packet types have a fixed, versioned wire format" do
    for {type, code} <- [announce: 0, join: 1, accept: 2, reject: 3, confirm: 4] do
      packet = %Packet{token: "peer0001", type: type, request: <<123::32>>}
      wire = <<"NCD", 2, code, "peer0001", 123::32>>
      assert Packet.encode(packet) == wire
      assert byte_size(wire) == Packet.header_size()
      assert Packet.decode(wire) == {:ok, packet}
    end
  end

  test "rejects malformed, oversized, old-version, and unknown-type packets" do
    wire = Packet.encode(%Packet{token: "peer0001"})

    for data <- [
          "",
          "garbage",
          <<"NCD", 1, "peer0001">>,
          <<"NCD", 2, 6, "peer0001", 0::32>>,
          binary_part(wire, 0, 16),
          wire <> "extra"
        ] do
      assert Packet.decode(data) == :error
    end
  end

  test "a routes packet carries nine-byte destination and hop pairs after the header" do
    routes = [{"peer0002", 0}, {"peer0003", 1}, {"peer0004", 255}]
    packet = %Packet{token: "peer0001", type: :routes, routes: routes}
    wire = <<"NCD", 2, 5, "peer0001", 0::32, "peer0002", 0, "peer0003", 1, "peer0004", 255>>
    assert Packet.encode(packet) == wire
    assert Packet.decode(wire) == {:ok, packet}

    empty = %Packet{token: "peer0001", type: :routes}
    assert Packet.decode(Packet.encode(empty)) == {:ok, empty}
    assert byte_size(Packet.encode(empty)) == Packet.header_size()
  end

  test "rejects a routes payload that is not whole pairs or has too many entries" do
    header = <<"NCD", 2, 5, "peer0001", 0::32>>
    assert Packet.decode(header <> "peer0002") == :error
    assert Packet.decode(header <> <<"peer0002", 1, "pee">>) == :error

    too_many =
      for n <- 1..(Packet.max_routes() + 1), into: <<>> do
        <<n::64, 1>>
      end

    assert Packet.decode(header <> too_many) == :error

    just_enough =
      for n <- 1..Packet.max_routes(), into: <<>> do
        <<n::64, 1>>
      end

    assert {:ok, %Packet{routes: routes}} = Packet.decode(header <> just_enough)
    assert length(routes) == Packet.max_routes()
    assert byte_size(header <> just_enough) <= Packet.max_size()
  end

  test "a message packet carries destination, origin, hops left and an opaque body" do
    packet = %Packet{
      token: "peer0001",
      type: :message,
      destination: "peer0009",
      origin: "peer0002",
      ttl: 7,
      body: "hello"
    }

    wire = <<"NCD", 2, 6, "peer0001", 0::32, "peer0009", "peer0002", 7, "hello">>
    assert Packet.encode(packet) == wire
    assert Packet.decode(wire) == {:ok, packet}

    empty = %{packet | body: <<>>}
    assert Packet.decode(Packet.encode(empty)) == {:ok, empty}

    # header alone, or a body over the limit, is not a message
    assert Packet.decode(<<"NCD", 2, 6, "peer0001", 0::32, "peer0009", "peer00">>) == :error
    too_big = :binary.copy("x", Packet.max_body() + 1)
    assert Packet.decode(wire <> too_big) == :error
    assert_raise MatchError, fn -> Packet.encode(%{packet | body: too_big}) end

    full = %{packet | body: :binary.copy("x", Packet.max_body())}
    assert byte_size(Packet.encode(full)) == Packet.max_size()
  end

  test "hop counts and ids outside the wire format cannot be encoded" do
    assert_raise FunctionClauseError, fn ->
      Packet.encode(%Packet{token: "peer0001", type: :routes, routes: [{"peer0002", 256}]})
    end

    assert_raise FunctionClauseError, fn ->
      Packet.encode(%Packet{token: "peer0001", type: :routes, routes: [{"short", 1}]})
    end
  end
end
