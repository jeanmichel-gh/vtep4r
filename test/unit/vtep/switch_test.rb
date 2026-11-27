#--
# Copyright 2026 Jean-Michel Esnault.
# All rights reserved.
# See LICENSE.txt for permissions.
#
#
# This file is part of VTEP4R.
#
# VTEP4R is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VTEP4R is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VTEP4R.  If not, see <http://www.gnu.org/licenses/>.
#++

require 'test/unit'
require 'vxlan/vtep'

# The forwarding decision, case by case, on given octets, through Switch,
# which applies the learning the Forwarder asks for. No socket, no thread,
# no clock: the time is an argument.
class Switch_Test < Test::Unit::TestCase
  include VXLAN
  include VXLAN::Vtep

  H1 = '020000000101'
  H2 = '020000000102'
  H3 = '020000000103'
  BCAST = 'ffffffffffff'

  def frame(dst, src, type = '88b5', payload = '00' * 46)
    [dst + src + type + payload].pack('H*')
  end

  def switch(mode: :learn, flood: %w[10.255.0.12 10.255.0.13], ports: %w[eth2 eth3])
    Switch.new(local: '10.255.0.11', mtu: 1500,
               vnis: [{ vni: 100, ports: ports, mode: mode, flood: flood, ageing: 300 }])
  end

  def kinds(actions)
    actions.map { |a| [a.class.name.split('::').last.to_sym, a.respond_to?(:port) ? a.port : a.respond_to?(:vtep) ? a.vtep : a.reason] }
  end

  # From a host port.

  def test_a_broadcast_floods_the_other_ports_and_every_vtep
    acts = switch.from_port('eth2', frame(BCAST, H1), 0)
    assert_equal [[:Deliver, 'eth3'], [:Tunnel, '10.255.0.12'], [:Tunnel, '10.255.0.13']], kinds(acts)
  end

  def test_the_tunnel_copy_is_vxlan_with_the_vni
    t = switch.from_port('eth2', frame(BCAST, H1), 0).find { |a| a.is_a?(Tunnel) }
    assert_equal '0800000000006400', t.packet.header.to_shex
    assert_equal frame(BCAST, H1), t.packet.inner
  end

  def test_the_source_is_learned_on_its_port
    sw = switch
    sw.from_port('eth2', frame(BCAST, H1), 0)
    assert_equal Location.port('eth2'), sw.bridge(100).macs.lookup(Datalink::MAC.new(H1)).location
  end

  def test_a_known_unicast_goes_to_its_place_only
    sw = switch
    sw.from_port('eth3', frame(BCAST, H3), 0)
    assert_equal [[:Deliver, 'eth3']], kinds(sw.from_port('eth2', frame(H3, H1), 1))
    sw.bridge(100).macs.add(Datalink::MAC.new(H2), Location.vtep('10.255.0.12'))
    assert_equal [[:Tunnel, '10.255.0.12']], kinds(sw.from_port('eth2', frame(H2, H1), 2))
  end

  def test_a_unicast_to_its_own_port_is_dropped
    sw = switch
    sw.from_port('eth2', frame(BCAST, H3), 0)
    assert_equal [[:Drop, :same_port]], kinds(sw.from_port('eth2', frame(H3, H1), 1))
  end

  def test_an_unknown_unicast_floods
    assert_equal 3, switch.from_port('eth2', frame(H2, H1), 0).size
  end

  def test_less_than_an_ethernet_header_is_dropped
    assert_equal [[:Drop, :not_a_frame]], kinds(switch.from_port('eth2', ['0200'].pack('H*'), 0))
  end

  def test_a_port_in_no_vni_is_dropped
    assert_equal [[:Drop, :unknown_port]], kinds(switch.from_port('eth9', frame(BCAST, H1), 0))
  end

  # RFC 7348 section 4.3: VTEPs MUST NOT fragment.
  def test_a_frame_too_big_for_the_tunnel_is_dropped_not_fragmented
    # The outer IP, UDP and VXLAN headers take 36 octets of the MTU; the
    # outer Ethernet header is not in it. So 1464 inner octets fit 1500.
    big = frame(H2, H1, '88b5', '00' * 1451)        # 1465 + 36 = 1501
    sw = switch(flood: ['10.255.0.12'], ports: ['eth2'])
    assert_equal [[:Drop, :too_big]], kinds(sw.from_port('eth2', big, 0))
    ok = frame(H2, H1, '88b5', '00' * 1450)         # 1464 + 36 = 1500
    assert_equal [[:Tunnel, '10.255.0.12']], kinds(sw.from_port('eth2', ok, 0))
  end

  # EVPN mode still learns local MACs: bgp4rd advertises them as type 2.
  def test_evpn_mode_learns_local_macs
    sw = switch(mode: :evpn)
    sw.from_port('eth2', frame(BCAST, H1), 0)
    assert_not_nil sw.bridge(100).macs.lookup(Datalink::MAC.new(H1))
  end

  # From the tunnel.

  def packet(dst, src, vni: 100, flags: 0x08)
    Packet.new({ vni: vni, flags: flags }, frame(dst, src))
  end

  def test_from_the_tunnel_a_broadcast_goes_to_every_port_never_back
    assert_equal [[:Deliver, 'eth2'], [:Deliver, 'eth3']],
                 kinds(switch.from_tunnel('10.255.0.12', packet(BCAST, H2).encode, 0))
  end

  def test_from_the_tunnel_the_source_is_learned_behind_the_vtep
    sw = switch
    sw.from_tunnel('10.255.0.12', packet(BCAST, H2).encode, 0)
    assert_equal Location.vtep('10.255.0.12'), sw.bridge(100).macs.lookup(Datalink::MAC.new(H2)).location
  end

  def test_evpn_mode_does_not_learn_from_the_tunnel
    sw = switch(mode: :evpn)
    sw.from_tunnel('10.255.0.12', packet(BCAST, H2).encode, 0)
    assert_nil sw.bridge(100).macs.lookup(Datalink::MAC.new(H2))
  end

  def test_from_the_tunnel_a_known_local_unicast_goes_to_its_port
    sw = switch
    sw.from_port('eth3', frame(BCAST, H1), 0)
    assert_equal [[:Deliver, 'eth3']], kinds(sw.from_tunnel('10.255.0.12', packet(H1, H2).encode, 1))
  end

  # Never back into the tunnel: that keeps ingress replication loop free.
  def test_from_the_tunnel_a_remote_destination_is_dropped
    sw = switch
    sw.bridge(100).macs.add(Datalink::MAC.new(H3), Location.vtep('10.255.0.13'))
    assert_equal [[:Drop, :split_horizon]], kinds(sw.from_tunnel('10.255.0.12', packet(H3, H2).encode, 0))
  end

  def test_an_unknown_vni_is_dropped
    assert_equal [[:Drop, :unknown_vni]], kinds(switch.from_tunnel('10.255.0.12', packet(BCAST, H2, vni: 200).encode, 0))
  end

  def test_validation_findings_drop_under_the_rfc_policy
    assert_equal [[:Drop, :no_i_flag]], kinds(switch.from_tunnel('10.255.0.12', packet(BCAST, H2, flags: 0).encode, 0))
    assert_equal [[:Drop, :short]], kinds(switch.from_tunnel('10.255.0.12', ['0800'].pack('H*'), 0))
  end

  # RFC 7348 section 5: R bits are ignored on receipt.
  def test_reserved_bits_are_ignored
    assert_equal 2, switch.from_tunnel('10.255.0.12', packet(BCAST, H2, flags: 0x0c).encode, 0).size
  end

  def test_drops_are_counted_by_reason
    sw = switch
    sw.from_tunnel('10.255.0.12', packet(BCAST, H2, vni: 200).encode, 0)
    sw.from_tunnel('10.255.0.12', packet(BCAST, H2, flags: 0).encode, 0)
    sw.from_tunnel('10.255.0.12', packet(BCAST, H2, flags: 0x0c).encode, 0)
    assert_equal({ unknown_vni: 1, no_i_flag: 1 }, sw.drops)
    assert_equal({ reserved_set: 1 }, sw.findings)
  end

  # Learning and moves are events, for bgp4rd and routescope.
  def test_events
    sw = switch
    sw.from_port('eth2', frame(BCAST, H1), 0)
    sw.from_tunnel('10.255.0.12', packet(BCAST, H1).encode, 1)
    assert_equal [[:learned, 100, '02:00:00:00:01:01'], [:moved, 100, '02:00:00:00:01:01']],
                 sw.events.map { |e| [e.type, e.vni, e.mac.to_s] }
  end

  def test_ageing
    sw = switch
    sw.from_port('eth2', frame(BCAST, H1), 0)
    sw.events.clear
    sw.age(300)
    assert_equal [[:aged, 100, '02:00:00:00:01:01']], sw.events.map { |e| [e.type, e.vni, e.mac.to_s] }
  end

  # Where a MAC was: an aged one's place, a moved one's old place.
  def test_events_say_where_the_mac_was
    sw = switch
    sw.from_port('eth2', frame(BCAST, H1), 0)
    sw.from_tunnel('10.255.0.12', packet(BCAST, H1).encode, 1)
    sw.age(301)
    assert_equal [[:learned, Location.port('eth2'), nil],
                  [:moved, Location.vtep('10.255.0.12'), Location.port('eth2')],
                  [:aged, Location.vtep('10.255.0.12'), nil]],
                 sw.events.map { |e| [e.type, e.location, e.from] }
  end

  # In evpn mode, a MAC bgp4rd put behind a VTEP that then speaks on our
  # port is moved here, and the event says from where.
  def test_evpn_mode_a_remote_mac_on_our_port_moves_here
    sw = switch(mode: :evpn, flood: [])
    sw.bridge(100).macs.add(Datalink::MAC.new(H1), Location.vtep('10.255.0.12'), seq: 1)
    sw.from_port('eth2', frame(BCAST, H1), 0)
    assert_equal [[:moved, Location.port('eth2'), Location.vtep('10.255.0.12')]],
                 sw.events.map { |e| [e.type, e.location, e.from] }
    assert_equal [[:Deliver, 'eth2']], kinds(sw.from_port('eth3', frame(H1, H2), 1))
  end

  # The UDP source port: a hash of the inner Ethernet header, in 49152 to
  # 65535 (RFC 7348 section 5), the same for every packet of a flow.
  def test_the_source_port
    sw = switch(flood: ['10.255.0.12'], ports: ['eth2'])
    a = sw.from_port('eth2', frame(H2, H1), 0)[0].source_port
    b = sw.from_port('eth2', frame(H2, H1, '88b5', 'ff' * 46), 0)[0].source_port
    c = sw.from_port('eth2', frame(H2, H3), 0)[0].source_port
    assert_equal a, b
    assert_not_equal a, c
    [a, c].each { |p| assert_include 49_152..65_535, p }
  end

# Two VTEPs, wired through each other's Tunnel actions: h1 broadcasts,
# h2 answers by unicast, and after that each side sends straight to the
# other with no flooding. The packets cross as wire octets.
def test_two_vteps
  l1 = Switch.new(local: "10.255.0.11", vnis: [{ vni: 100, ports: ["eth2"], flood: ["10.255.0.12"] }])
  l2 = Switch.new(local: "10.255.0.12", vnis: [{ vni: 100, ports: ["eth2"], flood: ["10.255.0.11"] }])
  peer = { "10.255.0.11" => l1, "10.255.0.12" => l2 }
  cross = lambda do |from, acts|
    acts.grep(Tunnel).flat_map { |t| peer[t.vtep].from_tunnel(from.local, t.packet.encode, 0) }
  end

  out = cross.(l1, l1.from_port("eth2", frame(BCAST, H1), 0))
  assert_equal [[:Deliver, "eth2"]], kinds(out)
  assert_equal frame(BCAST, H1), out[0].octets

  reply = l2.from_port("eth2", frame(H1, H2), 0)
  assert_equal [[:Tunnel, "10.255.0.11"]], kinds(reply)
  assert_equal [[:Deliver, "eth2"]], kinds(cross.(l2, reply))

  assert_equal [[:Tunnel, "10.255.0.12"]], kinds(l1.from_port("eth2", frame(H2, H1), 0))
  assert_equal({}, l1.drops)
  assert_equal({}, l2.drops)
end

  def test_a_bridge_domain_that_does_not_exist
    assert_nil switch.bridge(5)
  end

  # EVPN over MPLS: our labels, across the VNIs.

  def mpls_switch
    Switch.new(local: '10.255.0.11', vnis: [
                 { vni: 100, ports: %w[eth2], mode: :evpn, encap: :mpls, labels: { unicast: 25_000, bum: 25_001 } },
                 { vni: 200, ports: %w[eth3], mode: :evpn, encap: :mpls }
               ])
  end

  def test_the_labels_we_gave
    sw = mpls_switch
    assert_equal({ 25_000 => [100, :unicast], 25_001 => [100, :bum] }, sw.labels)
    assert sw.set_labels(200, unicast: 25_002, bum: 25_003)
    assert_equal [25_000, 25_001, 25_002, 25_003], sw.labels.keys.sort
    sw.set_labels(200, unicast: 25_004, bum: 25_003)
    refute sw.labels.key?(25_002), 'a label given up is no longer ours'
    sw.del_vni(100)
    assert_equal [25_003, 25_004], sw.labels.keys.sort
  end

  def test_a_label_is_one_vnis
    sw = mpls_switch
    e = assert_raise(ArgumentError) { sw.set_labels(200, unicast: 25_001, bum: 25_003) }
    assert_match(/label 25001 is vni 100's/, e.message)
    assert_raise(ArgumentError) do
      sw.add_vni(vni: 300, ports: [], mode: :evpn, encap: :mpls, labels: { unicast: 25_009, bum: 25_000 })
    end
    assert_nil sw.bridge(300)
  end

  def test_from_the_core_through_the_switch
    sw = mpls_switch
    out = sw.from_core(Mpls::Packet.new([25_001], Mpls::ControlWord.new, frame(BCAST, H2)).encode, 0)
    assert_equal ['eth2'], out.grep(Deliver).map(&:port)
    sw.from_core(Mpls::Packet.new([25_009], Mpls::ControlWord.new, frame(BCAST, H2)).encode, 0)
    assert_equal 1, sw.drops[:unknown_label]
    assert_empty sw.events, 'nothing learned from the core'
  end
end
