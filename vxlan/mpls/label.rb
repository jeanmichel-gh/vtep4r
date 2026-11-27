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
  module Mpls
    # One MPLS label stack entry, RFC 3032 section 2.1, Figure 1:
    #
    #   |                Label                  | Exp |S|       TTL     |
    #
    # A 20-bit label, 3 bits "reserved for experimental use" (tcpdump
    # prints them as tc), the bottom of stack bit S and an 8-bit TTL.
    #
    # Built four ways, as Header is:
    #
    #   Label.new(25000)                           # field value: the label
    #   Label.new(label: 25000, s: 1, ttl: 255)    # a hash
    #   Label.new(octets)                          # wire bytes, the first four
    #   Label.new(other)                           # another instance
    #
    # **Building is never validated.** Any label goes out, the reserved
    # ones (0 to 15) included, with any S bit: a receiver can then be
    # watched handling them. Only a value that cannot fit its field is
    # refused.
    class Label
      SIZE = 4

      # RFC 3032 section 2.1, as RFC 4182 section 2 changed it: an
      # explicit null "at the top of the label stack means that the stack
      # must be popped", and the label beneath it rises.
      IPV4_EXPLICIT_NULL = 0
      IPV6_EXPLICIT_NULL = 2
      EXPLICIT_NULLS = [IPV4_EXPLICIT_NULL, IPV6_EXPLICIT_NULL].freeze

      # Each field: its default, and the largest value it holds. A TTL of
      # 64 is what the kernel and the spec's measurement sent.
      FIELDS = { label: [0, 0xfffff], tc: [0, 7], s: [0, 1], ttl: [64, 0xff] }.freeze

      attr_reader :label, :tc, :s, :ttl

      def initialize(arg)
        case arg
        when String then parse(arg)
        when Label then parse(arg.encode)
        when Integer then set(label: arg)
        when Hash then set(**arg)
        else raise ArgumentError, "invalid argument, #{arg.inspect}"
        end
      end

      def bottom?
        @s == 1
      end

      def explicit_null?
        EXPLICIT_NULLS.include?(@label)
      end

      def encode
        [(@label << 12) | (@tc << 9) | (@s << 8) | @ttl].pack('N')
      end

      def to_shex
        encode.unpack1('H*')
      end

      # The label, and each other field only when it is not its default.
      # Round trips through new.
      def to_hash
        h = { label: @label }
        FIELDS.each do |name, (default, _)|
          next if name == :label

          value = instance_variable_get("@#{name}")
          h[name] = value unless value == default
        end
        h
      end

      # tcpdump's form: "(label 25001, tc 0, [S], ttl 64)".
      def to_s
        format('(label %d, tc %d, %sttl %d)', @label, @tc, bottom? ? '[S], ' : '', @ttl)
      end

      def ==(other)
        other.is_a?(Label) && encode == other.encode
      end
      alias eql? ==

      def hash
        encode.hash
      end

      private

      def parse(octets)
        raise ArgumentError, "a label stack entry is #{SIZE} octets, got #{octets.bytesize}" if octets.bytesize < SIZE

        word = octets.byteslice(0, SIZE).unpack1('N')
        @label = word >> 12
        @tc = (word >> 9) & 7
        @s = (word >> 8) & 1
        @ttl = word & 0xff
      end

      def set(**fields)
        unknown = fields.keys - FIELDS.keys
        raise ArgumentError, "unknown label field #{unknown.join(', ')}" unless unknown.empty?

        FIELDS.each do |name, (default, max)|
          value = fields.fetch(name, default)
          unless value.is_a?(Integer) && value.between?(0, max)
            raise ArgumentError, "#{name} #{value.inspect} does not fit (0 to 0x#{max.to_s(16)})"
          end

          instance_variable_set("@#{name}", value)
        end
      end
    end
  end
end
