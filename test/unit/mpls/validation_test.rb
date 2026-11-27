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

class Mpls_Validation_Test < Test::Unit::TestCase
  include VXLAN::Mpls

  FRAME = [('020000000102' '020000000101' '0800') + ('00' * 46)].pack('H*')

  def names(pk)
    pk.errors.map(&:name)
  end

  def test_a_good_packet_has_no_finding
    assert_equal [], names(Packet.new([16_002, 25_001], ControlWord.new, FRAME))
    assert_equal :deliver, Validation.decide(Packet.new([25_001], ControlWord.new, FRAME))
  end

  def test_each_finding_and_its_action
    {
      Packet.new([Label.new(25_001)], ControlWord.new, FRAME) => [:no_bottom, :drop, '3032 section 2.1'],
      Packet.new(Label.new(label: 25_001, s: 1).encode + "\x00".b) => [:no_control_word, :drop, '7432 section 18'],
      Packet.new([25_001], ControlWord.new(nibble: 6), FRAME) => [:control_word_nibble, :drop, '4385 section 3'],
      Packet.new([25_001], ControlWord.new(1), FRAME) => [:control_word_set, :ignore, '7432 section 18'],
      Packet.new([25_001], ControlWord.new, FRAME.byteslice(0, 13)) => [:short, :drop, '13 octets']
    }.each do |pk, (name, action, said)|
      f = pk.errors
      assert_equal [name], f.map(&:name)
      assert_equal action, f.first.action
      assert_include f.first.reason, said
    end
  end

  # RFC 4182 section 2: explicit null is legal anywhere in the stack.
  def test_explicit_null_is_no_finding
    assert_equal [], names(Packet.new([0, 25_001], ControlWord.new, FRAME))
    assert_equal [], names(Packet.new([2, 25_001], ControlWord.new, FRAME))
  end

  def test_no_control_word_expected_none_missing
    assert_equal [], names(Packet.new(Packet.new([25_001], nil, FRAME).encode, control_word: false))
  end

  def test_the_policies
    bad = Packet.new([Label.new(25_001)], ControlWord.new, FRAME)
    odd = Packet.new([25_001], ControlWord.new(1), FRAME)
    assert_equal :drop, Validation.decide(bad)
    assert_equal :deliver, Validation.decide(odd)
    assert_equal :deliver, Validation.decide(bad, policy: :lenient)
    e = assert_raise(VXLAN::Malformed_packet) { Validation.decide(odd, policy: :strict) }
    assert_equal :control_word_set, e.finding.name
    assert_raise(ArgumentError) { Validation.decide(odd, policy: :loose) }
  end
end
