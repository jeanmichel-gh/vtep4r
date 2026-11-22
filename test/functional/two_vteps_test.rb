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
require 'vtep4r'
require 'vxlan/daemon/vtepd'
require 'datalink/backends/loopback'

# Two vtep4rd in one process, with every thread they run: each has a
# host on its own loopback wire, and the two meet over an in-memory
# tunnel. No root, no kernel.
#
#   h1 --wire1-- [l1 10.255.0.11] ==fabric== [l2 10.255.0.12] --wire2-- h2
class Two_vteps_Test < Test::Unit::TestCase
  include VXLAN
  Loopback = Datalink::Backends::Loopback

  H1 = '020000000101'
  H2 = '020000000102'

  def frame(dst, src, tag = '00')
    [dst + src + '88b5' + tag * 46].pack('H*')
  end

  def setup
    @now = 1000.0
    clock = -> { @now }
    quiet = ->(*) {}
    @fabric = Vtep::MemoryTunnel::Fabric.new
    w1 = Loopback::Wire.new
    w2 = Loopback::Wire.new
    @l1 = vtepd('10.255.0.11', '10.255.0.12', w1, clock, quiet)
    @l2 = vtepd('10.255.0.12', '10.255.0.11', w2, clock, quiet)
    @h1 = Datalink::Socket.new('h1', backend: :loopback, wire: w1, recv_timeout: 2).open
    @h2 = Datalink::Socket.new('h2', backend: :loopback, wire: w2, recv_timeout: 2).open
  end

  def teardown
    [@l1, @l2].each(&:stop)
    [@h1, @h2].each(&:close)
  end

  def vtepd(local, peer, wire, clock, logger)
    config = Daemon::Config.new('local' => local, 'ageing' => 300,
                                'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'flood' => [peer] }])
    Daemon::Vtepd.new(config, ports: Vtep::Ports.loopback('eth2' => wire),
                              tunnel: Vtep::MemoryTunnel.new(local, @fabric),
                              clock: clock, logger: logger, age_every: nil).start
  end

  def macs(d)
    d.on_worker { |sw| sw.bridge(100).macs.rows(now: @now).map { |r| [r[:mac], r[:type], r[:port] || r[:vtep]] } }
  end

  # The first frame from h2 may be the one we want or not; skip others.
  def recv_frame(host, want)
    loop do
      got = host.recv.bytes
      return got if got == want
    end
  rescue Datalink::TimeoutError
    nil
  end

  def test_a_broadcast_then_a_unicast_reply
    hello = frame('ffffffffffff', H1)
    @h1.send(hello)
    assert_equal hello, recv_frame(@h2, hello)

    reply = frame(H1, H2, '11')
    @h2.send(reply)
    assert_equal reply, recv_frame(@h1, reply)

    assert_equal [['02:00:00:00:01:01', :local, 'eth2'], ['02:00:00:00:01:02', :remote, '10.255.0.12']], macs(@l1).sort
    assert_equal [['02:00:00:00:01:01', :remote, '10.255.0.11'], ['02:00:00:00:01:02', :local, 'eth2']], macs(@l2).sort
    assert_equal({ rx: 1, tx: 1 }, @l1.counters[:ports]['eth2'])
    assert_equal({ rx: 1, tx: 1 }, @l1.counters[:peers]['10.255.0.12'])
  end

  # Crafted packets into l2 from a VTEP that does not exist. The I flag
  # clear is dropped; an R bit set is ignored and the frame delivered
  # (RFC 7348 section 5).
  def test_faults_from_the_tunnel
    @fabric.deliver('10.255.0.12', '10.255.0.99', Fault.wire(:no_i_flag, vni: 100), 50_000)
    @fabric.deliver('10.255.0.12', '10.255.0.99', Fault.wire(:r_bit_set, vni: 100), 50_000)
    assert_equal Fault::ARP, recv_frame(@h2, Fault::ARP)
    drops, findings = @l2.on_worker { |sw| [sw.drops.dup, sw.findings.dup] }
    assert_equal({ no_i_flag: 1 }, drops)
    assert_equal({ reserved_set: 1 }, findings)
  end

  def test_learned_macs_age_out
    @h1.send(frame('ffffffffffff', H1))
    recv_frame(@h2, frame('ffffffffffff', H1))
    @now += 299
    @l2.age_now
    assert_equal 1, macs(@l2).size
    @now += 1
    @l2.age_now
    assert_equal [], macs(@l2)
  end

  # A port whose interface goes down answers ENETDOWN once (Linux
  # AF_PACKET). The reader logs it and reads again, so frames flow when
  # the interface is back.
  def test_a_port_that_went_down_is_read_again
    @l1.stop
    @h1.close
    w1 = Loopback::Wire.new
    ports = Vtep::Ports.loopback('eth2' => w1)
    downs = 1
    real = ports.method(:recv)
    ports.define_singleton_method(:recv) do |name, timeout|
      if downs.positive?
        downs -= 1
        raise Errno::ENETDOWN, 'recvfrom(2)'
      end
      real.call(name, timeout)
    end
    logged = []
    config = Daemon::Config.new('local' => '10.255.0.11', 'ageing' => 300,
                                'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'flood' => ['10.255.0.12'] }])
    @l1 = Daemon::Vtepd.new(config, ports: ports, tunnel: Vtep::MemoryTunnel.new('10.255.0.11', @fabric),
                                    logger: ->(level, msg) { logged << [level, msg] }, age_every: nil).start
    @h1 = Datalink::Socket.new('h1', backend: :loopback, wire: w1, recv_timeout: 2).open
    sleep Daemon::Vtepd::POLL * 2
    hello = frame('ffffffffffff', H1)
    @h1.send(hello)
    assert_equal hello, recv_frame(@h2, hello)
    assert_equal 1, logged.count { |_, m| m.include?('port eth2: Network is down') }
  end

  def test_on_worker_raises_what_the_block_raised
    assert_raise(KeyError) { @l1.on_worker { {}.fetch(:x) } }
    assert_equal 100, @l1.on_worker { |sw| sw.bridge(100).vni }
  end
end
