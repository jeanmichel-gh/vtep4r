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
require 'fileutils'
require 'vtep4r'
require 'vxlan/daemon/vtepd'
require 'vxlan/daemon/api'
require 'vxlan/daemon/client'
require 'datalink/backends/loopback'

# The event stream over a real socket, in bgp4rd's form, and a VNI
# added at run time that forwards at once.
class Events_stream_Test < Test::Unit::TestCase
  include VXLAN
  Loopback = Datalink::Backends::Loopback

  def setup
    @dir = File.join(ENV['TMPDIR'] || '/tmp', "vtep4r-e#{Process.pid}-#{rand(1 << 16)}")
    @path = File.join(@dir, 'v.sock')
    @w2 = Loopback::Wire.new
    @w3 = Loopback::Wire.new
    @fabric = Vtep::MemoryTunnel::Fabric.new
    @peer = Vtep::MemoryTunnel.new('10.255.0.12', @fabric)
    config = Daemon::Config.new('local' => '10.255.0.11',
                                'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'flood' => ['10.255.0.12'] }])
    @vtepd = Daemon::Vtepd.new(config, ports: Vtep::Ports.loopback({ 'eth2' => @w2, 'eth3' => @w3 }, ['eth2']),
                                       tunnel: Vtep::MemoryTunnel.new('10.255.0.11', @fabric),
                                       logger: ->(*) {}, age_every: nil).start
    @api = Daemon::Api.new(@vtepd, path: @path, keepalive: 0.5).start
    @h1 = Datalink::Socket.new('h1', backend: :loopback, wire: @w2).open
  end

  def teardown
    @api.stop
    @vtepd.stop
    @h1.close
    FileUtils.rm_rf(@dir)
  end

  def frame(src)
    ['ffffffffffff' + src + '88b5' + '00' * 46].pack('H*')
  end

  def line(s, timeout = 3)
    s.wait_readable(timeout) or flunk('no line within the timeout')
    JSON.parse(s.gets)
  end

  def test_subscribe_see_a_mac_learned_then_unsubscribe
    s = UNIXSocket.new(@path)
    s.write(%({"id":2,"method":"events.subscribe","params":{"kinds":["mac"]}}\n))
    r = line(s)
    assert_equal [2, 0], [r['id'], r['result']['replayed']]
    assert_equal ['mac'], r['result']['kinds']

    @h1.send(frame('020000000101'))
    ev = line(s)['event']
    assert_equal %w[info mac], ev.values_at('level', 'kind')
    assert_equal({ 'type' => 'learned', 'vni' => 100, 'mac' => '02:00:00:00:01:01', 'port' => 'eth2' }, ev['data'])
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, ev['time'])

    s.write(%({"id":3,"method":"show.vnis","params":{}}\n))
    r = line(s)
    assert_equal 3, r['id']
    assert_match(/show.vnis refused: this connection is streaming events/, r['error'])

    s.write(%({"id":4,"method":"events.unsubscribe"}\n))
    r = line(s)
    r = line(s) while r['keepalive'] || r['event']
    assert_equal({ 'id' => 4, 'result' => { 'unsubscribed' => true } }, r)
    assert_equal 0, @vtepd.events.subscribers

    s.write(%({"id":5,"method":"show.status","params":{}}\n))
    assert_equal 5, line(s)['id']
  ensure
    s&.close
  end

  def test_a_quiet_stream_sends_keepalives
    s = UNIXSocket.new(@path)
    s.write(%({"id":1,"method":"events.subscribe","params":{}}\n))
    line(s)
    k = line(s, 3)
    assert_kind_of String, k['keepalive']
    assert_kind_of Integer, k['seq']
  ensure
    s&.close
  end

  def test_since_replays_and_a_drop_is_an_event
    @fabric.deliver('10.255.0.11', '10.255.0.99', Fault.wire(:no_i_flag, vni: 100), 50_000)
    @vtepd.on_worker { nil } # the drop is processed once the worker answers
    s = UNIXSocket.new(@path)
    s.write(%({"id":1,"method":"events.subscribe","params":{"since":0}}\n))
    assert_equal 1, line(s)['result']['replayed']
    ev = line(s)['event']
    assert_equal ['drop', '10.255.0.99', { 'reason' => 'no_i_flag' }], ev.values_at('kind', 'peer', 'data')
  ensure
    s&.close
  end

  def test_a_bad_kind_is_refused_and_the_connection_goes_on
    s = UNIXSocket.new(@path)
    s.write(%({"id":1,"method":"events.subscribe","params":{"kinds":["session"]}}\n))
    assert_match(/unknown event kind session/, line(s)['error'])
    s.write(%({"id":2,"method":"api.info","params":{}}\n))
    assert_equal 2, line(s)['id']
  ensure
    s&.close
  end

  # vni.add opens eth3 and starts its reader: a frame on it is flooded to
  # the VNI's VTEP at once. vni.del closes it again.
  def test_a_vni_added_at_run_time_forwards
    c = Daemon::Client.new(@path)
    c.call('vni.add', 'vni' => 200, 'ports' => ['eth3'], 'flood' => ['10.255.0.12'])
    h3 = Datalink::Socket.new('h3', backend: :loopback, wire: @w3).open
    h3.send(frame('020000000103'))
    from, octets = @peer.recv(3)
    assert_equal '10.255.0.11', from
    assert_equal 200, Packet.new(octets).header.vni
    c.call('vni.del', 'vni' => 200)
    assert_equal({ 'vni' => 100 }, c.call('show.vnis').map { |v| v.slice('vni') }.first)
  ensure
    h3&.close
    c&.close
  end


  # vtep4r-cli events.subscribe, through Client#stream, until it stops.
  def test_the_client_streams_and_unsubscribes
    c = Daemon::Client.new(@path)
    lines = []
    Thread.new { sleep 0.3; @h1.send(frame('020000000102')) }
    # In a thread with a deadline: a stream that never sends the event
    # must fail the test, not hang it.
    reader = Thread.new do
      c.stream('events.subscribe', 'kinds' => 'mac') do |l|
        lines << l
        !l.key?('event')
      end
    end
    unless reader.join(5)
      reader.kill
      flunk("no mac event within 5 s: #{lines.inspect}")
    end
    assert_equal 0, lines[0]['result']['replayed']
    assert_equal 'mac', lines[1]['event']['kind']
    assert_equal 0, @vtepd.events.subscribers
    assert_equal 1, c.call('api.info')['api']
  ensure
    c&.close
  end
end
