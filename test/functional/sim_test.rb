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

root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
$LOAD_PATH.unshift(ENV['DATALINK_LIB']) if ENV['DATALINK_LIB']

require 'test/unit'
require 'json'
require 'net/http'
require 'vtep4r'
require 'vxlan/daemon/vtepd'
require 'vxlan/sim/injector'
require 'vxlan/sim/http'
require 'vxlan/sim/config'
require 'vxlan/vtep/tunnel'

# vtep4r-sim over real HTTP, as routescope's one-line client drives it,
# sending real UDP into a vtep4rd on the loopback. No root.
class Sim_Test < Test::Unit::TestCase
  include VXLAN
  PORT = 47_892

  def setup
    config = Daemon::Config.new('local' => '127.0.0.42', 'vnis' => [{ 'vni' => 100, 'ports' => [] }])
    @vtepd = Daemon::Vtepd.new(config, ports: Vtep::Ports.new, tunnel: Vtep::UdpTunnel.new('127.0.0.42', port: PORT),
                                       logger: ->(*) {}, age_every: nil).start
    @sender = Vtep::UdpSender.new('127.0.0.41', port: PORT)
    @inj = Sim::Injector.new(Sim::Config.new('local' => '127.0.0.41', 'port' => PORT), sender: @sender)
    @http = Sim::Http.new(@inj, port: 0).start
  end

  def teardown
    @inj.act('stop', {})
    @http.stop
    @sender.close
    @vtepd.stop
  end

  # As routescope's Bgp4rSim.post_argv: Net::HTTP sends X-VTEP4R as
  # X-Vtep4r, which the sim must take.
  def post(path, body)
    r = Net::HTTP.post(URI("http://127.0.0.1:#{@http.port}#{path}"), JSON.generate(body),
                       'X-VTEP4R' => 'routescope', 'Content-Type' => 'application/json')
    [r.code.to_i, JSON.parse(r.body)]
  end

  def get(path)
    JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{@http.port}#{path}")))
  end

  def wait_for(seconds = 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until (v = yield)
      flunk('not within the deadline') if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    v
  end

  def test_a_fault_reaches_vtep4rd_and_is_dropped_as_the_rfc_says
    code, r = post('/api/fault', 'to' => '127.0.0.42', 'case' => 'no_i_flag', 'vni' => 100)
    assert_equal [200, 'drop'], [code, r['expect']]
    wait_for { @vtepd.on_worker { |sw| sw.drops[:no_i_flag] == 1 } }
  end

  def test_an_r_bit_is_ignored_and_the_mac_learned
    post('/api/fault', 'to' => '127.0.0.42', 'case' => 'r_bit_set', 'vni' => 100)
    wait_for { @vtepd.on_worker { |sw| sw.findings[:reserved_set] == 1 && sw.bridge(100).macs.size == 1 } }
  end

  # A MAC flood of 200 at 1000 a second: vtep4rd learns every one,
  # behind the sim's address.
  def test_generate_fills_a_mac_table
    code, r = post('/api/generate', 'to' => '127.0.0.42', 'spec' => { 'vni' => 100, 'macs' => 200 }, 'per_second' => 1000)
    assert_equal [200, 200], [code, r['total']]
    wait_for(5) { get('/api/sent')['generate']['state'] == 'finished' }
    rows = wait_for(3) do
      m = @vtepd.on_worker { |sw| sw.bridge(100).macs.rows(now: 0) }
      m.size == 200 && m
    end
    assert_equal ['127.0.0.41'], rows.map { |x| x[:vtep] }.uniq
  end

  def test_no_header_is_403
    r = Net::HTTP.post(URI("http://127.0.0.1:#{@http.port}/api/stop"), '{}', 'Content-Type' => 'application/json')
    assert_equal '403', r.code
  end

  def test_reads_and_events
    post('/api/send', 'to' => '127.0.0.42', 'vni' => 100)
    assert_equal 1, get('/api/status')['packets']
    assert_equal 'send', get('/api/events?since=0')['events'][0]['kind']
    assert_include get('/api/topology')['faults'].map { |f| f['name'] }, 'no_i_flag'
    assert_equal 1, get('/')['api']
  end
end
