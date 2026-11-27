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

# The Forwarder alone: a pure function. It reads the bridge domain and
# answers actions; it asks for learning and never changes the table.
class Forwarder_Test < Test::Unit::TestCase
  include VXLAN
  include VXLAN::Vtep

  def frame(dst, src)
    [dst + src + '88b5' + '00' * 46].pack('H*')
  end

  def bd
    @bd ||= BridgeDomain.new(vni: 100, ports: %w[eth2], flood: %w[10.255.0.12])
  end

  def test_from_a_port_learning_is_asked_for_not_done
    acts = Forwarder.from_port(bd, 'eth2', frame('ffffffffffff', '020000000101'), mtu: 1500)
    learn = acts.find { |a| a.is_a?(Learn) }
    assert_equal [100, '02:00:00:00:01:01', Location.port('eth2')], [learn.vni, learn.mac.to_s, learn.location]
    assert_equal 0, bd.macs.size
  end

  def test_from_the_tunnel_learning_is_asked_for_not_done
    pk = Packet.new(100, frame('ffffffffffff', '020000000102')).encode
    acts = Forwarder.from_tunnel({ 100 => bd }, '10.255.0.12', pk, policy: :rfc)
    assert_equal Location.vtep('10.255.0.12'), acts.find { |a| a.is_a?(Learn) }.location
    assert_equal 0, bd.macs.size
  end

  def test_an_ignored_finding_is_noted
    pk = Packet.new({ vni: 100, flags: 0x0c }, frame('ffffffffffff', '020000000102')).encode
    acts = Forwarder.from_tunnel({ 100 => bd }, '10.255.0.12', pk, policy: :rfc)
    assert_equal [:reserved_set], acts.select { |a| a.is_a?(Note) }.map(&:finding)
  end

  def test_the_lenient_policy_still_cannot_forward_a_cut_frame
    acts = Forwarder.from_tunnel({ 100 => bd }, '10.255.0.12', Packet.new(100, 'ab'.b).encode, policy: :lenient)
    assert_equal [:not_a_frame], acts.map(&:reason)
  end

  def test_the_source_port_is_deterministic
    f = frame('020000000102', '020000000101')
    assert_equal Forwarder.source_port(f), Forwarder.source_port(f.dup)
  end

  # EVPN over MPLS (bgp4r docs/design/evpn-mpls.md): pe2 gave 26000 and
  # 26001; we gave 25000 (unicast) and 25001 (BUM).

  def mpls_bd
    @mpls_bd ||= BridgeDomain.new(vni: 200, ports: %w[eth3 eth4], mode: :evpn, encap: :mpls,
                                  labels: { unicast: 25_000, bum: 25_001 }).tap do |b|
      b.flood_add('10.255.0.12', label: 26_001)
      b.macs.add(Datalink::MAC.new('02:00:00:00:02:02'), Location.vtep('10.255.0.12', 26_000))
      b.macs.add(Datalink::MAC.new('02:00:00:00:01:03'), Location.port('eth4'))
    end
  end

  def by_label
    { 25_000 => [mpls_bd, :unicast], 25_001 => [mpls_bd, :bum] }
  end

  def core(labels, f, cw: Mpls::ControlWord.new)
    Mpls::Packet.new(labels, cw, f).encode
  end

  def test_a_known_remote_mac_is_pushed_with_its_pes_label
    f = frame('020000000202', '020000000101')
    acts = Forwarder.from_port(mpls_bd, 'eth3', f, mtu: 1500)
    push = acts.grep(Push)
    assert_equal 1, push.size
    assert_equal ['10.255.0.12', 26_000], [push[0].vtep, push[0].label]
    # The label with S set, the control word of zeros, the frame.
    assert_equal '065901400' + '0000000' + f.unpack1('H*'), push[0].packet.to_shex
    assert_empty acts.grep(Tunnel)
  end

  def test_a_broadcast_is_pushed_under_each_pes_bum_label
    acts = Forwarder.from_port(mpls_bd, 'eth3', frame('ffffffffffff', '020000000101'), mtu: 1500)
    assert_equal [['10.255.0.12', 26_001]], acts.grep(Push).map { |a| [a.vtep, a.label] }
    assert_equal ['eth4'], acts.grep(Deliver).map(&:port)
  end

  # At the egress the core has popped its own label (PHP), so ours is on
  # top (the spec's measurement, bgp4r docs/design/evpn-mpls.md).
  def test_from_the_core_a_known_mac_goes_to_its_port
    acts = Forwarder.from_core(by_label, core([25_000], frame('020000000103', '020000000202')), policy: :rfc)
    assert_equal ['eth4'], acts.grep(Deliver).map(&:port)
    assert_empty acts.grep(Learn), 'nothing is learned from the core'
  end

  def test_from_the_core_the_bum_label_floods_every_port
    acts = Forwarder.from_core(by_label, core([25_001], frame('020000000103', '020000000202')), policy: :rfc)
    assert_equal %w[eth3 eth4], acts.grep(Deliver).map(&:port), 'BUM is flooded, even for a known MAC'
  end

  def test_from_the_core_an_unknown_mac_floods_every_port
    acts = Forwarder.from_core(by_label, core([25_000], frame('020000000199', '020000000202')), policy: :rfc)
    assert_equal %w[eth3 eth4], acts.grep(Deliver).map(&:port)
  end

  def test_from_the_core_never_back_into_the_core
    acts = Forwarder.from_core(by_label, core([25_000], frame('020000000202', '020000000303')), policy: :rfc)
    assert_equal [:split_horizon], acts.grep(Drop).map(&:reason)
  end

  # RFC 4182 section 2.
  def test_an_explicit_null_on_top_is_popped
    [0, 2].each do |null|
      acts = Forwarder.from_core(by_label, core([null, 25_000], frame('020000000103', '020000000202')), policy: :rfc)
      assert_equal ['eth4'], acts.grep(Deliver).map(&:port), "null #{null}"
    end
  end

  # RFC 3031 section 3.18, even under the lenient policy.
  def test_a_label_we_did_not_give_is_dropped
    %i[rfc lenient].each do |policy|
      acts = Forwarder.from_core(by_label, core([25_002], frame('020000000103', '020000000202')), policy: policy)
      assert_equal [:unknown_label], acts.map(&:reason)
    end
  end

  # A transport label still on top is not ours: the packet is the
  # kernel's to switch, and vtep4rd's copy goes nowhere.
  def test_a_transport_label_on_top_is_not_ours
    acts = Forwarder.from_core(by_label, core([16_002, 25_000], frame('020000000103', '020000000202')), policy: :rfc)
    assert_equal [:unknown_label], acts.map(&:reason)
  end

  def test_our_label_must_be_the_bottom_one
    pk = Mpls::Packet.new([Mpls::Label.new(25_000), 16_002], Mpls::ControlWord.new, frame('020000000103', '020000000202'))
    assert_equal [:not_bottom], Forwarder.from_core(by_label, pk.encode, policy: :rfc).map(&:reason)
  end

  def test_a_finding_from_the_core_is_noted_or_dropped
    f = frame('020000000103', '020000000202')
    acts = Forwarder.from_core(by_label, core([25_000], f, cw: Mpls::ControlWord.new(1)), policy: :rfc)
    assert_equal [:control_word_set], acts.grep(Note).map(&:finding)
    assert_equal ['eth4'], acts.grep(Deliver).map(&:port)
    acts = Forwarder.from_core(by_label, core([25_000], f, cw: Mpls::ControlWord.new(nibble: 4)), policy: :rfc)
    assert_equal [:control_word_nibble], acts.map(&:reason)
  end

  def test_each_fault_from_the_core
    # Built on the BUM label: the fault's unknown label, one above, is
    # then none of ours.
    Mpls::Fault.catalog.each do |e|
      acts = Forwarder.from_core(by_label, Mpls::Fault.wire(e[:name], label: 25_001), policy: :rfc)
      delivered = !acts.grep(Deliver).empty?
      assert_equal e[:expect] != :drop, delivered, e[:name]
    end
  end
end
