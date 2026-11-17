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

require 'vxlan/vtep/mac_table'

module VXLAN
  module Vtep
    # One VNI: its host ports, its MAC table, its flood list and its mode.
    #
    #   :learn  remote MACs are learned from the tunnel (RFC 7348 section
    #           4.1), and the flood list is static
    #   :evpn   remote MACs and the flood list come from vtep4rd's API,
    #           which bgp4rd drives; local MACs are still learned from
    #           the ports, since bgp4rd advertises them
    class BridgeDomain
      MODES = %i[learn evpn].freeze

      attr_reader :vni, :ports, :mode, :flood, :macs

      def initialize(vni:, ports:, mode: :learn, flood: [], ageing: 300)
        raise ArgumentError, "vni #{vni.inspect} is not 0 to 0xffffff" unless vni.is_a?(Integer) && vni.between?(0, 0xffffff)

        mode = mode.to_sym
        raise ArgumentError, "mode #{mode.inspect}, one of #{MODES.join(', ')}" unless MODES.include?(mode)

        @vni = vni
        @ports = ports.map(&:to_s).freeze
        @mode = mode
        @flood = flood.map(&:to_s).uniq
        @macs = MacTable.new(ageing: ageing)
      end

      def learn_remote?
        @mode == :learn
      end

      # true when the list changed.
      def flood_add(vtep)
        return false if @flood.include?(vtep.to_s)

        @flood << vtep.to_s
        true
      end

      def flood_del(vtep)
        !@flood.delete(vtep.to_s).nil?
      end
    end
  end
end
