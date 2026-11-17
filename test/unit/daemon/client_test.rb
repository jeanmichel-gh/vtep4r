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
require 'vxlan/daemon/client'

class Client_Test < Test::Unit::TestCase
  Client = VXLAN::Daemon::Client

  def test_the_environment_wins
    assert_equal '/x/y.sock', Client.default_socket({ 'VTEP4R_SOCKET' => '/x/y.sock' })
  end

  def test_the_first_writable_place
    w = File.expand_path('../..', __dir__)
    assert_equal File.join(w, 'vtep4rd.sock'), Client.default_socket({}, ['/proc/nope/vtep4r', w])
  end

  def test_none_writable_still_names_run
    assert_equal '/run/vtep4r/vtep4rd.sock', Client.default_socket({}, ['/proc/nope/vtep4r'])
  end

  def test_the_order
    c = Client.candidates({ 'XDG_RUNTIME_DIR' => '/run/user/1000', 'TMPDIR' => '/proc/missing' })
    assert_equal ['/run/vtep4r', '/run/user/1000/vtep4r', '/tmp/vtep4r'], c
  end

  def test_no_daemon_is_said_plainly
    e = assert_raise(Client::Error) { Client.new('/proc/nope/vtep4rd.sock').call('api.info') }
    assert_match(%r{no vtep4rd answers on /proc/nope/vtep4rd.sock}, e.message)
  end
end
