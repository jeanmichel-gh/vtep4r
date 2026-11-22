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

root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
$LOAD_PATH.unshift(ENV['DATALINK_LIB']) if ENV['DATALINK_LIB']

require 'test/unit'
require_relative 'lab_net'

# The lab tier: vtep4rd and vtep4r-sim, the real programs, against the
# kernel's own VXLAN, in LabNet's three namespaces (test/lab/lab_net.rb).
#
#   sudo DATALINK_LIB=~/datalink-socket/lib ruby -I. test/lab/kernel_test.rb
class Kernel_Test < Test::Unit::TestCase
  include LabNet

  # Both directions: the kernel pings the host behind vtep4rd, and the
  # host pings the kernel's address.
  def test_pings_cross_both_ways
    assert_match(/3 received/, in_ns('vt4A', 'ping', '-c', '3', '-W', '2', '172.16.100.2'))
    assert_match(/2 received/, in_ns('vt4H', 'ping', '-c', '2', '-W', '2', '172.16.100.1'))
  end

  # The host must broadcast an ARP request, which only vtep4rd's flood to
  # its flood list carries. Without the flush the kernel's own ARP request
  # has already taught the host, and the flood is never needed: a test that
  # missed a broken flood that way.
  def test_a_broadcast_from_the_host_is_flooded_into_the_tunnel
    in_ns('vt4H', 'ip', 'neigh', 'flush', 'all')
    in_ns('vt4A', 'ip', 'neigh', 'flush', 'all')
    assert_match(/2 received/, in_ns('vt4H', 'ping', '-c', '2', '-W', '2', '172.16.100.1'))
  end

  # Each side learns the other's MAC behind the other's address.
  def test_each_side_learns_the_other
    in_ns('vt4A', 'ping', '-c', '1', '-W', '2', '172.16.100.2')
    macs = cli('show.macs', 'vni=100').to_h { |m| [m['mac'], [m['type'], m['port'] || m['vtep']]] }
    assert_equal ['remote', '10.9.0.1'], macs['02:00:00:00:01:01']
    assert_equal ['local', 'p0'], macs['02:00:00:00:01:02']
    assert_match(/dst 10.9.0.2/, kernel_fdb('02:00:00:00:01:02').join)
    assert_equal({}, cli('show.counters')['drops'])
  end

  # The host port's link down and up: Linux answers ENETDOWN to the
  # packet socket's reader, which must keep reading. Before the fix
  # vtep4rd's reader ended, and the host stayed cut off.
  def test_the_port_is_read_again_after_its_link_goes_down_and_up
    in_ns('vt4B', 'ip', 'link', 'set', 'p0', 'down')
    sleep 0.5
    in_ns('vt4B', 'ip', 'link', 'set', 'p0', 'up')
    wait_for { in_ns('vt4H', 'ip', 'link', 'show', 'p1').include?('LOWER_UP') }
    assert_match(/2 received/, in_ns('vt4H', 'ping', '-c', '2', '-W', '2', '172.16.100.1'))
  end

  # vtep4r-sim, beside vtep4rd in its namespace, into the kernel: the
  # generated MACs are learned behind the sim's address.
  def test_the_sim_fills_the_kernels_table
    r = sim_post('/api/generate', 'to' => '10.9.0.1', 'per_second' => 500,
                                  'spec' => { 'vni' => 100, 'macs' => 50, 'src' => '02:00:00:aa:00:00' })
    assert_equal 50, r['total']
    wait_for { kernel_fdb('02:00:00:aa:00').size == 50 }
    assert kernel_fdb('02:00:00:aa:00').all? { |l| l.include?('dst 10.9.0.2') }
  end

  # The sim's own address on the same namespace as vtep4rd's port 4789:
  # it never binds it, so both run.
  def test_the_sim_runs_beside_vtep4rd
    status = JSON.parse(in_ns('vt4B', RUBY, '-rnet/http', '-e', "print Net::HTTP.get(URI('http://127.0.0.1:#{API}/api/status'))"))
    assert_equal '10.9.0.2', status['local']
    assert_equal '10.9.0.2', cli('show.status')['local']
  end
end
