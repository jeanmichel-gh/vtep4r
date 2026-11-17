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
require 'vxlan/vtep/ports'

class Ports_Test < Test::Unit::TestCase
  require 'datalink/backends/loopback'
  Loopback = Datalink::Backends::Loopback

  def test_a_loopback_port_sends_and_receives
    w = Loopback::Wire.new
    ports = VXLAN::Vtep::Ports.loopback('eth2' => w)
    host = Datalink::Socket.new('h1', backend: :loopback, wire: w, recv_timeout: 1).open
    frame = ['ffffffffffff020000000101' + '88b5' + '00' * 46].pack('H*')
    host.send(frame)
    assert_equal frame, ports.recv('eth2', 1)
    ports.send('eth2', frame)
    assert_equal frame, host.recv.bytes
    assert_nil ports.recv('eth2', 0.01)
    assert_equal ['eth2'], ports.names
  ensure
    ports&.close
    host&.close
  end

  def test_a_port_opens_and_closes_at_run_time
    require 'datalink/backends/loopback'
    w = Loopback::Wire.new
    ports = VXLAN::Vtep::Ports.loopback({ 'eth2' => Loopback::Wire.new, 'eth3' => w }, ['eth2'])
    refute ports.open?('eth3')
    assert ports.open('eth3')
    refute ports.open('eth3')
    assert_equal %w[eth2 eth3], ports.names
    assert ports.close_port('eth3')
    refute ports.close_port('eth3')
    assert_raise(IOError) { ports.send('eth3', 'x'.b) }
  ensure
    ports&.close
  end

  def test_a_port_with_no_opener
    assert_raise(ArgumentError) { VXLAN::Vtep::Ports.new.open('eth2') }
  end
end
