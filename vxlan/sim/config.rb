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
  module Sim
    # vtep4r-sim's file:
    #
    #   local: 10.255.0.11      the address it sends from
    #   api: 127.0.0.1:8080     its HTTP API (the loopback by default)
    #   port: 4789              the VXLAN port it sends to
    #
    # An injector keeps no MAC table and forwards nothing, so the keys
    # that would make it a VTEP are refused by name, as bgp4r-sim refuses
    # a Loc-RIB's: an injector that quietly decided things would void
    # every assertion about what it sent.
    class Config
      class Error < StandardError; end

      KEYS = %w[local api port].freeze
      VTEP_KEYS = %w[vnis ports ageing mtu receive_policy socket].freeze

      attr_reader :local, :api, :port

      def self.load(path)
        new(YAML.safe_load(File.read(path), filename: path) || {})
      rescue Psych::SyntaxError => e
        raise Error, e.message
      end

      def initialize(hash)
        raise Error, 'the file is not a YAML mapping' unless hash.is_a?(Hash)

        h = hash.transform_keys(&:to_s)
        vtep = h.keys & VTEP_KEYS
        unless vtep.empty?
          raise Error, "#{vtep.join(', ')}: an injector keeps no MAC table and forwards nothing; " \
                       "that is vtep4rd's file"
        end
        unknown = h.keys - KEYS
        raise Error, "unknown key #{unknown.join(', ')}; vtep4r-sim's file takes #{KEYS.join(', ')}" unless unknown.empty?

        @local = h['local'] or raise Error, 'local: the address to send from is required'
        @api = (h['api'] || '127.0.0.1:8080').to_s
        @port = Integer(h['port'] || 4789)
      rescue ArgumentError, TypeError => e
        raise Error, e.message
      end
    end
  end
end
