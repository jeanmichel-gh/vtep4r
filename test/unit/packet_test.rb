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
require 'vxlan/packet'

# Two UDP payloads from test/fixtures/kernel-vxlan.pcap, the kernel's own
# VXLAN on Linux 7.0: the ARP request (packet 2, an inner frame of 42
# octets, unpadded) and the ICMP echo request (packet 4).
class Packet_Test < Test::Unit::TestCase
  include VXLAN

  ARP = '0800000000006400' \
        'ffffffffffff02000000010108060001080006040001020000000101ac106401000000000000ac106402'
  ICMP = '0800000000006400' \
         '0200000001020200000001010800450000544a9040004001cff4ac106401ac1064020800ed9b822e00' \
         '0175bbfc6a000000004b3b0c0000000000101112131415161718191a1b1c1d1e1f202122232425262728' \
         '292a2b2c2d2e2f3031323334353637'

  def wire(hex)
    [hex].pack('H*')
  end

  def test_the_kernels_arp_request
    pk = Packet.new(wire(ARP))
    assert_equal 100, pk.header.vni
    assert_equal 42, pk.inner.bytesize
    assert_equal 'ff:ff:ff:ff:ff:ff', pk.frame.dst.to_s
    assert_equal '02:00:00:00:01:01', pk.frame.src.to_s
    assert_equal 0x0806, pk.frame.ether_type
    assert_equal ARP, pk.to_shex
  end

  def test_the_kernels_icmp_echo
    pk = Packet.new(wire(ICMP))
    assert_equal ICMP, pk.to_shex
    assert_equal 0x0800, pk.frame.ether_type
  end

  def test_the_string_is_not_consumed
    octets = wire(ARP)
    Packet.new(octets)
    assert_equal ARP, octets.unpack1('H*')
  end

  # Field values: a header (or its hash) and an inner frame, as a
  # Datalink::Frame or its octets.

  def test_from_a_header_and_a_frame
    frame = Packet.new(wire(ARP)).frame
    assert_equal ARP, Packet.new(Header.new(100), frame).to_shex
    assert_equal ARP, Packet.new({ vni: 100 }, frame).to_shex
  end

  def test_from_a_header_and_octets
    inner = wire(ARP[16..])
    assert_equal ARP, Packet.new(Header.new(100), inner).to_shex
  end

  def test_any_header_goes_out
    pk = Packet.new(Header.new(vni: 100, flags: 0, reserved2: 9), wire(ARP[16..]))
    assert_equal '0000000000006409' + ARP[16..], pk.to_shex
  end

  # Round trips.

  def test_the_hash
    pk = Packet.new(wire(ICMP))
    assert_equal({ header: { vni: 100 }, inner: ICMP[16..] }, pk.to_hash)
    assert_equal ICMP, Packet.new(pk.to_hash).to_shex
  end

  def test_the_hash_keeps_unusual_header_bits
    odd = 'cfabcdef123456ff' + ARP[16..]
    pk = Packet.new(wire(odd))
    assert_equal odd, Packet.new(pk.to_hash).to_shex
  end

  def test_another_instance
    pk = Packet.new(wire(ARP))
    assert_equal ARP, Packet.new(pk).to_shex
  end

  # Keep what cannot be read, and write it back.

  def test_an_inner_frame_too_short_to_parse_is_kept
    pk = Packet.new(wire('0800000000006400' + '0102030405'))
    assert_nil pk.frame
    assert_equal '0800000000006400' + '0102030405', pk.to_shex
    assert_equal '0102030405', pk.to_hash[:inner]
  end

  def test_no_inner_frame
    pk = Packet.new(wire('0800000000006400'))
    assert_equal '', pk.inner
    assert_nil pk.frame
    assert_equal '0800000000006400', pk.to_shex
  end

  def test_fewer_octets_than_a_header_are_kept
    pk = Packet.new(wire('08000000'))
    assert_nil pk.header
    assert_nil pk.frame
    assert_equal '08000000', pk.to_shex
    assert_equal({ short: '08000000' }, pk.to_hash)
    assert_equal '08000000', Packet.new(pk.to_hash).to_shex
  end

  def test_encode_is_binary
    assert_equal Encoding::BINARY, Packet.new(wire(ARP)).encode.encoding
    assert_equal Encoding::BINARY, Packet.new(100, ''.b).encode.encoding
  end

  def test_to_s
    assert_equal 'VXLAN, flags [I] (0x08), vni 100: 02:00:00:00:01:01 > ff:ff:ff:ff:ff:ff ARP len 28',
                 Packet.new(wire(ARP)).to_s
  end
end
