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
require 'stringio'
require 'vxlan/logging'

class Logging_Test < Test::Unit::TestCase
  class Thing
    include VXLAN::Logging
  end

  def test_an_object_logs_to_its_own_callable
    lines = []
    t = Thing.new
    t.logger = ->(level, message) { lines << [level, message] }
    t.log(:info, 'hello')
    assert_equal [[:info, 'hello']], lines
  end

  def test_two_objects_log_apart
    a, b = [], []
    x = Thing.new
    y = Thing.new
    x.logger = ->(_l, m) { a << m }
    y.logger = ->(_l, m) { b << m }
    x.log(:warn, 'x')
    y.log(:warn, 'y')
    assert_equal [%w[x], %w[y]], [a, b]
  end

  def test_without_one_it_uses_the_default
    lines = []
    old = VXLAN::Logging.default
    VXLAN::Logging.default = ->(level, message) { lines << [level, message] }
    Thing.new.log(:debug, 'd')
    assert_equal [[:debug, 'd']], lines
  ensure
    VXLAN::Logging.default = old
  end

  def test_an_unknown_level_is_refused
    t = Thing.new
    t.logger = ->(*) {}
    assert_raise(ArgumentError) { t.log(:loud, 'x') }
  end

  def test_to_io
    io = StringIO.new
    VXLAN::Logging.to_io(io, level: :info).call(:debug, 'hidden')
    VXLAN::Logging.to_io(io, level: :info).call(:warn, 'shown')
    assert_not_match(/hidden/, io.string)
    assert_match(/WARN.*shown/, io.string)
  end
end
