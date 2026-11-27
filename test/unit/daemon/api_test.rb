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
require 'fileutils'

# The API's methods through #handle, with no socket: a Vtepd on a
# loopback port and an in-memory tunnel.
class Api_Test < Test::Unit::TestCase
  include VXLAN

  def setup
    @now = 100.0
    config = Daemon::Config.new('local' => '10.255.0.11',
                                'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'flood' => ['10.255.0.12'] }])
    @vtepd = Daemon::Vtepd.new(config, ports: Vtep::Ports.loopback({ 'eth2' => Datalink::Backends::Loopback::Wire.new, 'eth3' => Datalink::Backends::Loopback::Wire.new }, ['eth2']),
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
    assert_match(/unknown method "show.foo"; this vtep4rd answers api.info, config.reload, events.subscribe/, r[:error])
  end

  def test_show_status
    @now = 112.34
    s = call('show.status')[:result]
    assert_equal ['10.255.0.11', [100], :rfc, 1500, 12.3], s.values_at(:local, :vnis, :receive_policy, :mtu, :uptime)
  end

  def test_show_vnis
    assert_equal [{ vni: 100, type: 'L2', vtep_ip: '10.255.0.11', ports: ['eth2'], mode: :learn,
                    remote_vteps: ['10.255.0.12'], flood: 'HER', macs: 0, ageing: 300, encap: :vxlan }],
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

  def test_info_says_where_the_event_stream_is
    i = call('api.info')[:result]
    assert_equal %w[mac drop config overflow], i[:event_kinds]
    assert_kind_of Integer, i[:event_seq]
    assert_include i[:methods], 'events.subscribe'
  end

  def test_a_stream_needs_the_socket
    assert_match(/is a stream/, call('events.subscribe')[:error])
    assert_equal({ unsubscribed: false }, call('events.unsubscribe')[:result])
  end

  def test_vni_add_opens_its_port_and_vni_del_closes_it
    r = call('vni.add', 'vni' => 200, 'ports' => ['eth3'], 'flood' => ['10.255.0.13'])[:result]
    assert_equal({ vni: 200, ports: ['eth3'], mode: :learn, flood: ['10.255.0.13'] }, r)
    assert_equal [100, 200], call('show.status')[:result][:vnis]
    assert_match(/port eth3 in vni 200 and 300/, call('vni.add', 'vni' => 300, 'ports' => ['eth3'])[:error])
    assert_match(/vni 100 twice/, call('vni.add', 'vni' => 100, 'ports' => [])[:error])
    assert_match(/unknown vni key port/, call('vni.add', 'vni' => 400, 'port' => ['eth9'])[:error])
    assert_match(/vni 500: flood is for learn mode/,
                 call('vni.add', 'vni' => 500, 'ports' => ['eth9'], 'mode' => 'evpn', 'flood' => ['10.255.0.13'])[:error])
    assert_equal %w[eth2 eth3], call('show.status')[:result][:ports]
    assert_equal({ vni: 200, macs: 0 }, call('vni.del', 'vni' => 200)[:result])
    assert_equal [[100], ['eth2']], call('show.status')[:result].values_at(:vnis, :ports)
    assert_match(/no vni 200/, call('vni.del', 'vni' => 200)[:error])
  end

  def test_config_reload_without_a_file
    assert_match(/not started from a file/, call('config.reload')[:error])
  end

  def test_config_reload
    dir = File.join(ENV['TMPDIR'] || '/tmp', "vtep4r-r#{Process.pid}-#{rand(1 << 16)}")
    Dir.mkdir(dir)
    file = File.join(dir, 'f.yml')
    api = Daemon::Api.new(@vtepd, path: '/nonexistent', config_path: file)
    File.write(file, "local: 10.255.0.11\nageing: 60\nvnis:\n  - vni: 100\n    ports: [eth2]\n    flood: [10.255.0.12, 10.255.0.14]\n" \
                     "  - vni: 200\n    ports: [eth3]\n")
    r = api.handle('id' => 1, 'method' => 'config.reload')[:result]
    assert_equal({ added: [200], removed: [], replaced: [], changed: [100], needs_restart: [] }, r)
    assert_equal [['10.255.0.12', '10.255.0.14'], 60], call('show.vnis')[:result][0].values_at(:remote_vteps, :ageing)

    File.write(file, "local: 10.255.0.99\nvnis:\n  - vni: 100\n    ports: [eth2]\n    mode: evpn\n")
    r = api.handle('id' => 2, 'method' => 'config.reload')[:result]
    assert_equal({ added: [], removed: [200], replaced: [100], changed: [], needs_restart: [:local] }, r)
    assert_equal '10.255.0.11', call('show.status')[:result][:local]

    File.write(file, "local: [\n")
    assert_match(/f.yml/, api.handle('id' => 3, 'method' => 'config.reload')[:error])
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # Labels in the file are set in place; a change of encapsulation
  # replaces the VNI, as a change of mode does.
  def test_config_reload_over_mpls
    dir = File.join(ENV['TMPDIR'] || '/tmp', "vtep4r-m#{Process.pid}-#{rand(1 << 16)}")
    Dir.mkdir(dir)
    file = File.join(dir, 'f.yml')
    api = Daemon::Api.new(@vtepd, path: '/nonexistent', config_path: file)
    head = "local: 10.255.0.11\nvnis:\n  - vni: 100\n    ports: [eth2]\n    flood: [10.255.0.12]\n"
    mpls = "  - vni: 200\n    ports: [eth3]\n    mode: evpn\n    encap: mpls\n"
    File.write(file, "#{head}#{mpls}    labels: { unicast: 25000, bum: 25001 }\n")
    assert_equal [200], api.handle('id' => 1, 'method' => 'config.reload')[:result][:added]
    File.write(file, "#{head}#{mpls}    labels: { unicast: 25000, bum: 25002 }\n")
    assert_equal [200], api.handle('id' => 2, 'method' => 'config.reload')[:result][:changed]
    assert_equal [25_000, 25_002], call('show.labels')[:result].map { |r| r[:label] }
    File.write(file, "#{head}#{mpls}")
    r = api.handle('id' => 3, 'method' => 'config.reload')[:result]
    assert_equal [[], []], r.values_at(:changed, :replaced)
    assert_equal [25_000, 25_002], call('show.labels')[:result].map { |r2| r2[:label] }, 'no labels in the file: kept'
    File.write(file, "#{head}  - vni: 200\n    ports: [eth3]\n    mode: evpn\n")
    assert_equal [200], api.handle('id' => 4, 'method' => 'config.reload')[:result][:replaced]
    assert_equal [], call('show.labels')[:result]
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  def test_a_reload_described_in_words
    assert_equal 'nothing changed', Daemon::Vtepd.describe(added: [], removed: [], needs_restart: [])
    assert_equal 'added 200, 300; needs_restart local',
                 Daemon::Vtepd.describe(added: [200, 300], removed: [], needs_restart: [:local])
  end

  # EVPN over MPLS.

  def add_mpls(labels = { 'unicast' => 25_000, 'bum' => 25_001 })
    call('vni.add', { 'vni' => 200, 'ports' => ['eth3'], 'mode' => 'evpn', 'encap' => 'mpls', 'labels' => labels }.compact)
  end

  def test_an_mpls_vni_added_with_its_labels
    r = add_mpls[:result]
    assert_equal [:mpls, { unicast: 25_000, bum: 25_001 }], r.values_at(:encap, :labels)
    row = call('show.vnis')[:result].find { |v| v[:vni] == 200 }
    assert_equal [:mpls, { unicast: 25_000, bum: 25_001 }, {}], row.values_at(:encap, :labels, :flood_labels)
    assert_equal [{ label: 25_000, vni: 200, kind: :unicast }, { label: 25_001, vni: 200, kind: :bum }],
                 call('show.labels')[:result]
  end

  def test_vni_labels_sets_them_later
    add_mpls(nil)
    assert_nil call('show.vnis')[:result].find { |v| v[:vni] == 200 }[:labels]
    r = call('vni.labels', 'vni' => 200, 'unicast' => 25_010, 'bum' => 25_011)[:result]
    assert_equal [true, { unicast: 25_010, bum: 25_011 }], r.values_at(:changed, :labels)
    refute call('vni.labels', 'vni' => 200, 'unicast' => 25_010, 'bum' => 25_011)[:result][:changed]
    assert_match(/labels are for encap mpls/, call('vni.labels', 'vni' => 100, 'unicast' => 25_020, 'bum' => 25_021)[:error])
    assert_match(/is not 16 to/, call('vni.labels', 'vni' => 200, 'unicast' => 3, 'bum' => 25_021)[:error])
  end

  def test_a_remote_mac_and_flood_entry_over_mpls_carry_the_pes_label
    add_mpls
    assert_match(/needs the remote PE's label/, call('mac.add', 'vni' => 200, 'mac' => '02:00:00:00:02:02', 'vtep' => '10.255.0.12')[:error])
    r = call('mac.add', 'vni' => 200, 'mac' => '02:00:00:00:02:02', 'vtep' => '10.255.0.12', 'label' => 26_000)[:result]
    assert_equal 26_000, r[:label]
    assert_equal 26_000, call('show.macs', 'vni' => 200)[:result][0][:label]
    assert_match(/needs the remote PE's label/, call('vni.flood.add', 'vni' => 200, 'vtep' => '10.255.0.12')[:error])
    r = call('vni.flood.add', 'vni' => 200, 'vtep' => '10.255.0.12', 'label' => 26_001)[:result]
    assert_equal [true, 26_001], r.values_at(:changed, :label)
    assert_equal({ '10.255.0.12' => 26_001 }, call('show.vnis')[:result].find { |v| v[:vni] == 200 }[:flood_labels])
  end

  def test_a_vxlan_vni_takes_no_label
    assert_match(/a label is for encap mpls/, call('mac.add', 'vni' => 100, 'mac' => '02:00:00:00:02:02', 'vtep' => '10.255.0.12', 'label' => 26_000)[:error])
    assert_match(/a label is for encap mpls/, call('vni.flood.add', 'vni' => 100, 'vtep' => '10.255.0.13', 'label' => 26_001)[:error])
    assert_nil call('show.macs')[:result].find { |m| m.key?(:label) }
  end

  def test_an_mpls_vni_in_learn_mode_is_refused
    assert_match(/needs mode evpn/, call('vni.add', 'vni' => 300, 'ports' => [], 'encap' => 'mpls')[:error])
  end

  # Until the MPLS edge is built, what would go to a PE is a drop of its
  # own, counted and published.
  def test_a_frame_for_a_pe_is_a_no_mpls_edge_drop
    add_mpls
    call('vni.flood.add', 'vni' => 200, 'vtep' => '10.255.0.12', 'label' => 26_001)
    @vtepd.on_worker do |sw|
      @vtepd.send(:execute, sw.from_port('eth3', ['ffffffffffff020000000101' + '88b5' + '00' * 46].pack('H*'), @now), port: 'eth3')
    end
    assert_equal 1, call('show.counters')[:result][:drops][:no_mpls_edge]
  end
end
