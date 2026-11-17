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

require 'vxlan/packet'

module VXLAN
  # Every receive-side rule, in one place, as bgp4r's validation.rb.
  #
  # It runs only on what was received. Building and encoding are never
  # checked (CLAUDE.md, Conventions). A finding says what the sender got
  # wrong and what RFC 7348 has the receiver do about it; a receive
  # policy turns the findings into a verdict.
  #
  # An unknown VNI is not here. Whether a VNI is valid depends on the
  # VNIs a VTEP serves (RFC 7348 section 4.1), so the VTEP decides it.
  module Validation
    # name     :short, :no_i_flag or :reserved_set
    # action   :drop, or :ignore for a fault the RFC has the receiver
    #          ignore
    # reason   plain words, with the RFC section
    Finding = Struct.new(:name, :action, :reason) do
      def to_s
        "#{name}: #{reason} (#{action})"
      end
    end

    # The receive policies:
    #   :rfc      drop on a :drop finding, deliver past an :ignore one
    #   :strict   raise Malformed_packet on any finding
    #   :lenient  deliver everything, for watching what a sender sends
    POLICIES = %i[rfc strict lenient].freeze

    # The inner Ethernet header: two addresses and an EtherType.
    ETHERNET_HEADER = 14

    module_function

    def check(packet)
      return [short("#{packet.encode.bytesize} octets, fewer than the #{Header::SIZE} of a header")] if packet.header.nil?

      out = []
      h = packet.header
      unless h.i_flag?
        out << Finding.new(:no_i_flag, :drop,
                           format('I flag clear in flags 0x%02x: it "MUST be set to 1 for a valid VXLAN ' \
                                  'Network ID" (RFC 7348 section 5), and only a valid VNI is passed on ' \
                                  '(section 4.1)', h.flags))
      end
      if (h.flags & ~Header::I_FLAG).nonzero? || h.reserved1.nonzero? || h.reserved2.nonzero?
        out << Finding.new(:reserved_set, :ignore,
                           format('reserved bits set (flags 0x%02x, reserved 0x%06x and 0x%02x): "set to ' \
                                  'zero on transmission and ignored on receipt" (RFC 7348 section 5)',
                                  h.flags, h.reserved1, h.reserved2))
      end
      if packet.inner.bytesize < ETHERNET_HEADER
        out << short("an inner frame of #{packet.inner.bytesize} octets, fewer than an Ethernet header's " \
                     "#{ETHERNET_HEADER}")
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

    # RFC 7348 says nothing of a cut packet. Section 5 gives a header of
    # 8 octets and an inner MAC frame after it; a packet without them
    # cannot be passed on, so the reading here is to drop it.
    def short(what)
      Finding.new(:short, :drop, "#{what}: section 5 of RFC 7348 has a header and an inner MAC frame")
    end
    private_class_method :short
  end

  # Raised by the :strict receive policy. finding is the first finding,
  # findings all of them.
  class Malformed_packet < StandardError
    attr_reader :finding, :findings

    def initialize(finding, findings = [finding])
      @finding = finding
      @findings = findings
      super(finding.to_s)
    end
  end

  class Packet
    # What the sender got wrong, as Validation::Finding.
    def errors
      Validation.check(self)
    end
  end
end
