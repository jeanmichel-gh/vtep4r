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
require 'vxlan/daemon/api'
require 'datalink/backends/loopback'

# Two vtep4rd as EVPN-over-MPLS PEs in one process, with every thread
# they run: each a host on its own loopback wire, and the two on one
# loopback "core" wire, as neighbors reached by PHP. A sniffer on the
# core wire sees what goes between them. The resolver is a stand-in
# answering what `ip` would; test/lab/mpls_test.rb runs the real one.
#
#   h1 --wire1-- [pe1 10.255.0.1] ==core== [pe2 10.255.0.2] --wire2-- h2
#
# pe1 gave 25000 (unicast) and 25001 (BUM), pe2 26000 and 26001.
class Mpls_two_pes_Test < Test::Unit::TestCase
  include VXLAN
  Loopback = Datalink::Backends::Loopback

  H1 = '020000000101'
  H2 = '020000000102'
  MAC = { '10.255.0.1' => '02:00:00:00:ff:01', '10.255.0.2' => '02:00:00:00:ff:02' }.freeze

  # Answers each PE as `ip` would; +labels+ and +mtu+ and +error+ can be
  # changed under it.
  class FakeTransport
    attr_accessor :labels, :mtu, :error
    attr_reader :asked

    def initialize(me)
      @me = me
      @labels = []
      @mtu = 1500
      @asked = Queue.new
    end

    def resolve(pe)
      @asked << pe
      return VXLAN::Vtep::Transport::Hop.new(pe, nil, nil, nil, nil, nil, nil, @error) if @error

      VXLAN::Vtep::Transport::Hop.new(pe, @labels.dup, pe, 'core0', MAC.fetch(pe), MAC.fetch(@me), @mtu, nil)
    end
  end

  def frame(dst, src, tag = '00')
    [dst + src + '88b5' + tag * 46].pack('H*')
  end

  def setup
    @now = 1000.0
    @core = Loopback::Wire.new
    w1 = Loopback::Wire.new
    w2 = Loopback::Wire.new
    @t1 = FakeTransport.new('10.255.0.1')
    @t2 = FakeTransport.new('10.255.0.2')
    @pe1 = pe('10.255.0.1', w1, @t1, 25_000)
    @pe2 = pe('10.255.0.2', w2, @t2, 26_000)
    @h1 = Datalink::Socket.new('h1', backend: :loopback, wire: w1, recv_timeout: 2).open
    @h2 = Datalink::Socket.new('h2', backend: :loopback, wire: w2, recv_timeout: 2).open
    @sniff = Datalink::Socket.new('p', backend: :loopback, wire: @core, recv_timeout: 2).open
    # Each PE as bgp4rd would set it from the other's type 3 route.
    @pe1.on_worker { |sw| sw.bridge(100).flood_add('10.255.0.2', label: 26_001) }
    @pe2.on_worker { |sw| sw.bridge(100).flood_add('10.255.0.1', label: 25_001) }
  end

  def teardown
    [@pe1, @pe2].each(&:stop)
    [@h1, @h2, @sniff].each(&:close)
  end

  def pe(local, wire, transport, label)
    config = Daemon::Config.new('local' => local, 'core' => ['core0'],
                                'vnis' => [{ 'vni' => 100, 'ports' => ['eth2'], 'mode' => 'evpn', 'encap' => 'mpls',
                                             'labels' => { 'unicast' => label, 'bum' => label + 1 } }])
    Daemon::Vtepd.new(config, ports: Vtep::Ports.loopback('eth2' => wire), tunnel: Vtep::MemoryTunnel.new(local, Vtep::MemoryTunnel::Fabric.new),
                              core: Vtep::Ports.loopback('core0' => @core), transport: transport, resolve_every: 0.05,
                              clock: -> { @now }, logger: ->(*) {}, age_every: nil).start
  end

  def recv_frame(sock, want = nil)
    loop do
      got = sock.recv.bytes
      return got if want.nil? || got == want
    end
  rescue Datalink::TimeoutError
    nil
  end

  # Waits until +pe+ has resolved every PE it sends to.
  def resolved(pe, n = 1)
    deadline = Time.now + 3
    until (rows = pe.on_worker { pe.transport_rows }).size >= n && rows.all? { |r| r[:error].nil? }
      flunk 'not resolved' if Time.now > deadline
      sleep 0.02
    end
    rows
  end

  def test_a_broadcast_crosses_under_the_bum_label
    resolved(@pe1)
    hello = frame('ffffffffffff', H1)
    @h1.send(hello)
    assert_equal hello, recv_frame(@h2, hello)
    assert_equal({ rx: 1, tx: 0 }, @pe2.counters[:core]['core0'])
  end

  # The frame on the core: PE2's MAC from PE1's, EtherType 0x8847, PE2's
  # BUM label with S set, the zero control word, h1's frame.
  def test_what_goes_on_the_core
    resolved(@pe1)
    hello = frame('ffffffffffff', H1)
    @h1.send(hello)
    got = recv_frame(@sniff)
    assert_equal '02000000ff02' '02000000ff01' '8847', got.byteslice(0, 14).unpack1('H*')
    pk = Mpls::Packet.new(got.byteslice(14..))
    assert_equal [[26_001, 1]], pk.labels.map { |l| [l.label, l.s] }
    assert_equal Mpls::ControlWord.new, pk.control_word
    assert_equal hello, pk.inner
  end

  # A known remote MAC goes under the unicast label PE2 gave for it.
  def test_a_unicast_crosses_under_the_pes_label
    @pe1.on_worker { |sw| sw.bridge(100).macs.add(Datalink::MAC.new('02:00:00:00:01:02'), Vtep::Location.vtep('10.255.0.2', 26_000)) }
    resolved(@pe1)
    to_h2 = frame(H2, H1, '11')
    @h1.send(to_h2)
    got = recv_frame(@sniff)
    assert_equal [26_000], Mpls::Packet.new(got.byteslice(14..)).labels.map(&:label)
    assert_equal to_h2, recv_frame(@h2, to_h2)
  end

  # The transport's labels go on top, top first. PE2 is no P: it drops
  # what still carries a transport label, as unknown_label.
  def test_the_transport_labels_go_on_top
    @t1.labels = [16_002, 24_009]
    resolved(@pe1)
    @h1.send(frame('ffffffffffff', H1))
    pk = Mpls::Packet.new(recv_frame(@sniff).byteslice(14..))
    assert_equal [[16_002, 0], [24_009, 0], [26_001, 1]], pk.labels.map { |l| [l.label, l.s] }
    deadline = Time.now + 2
    sleep 0.02 until @pe2.on_worker { |sw| sw.drops[:unknown_label] } == 1 || Time.now > deadline
    assert_equal 1, @pe2.on_worker { |sw| sw.drops[:unknown_label] }
  end

  def test_show_transport
    api = Daemon::Api.new(@pe1, path: '/nonexistent')
    rows = resolved(@pe1)
    assert_equal [{ pe: '10.255.0.2', labels: [], gateway: '10.255.0.2', dev: 'core0', mac: '02:00:00:00:ff:02',
                    src_mac: '02:00:00:00:ff:01', mtu: 1500, error: nil }],
                 rows.map { |r| r.except(:since) }
    assert_match(/\A\d{4}-\d\d-\d\dT/, rows[0][:since])
    assert_equal rows, api.handle('id' => 1, 'method' => 'show.transport')[:result]
  end

  # A PE the resolver cannot reach: the frame is dropped, and
  # show.transport says why.
  def test_no_transport
    @t1.error = 'no route to 10.255.0.2: RTNETLINK answers: Network is unreachable'
    deadline = Time.now + 2
    sleep 0.02 until @pe1.on_worker { @pe1.transport_rows }.any? || Time.now > deadline
    @h1.send(frame('ffffffffffff', H1))
    sleep 0.1
    assert_equal 1, @pe1.on_worker { |sw| sw.drops[:no_transport] }
    assert_equal @t1.error, @pe1.on_worker { @pe1.transport_rows }[0][:error]
  end

  # A frame that does not fit the core device's MTU with its labels is
  # dropped: 4 for the EVPN label and 4 for the control word over the
  # frame's 60, against an MTU of 67.
  def test_too_big
    @t1.mtu = 67
    resolved(@pe1)
    @h1.send(frame('ffffffffffff', H1))
    sleep 0.1
    assert_equal 1, @pe1.on_worker { |sw| sw.drops[:too_big] }
    @t1.mtu = 68
    sleep 0.2
    @h1.send(frame('ffffffffffff', H1))
    assert_not_nil recv_frame(@h2)
  end

  # A label change is picked up at the next resolution.
  def test_a_new_label_is_used_after_the_next_resolution
    resolved(@pe1)
    @t1.labels = [16_002]
    deadline = Time.now + 2
    sleep 0.02 until @pe1.on_worker { @pe1.transport_rows }[0][:labels] == [16_002] || Time.now > deadline
    assert_equal [16_002], @pe1.on_worker { @pe1.transport_rows }[0][:labels]
  end

  # Faults from the core into pe2, from a PE that does not exist.
  def test_faults_from_the_core
    head = ['02000000ff02' '02000000ff09' '8847'].pack('H*')
    Mpls::Fault.catalog.each do |e|
      @sniff.send(head + Mpls::Fault.wire(e[:name], label: 26_001))
    end
    got = []
    while (f = recv_frame(@h2)) && got.size < 5
      got << f
    end
    drops = @pe2.on_worker { |sw| sw.drops.dup }
    # no_bottom is read into the frame until an S bit, and then fails as a
    # control word (docs/mpls.md): two control_word_nibble drops.
    assert_equal({ no_control_word: 1, control_word_nibble: 2, short: 1, unknown_label: 1 },
                 drops.slice(:no_control_word, :control_word_nibble, :short, :unknown_label))
    assert_equal 3, got.size, 'control_word_set and the two explicit nulls are delivered'
  end
end
