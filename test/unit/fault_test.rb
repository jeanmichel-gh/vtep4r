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
require 'vxlan/fault'

class Fault_Test < Test::Unit::TestCase
  include VXLAN

  def test_the_names
    assert_equal %i[no_i_flag r_bit_set r_bits_all reserved1_set reserved2_set unknown_vni
                    short_header no_inner_frame inner_too_short], Fault.names
  end

  def test_every_entry_says_what_the_rfc_expects
    Fault.catalog.each do |e|
      assert_include %i[drop ignore], e[:expect], e[:name].to_s
      assert_match(/\ARFC 7348 /, e[:rfc], e[:name].to_s)
      assert_kind_of String, e[:description]
    end
  end

  def test_each_entry_builds_what_its_name_says
    vni = 100
    pk = ->(name) { Fault.build(name, vni: vni) }
    assert_equal '0000000000006400', pk.(:no_i_flag).header.to_shex
    assert_equal '0c00000000006400', pk.(:r_bit_set).header.to_shex
    assert_equal 'ff00000000006400', pk.(:r_bits_all).header.to_shex
    assert_equal '08ffffff00006400', pk.(:reserved1_set).header.to_shex
    assert_equal '08000000000064ff', pk.(:reserved2_set).header.to_shex
    assert_equal 101, pk.(:unknown_vni).header.vni
    assert_equal 4, pk.(:short_header).encode.bytesize
    assert_equal 8, pk.(:no_inner_frame).encode.bytesize
    assert_equal 8 + 13, pk.(:inner_too_short).encode.bytesize
  end

  def test_unknown_vni_never_lands_on_the_receivers
    assert_equal 0, Fault.build(:unknown_vni, vni: 0xffffff).header.vni
  end

  def test_the_inner_frame_is_the_kernels_arp_unless_given
    assert_equal 0x0806, Fault.build(:r_bit_set, vni: 7).frame.ether_type
    inner = ['020000000102020000000101'].pack('H*') + "\x88\xb5".b + 'x'.b * 46
    assert_equal 0x88b5, Fault.build(:r_bit_set, vni: 7, inner: inner).frame.ether_type
  end

  def test_wire_is_the_packets_octets
    assert_equal Fault.build(:no_i_flag, vni: 5).encode, Fault.wire(:no_i_flag, vni: 5)
  end

  def test_an_unknown_name_is_refused
    assert_raise(ArgumentError) { Fault.build(:nope, vni: 1) }
  end

  # The catalog and the validation say the same thing. An entry the
  # codec cannot judge is marked vtep: the VTEP decides, as RFC 7348
  # section 4.1 has the receiver check the VNI it serves.
  def test_the_catalog_and_the_validation_agree
    Fault.catalog.each do |e|
      pk = Fault.build(e[:name], vni: 100)
      verdict = Validation.decide(pk, policy: :rfc)
      if e[:vtep]
        assert_equal :deliver, verdict, "#{e[:name]} is the VTEP's to drop, not the codec's"
      else
        assert_equal(e[:expect] == :drop ? :drop : :deliver, verdict, e[:name].to_s)
        refute_empty Validation.check(pk), "#{e[:name]} has no finding"
      end
    end
  end
end
