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
require 'vxlan/mpls/label'

# The entries tcpdump printed, on 2026-11-27, for a frame built with
# node SID 16002 over EVPN label 25001: "MPLS (label 16002, tc 0, ttl 63)
# (label 25001, tc 0, [S], ttl 64)".
class Mpls_Label_Test < Test::Unit::TestCase
  include VXLAN::Mpls

  NODE_SID = '03e8203f'  # 16002, S clear, TTL 63
  EVPN = '061a9140'      # 25001, S set, TTL 64

  def wire(hex)
    [hex].pack('H*')
  end

  def test_parse
    l = Label.new(wire(NODE_SID))
    assert_equal [16_002, 0, 0, 63], [l.label, l.tc, l.s, l.ttl]
    refute l.bottom?
    l = Label.new(wire(EVPN))
    assert_equal [25_001, 0, 1, 64], [l.label, l.tc, l.s, l.ttl]
    assert l.bottom?
  end

  def test_only_the_first_four_octets_are_the_entry
    assert_equal EVPN, Label.new(wire(EVPN + 'ffffffff')).to_shex
  end

  def test_the_string_is_not_consumed
    octets = wire(EVPN)
    Label.new(octets)
    assert_equal EVPN, octets.unpack1('H*')
  end

  def test_fewer_than_four_octets_is_not_an_entry
    assert_raise(ArgumentError) { Label.new(wire('061a91')) }
  end

  def test_tcpdumps_form
    assert_equal '(label 16002, tc 0, ttl 63)', Label.new(wire(NODE_SID)).to_s
    assert_equal '(label 25001, tc 0, [S], ttl 64)', Label.new(wire(EVPN)).to_s
  end

  def test_four_ways_give_the_same_octets
    a = Label.new(wire(EVPN))
    assert_equal EVPN, Label.new(label: 25_001, s: 1).to_shex
    assert_equal EVPN, Label.new(a).to_shex
    assert_equal '061a9040', Label.new(25_001).to_shex
  end

  def test_to_hash_round_trips_and_names_only_what_is_not_default
    assert_equal({ label: 25_001, s: 1 }, Label.new(wire(EVPN)).to_hash)
    assert_equal({ label: 16_002, ttl: 63 }, Label.new(wire(NODE_SID)).to_hash)
    [NODE_SID, EVPN, 'ffffffff', '00000000'].each do |hex|
      l = Label.new(wire(hex))
      assert_equal hex, Label.new(l.to_hash).to_shex
    end
  end

  # Building is never validated: a reserved label, any S bit.
  def test_any_label_and_bits
    assert_equal 'fffffeff', Label.new(label: 0xfffff, tc: 7, s: 0, ttl: 255).to_shex
    assert_equal '00001001', Label.new(label: 1, s: 0, ttl: 1).to_shex
  end

  def test_a_value_that_does_not_fit_is_refused
    assert_raise(ArgumentError) { Label.new(0x100000) }
    assert_raise(ArgumentError) { Label.new(label: 1, tc: 8) }
    assert_raise(ArgumentError) { Label.new(label: 1, s: 2) }
    assert_raise(ArgumentError) { Label.new(label: 1, ttl: 256) }
    assert_raise(ArgumentError) { Label.new(label: 1, exp: 1) }
  end

  # RFC 4182 section 2.
  def test_explicit_nulls
    assert Label.new(0).explicit_null?
    assert Label.new(2).explicit_null?
    refute Label.new(3).explicit_null?
    refute Label.new(25_001).explicit_null?
  end

  def test_equality
    assert_equal Label.new(wire(EVPN)), Label.new(label: 25_001, s: 1)
    assert_equal Label.new(wire(EVPN)).hash, Label.new(label: 25_001, s: 1).hash
    refute_equal Label.new(25_001), Label.new(label: 25_001, s: 1)
  end
end
