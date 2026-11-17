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
require 'vxlan/validation'

class Validation_Test < Test::Unit::TestCase
  include VXLAN

  # The kernel's ARP request, from test/fixtures/kernel-vxlan.pcap.
  ARP = 'ffffffffffff02000000010108060001080006040001020000000101ac106401000000000000ac106402'

  def packet(header_hex, inner_hex = ARP)
    Packet.new([header_hex + inner_hex].pack('H*'))
  end

  def names(pk)
    Validation.check(pk).map(&:name)
  end

  def test_the_kernels_packet_has_no_finding
    assert_equal [], names(packet('0800000000006400'))
    assert_equal [], packet('0800000000006400').errors
  end

  def test_i_flag_clear
    f = Validation.check(packet('0000000000006400'))
    assert_equal [:no_i_flag], f.map(&:name)
    assert_equal :drop, f[0].action
    assert_match(/RFC 7348 section 5/, f[0].reason)
  end

  # RFC 7348 section 5: "set to zero on transmission and ignored on
  # receipt". Reported, never a drop.
  def test_an_r_bit_is_reported_and_ignored
    f = Validation.check(packet('0c00000000006400'))
    assert_equal [:reserved_set], f.map(&:name)
    assert_equal :ignore, f[0].action
  end

  def test_each_reserved_field_is_reported
    assert_equal [:reserved_set], names(packet('0801000000006400'))
    assert_equal [:reserved_set], names(packet('0800000000006401'))
  end

  def test_one_finding_for_several_reserved_bits
    assert_equal [:reserved_set], names(packet('ffffffffffffffff'))
  end

  def test_short_header
    f = Validation.check(Packet.new(['08000000'].pack('H*')))
    assert_equal [:short], f.map(&:name)
    assert_equal :drop, f[0].action
  end

  def test_no_inner_frame
    assert_equal [:short], names(packet('0800000000006400', ''))
  end

  def test_an_inner_frame_shorter_than_an_ethernet_header
    assert_equal [:short], names(packet('0800000000006400', ARP[0, 26]))
    assert_equal [], names(packet('0800000000006400', ARP[0, 28]))
  end

  def test_findings_together
    assert_equal %i[no_i_flag reserved_set short], names(packet('0400000000006400', ''))
  end

  # The receive policies.

  def test_rfc_policy
    assert_equal :deliver, Validation.decide(packet('0800000000006400'))
    assert_equal :deliver, Validation.decide(packet('0c00000000006400'))
    assert_equal :drop, Validation.decide(packet('0000000000006400'))
    assert_equal :drop, Validation.decide(packet('0800000000006400', ''), policy: :rfc)
  end

  def test_lenient_policy_delivers_everything
    assert_equal :deliver, Validation.decide(packet('0000000000006400', ''), policy: :lenient)
  end

  def test_strict_policy_raises_on_any_finding
    assert_equal :deliver, Validation.decide(packet('0800000000006400'), policy: :strict)
    e = assert_raise(Malformed_packet) { Validation.decide(packet('0c00000000006400'), policy: :strict) }
    assert_equal :reserved_set, e.finding.name
    assert_raise(Malformed_packet) { Validation.decide(packet('0000000000006400'), policy: :strict) }
  end

  def test_an_unknown_policy_is_refused
    assert_raise(ArgumentError) { Validation.decide(packet('0800000000006400'), policy: :loose) }
  end

  # Validation reads; it never changes the packet.
  def test_a_checked_packet_still_encodes_as_it_came
    pk = packet('cfabcdef123456ff')
    Validation.check(pk)
    assert_equal 'cfabcdef123456ff' + ARP, pk.to_shex
  end
end
