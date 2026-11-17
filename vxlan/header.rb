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
  # The 8-octet VXLAN header, RFC 7348 section 5:
  #
  #   |R|R|R|R|I|R|R|R|            Reserved                           |
  #   |                VXLAN Network Identifier (VNI) |   Reserved    |
  #
  # Flags are 8 bits, the I flag is 0x08. Then 24 reserved bits, the
  # 24-bit VNI and 8 reserved bits. The RFC says the R bits and reserved
  # fields "MUST be set to zero on transmission and ignored on receipt".
  #
  # Built four ways, as bgp4r's classes are:
  #
  #   Header.new(100)                                  # field value: the VNI
  #   Header.new(vni: 100, flags: 0x0c, reserved2: 1)  # a hash
  #   Header.new(octets)                               # wire bytes
  #   Header.new(other)                                # another instance
  #
  # A String is always wire bytes, since no field is a String. So vtep4r
  # needs no mark on packed strings, where bgp4r does.
  #
  # **Building is never validated.** Any flags, reserved bits and VNI go
  # out as asked: this library is for negative testing. Only a value that
  # cannot fit its field is refused, since sending another value in its
  # place would be silent. A header read from the wire keeps every bit
  # and encode gives back the same octets.
  class Header
    I_FLAG = 0x08
    SIZE = 8

    # Each field: its default, and the largest value it holds.
    FIELDS = { flags: [I_FLAG, 0xff], reserved1: [0, 0xffffff],
               vni: [0, 0xffffff], reserved2: [0, 0xff] }.freeze

    attr_reader :flags, :reserved1, :vni, :reserved2

    def initialize(arg)
      case arg
      when String then parse(arg)
      when Header then parse(arg.encode)
      when Integer then set(vni: arg)
      when Hash then set(**arg)
      else raise ArgumentError, "invalid argument, #{arg.inspect}"
      end
    end

    def i_flag?
      @flags & I_FLAG != 0
    end

    def encode
      [(@flags << 24) | @reserved1, (@vni << 8) | @reserved2].pack('NN')
    end

    def to_shex
      encode.unpack1('H*')
    end

    # The VNI, and each other field only when it is not its default, so an
    # ordinary header hashes as { vni: 100 }. Round trips through new.
    def to_hash
      h = { vni: @vni }
      FIELDS.each do |name, (default, _)|
        next if name == :vni

        value = instance_variable_get("@#{name}")
        h[name] = value unless value == default
      end
      h
    end

    # tcpdump's form for the kernel's header: "VXLAN, flags [I] (0x08), vni 100".
    def to_s
      format('VXLAN, flags [%s] (0x%02x), vni %d', i_flag? ? 'I' : '', @flags, @vni)
    end

    def ==(other)
      other.is_a?(Header) && encode == other.encode
    end
    alias eql? ==

    def hash
      encode.hash
    end

    private

    def parse(octets)
      raise ArgumentError, "a VXLAN header is #{SIZE} octets, got #{octets.bytesize}" if octets.bytesize < SIZE

      word1, word2 = octets.byteslice(0, SIZE).unpack('NN')
      @flags = word1 >> 24
      @reserved1 = word1 & 0xffffff
      @vni = word2 >> 8
      @reserved2 = word2 & 0xff
    end

    def set(**fields)
      unknown = fields.keys - FIELDS.keys
      raise ArgumentError, "unknown header field #{unknown.join(', ')}" unless unknown.empty?

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
