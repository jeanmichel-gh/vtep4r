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
end
