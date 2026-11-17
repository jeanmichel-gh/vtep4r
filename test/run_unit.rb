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

# Runs every unit test under test/unit, at any depth. The same command
# works on a laptop, in Docker and in CI:
#
#   ruby test/run_unit.rb
#
# It sets the load path and working directory itself, so no -I. is
# needed. datalink-socket comes from the gem, or from DATALINK_LIB, a
# checkout's lib/ directory, when it is not installed.

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
$LOAD_PATH.unshift(ENV['DATALINK_LIB']) if ENV['DATALINK_LIB']
Dir.chdir(root)

require 'test/unit'
Dir['test/unit/**/*_test.rb'].sort.each { |f| require "./#{f}" }
