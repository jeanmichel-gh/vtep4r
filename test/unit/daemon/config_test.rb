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
require 'vxlan/daemon/config'

class Config_Test < Test::Unit::TestCase
  Config = VXLAN::Daemon::Config

  FILE = <<~YAML
    local: 10.255.0.11
    socket: /run/vtep4r/vtep4rd.sock
    receive_policy: rfc
    ageing: 300
    vnis:
      - vni: 100
        ports: [eth2]
        mode: learn
        flood: [10.255.0.12]
  YAML

  def test_the_design_documents_file
    c = Config.new(YAML.safe_load(FILE))
    assert_equal '10.255.0.11', c.local
    assert_equal :rfc, c.receive_policy
    assert_equal 1500, c.mtu
    assert_equal [{ vni: 100, ports: ['eth2'], mode: :learn, flood: ['10.255.0.12'], ageing: 300, encap: :vxlan,
                    labels: nil }], c.vnis
    assert_equal ['eth2'], c.ports
  end

  def test_switch_args_build_a_switch
    require 'vxlan/vtep'
    sw = VXLAN::Vtep::Switch.new(**Config.new(YAML.safe_load(FILE)).switch_args)
    assert_equal ['10.255.0.12'], sw.bridge(100).flood
  end

  def test_a_vni_takes_the_files_ageing_unless_it_has_its_own
    c = Config.new('local' => '1.1.1.1', 'ageing' => 30,
                   'vnis' => [{ 'vni' => 1, 'ports' => ['a'] }, { 'vni' => 2, 'ports' => ['b'], 'ageing' => 5 }])
    assert_equal [30, 5], c.vnis.map { |v| v[:ageing] }
  end

  def test_an_unknown_key_is_refused_by_name
    e = assert_raise(Config::Error) { Config.new('local' => '1.1.1.1', 'flod' => []) }
    assert_match(/flod/, e.message)
    e = assert_raise(Config::Error) { Config.new('local' => '1.1.1.1', 'vnis' => [{ 'vni' => 1, 'port' => ['a'] }]) }
    assert_match(/port/, e.message)
  end

  # In evpn mode the flood list is bgp4rd's, through the API.
  def test_a_flood_list_in_evpn_mode_is_refused
    e = assert_raise(Config::Error) do
      Config.new('local' => '1.1.1.1', 'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'mode' => 'evpn', 'flood' => ['10.255.0.12'] }])
    end
    assert_match(/vni 100: flood is for learn mode/, e.message)
    v = Config.new('local' => '1.1.1.1', 'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'mode' => 'evpn', 'flood' => [] }]).vnis.first
    assert_equal [:evpn, []], v.values_at(:mode, :flood)
  end

  def test_local_is_required
    assert_raise(Config::Error) { Config.new('vnis' => []) }
  end

  def test_not_a_mapping
    assert_raise(Config::Error) { Config.new([1]) }
  end

  def test_a_bad_number
    assert_raise(Config::Error) { Config.new('local' => '1.1.1.1', 'mtu' => 'big') }
  end

  # EVPN over MPLS.

  def test_an_mpls_vni
    c = VXLAN::Daemon::Config.new('local' => '10.255.0.11',
                                  'vnis' => [{ 'vni' => 200, 'ports' => ['eth3'], 'mode' => 'evpn', 'encap' => 'mpls',
                                               'labels' => { 'unicast' => 25_000, 'bum' => 25_001 } }])
    assert_equal [:mpls, { unicast: 25_000, bum: 25_001 }], c.vnis[0].values_at(:encap, :labels)
    VXLAN::Vtep::Switch.new(**c.switch_args)
  end

  def test_labels_are_both_or_neither_and_nothing_else
    base = { 'vni' => 200, 'mode' => 'evpn', 'encap' => 'mpls' }
    [{ 'unicast' => 25_000 }, { 'unicast' => 25_000, 'bum' => 25_001, 'evi' => 1 }, [25_000, 25_001]].each do |l|
      assert_raise(VXLAN::Daemon::Config::Error, l.inspect) do
        VXLAN::Daemon::Config.new('local' => '1.1.1.1', 'vnis' => [base.merge('labels' => l)])
      end
    end
  end
end
