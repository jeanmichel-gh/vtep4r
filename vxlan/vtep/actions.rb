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

module VXLAN
  module Vtep
    # Where a MAC is: on a host port, or behind a remote VTEP.
    Location = Struct.new(:kind, :name) do
      def self.port(name)
        new(:port, name)
      end

      def self.vtep(address)
        new(:vtep, address)
      end

      def port?
        kind == :port
      end

      def vtep?
        kind == :vtep
      end

      def to_s
        "#{kind} #{name}"
      end
    end

    # What the Forwarder answers. Deliver and Tunnel are for the edges to
    # carry out; Learn, Note and Drop are for Switch.
    #
    #   Deliver  a frame's octets out of a host port
    #   Tunnel   a Packet to a VTEP, from a UDP source port
    #   Learn    a MAC seen at a location, in a VNI
    #   Note     a finding the receiver ignores, by name
    #   Drop     why a frame or packet went nowhere
    Deliver = Struct.new(:port, :octets)
    Tunnel = Struct.new(:vtep, :packet, :source_port)
    Learn = Struct.new(:vni, :mac, :location)
    Note = Struct.new(:finding)
    Drop = Struct.new(:reason)

    # A change in a MAC table, for bgp4rd's type 2 routes and routescope:
    # :learned, :moved or :aged. +location+ is where the MAC is, or was
    # for :aged; +from+ is where a :moved MAC was before.
    Event = Struct.new(:type, :vni, :mac, :location, :from)
  end
end
