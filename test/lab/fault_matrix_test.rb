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
require 'time'
require_relative 'lab_net'
require_relative 'fault_matrix'
require 'vtep4r'

# The fault matrix: every crafted packet of VXLAN::Fault::CATALOG, and a
# valid one, sent by vtep4r-sim to vtep4rd and to the kernel's vxlan.
# vtep4rd must do what RFC 7348 expects; the kernel's answers are
# recorded, not asserted. With VTEP4R_MATRIX_DOC set to a path, it writes
# the matrix there (docs/fault-matrix.md).
#
#   sudo DATALINK_LIB=~/datalink-socket/lib ruby -I. test/lab/fault_matrix_test.rb
class Fault_matrix_Test < Test::Unit::TestCase
  include LabNet

  VNI = 100

  # An inert broadcast, the local experimental EtherType 0x88b5, from the
  # case's own source MAC: 02:00:00:0a:RR:NN, RR the receiver, NN the
  # case. Nothing answers it. The first draft used the catalog's ARP
  # request, which the host and the kernel answered; their answers crossed
  # the tunnel during the next case.
  def mac(receiver, n)
    format('02:00:00:0a:%02x:%02x', receiver, n)
  end

  def inner(mac)
    "ffffffffffff#{mac.delete(':')}88b5#{'00' * 46}"
  end

  def cases
    [{ name: :valid, description: 'a valid packet, the baseline', expect: :deliver, rfc: '5',
       body: ->(to, i) { ['/api/send', { 'to' => to, 'vni' => VNI, 'inner' => i }] } }] +
      VXLAN::Fault.catalog.map do |e|
        e.merge(rfc: e[:rfc].sub('RFC 7348 ', ''),
                body: ->(to, i) { ['/api/fault', { 'to' => to, 'case' => e[:name].to_s, 'vni' => VNI, 'inner' => i }] })
      end
  end

  def vtep4rd_learned?(m)
    cli('show.macs', 'vni=100').any? { |r| r['mac'] == m }
  end

  def measure(c, n)
    v_mac = mac(1, n)
    k_mac = mac(2, n)
    v0 = cli('show.counters')
    k0 = kernel_rx
    sim_post(*c[:body].call('10.9.0.2', inner(v_mac)))
    sim_post(*c[:body].call('10.9.0.1', inner(k_mac)))
    sleep 0.3
    { name: c[:name], description: c[:description], expect: c[:expect], rfc: c[:rfc],
      vtep4rd: FaultMatrix.vtep4rd(vtep4rd_learned?(v_mac), v0, cli('show.counters')),
      kernel: FaultMatrix.kernel(!kernel_fdb(k_mac).empty?, k0, kernel_rx) }
  end

  def test_the_matrix
    rows = cases.each_with_index.map { |c, n| measure(c, n) }
    rows.each do |r|
      assert FaultMatrix.agrees?(r[:expect], r[:vtep4rd]), "vtep4rd on #{r[:name]}: #{r[:vtep4rd]}, expected #{r[:expect]}"
      assert_not_equal 'nothing seen', r[:vtep4rd], "vtep4rd saw nothing for #{r[:name]}"
    end
    assert_equal 'delivered', rows.first[:kernel], 'the kernel must deliver the valid baseline'
    if (path = ENV['VTEP4R_MATRIX_DOC'])
      kernel = `uname -r`.strip
      File.write(path, FaultMatrix.render(rows, kernel: kernel, version: VXLAN::VERSION, date: Time.now.utc.strftime('%Y-%m-%d')))
    end
  end
end
