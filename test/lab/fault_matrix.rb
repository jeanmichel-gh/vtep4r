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

# What the fault matrix measured, as words, and the document it writes:
# docs/fault-matrix.md, after bgp4r's docs/protocol-testing.md, "What
# three implementations do". Used by test/lab/fault_matrix_test.rb.
module FaultMatrix
  module_function

  # **Delivered means the receiver learned the case's own source MAC.**
  # Each case sends its inner frame from a MAC no other packet uses, and a
  # receiver learns a source only from a packet it accepted. The first
  # draft judged by counters instead, and they lied: the host's own IPv6
  # frames crossed the tunnel during a case and read as deliveries, so the
  # kernel looked as if it delivered R-bit packets it drops.

  # vtep4rd: delivered when it learned +mac+, else the drop reason that
  # rose in show.counters.
  def vtep4rd(learned, before, after)
    return 'delivered' if learned

    rose = after['drops'].select { |k, v| v.to_i > before['drops'][k].to_i }.keys
    rose.empty? ? 'nothing seen' : "dropped: #{rose.join(', ')}"
  end

  # The kernel: delivered when its fdb learned +mac+; else how vxlan100's
  # receive counters saw the drop. Linux 7.0, measured: a reserved bit set
  # counts in errors; the I flag clear, an unknown VNI and a cut packet
  # count nowhere on the device.
  def kernel(learned, before, after)
    return 'delivered' if learned

    d = after.to_h { |k, v| [k, v - before[k].to_i] }
    return 'dropped, counted as an rx error' if d['errors'].to_i.positive?
    return 'dropped, counted as rx dropped' if d['dropped'].to_i.positive?

    'dropped before the device, not counted'
  end

  def delivered?(outcome)
    outcome == 'delivered'
  end

  # Does +outcome+ do what the RFC expects (:drop, :ignore or :deliver)?
  def agrees?(expect, outcome)
    expect == :drop ? !delivered?(outcome) : delivered?(outcome)
  end

  def render(rows, kernel:, version:, date:)
    lines = []
    lines << '# The fault matrix'
    lines << ''
    lines << 'What each receiver does with each crafted packet of `VXLAN::Fault::CATALOG`,'
    lines << 'against what RFC 7348 expects. After bgp4r\'s `docs/protocol-testing.md`,'
    lines << '"What three implementations do".'
    lines << ''
    lines << "**Generated** by `test/lab/fault_matrix_test.rb` on #{date}, Linux #{kernel},"
    lines << "vtep4r #{version}. Do not edit it by hand; run again, as root:"
    lines << ''
    lines << '```sh'
    lines << 'sudo VTEP4R_MATRIX_DOC=docs/fault-matrix.md DATALINK_LIB=~/datalink-socket/lib ruby -I. test/lab/fault_matrix_test.rb'
    lines << '```'
    lines << ''
    lines << 'Each packet is sent once by vtep4r-sim, with an inert broadcast (EtherType 0x88b5) as'
    lines << 'its inner frame, from a source MAC of its own, to two receivers serving VNI 100 in'
    lines << 'the namespaces of `test/lab/lab_net.rb`:'
    lines << ''
    lines << "- **vtep4rd**: delivered when it learned the case's source MAC, which it does"
    lines << '  only from a packet it accepted; else the drop reason that rose.'
    lines << "- **The Linux kernel's `vxlan` device**: delivered when its fdb learned the MAC,"
    lines << '  else how its receive counters saw the drop. FRR has no VXLAN data plane of'
    lines << "  its own: zebra programs this device. So this column is FRR's too."
    lines << ''
    lines << '| Case | What | RFC 7348 expects | vtep4rd | Linux kernel, and FRR | Kernel as the RFC |'
    lines << '| --- | --- | --- | --- | --- | --- |'
    rows.each do |r|
      lines << "| `#{r[:name]}` | #{r[:description]} | #{r[:expect]} (#{r[:rfc]}) | #{r[:vtep4rd]} | #{r[:kernel]} | " \
               "#{agrees?(r[:expect], r[:kernel]) ? 'yes' : '**no**'} |"
    end
    lines << ''
    lines << '"ignore" means the receiver ignores the bits and delivers the frame: RFC'
    lines << '7348 section 5 says the R bits and reserved fields are "set to zero on'
    lines << 'transmission and ignored on receipt". For the three cut packets the RFC'
    lines << 'says nothing; a drop is our reading (`VXLAN::Fault`).'
    lines << ''
    differ = rows.reject { |r| agrees?(r[:expect], r[:kernel]) }.map { |r| "`#{r[:name]}`" }
    lines << if differ.empty?
               'The kernel does what the RFC expects in every case.'
             else
               "The kernel differs from the RFC on #{differ.join(', ')}: it drops packets whose reserved bits " \
                 'are set, where the RFC says to ignore them. Why is not known here.'
             end
    lines.join("\n") + "\n"
  end
end
