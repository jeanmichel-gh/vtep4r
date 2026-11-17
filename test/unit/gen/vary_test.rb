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
require 'vxlan/gen/vary'

# Patterns, after bgp4r's bgp/gen/vary.rb: a value is a function of the
# item's number and the seed, and of nothing else.
class Vary_Test < Test::Unit::TestCase
  Vary = VXLAN::Gen::Vary
  SpecError = VXLAN::Gen::SpecError
  RANDOM = { 'random' => { 'min' => 1, 'max' => 1000 } }.freeze

  # The pattern's first n values. Patterns are passed in braces: Ruby 3
  # reads a bare hash argument as keywords.
  def at(v, n = 6, seed: nil, max: 0xffffff)
    p = Vary.compile(v, 'x', max: max, seed: seed)
    (0...n).map { |i| p.at(i) }
  end

  def test_fixed
    assert_equal [5] * 3, at(5, 3)
    assert_equal [5] * 3, at({ 'fixed' => 5 }, 3)
  end

  def test_cycle
    assert_equal [1, 2, 3, 1, 2, 3], at({ 'cycle' => [1, 2, 3] })
  end

  def test_step
    assert_equal [10, 12, 14, 10, 12, 14], at({ 'step' => { 'start' => 10, 'by' => 2, 'wrap' => 16 } })
    assert_equal [100, 101, 102], at({ 'step' => { 'start' => 100 } }, 3)
  end

  def test_every
    assert_equal [7, 7, 8, 8, 7, 7], at({ 'every' => { 'n' => 2, 'values' => [7, 8] } })
  end

  # The same seed gives the same values on every Ruby; another seed or
  # another name gives another draw. Pinned with the values, measured on
  # Ruby 3.3 when this was written: CI checks them on 3.4 and 4.0.
  def test_random_is_a_function_of_seed_name_and_number
    a = at(RANDOM, 4, seed: 7)
    assert_equal [840, 628, 840, 566], a
    assert_not_equal a, at(RANDOM, 4, seed: 8)
    b = Vary.compile(RANDOM, 'y', max: 0xffffff, seed: 7)
    assert_not_equal a, (0...4).map { |i| b.at(i) }
  end

  def test_random_needs_a_seed
    e = assert_raise(SpecError) { at({ 'random' => { 'min' => 1, 'max' => 2 } }) }
    assert_match(/x: random needs the spec's seed/, e.message)
  end

  def test_a_value_wider_than_its_field_is_refused
    assert_raise(SpecError) { at(0x100, max: 0xff) }
    assert_raise(SpecError) { at({ 'cycle' => [1, 0x100] }, max: 0xff) }
    assert_raise(SpecError) { at({ 'random' => { 'min' => 0, 'max' => 0x100 } }, seed: 1, max: 0xff) }
  end

  def test_what_cannot_be_read_is_refused
    assert_raise(SpecError) { at({ 'spiral' => 1 }) }
    assert_raise(SpecError) { at('x') }
    assert_raise(SpecError) { at({ 'cycle' => [] }) }
    assert_raise(SpecError) { at({ 'random' => { 'min' => 5, 'max' => 1 } }, seed: 1) }
    assert_raise(SpecError) { at({ 'fixed' => 1, 'cycle' => [1] }) }
    assert_raise(SpecError) { at({ 'step' => { 'start' => 5, 'wrap' => 5 } }) }
  end
end
