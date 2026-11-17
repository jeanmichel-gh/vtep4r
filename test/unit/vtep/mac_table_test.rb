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
require 'vxlan/vtep/mac_table'

# The table takes the time as an argument, so a test is its clock.
class Mac_table_Test < Test::Unit::TestCase
  include VXLAN::Vtep

  A = Datalink::MAC.new('02:00:00:00:01:01')
  B = Datalink::MAC.new('02:00:00:00:01:02')

  def setup
    @t = MacTable.new(ageing: 300)
  end

  def test_learn_a_new_mac
    assert_equal :learned, @t.learn(A, Location.port('eth2'), 10)
    e = @t.lookup(A)
    assert_equal Location.port('eth2'), e.location
    assert_equal :learned, e.origin
    assert_equal 10, e.seen
  end

  def test_seeing_it_again_where_it_was_is_no_event
    @t.learn(A, Location.port('eth2'), 10)
    assert_nil @t.learn(A, Location.port('eth2'), 20)
    assert_equal 20, @t.lookup(A).seen
  end

  def test_seen_elsewhere_is_a_move
    @t.learn(A, Location.port('eth2'), 10)
    assert_equal :moved, @t.learn(A, Location.vtep('10.255.0.12'), 20)
    assert_equal Location.vtep('10.255.0.12'), @t.lookup(A).location
    assert_equal 1, @t.lookup(A).moves
  end

  def test_an_api_entry_is_not_overwritten_by_learning
    @t.add(A, Location.vtep('10.255.0.12'), seq: 3)
    assert_nil @t.learn(A, Location.port('eth2'), 10)
    e = @t.lookup(A)
    assert_equal Location.vtep('10.255.0.12'), e.location
    assert_equal :api, e.origin
    assert_equal 3, e.seq
  end

  def test_learned_entries_age_out
    @t.learn(A, Location.port('eth2'), 0)
    @t.learn(B, Location.port('eth2'), 200)
    assert_equal [], @t.age(299)
    assert_equal [A], @t.age(300)
    assert_nil @t.lookup(A)
    assert_not_nil @t.lookup(B)
  end

  def test_api_entries_never_age
    @t.add(A, Location.vtep('10.255.0.12'))
    assert_equal [], @t.age(10_000)
    assert_not_nil @t.lookup(A)
  end

  def test_delete_and_flush
    @t.learn(A, Location.port('eth2'), 0)
    @t.add(B, Location.vtep('10.255.0.12'))
    assert @t.delete(A)
    refute @t.delete(A)
    assert_equal 1, @t.size
    @t.flush
    assert_equal 0, @t.size
  end

  def test_flush_learned_only
    @t.learn(A, Location.port('eth2'), 0)
    @t.add(B, Location.vtep('10.255.0.12'))
    @t.flush(origin: :learned)
    assert_nil @t.lookup(A)
    assert_not_nil @t.lookup(B)
  end

  def test_rows
    @t.learn(A, Location.port('eth2'), 5)
    @t.add(B, Location.vtep('10.255.0.12'), seq: 2)
    rows = @t.rows(now: 15)
    assert_equal [{ mac: '02:00:00:00:01:01', type: :local, port: 'eth2', vtep: nil, origin: :learned, age: 10, seq: 0, moves: 0 },
                  { mac: '02:00:00:00:01:02', type: :remote, port: nil, vtep: '10.255.0.12', origin: :api, age: nil, seq: 2, moves: 0 }],
                 rows
  end
end
