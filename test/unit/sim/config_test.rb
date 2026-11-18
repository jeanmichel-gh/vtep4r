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
require 'vxlan/sim/config'

class Sim_config_Test < Test::Unit::TestCase
  Config = VXLAN::Sim::Config

  def test_defaults
    c = Config.new('local' => '10.255.0.11')
    assert_equal ['10.255.0.11', '127.0.0.1:8080', 4789], [c.local, c.api, c.port]
  end

  # An injector keeps no MAC table: a VTEP's keys are refused by name.
  def test_a_vteps_keys_are_refused_by_name
    e = assert_raise(Config::Error) { Config.new('local' => '1.1.1.1', 'vnis' => [], 'ageing' => 3) }
    assert_match(/vnis, ageing: an injector keeps no MAC table/, e.message)
  end

  def test_unknown_and_missing
    assert_raise(Config::Error) { Config.new('local' => '1.1.1.1', 'apx' => 1) }
    assert_raise(Config::Error) { Config.new('api' => '1') }
    assert_raise(Config::Error) { Config.new('local' => '1.1.1.1', 'port' => 'x') }
  end
end
