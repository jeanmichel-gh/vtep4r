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
require 'vxlan/header'

# Captured with the kernel's own VXLAN on Linux 7.0, between two network
# namespaces, ping from 172.16.100.1 to .2 over VNI 100:
# test/fixtures/kernel-vxlan.pcap. Every packet's header was this one.
class Header_Test < Test::Unit::TestCase
  include VXLAN

  KERNEL = '0800000000006400'

  def wire(hex)
    [hex].pack('H*')
  end

  # From the wire.

  def test_parse_the_kernels_header
    h = Header.new(wire(KERNEL))
    assert_equal 100, h.vni
    assert_equal 0x08, h.flags
    assert_equal 0, h.reserved1
    assert_equal 0, h.reserved2
    assert h.i_flag?
    assert_equal KERNEL, h.to_shex
  end

  def test_only_the_first_eight_octets_are_the_header
    assert_equal KERNEL, Header.new(wire(KERNEL + 'ffffffffffff')).to_shex
  end

  def test_the_string_is_not_consumed
    octets = wire(KERNEL)
    Header.new(octets)
    assert_equal KERNEL, octets.unpack1('H*')
  end

  def test_fewer_than_eight_octets_is_not_a_header
    assert_raise(ArgumentError) { Header.new(wire('08000000000064')) }
  end

  # Field values, and a hash.

  def test_a_vni_alone_gives_the_kernels_header
    assert_equal KERNEL, Header.new(100).to_shex
    assert_equal KERNEL, Header.new(vni: 100).to_shex
    assert_equal KERNEL, Header.new({ vni: 100 }).to_shex
  end

  def test_the_vni_is_24_bits
    assert_equal '08000000ffffff00', Header.new(0xffffff).to_shex
    assert_equal '0800000000000000', Header.new(0).to_shex
  end

  # Building is never validated: any flags and reserved bits go out as
  # asked, so a receiver can be watched handling them.

  def test_any_flags
    assert_equal '0000000000006400', Header.new(vni: 100, flags: 0).to_shex
    assert_equal '0c00000000006400', Header.new(vni: 100, flags: 0x0c).to_shex
    assert_equal 'ff00000000006400', Header.new(vni: 100, flags: 0xff).to_shex
    refute Header.new(vni: 100, flags: 0xf7).i_flag?
  end

  def test_any_reserved_bits
    h = Header.new(vni: 100, reserved1: 0x010203, reserved2: 0xfe)
    assert_equal '08010203000064fe', h.to_shex
  end

  # Only what cannot be represented is refused.

  def test_a_value_wider_than_its_field_is_refused
    assert_raise(ArgumentError) { Header.new(0x1000000) }
    assert_raise(ArgumentError) { Header.new(-1) }
    assert_raise(ArgumentError) { Header.new(vni: 1, flags: 0x100) }
    assert_raise(ArgumentError) { Header.new(vni: 1, reserved1: 0x1000000) }
    assert_raise(ArgumentError) { Header.new(vni: 1, reserved2: 0x100) }
  end

  def test_an_unknown_key_is_refused
    assert_raise(ArgumentError) { Header.new(vni: 1, flag: 8) }
  end

  # Keep what arrived, and write it back.

  def test_reserved_bits_that_arrive_go_back_out
    odd = 'cfabcdef123456ff'
    h = Header.new(wire(odd))
    assert_equal odd, h.to_shex
    assert_equal 0xcf, h.flags
    assert_equal 0xabcdef, h.reserved1
    assert_equal 0x123456, h.vni
    assert_equal 0xff, h.reserved2
  end

  # Round trips: the hash, and another instance.

  def test_an_ordinary_header_hashes_to_its_vni
    assert_equal({ vni: 100 }, Header.new(wire(KERNEL)).to_hash)
  end

  def test_an_unusual_field_adds_its_key
    assert_equal({ vni: 100, flags: 0 }, Header.new(vni: 100, flags: 0).to_hash)
    assert_equal({ vni: 100, reserved1: 1, reserved2: 2 },
                 Header.new(vni: 100, reserved1: 1, reserved2: 2).to_hash)
  end

  def test_the_hash_round_trips_every_field
    h = Header.new(wire('cfabcdef123456ff'))
    assert_equal h.to_shex, Header.new(h.to_hash).to_shex
  end

  def test_another_instance
    h = Header.new(wire('cfabcdef123456ff'))
    assert_equal h.to_shex, Header.new(h).to_shex
  end

  def test_encode_is_binary_and_eight_octets
    e = Header.new(100).encode
    assert_equal Encoding::BINARY, e.encoding
    assert_equal 8, e.bytesize
  end

  def test_equal_headers
    assert_equal Header.new(100), Header.new(wire(KERNEL))
    assert_not_equal Header.new(100), Header.new(101)
  end

  # tcpdump printed the kernel's header as "VXLAN, flags [I] (0x08), vni 100".
  def test_to_s
    assert_equal 'VXLAN, flags [I] (0x08), vni 100', Header.new(100).to_s
    assert_equal 'VXLAN, flags [I] (0x0c), vni 100', Header.new(vni: 100, flags: 0x0c).to_s
    assert_equal 'VXLAN, flags [] (0x00), vni 7', Header.new(vni: 7, flags: 0).to_s
  end
end
