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
    # One VNI: its host ports, its MAC table, its flood list, its mode and
    # its encapsulation.
    #
    #   :learn  remote MACs are learned from the tunnel (RFC 7348 section
    #           4.1), and the flood list is static
    #   :evpn   remote MACs and the flood list come from vtep4rd's API,
    #           which bgp4rd drives; local MACs are still learned from
    #           the ports, since bgp4rd advertises them
    #
    # The encapsulation is :vxlan, or :mpls for EVPN over MPLS (bgp4r
    # docs/design/evpn-mpls.md). An MPLS bridge domain has two labels of
    # its own, unicast and BUM, which bgp4rd gives out and advertises:
    # Label1 of its type 2 routes and the PMSI label of its type 3 route
    # (RFC 7432 sections 9.2.1 and 11.1). Its remote MACs and flood list
    # each carry the remote PE's label. It is always :evpn: a packet over
    # MPLS does not say which PE sent it, so there is nothing to learn a
    # remote MAC from. The VNI stays its key, the local bridge domain's
    # number; no VNI is on the wire.
    class BridgeDomain
      MODES = %i[learn evpn].freeze
      ENCAPS = %i[vxlan mpls].freeze
      # RFC 3032 section 2.1 gives labels 0 to 3 their meaning, and "Values
      # 4-15 are reserved", so a label given out is 16 or more.
      FIRST_LABEL = 16
      LAST_LABEL = 0xfffff

      attr_reader :vni, :ports, :mode, :flood, :macs, :encap, :labels

      def initialize(vni:, ports:, mode: :learn, flood: [], ageing: 300, encap: :vxlan, labels: nil)
        raise ArgumentError, "vni #{vni.inspect} is not 0 to 0xffffff" unless vni.is_a?(Integer) && vni.between?(0, 0xffffff)

        mode = mode.to_sym
        raise ArgumentError, "mode #{mode.inspect}, one of #{MODES.join(', ')}" unless MODES.include?(mode)

        encap = encap.to_sym
        raise ArgumentError, "encap #{encap.inspect}, one of #{ENCAPS.join(', ')}" unless ENCAPS.include?(encap)
        if encap == :mpls && mode != :evpn
          raise ArgumentError, "vni #{vni}: encap mpls needs mode evpn; a packet over MPLS does not say which PE " \
                               'sent it, so remote MACs come from the API'
        end
        raise ArgumentError, "vni #{vni}: labels are for encap mpls" if labels && encap != :mpls

        @vni = vni
        @ports = ports.map(&:to_s).freeze
        @mode = mode
        @encap = encap
        @flood = flood.map(&:to_s).uniq
        @flood_labels = {}
        @macs = MacTable.new(ageing: ageing)
        set_labels(**labels.transform_keys(&:to_sym)) if labels
      end

      def learn_remote?
        @mode == :learn
      end

      def mpls?
        @encap == :mpls
      end

      # The two labels, { unicast:, bum: }. true when they changed.
      def set_labels(unicast:, bum:)
        raise ArgumentError, "vni #{@vni}: labels are for encap mpls" unless mpls?

        u = BridgeDomain.label(unicast, 'unicast')
        b = BridgeDomain.label(bum, 'bum')
        raise ArgumentError, "vni #{@vni}: unicast and bum are both #{u}; a receiver could not tell them apart" if u == b

        new = { unicast: u, bum: b }.freeze
        return false if new == @labels

        @labels = new
        true
      end

      # A label a PE gave or we give: 16 to 2^20 - 1.
      def self.label(value, what = 'label')
        v = Integer(value)
        raise ArgumentError, "#{what} #{v} is not #{FIRST_LABEL} to #{LAST_LABEL}" unless v.between?(FIRST_LABEL, LAST_LABEL)

        v
      rescue TypeError
        raise ArgumentError, "#{what} #{value.inspect} is not a label"
      end

      # The BUM label a remote PE gave, for its place in the flood list.
      def flood_label(vtep)
        @flood_labels[vtep.to_s]
      end

      # true when the list changed. Over MPLS +label+ is the remote PE's
      # BUM label, required, and a new label for a VTEP in the list is a
      # change; over VXLAN there is none.
      def flood_add(vtep, label: nil)
        vtep = vtep.to_s
        if mpls?
          raise ArgumentError, "vni #{@vni}: a flood entry over mpls needs the remote PE's label" if label.nil?

          label = BridgeDomain.label(label)
          had = @flood_labels[vtep]
          @flood_labels[vtep] = label
          @flood << vtep unless @flood.include?(vtep)
          return had != label
        end
        raise ArgumentError, "vni #{@vni}: a label is for encap mpls" unless label.nil?
        return false if @flood.include?(vtep)

        @flood << vtep
        true
      end

      def flood_del(vtep)
        @flood_labels.delete(vtep.to_s)
        !@flood.delete(vtep.to_s).nil?
      end

      # The whole list at once, for a reload. true when it changed.
      def flood_replace(list)
        list = list.map(&:to_s).uniq
        return false if list == @flood

        @flood.replace(list)
        true
      end
    end
  end
end
