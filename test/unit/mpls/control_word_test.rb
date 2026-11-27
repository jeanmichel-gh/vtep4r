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
require 'vxlan/mpls/control_word'

# RFC 4385 section 3's preferred format, and EVPN's control word, four
# zero octets (RFC 7432 section 18).
class Mpls_ControlWord_Test < Test::Unit::TestCase
  include VXLAN::Mpls

  def wire(hex)
    [hex].pack('H*')
  end

  def test_evpns_control_word_is_four_zero_octets
    assert_equal '00000000', ControlWord.new.to_shex
    assert_equal({}, ControlWord.new.to_hash)
    assert_equal 'control word 0x00000000', ControlWord.new.to_s
  end

  # |0 0 0 0| Flags |FRG|  Length   | Sequence Number               |
  def test_each_field_in_its_place
    assert_equal '40000000', ControlWord.new(nibble: 4).to_shex
    assert_equal '0f000000', ControlWord.new(flags: 0xf).to_shex
    assert_equal '00c00000', ControlWord.new(frg: 3).to_shex
    assert_equal '003f0000', ControlWord.new(length: 0x3f).to_shex
    assert_equal '0000ffff', ControlWord.new(sequence: 0xffff).to_shex
    assert_equal '00000007', ControlWord.new(7).to_shex
  end

  def test_parse_round_trips
    %w[00000000 4f1e1234 ffffffff 0000ffff].each do |hex|
      c = ControlWord.new(wire(hex))
      assert_equal hex, c.to_shex
      assert_equal hex, ControlWord.new(c.to_hash).to_shex
      assert_equal hex, ControlWord.new(c).to_shex
    end
    c = ControlWord.new(wire('4f1e1234'))
    assert_equal({ nibble: 4, flags: 0xf, length: 0x1e, sequence: 0x1234 }, c.to_hash)
  end

  def test_the_string_is_not_consumed
    octets = wire('0000000102')
    ControlWord.new(octets)
    assert_equal '0000000102', octets.unpack1('H*')
  end

  def test_fewer_than_four_octets_is_not_a_control_word
    assert_raise(ArgumentError) { ControlWord.new(wire('000000')) }
  end

  def test_a_value_that_does_not_fit_is_refused
    assert_raise(ArgumentError) { ControlWord.new(nibble: 16) }
    assert_raise(ArgumentError) { ControlWord.new(length: 64) }
    assert_raise(ArgumentError) { ControlWord.new(0x10000) }
    assert_raise(ArgumentError) { ControlWord.new(seq: 1) }
  end
end
