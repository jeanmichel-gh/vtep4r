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
require 'vxlan/vtep/tunnel'

class Tunnel_Test < Test::Unit::TestCase
  include VXLAN::Vtep

  def test_memory_tunnel
    f = MemoryTunnel::Fabric.new
    a = MemoryTunnel.new('10.0.0.1', f)
    b = MemoryTunnel.new('10.0.0.2', f)
    assert a.send('abc'.b, '10.0.0.2', 50_000)
    assert_equal ['10.0.0.1', 'abc'], b.recv(1)
    assert_nil b.recv(0.01)
    refute a.send('x'.b, '10.0.0.9', 50_000)
  end

  # Real UDP on two loopback addresses, no root: port 4789 is above 1023.
  # RFC 7348 section 5's per-flow source port is what the pool is for.
  def test_udp_tunnel_sends_from_the_source_port_asked_for
    a = UdpTunnel.new('127.0.0.11', port: 47_890)
    b = UdpTunnel.new('127.0.0.12', port: 47_890)
    a.send('hello'.b, '127.0.0.12', 50_001)
    from, octets = b.recv(2)
    assert_equal ['127.0.0.11', 'hello'], [from, octets]
    probe = UDPSocket.new
    probe.bind('127.0.0.13', 47_890)
    a.send('x'.b, '127.0.0.13', 50_002)
    _, addr = probe.recvfrom(10)
    assert_equal 50_002, addr[1]
  ensure
    [a, b].compact.each(&:close)
    probe&.close
  end

  def test_udp_tunnel_recv_times_out
    t = UdpTunnel.new('127.0.0.14', port: 47_890)
    assert_nil t.recv(0.05)
  ensure
    t&.close
  end
end
