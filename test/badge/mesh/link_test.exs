defmodule Badge.Mesh.LinkTest do
  use ExUnit.Case, async: true

  alias Badge.Mesh.Link

  defp peer(id, last, extra \\ %{}) do
    Map.merge(%{id: id, address: {192, 168, 1, last}, port: 4573, last_seen: 0}, extra)
  end

  describe "blocker/1" do
    test "nothing blocks once wifi has an address" do
      assert Link.blocker(%{radio: :connected, ip: "192.168.1.42"}) == nil
    end

    test "an association without a lease still waits" do
      assert Link.blocker(%{radio: :connected, ip: nil}) == "waiting for an address"
    end

    test "names what the radio is doing otherwise" do
      assert Link.blocker(%{radio: :connecting, ip: nil}) == "wifi connecting"
      assert Link.blocker(%{radio: :failed, ip: nil}) == "wifi failed"
      assert Link.blocker(%{radio: :disabled, ip: nil}) == "wifi off"
    end
  end

  describe "peers/1" do
    test "lists active, then pending, then potential peers" do
      table = %{
        active: [peer("node000A", 10, %{phase: :active, request: <<1::32>>})],
        pending: [peer("node000B", 11, %{phase: :joining, request: <<2::32>>})],
        potential: [peer("node000C", 12, %{since: 0})]
      }

      assert [
               %{address: "192.168.1.10", phase: :active},
               %{address: "192.168.1.11", phase: :joining},
               %{address: "192.168.1.12", phase: :potential}
             ] = Link.peers(table)
    end

    test "carries a short hex id and the port" do
      table = %{active: [], pending: [], potential: [peer(<<0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4>>, 9)]}

      assert [%{id: "DEADBEEF", port: 4573}] = Link.peers(table)
    end

    test "an empty table is an empty list" do
      assert Link.peers(%{active: [], pending: [], potential: []}) == []
    end
  end

  describe "hex/1" do
    test "pads every byte to two digits" do
      assert Link.hex(<<0, 15, 16, 255>>) == "000F10FF"
    end

    test "short/1 keeps the first four bytes" do
      assert Link.short("node000A") == "6E6F6465"
    end
  end
end
