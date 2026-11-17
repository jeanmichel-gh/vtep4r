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
require 'vtep4r'
require 'vxlan/daemon/vtepd'
require 'vxlan/daemon/api'
require 'datalink/backends/loopback'

# The API's methods through #handle, with no socket: a Vtepd on a
# loopback port and an in-memory tunnel.
class Api_Test < Test::Unit::TestCase
  include VXLAN

  def setup
    @now = 100.0
    config = Daemon::Config.new('local' => '10.255.0.11',
                                'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'flood' => ['10.255.0.12'] }])
    @vtepd = Daemon::Vtepd.new(config, ports: Vtep::Ports.loopback('eth2' => Datalink::Backends::Loopback::Wire.new),
                                       tunnel: Vtep::MemoryTunnel.new('10.255.0.11', Vtep::MemoryTunnel::Fabric.new),
                                       clock: -> { @now }, logger: ->(*) {}, age_every: nil).start
    @api = Daemon::Api.new(@vtepd, path: '/nonexistent/never-started.sock', clock: -> { @now })
  end

  def teardown
    @vtepd.stop
  end

  def call(method, params = {})
    @api.handle('id' => 7, 'method' => method, 'params' => params)
  end

  def test_the_envelope
    r = call('api.info')
    assert_equal 7, r[:id]
    assert_equal VXLAN::VERSION, r[:result][:version]
    assert_equal 1, r[:result][:api]
    assert_include r[:result][:methods], 'show.macs'
  end

  def test_an_unknown_method_names_the_ones_that_exist
    r = call('show.foo')
    assert_match(/unknown method "show.foo"; this vtep4rd answers api.info, mac.add/, r[:error])
  end

  def test_show_status
    @now = 112.34
    s = call('show.status')[:result]
    assert_equal ['10.255.0.11', [100], :rfc, 1500, 12.3], s.values_at(:local, :vnis, :receive_policy, :mtu, :uptime)
  end

  def test_show_vnis
    assert_equal [{ vni: 100, type: 'L2', vtep_ip: '10.255.0.11', ports: ['eth2'], mode: :learn,
                    remote_vteps: ['10.255.0.12'], flood: 'HER', macs: 0, ageing: 300 }],
                 call('show.vnis')[:result]
  end

  def test_flood_add_and_del
    assert_equal true, call('vni.flood.add', 'vni' => 100, 'vtep' => '10.255.0.13')[:result][:changed]
    assert_equal false, call('vni.flood.add', 'vni' => 100, 'vtep' => '10.255.0.13')[:result][:changed]
    assert_equal %w[10.255.0.12 10.255.0.13], call('show.vnis')[:result][0][:remote_vteps]
    assert_equal ['10.255.0.12'], call('vni.flood.del', 'vni' => 100, 'vtep' => '10.255.0.13')[:result][:flood]
  end

  def test_mac_add_show_del_and_flush
    r = call('mac.add', 'vni' => 100, 'mac' => '02:00:00:00:01:09', 'vtep' => '10.255.0.13', 'seq' => 2)
    assert_equal({ vni: 100, mac: '02:00:00:00:01:09', vtep: '10.255.0.13', seq: 2 }, r[:result])
    assert_equal [{ vni: 100, mac: '02:00:00:00:01:09', type: :remote, port: nil, vtep: '10.255.0.13',
                    origin: :api, age: nil, seq: 2, moves: 0 }], call('show.macs', 'vni' => 100)[:result]
    assert_equal true, call('mac.del', 'vni' => 100, 'mac' => '02:00:00:00:01:09')[:result][:deleted]
    call('mac.add', 'vni' => 100, 'mac' => '02:00:00:00:01:09', 'vtep' => '10.255.0.13')
    assert_equal 1, call('mac.flush', 'vni' => 100, 'origin' => 'api')[:result][:flushed]
    assert_equal [], call('show.macs')[:result]
  end

  def test_show_counters
    c = call('show.counters')[:result]
    assert_equal({ ports: {}, peers: {}, drops: {}, findings: {} }, c)
  end

  # Wrong parameters are the caller's error, said plainly; the API goes on.
  def test_bad_parameters
    assert_match(/no vni 5; this vtep4rd has 100/, call('show.macs', 'vni' => 5)[:error])
    assert_match(/key not found: "vtep"/, call('vni.flood.add', 'vni' => 100)[:error])
    assert_match(/zz/, call('mac.add', 'vni' => 100, 'mac' => 'zz', 'vtep' => '1.1.1.1')[:error])
    assert_match(/origin/, call('mac.flush', 'vni' => 100, 'origin' => 'all')[:error])
    assert_match(/invalid value/, call('show.macs', 'vni' => 'x')[:error])
    assert_equal 'L2', call('show.vnis')[:result][0][:type]
  end

  def test_params_that_are_not_an_object_are_none
    r = @api.handle('id' => 1, 'method' => 'show.vnis', 'params' => [1, 2])
    assert_equal 1, r[:result].size
  end

  def test_a_method_that_breaks_is_an_internal_error_not_a_crash
    @vtepd.stop
    @vtepd = Daemon::Vtepd.new(Daemon::Config.new('local' => '1.1.1.1'),
                               ports: Vtep::Ports.new({}), tunnel: Vtep::MemoryTunnel.new('1.1.1.1', Vtep::MemoryTunnel::Fabric.new),
                               logger: ->(*) {}, age_every: nil).start
    lines = []
    api = Daemon::Api.new(@vtepd, path: '/nonexistent', logger: ->(l, m) { lines << [l, m] })
    def @vtepd.counters = raise(NoMethodError, 'boom')
    assert_equal 'internal error: NoMethodError', api.handle('id' => 1, 'method' => 'show.counters')[:error]
    assert_equal :error, lines[0][0]
  end
end
