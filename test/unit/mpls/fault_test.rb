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

class Mpls_Fault_Test < Test::Unit::TestCase
  include VXLAN::Mpls

  LABEL = 25_001

  # Each entry not left to a VTEP gives the finding of its own name and
  # the action it expects. The VTEP's entries give none.
  def test_each_entry_gives_its_finding
    Fault.catalog.each do |e|
      pk = Fault.build(e[:name], label: LABEL)
      found = pk.errors
      if e[:vtep]
        assert_equal [], found.map(&:name), e[:name]
        next
      end
      name = e[:name] == :inner_too_short ? :short : e[:name]
      assert_equal [name], found.map(&:name), e[:name]
      assert_equal e[:expect], found.first.action, e[:name]
    end
  end

  def test_wire_is_the_packets_octets
    Fault.names.each do |n|
      assert_equal Fault.build(n, label: LABEL).encode, Fault.wire(n, label: LABEL)
    end
  end

  # Each packet parsed from its wire gets the verdict it was built for.
  # Not always the same finding: with no S bit, a receiver reads the
  # control word and the frame as more labels, here until an entry of
  # the ARP frame has its S bit set, and then the octets after it fail
  # as a control word.
  def test_each_wire_parses_back_to_the_same_verdict
    Fault.names.each do |n|
      pk = Fault.build(n, label: LABEL)
      assert_equal Validation.decide(pk), Validation.decide(Packet.new(pk.encode)), n
    end
    back = Packet.new(Fault.wire(:no_bottom, label: LABEL))
    assert_equal 3, back.labels.size
    assert_equal [:control_word_nibble], back.errors.map(&:name)
  end

  def test_the_vtep_entries
    assert_equal [25_002], Fault.build(:unknown_label, label: LABEL).labels.map(&:label)
    assert_equal [0, LABEL], Fault.build(:ipv4_explicit_null, label: LABEL).labels.map(&:label)
    assert_equal [2, LABEL], Fault.build(:ipv6_explicit_null, label: LABEL).labels.map(&:label)
  end

  def test_every_entry_cites_an_rfc_and_has_a_known_expectation
    Fault.catalog.each do |e|
      assert_match(/\ARFC \d{4} \d/, e[:rfc])
      assert_include %i[drop ignore deliver], e[:expect]
    end
  end

  def test_an_unknown_name_is_refused
    assert_raise(ArgumentError) { Fault.build(:nope, label: LABEL) }
  end
end
