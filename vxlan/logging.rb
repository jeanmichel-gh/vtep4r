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

require 'logger'

module VXLAN
  # Where one object writes its log lines, as bgp4r's BGP::Logging.
  #
  # A logger is a plain callable, ->(level, message), with level one of
  # LEVELS. An object that has one calls it; one that has none falls back
  # to Logging.default, which writes to standard error. So two VTEPs in
  # one process log apart when each is handed its own.
  module Logging
    LEVELS = %i[debug info warn error fatal].freeze

    class << self
      attr_writer :default

      # Standard error at info, until a program sets another.
      def default
        @default ||= begin
          out = Logger.new($stderr, level: :info)
          ->(level, message) { out.add(Logger.const_get(level.to_s.upcase), message) }
        end
      end

      # A callable that writes to +io+, one line per message, from +level+
      # up. "-" is standard output.
      def to_io(io, level: :info)
        out = Logger.new(io == '-' ? $stdout : io, level: level)
        ->(lvl, message) { out.add(Logger.const_get(lvl.to_s.upcase), message) }
      end
    end

    attr_writer :logger

    def logger
      @logger || Logging.default
    end

    def log(level, message)
      raise ArgumentError, "log level #{level.inspect}: one of #{LEVELS.join(', ')}" unless LEVELS.include?(level)

      logger.call(level, message)
    end
  end
end
