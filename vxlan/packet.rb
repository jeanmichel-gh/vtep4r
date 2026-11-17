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
require 'vxlan/header'

module VXLAN
  # A VXLAN packet: the UDP payload, a Header then the inner Ethernet
  # frame (RFC 7348 section 5). The outer IP and UDP headers belong to the
  # socket that sends it, so they are not in the object.
  #
  # Built four ways:
  #
  #   Packet.new(header, frame)    # field values: a Header or its hash, and
  #                                # a Datalink::Frame or its octets
  #   Packet.new(header: { vni: 100 }, inner: 'ffff...')  # a hash, inner in hex
  #   Packet.new(octets)           # wire bytes
  #   Packet.new(other)            # another instance
  #
  # **Keep what cannot be read.** The inner frame is kept as the octets
  # that came, and #frame parses them on demand: nil when they are too
  # short to be a frame, as a crafted packet may be. Fewer octets than a
  # header are kept whole, with no header. encode always gives back what
  # arrived.
  class Packet
    attr_reader :header, :inner

    def initialize(*args)
      if args.size == 2
        @header = args[0].is_a?(Header) ? args[0] : Header.new(args[0])
        @inner = octets_of(args[1])
        return
      end
      raise ArgumentError, "invalid arguments, #{args.inspect}" unless args.size == 1

      arg = args[0]
      case arg
      when String then parse(arg)
      when Packet then parse(arg.encode)
      when Hash then from_hash(arg)
      else raise ArgumentError, "invalid argument, #{arg.inspect}"
      end
    end

    # The inner frame as a Datalink::Frame, or nil when it cannot be one.
    def frame
      return nil if @inner.nil? || @inner.empty?

      @frame ||= Datalink::Frame.parse(@inner)
    rescue Datalink::ParseError
      nil
    end

    def encode
      return @short.dup if @short

      @header.encode + @inner
    end

    def to_shex
      encode.unpack1('H*')
    end

    # { header: { vni: 100 }, inner: hex }, or { short: hex } for fewer
    # octets than a header. Round trips through new.
    def to_hash
      return { short: @short.unpack1('H*') } if @short

      { header: @header.to_hash, inner: @inner.unpack1('H*') }
    end

    def to_s
      return "VXLAN, short (#{@short.bytesize} octets)" if @short

      f = frame
      f ? "#{@header}: #{f}" : "#{@header}: #{@inner.bytesize} octets"
    end

    private

    def parse(octets)
      octets = octets.b
      if octets.bytesize < Header::SIZE
        @short = octets
        return
      end
      @header = Header.new(octets)
      @inner = octets.byteslice(Header::SIZE..)
    end

    def from_hash(hash)
      unknown = hash.keys - %i[header inner short]
      raise ArgumentError, "unknown packet key #{unknown.join(', ')}" unless unknown.empty?
      return parse([hash[:short]].pack('H*')) if hash.key?(:short)

      @header = hash[:header].is_a?(Header) ? hash[:header] : Header.new(hash.fetch(:header, {}))
      inner = hash.fetch(:inner, '')
      @inner = inner.is_a?(String) ? [inner].pack('H*') : octets_of(inner)
    end

    # A Datalink::Frame, or octets.
    def octets_of(inner)
      return inner.encode.b if inner.respond_to?(:encode) && !inner.is_a?(String)
      raise ArgumentError, "invalid inner frame, #{inner.inspect}" unless inner.is_a?(String)

      inner.b
    end
  end
end
