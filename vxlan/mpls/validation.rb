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

require 'vxlan/validation'
require 'vxlan/mpls/packet'

module VXLAN
  module Mpls
    # Every receive-side rule for EVPN over MPLS, as VXLAN::Validation is
    # for VXLAN. It runs only on what was received, and uses the same
    # Finding, policies and Malformed_packet.
    #
    # A label that is not the receiver's is not here: whether a label is
    # valid depends on the labels a VTEP gave out (RFC 3031 section 3.18),
    # so the VTEP decides it. An explicit null is not a finding either:
    # RFC 4182 section 2 made it legal anywhere in the stack.
    module Validation
      Finding = VXLAN::Validation::Finding
      POLICIES = VXLAN::Validation::POLICIES
      ETHERNET_HEADER = VXLAN::Validation::ETHERNET_HEADER

      module_function

      def check(packet)
        unless packet.bottom?
          return [Finding.new(:no_bottom, :drop,
                              "#{packet.labels.size} label(s) and no S bit: \"The network layer packet " \
                              'immediately follows the label stack entry which has the S bit set" ' \
                              '(RFC 3032 section 2.1), so there is no packet')]
        end

        out = []
        if packet.expects_control_word? && packet.control_word.nil?
          return [Finding.new(:no_control_word, :drop,
                              "#{packet.tail&.bytesize.to_i} octet(s) after the bottom label, fewer than a " \
                              'control word: EVPN sends one (RFC 7432 section 18, RFC 4385 section 3)')]
        end
        cw = packet.control_word
        if cw && cw.nibble.nonzero?
          out << Finding.new(:control_word_nibble, :drop,
                             format('control word 0x%08x: its first four bits "MUST" be 0, the Generic ' \
                                    'format (RFC 4385 section 3)', cw.encode.unpack1('N')))
        elsif cw && !cw.to_hash.empty?
          # RFC 7432 section 18 sends the control word "with the value 0"
          # and says nothing of a receiver. The reading here: the frame is
          # still whole, so it is passed on.
          out << Finding.new(:control_word_set, :ignore,
                             format('control word 0x%08x: EVPN sends it "with the value 0" (RFC 7432 ' \
                                    'section 18)', cw.encode.unpack1('N')))
        end
        if packet.inner && packet.inner.bytesize < ETHERNET_HEADER
          out << Finding.new(:short, :drop,
                             "an inner frame of #{packet.inner.bytesize} octets, fewer than an Ethernet " \
                             "header's #{ETHERNET_HEADER}")
        end
        out
      end

      # :deliver or :drop for a received packet under a policy.
      def decide(packet, policy: :rfc)
        raise ArgumentError, "unknown receive policy #{policy.inspect}, one of #{POLICIES.join(', ')}" unless POLICIES.include?(policy)
        return :deliver if policy == :lenient

        findings = check(packet)
        raise Malformed_packet.new(findings.first, findings) if policy == :strict && !findings.empty?

        findings.any? { |f| f.action == :drop } ? :drop : :deliver
      end
    end

    class Packet
      # What the sender got wrong, as Validation::Finding.
      def errors
        Validation.check(self)
      end
    end
  end
end
