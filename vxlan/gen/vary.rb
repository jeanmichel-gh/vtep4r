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
  class Gen
    # A spec Gen cannot read: an unknown key, a value of the wrong type, a
    # value that cannot fit its field. Never a value that is only odd.
    class SpecError < ArgumentError; end

    # Integer patterns, after bgp4r's bgp/gen/vary.rb. A pattern is a
    # function of the item's number and the seed, and of nothing else.
    #
    #   5 or fixed: 5           the same value every time
    #   cycle: [a, b, c]        walk the list and start again
    #   step: {start, by, wrap} add by each item, back to start at wrap
    #   random: {min, max}      a value in the range, from the spec's seed
    #   every: {n, values}      the next value every n items
    #
    # **Random is a fresh generator per value per item**, seeded with
    # FNV-1a 64 of the seed, the value's name and the item's number, as
    # bgp4r's is. So a random VNI does not move when a random flag is
    # added beside it, and the same seed gives the same octets on every
    # Ruby.
    module Vary
      PATTERNS = %w[fixed cycle step random every].freeze

      Fixed = Struct.new(:value) do
        def at(_i) = value
      end
      Cycle = Struct.new(:values) do
        def at(i) = values[i % values.size]
      end
      Every = Struct.new(:n, :values) do
        def at(i) = values[(i / n) % values.size]
      end
      Step = Struct.new(:start, :by, :wrap) do
        def at(i)
          return start + (by * i) unless wrap

          span = ((wrap - start).to_f / by).ceil
          start + (by * (i % span))
        end
      end
      Rand = Struct.new(:min, :max, :seed, :name) do
        def at(i) = Vary.rng(seed, name, i).rand(min..max)
      end

      module_function

      # +v+ the spec's value; +name+ for refusals and as the random salt;
      # +max+ the field's largest value; +seed+ the spec's seed.
      def compile(v, name, max:, seed: nil)
        return Fixed.new(int(v, name, max)) unless v.is_a?(Hash)

        v = v.transform_keys(&:to_s)
        raise SpecError, "#{name}: one pattern of #{PATTERNS.join(', ')}, got #{v.keys.join(', ')}" unless v.size == 1 && PATTERNS.include?(v.keys[0])

        key, arg = v.first
        case key
        when 'fixed' then Fixed.new(int(arg, name, max))
        when 'cycle' then Cycle.new(list(arg, "#{name}.cycle", max))
        when 'every'
          a = hash(arg, "#{name}.every")
          Every.new(positive(a['n'], "#{name}.every.n"), list(a['values'], "#{name}.every.values", max))
        when 'step'
          a = hash(arg, "#{name}.step")
          start = int(a['start'], "#{name}.step.start", max)
          wrap = a['wrap'] && int(a['wrap'], "#{name}.step.wrap", max + 1)
          raise SpecError, "#{name}.step.wrap is not above start" if wrap && wrap <= start

          Step.new(start, positive(a.fetch('by', 1), "#{name}.step.by"), wrap)
        when 'random'
          a = hash(arg, "#{name}.random")
          raise SpecError, "#{name}: random needs the spec's seed" if seed.nil?

          min = int(a['min'], "#{name}.random.min", max)
          hi = int(a['max'], "#{name}.random.max", max)
          raise SpecError, "#{name}: random.min is above random.max" if min > hi

          Rand.new(min, hi, seed, name)
        end
      end

      def fnv(s)
        h = 0xcbf29ce484222325
        s.each_byte { |b| h = ((h ^ b) * 0x100000001b3) & 0xffffffffffffffff }
        h
      end

      def rng(seed, name, i)
        Random.new(fnv("#{seed}:#{name}:#{i}"))
      end

      def int(v, name, max)
        raise SpecError, "#{name}: #{v.inspect} is not an integer" unless v.is_a?(Integer)
        raise SpecError, "#{name}: #{v} does not fit (0 to 0x#{max.to_s(16)})" unless v.between?(0, max)

        v
      end

      def positive(v, name)
        raise SpecError, "#{name}: #{v.inspect} is not a positive integer" unless v.is_a?(Integer) && v.positive?

        v
      end

      def list(v, name, max)
        raise SpecError, "#{name}: a non-empty list" unless v.is_a?(Array) && !v.empty?

        v.each_with_index.map { |x, k| int(x, "#{name}[#{k}]", max) }
      end

      def hash(v, name)
        raise SpecError, "#{name}: a mapping" unless v.is_a?(Hash)

        v.transform_keys(&:to_s)
      end
    end
  end
end
