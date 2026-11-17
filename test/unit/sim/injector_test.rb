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
require 'vxlan/sim/injector'
require 'vxlan/sim/config'

# The injector alone: a recording sender, and a clock and a sleeper a
# test owns, so pacing is checked without waiting.
class Injector_Test < Test::Unit::TestCase
  include VXLAN

  class Recorder
    attr_reader :sent

    def initialize
      @sent = []
    end

    def send(octets, vtep, source_port)
      @sent << [octets, vtep, source_port]
    end
  end

  def setup
    @now = 0.0
    @sleeps = []
    @rec = Recorder.new
    @inj = Sim::Injector.new(Sim::Config.new('local' => '10.255.0.11'), sender: @rec, clock: -> { @now },
                                                                        sleeper: ->(s) { @sleeps << s.round(3); @now += s })
  end

  def test_send_any_header
    r = @inj.act('send', 'to' => '10.255.0.12', 'vni' => 100, 'flags' => 0x0c, 'reserved2' => 7)
    assert_equal({ sent: 1, to: '10.255.0.12', octets: 50 }, r)
    octets, to, = @rec.sent.first
    assert_equal ['0c00000000006407', '10.255.0.12'], [octets.byteslice(0, 8).unpack1('H*'), to]
    assert_equal Fault::ARP, octets.byteslice(8..)
  end

  def test_send_with_inner_hex_and_a_source_port
    @inj.act('send', 'to' => '10.255.0.12', 'vni' => 1, 'inner' => 'aabb', 'source_port' => 50_001)
    octets, _, port = @rec.sent.first
    assert_equal ['aabb', 50_001], [octets.byteslice(8..).unpack1('H*'), port]
  end

  # The default source port is vtep4rd's: a hash of the inner header.
  def test_the_source_port_is_the_flows
    @inj.act('send', 'to' => '10.255.0.12', 'vni' => 1)
    assert_equal Vtep::Forwarder.source_port(Fault::ARP), @rec.sent.first[2]
  end

  def test_fault_by_name
    r = @inj.act('fault', 'to' => '10.255.0.12', 'case' => 'no_i_flag', 'vni' => 100)
    assert_equal({ sent: 1, to: '10.255.0.12', case: :no_i_flag, expect: :drop, rfc: 'RFC 7348 5, 4.1' }, r)
    assert_equal '0000000000006400', @rec.sent.first[0].byteslice(0, 8).unpack1('H*')
    assert_equal({ no_i_flag: 1 }, @inj.sent[:fault])
  end

  def test_refusals
    [['send', { 'vni' => 1 }, /to: the VTEP/],
     ['send', { 'to' => '10.0.0.1' }, /send needs vni/],
     ['send', { 'to' => 'x', 'vni' => 1 }, /not an address/],
     ['send', { 'to' => '10.0.0.1', 'vni' => 1, 'inner' => 'abc' }, /even number of hex/],
     ['send', { 'to' => '10.0.0.1', 'vni' => 0x1000000 }, /vni/],
     ['send', { 'to' => '10.0.0.1', 'vni' => 1, 'flood' => 1 }, /not flood/],
     ['fault', { 'to' => '10.0.0.1', 'case' => 'nope', 'vni' => 1 }, /one of no_i_flag/],
     ['fault', { 'to' => '10.0.0.1', 'case' => 'no_i_flag' }, /needs vni/],
     ['generate', { 'to' => '10.0.0.1', 'spec' => { 'vni' => 1, 'bogus' => 2 } }, /spec: unknown key bogus/],
     ['generate', { 'to' => '10.0.0.1', 'spec' => { 'vni' => 1 }, 'per_second' => 0 }, /per_second/]]
      .each do |action, body, msg|
      e = assert_raise(Sim::Refused, "#{action} #{body}") { @inj.act(action, body) }
      assert_match(msg, e.message)
    end
    assert_raise(Sim::Refused) { @inj.act('jump', {}) }
  end

  # Paced from the start: packet i goes at i / per_second.
  def test_generate_paced
    r = @inj.act('generate', 'to' => '10.255.0.12', 'spec' => { 'vni' => 100, 'macs' => 5 }, 'per_second' => 10)
    assert_equal({ started: true, to: '10.255.0.12', total: 5, per_second: 10 }, r)
    @inj.join(5)
    assert_equal 5, @rec.sent.size
    assert_equal [0.1] * 4, @sleeps
    g = @inj.sent[:generate]
    assert_equal ['finished', 5, 5], g.values_at(:state, :sent, :total)
    assert_equal 5, @rec.sent.map { |o, _, _| o.byteslice(8 + 6, 6) }.uniq.size
  end

  def test_generate_unpaced_sends_without_sleeping
    @inj.act('generate', 'to' => '10.255.0.12', 'spec' => { 'vni' => 1, 'macs' => 3 })
    @inj.join(5)
    assert_equal [3, []], [@rec.sent.size, @sleeps]
  end

  # The real clock and the real wait: at 0.01 a second each wait is 100 s,
  # and stop must still return at once, not after it.
  def test_one_generation_at_a_time_and_stop_interrupts_the_wait
    slow = Sim::Injector.new(Sim::Config.new('local' => '10.255.0.11'), sender: @rec)
    slow.act('generate', 'to' => '10.255.0.12', 'spec' => { 'vni' => 1, 'macs' => 100 }, 'per_second' => 0.01)
    e = assert_raise(Sim::Busy) { slow.act('generate', 'to' => '10.255.0.12', 'spec' => { 'vni' => 1 }) }
    assert_match(/a generation is running/, e.message)
    sleep 0.1
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = slow.act('stop', {})
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, :<, 1
    assert_equal({ stopped: true, sent: 1 }, r)
    assert_equal 'stopped', slow.sent[:generate][:state]
    assert_equal({ stopped: false, sent: 1 }, slow.act('stop', {}))
  end

  def test_plan_is_a_dry_run
    r = @inj.plan('spec' => { 'vni' => 100, 'macs' => 3 }, 'limit' => 2)
    assert_equal [3, 0, 2, 2], r.values_at(:total, :offset, :limit, :next_offset)
    assert_equal({ vni: 100, src: '02:00:00:00:00:01', dst: 'ff:ff:ff:ff:ff:ff' }, r[:rows][0])
    assert_nil @inj.plan('spec' => { 'vni' => 1, 'macs' => 3 }, 'offset' => 2)[:next_offset]
    assert_equal [], @rec.sent
  end

  def test_status_topology_and_events
    @inj.act('fault', 'to' => '10.255.0.12', 'case' => 'r_bit_set', 'vni' => 1)
    assert_equal ['10.255.0.11', 4789, 1, false], @inj.status.values_at(:local, :port, :packets, :generating)
    t = @inj.topology
    assert_include t[:faults].map { |f| f[:name] }, :inner_too_short
    assert_equal %w[send fault generate stop], t[:actions].keys
    ev = @inj.events_since('since' => '0')
    assert_equal 1, ev[:seq]
    assert_equal ['fault', '10.255.0.12'], ev[:events][0].values_at(:kind, :peer)
    assert_raise(Sim::Refused) { @inj.events_since('since' => 'x') }
  end
end
