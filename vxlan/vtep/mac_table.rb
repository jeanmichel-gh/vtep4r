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

require 'datalink'
require 'vxlan/vtep/actions'

module VXLAN
  module Vtep
    # One VNI's MAC table: MAC to a Location.
    #
    # An entry is :learned, from traffic, and ages out after +ageing+
    # seconds unseen; or :api, set by vtep4rd's API for EVPN, which stays
    # until deleted. Learning from a tunnel never overwrites an :api
    # entry. Learning on a port does: the host is here now, and bgp4rd
    # hears it as a move (RFC 7432 section 15) and decides. The time is
    # an argument, never read from a clock, so a test is the clock.
    class MacTable
      Entry = Struct.new(:mac, :location, :origin, :seen, :seq, :moves)

      # Settable, for a reload; learned entries age by the new value from
      # the next tick.
      attr_accessor :ageing

      def initialize(ageing: 300)
        @ageing = ageing
        @entries = {}
      end

      # :learned for a new MAC, :moved for one seen at another location,
      # nil otherwise. A port learn over an :api entry is a :moved, and
      # the entry is :learned from then on, with seq 0 as every learned
      # entry has.
      def learn(mac, location, now)
        e = @entries[mac]
        if e.nil?
          @entries[mac] = Entry.new(mac, location, :learned, now, 0, 0)
          return :learned
        end
        if e.origin == :api
          return nil unless location.port?

          e.origin = :learned
          e.seq = 0
        end

        e.seen = now
        return nil if e.location == location

        e.location = location
        e.moves += 1
        :moved
      end

      # An entry from the API. +seq+ is bgp4rd's, for RFC 7432 MAC
      # Mobility; vtep4rd only keeps it.
      def add(mac, location, seq: 0)
        prev = @entries[mac]
        moves = prev ? prev.moves + (prev.location == location ? 0 : 1) : 0
        @entries[mac] = Entry.new(mac, location, :api, nil, seq, moves)
      end

      def lookup(mac)
        @entries[mac]
      end

      def delete(mac)
        !@entries.delete(mac).nil?
      end

      def flush(origin: nil)
        origin ? @entries.delete_if { |_, e| e.origin == origin } : @entries.clear
        self
      end

      # The learned MACs unseen for +ageing+ seconds at +now+, removed.
      def age(now)
        expire(now).map(&:mac)
      end

      # The same, as the entries removed, so each keeps its location.
      def expire(now)
        gone = @entries.values.select { |e| e.origin == :learned && now - e.seen >= @ageing }
        gone.each { |e| @entries.delete(e.mac) }
        gone
      end

      def size
        @entries.size
      end

      # One row per MAC, for show.macs and routescope's evpn_macs.
      def rows(now:)
        @entries.values.map do |e|
          { mac: e.mac.to_s, type: e.location.port? ? :local : :remote,
            port: (e.location.name if e.location.port?), vtep: (e.location.name if e.location.vtep?),
            origin: e.origin, age: ((now - e.seen).round(1) if e.seen), seq: e.seq, moves: e.moves }
        end
      end
    end
  end
end
