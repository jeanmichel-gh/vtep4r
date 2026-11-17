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
require 'json'
require 'vxlan/gen'

# VXLAN::Gen: a spec in plain JSON types in, packets out, as bgp4r's
# BGP::Gen. No socket, no thread, no clock.
class Gen_Test < Test::Unit::TestCase
  include VXLAN

  def test_the_default_is_one_broadcast
    g = Gen.new('vni' => 100)
    assert_equal 1, g.count
    pk = g.packets.first
    assert_equal '0800000000006400', pk.header.to_shex
    f = pk.frame
    assert_equal ['ff:ff:ff:ff:ff:ff', '02:00:00:00:00:01', 0x88b5], [f.dst.to_s, f.src.to_s, f.ether_type]
    assert_equal 60, pk.inner.bytesize
  end

  # macs: N distinct source MACs counting up from src, which fills a MAC
  # table; count defaults to macs.
  def test_a_mac_flood
    g = Gen.new('vni' => 100, 'macs' => 1000, 'src' => '02:00:00:01:00:00')
    assert_equal 1000, g.count
    srcs = g.packets.map { |p| p.frame.src.to_s }
    assert_equal 1000, srcs.uniq.size
    assert_equal ['02:00:00:01:00:00', '02:00:00:01:00:01', '02:00:00:01:03:e7'], srcs.values_at(0, 1, 999)
  end

  def test_count_beyond_macs_cycles_the_macs
    g = Gen.new('vni' => 1, 'macs' => 2, 'count' => 5)
    assert_equal %w[01 02 01 02 01], g.packets.map { |p| p.frame.src.to_s[-2..] }
  end

  def test_the_header_varies_by_pattern
    g = Gen.new('vni' => { 'cycle' => [100, 200] }, 'flags' => { 'every' => { 'n' => 2, 'values' => [8, 12] } },
                'reserved2' => 3, 'count' => 4)
    # vni 100 is 0x64 and 200 is 0xc8; flags 8 twice, then 12 (0x0c).
    assert_equal %w[0800000000006403 080000000000c803 0c00000000006403 0c0000000000c803],
                 g.packets.map { |p| p.header.to_shex }
  end

  def test_unicast_needs_dst
    assert_raise(Gen::SpecError) { Gen.new('vni' => 1, 'inner' => 'unicast') }
    g = Gen.new('vni' => 1, 'inner' => 'unicast', 'dst' => '02:00:00:00:00:09')
    assert_equal '02:00:00:00:00:09', g.packets.first.frame.dst.to_s
  end

  # An ARP request who-has target from each source, octet for octet the
  # kernel's (test/fixtures/kernel-vxlan.pcap, 42 octets unpadded), with
  # the sender address stepping per source.
  def test_arp
    g = Gen.new('vni' => 100, 'inner' => 'arp', 'macs' => 2, 'src' => '02:00:00:00:01:01',
                'sender_ip' => '172.16.100.1', 'target_ip' => '172.16.100.2')
    arp = 'ffffffffffff02000000010108060001080006040001020000000101ac106401000000000000ac106402'
    assert_equal arp, g.packets.first.inner.unpack1('H*')
    second = g.packets[1].inner
    assert_equal ['02:00:00:00:01:02', '172.16.100.2'],
                 [second.byteslice(22, 6).unpack1('H*').scan(/../).join(':'), second.byteslice(28, 4).unpack('C4').join('.')]
  end

  def test_size_and_ethertype
    g = Gen.new('vni' => 1, 'size' => 1514, 'ethertype' => 0x0800)
    assert_equal [1514, 0x0800], [g.packets.first.inner.bytesize, g.packets.first.frame.ether_type]
  end

  # Nothing validates: an R bit, the I flag clear, a reserved field set.
  def test_any_header_bits
    pk = Gen.new('vni' => 5, 'flags' => 0, 'reserved1' => 0xffffff).packets.first
    assert_equal '00ffffff00000500', pk.header.to_shex
  end

  def test_expected_is_what_it_meant_to_send
    g = Gen.new('vni' => { 'cycle' => [100, 200] }, 'macs' => 2)
    assert_equal [{ vni: 100, src: '02:00:00:00:00:01', dst: 'ff:ff:ff:ff:ff:ff' },
                  { vni: 200, src: '02:00:00:00:00:02', dst: 'ff:ff:ff:ff:ff:ff' }], g.expected
  end

  def test_each_does_not_build_an_array
    g = Gen.new('vni' => 1, 'macs' => 3)
    assert_kind_of Enumerator, g.each
    assert_equal 3, g.each.count
  end

  def test_the_same_spec_gives_the_same_octets
    spec = { 'vni' => { 'random' => { 'min' => 1, 'max' => 4000 } }, 'macs' => 5, 'seed' => 42 }
    a = Gen.new(spec).packets.map(&:encode)
    assert_equal a, Gen.new(JSON.parse(JSON.generate(spec))).packets.map(&:encode)
  end

  # A spec it cannot read is refused by name; a spec that is merely
  # strange is sent.
  def test_refusals
    [{ 'vni' => 1, 'flood' => 1 }, { 'vni' => 'x' }, { 'vni' => 1, 'macs' => 0 }, { 'vni' => 1, 'count' => -1 },
     { 'vni' => 1, 'inner' => 'ipv6' }, { 'vni' => 1, 'src' => 'zz' }, { 'vni' => 1, 'size' => 10 }, 'not a hash']
      .each { |s| assert_raise(Gen::SpecError, s.inspect) { Gen.new(s) } }
  end

  def test_symbol_keys_are_read_as_strings
    assert_equal 3, Gen.new(vni: 1, macs: 3).count
  end
end
