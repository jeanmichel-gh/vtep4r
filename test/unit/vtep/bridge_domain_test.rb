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

class Bridge_domain_Test < Test::Unit::TestCase
  include VXLAN::Vtep

  def test_defaults
    bd = BridgeDomain.new(vni: 100, ports: ['eth2'])
    assert_equal [100, ['eth2'], :learn, [], 300], [bd.vni, bd.ports, bd.mode, bd.flood, bd.macs.ageing]
  end

  def test_a_bad_mode_or_vni_is_refused
    assert_raise(ArgumentError) { BridgeDomain.new(vni: 100, ports: [], mode: :static) }
    assert_raise(ArgumentError) { BridgeDomain.new(vni: 0x1000000, ports: []) }
  end

  def test_the_flood_list
    bd = BridgeDomain.new(vni: 100, ports: [], flood: %w[10.0.0.2 10.0.0.2])
    assert_equal ['10.0.0.2'], bd.flood
    assert bd.flood_add('10.0.0.3')
    refute bd.flood_add('10.0.0.3')
    assert bd.flood_del('10.0.0.2')
    refute bd.flood_del('10.0.0.2')
    assert_equal ['10.0.0.3'], bd.flood
  end

  def test_a_port_in_two_vnis_is_refused
    assert_raise(ArgumentError) do
      VXLAN::Vtep::Switch.new(local: '10.0.0.1', vnis: [{ vni: 1, ports: ['eth2'] }, { vni: 2, ports: ['eth2'] }])
    end
  end

  def test_a_vni_twice_is_refused
    assert_raise(ArgumentError) do
      VXLAN::Vtep::Switch.new(local: '10.0.0.1', vnis: [{ vni: 1, ports: ['eth2'] }, { vni: 1, ports: ['eth3'] }])
    end
  end

  def test_flood_replace
    bd = BridgeDomain.new(vni: 100, ports: [], flood: %w[10.0.0.2])
    refute bd.flood_replace(%w[10.0.0.2])
    assert bd.flood_replace(%w[10.0.0.3 10.0.0.3 10.0.0.4])
    assert_equal %w[10.0.0.3 10.0.0.4], bd.flood
  end

  def test_a_vni_added_and_removed_at_run_time
    sw = VXLAN::Vtep::Switch.new(local: '10.0.0.1', vnis: [{ vni: 1, ports: ['eth2'] }])
    bd = sw.add_vni(vni: 2, ports: ['eth3'])
    assert_equal bd, sw.bridge(2)
    assert_raise(ArgumentError) { sw.add_vni(vni: 3, ports: ['eth3']) }
    assert_equal bd, sw.del_vni(2)
    assert_nil sw.del_vni(2)
    frame = ['ffffffffffff020000000101' + '88b5' + '00' * 46].pack('H*')
    assert_equal [:unknown_port], sw.from_port('eth3', frame, 0).map(&:reason)
    assert sw.add_vni(vni: 3, ports: ['eth3'])
  end
end
