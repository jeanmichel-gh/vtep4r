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

require 'yaml'

module VXLAN
  module Daemon
    # vtep4rd's file, read and checked. Unknown keys are refused by name,
    # as bgp4rd refuses them, so a typo is an error and not a default.
    #
    #   local: 10.255.0.11
    #   socket: /run/vtep4r/vtep4rd.sock
    #   receive_policy: rfc
    #   ageing: 300
    #   mtu: 1500
    #   vnis:
    #     - vni: 100
    #       ports: [eth2]
    #       mode: learn            # or evpn
    #       flood: [10.255.0.12]   # static, for learn mode
    class Config
      class Error < StandardError; end

      TOP = %w[local socket receive_policy ageing mtu vnis].freeze
      VNI = %w[vni ports mode flood ageing].freeze

      attr_reader :local, :socket, :receive_policy, :ageing, :mtu, :vnis

      def self.load(path)
        new(YAML.safe_load(File.read(path), filename: path) || {})
      rescue Psych::SyntaxError => e
        raise Error, e.message
      end

      def initialize(hash)
        raise Error, 'the file is not a YAML mapping' unless hash.is_a?(Hash)

        h = hash.transform_keys(&:to_s)
        refuse(h.keys - TOP, 'key')
        @local = h['local'] or raise Error, 'local: the VTEP address is required'
        @socket = h['socket']
        @receive_policy = (h['receive_policy'] || 'rfc').to_sym
        @ageing = Integer(h['ageing'] || 300)
        @mtu = Integer(h['mtu'] || 1500)
        @vnis = Array(h['vnis']).map { |v| vni(v) }
      rescue ArgumentError, TypeError => e
        raise Error, e.message
      end

      # What Vtep::Switch.new takes.
      def switch_args
        { local: @local, mtu: @mtu, policy: @receive_policy, vnis: @vnis }
      end

      # Every host port, across the VNIs.
      def ports
        @vnis.flat_map { |v| v[:ports] }
      end

      private

      def vni(v)
        raise Error, "a vnis entry is not a mapping: #{v.inspect}" unless v.is_a?(Hash)

        v = v.transform_keys(&:to_s)
        refuse(v.keys - VNI, 'vnis key')
        { vni: Integer(v['vni'] || raise(Error, 'vnis: an entry has no vni')),
          ports: Array(v['ports']).map(&:to_s), mode: (v['mode'] || 'learn').to_sym,
          flood: Array(v['flood']).map(&:to_s), ageing: Integer(v['ageing'] || @ageing) }
      end

      def refuse(keys, what)
        raise Error, "unknown #{what} #{keys.join(', ')}" unless keys.empty?
      end
    end
  end
end
