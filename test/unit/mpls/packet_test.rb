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

# What follows EtherType 0x8847 for EVPN over MPLS: the frame the spec's
# measurement sent (bgp4r docs/design/evpn-mpls.md), node SID 16002 over
# EVPN label 25001, the control word, then an inner frame.
class Mpls_Packet_Test < Test::Unit::TestCase
  include VXLAN::Mpls

  STACK = '03e8203f061a9140'
  CW = '00000000'
  FRAME = ('020000000102' '020000000101' '0800') + ('00' * 46)
  WIRE = STACK + CW + FRAME

  def wire(hex)
    [hex].pack('H*')
  end

  def test_parse
    pk = Packet.new(wire(WIRE))
    assert_equal [16_002, 25_001], pk.labels.map(&:label)
    assert pk.bottom?
    assert_equal ControlWord.new, pk.control_word
    assert_equal FRAME, pk.inner.unpack1('H*')
    assert_equal '02:00:00:00:01:02', pk.frame.dst.to_s
    assert_nil pk.tail
    assert_equal WIRE, pk.to_shex
  end

  def test_tcpdumps_stack_then_the_control_word_and_frame
    assert_match(/\AMPLS \(label 16002, tc 0, ttl 63\) \(label 25001, tc 0, \[S\], ttl 64\): control word 0x00000000: 02:00:00:00:01:01 > 02:00:00:00:01:02/,
                 Packet.new(wire(WIRE)).to_s)
  end

  def test_without_a_control_word_the_frame_follows_the_bottom_label
    pk = Packet.new(wire(STACK + FRAME), control_word: false)
    assert_nil pk.control_word
    assert_equal FRAME, pk.inner.unpack1('H*')
    assert_equal STACK + FRAME, pk.to_shex
  end

  def test_the_string_is_not_consumed
    octets = wire(WIRE)
    Packet.new(octets)
    assert_equal WIRE, octets.unpack1('H*')
  end

  def test_four_ways_give_the_same_octets
    frame = wire(FRAME)
    built = Packet.new([Label.new(label: 16_002, ttl: 63), 25_001], ControlWord.new, frame)
    assert_equal WIRE, built.to_shex
    assert_equal WIRE, Packet.new(built).to_shex
    assert_equal WIRE, Packet.new(built.to_hash).to_shex
    assert_equal WIRE, Packet.new(labels: [{ label: 16_002, ttl: 63 }, { label: 25_001, s: 1 }],
                                  control_word: {}, inner: FRAME).to_shex
  end

  def test_integers_get_the_s_bit_on_the_last
    pk = Packet.new([16_002, 25_001], nil, wire(FRAME))
    assert_equal [0, 1], pk.labels.map(&:s)
    refute pk.expects_control_word?
  end

  def test_to_hash_round_trips
    [WIRE, STACK, '03e8203f061a91', STACK + '0000', STACK + CW].each do |hex|
      pk = Packet.new(wire(hex))
      assert_equal hex, Packet.new(pk.to_hash).to_shex, hex
      assert_equal pk.errors.map(&:name), Packet.new(pk.to_hash).errors.map(&:name), hex
    end
    assert_equal({ labels: [{ label: 16_002, ttl: 63 }, { label: 25_001, s: 1 }], control_word: {}, inner: FRAME },
                 Packet.new(wire(WIRE)).to_hash)
  end

  # Keep what cannot be read.

  def test_a_stack_with_no_s_bit_is_kept_with_what_is_left
    pk = Packet.new(wire('03e8203f03e8203f0102'))
    assert_equal 2, pk.labels.size
    refute pk.bottom?
    assert_nil pk.inner
    assert_equal '0102', pk.tail.unpack1('H*')
    assert_equal '03e8203f03e8203f0102', pk.to_shex
  end

  def test_a_control_word_cut_short_is_kept
    pk = Packet.new(wire(STACK + '0000'))
    assert pk.bottom?
    assert_nil pk.control_word
    assert_equal '0000', pk.tail.unpack1('H*')
    assert_equal STACK + '0000', pk.to_shex
  end

  def test_nothing_at_all
    pk = Packet.new(String.new)
    assert_equal [], pk.labels
    assert_equal '', pk.to_shex
  end

  def test_a_short_inner_frame_has_no_frame
    assert_nil Packet.new(wire(STACK + CW + '0102')).frame
  end

  def test_unknown_keys_are_refused
    assert_raise(ArgumentError) { Packet.new(labels: [], vni: 100) }
    assert_raise(ArgumentError) { Packet.new(wire(WIRE), cw: false) }
  end
end
