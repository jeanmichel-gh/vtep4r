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

root = File.expand_path('../..', __dir__)
$LOAD_PATH.unshift(root) unless $LOAD_PATH.include?(root)
$LOAD_PATH.unshift(ENV['DATALINK_LIB']) if ENV['DATALINK_LIB']

require 'test/unit'
require 'fileutils'
require 'vtep4r'
require 'vxlan/daemon/vtepd'
require 'vxlan/daemon/api'
require 'vxlan/daemon/client'

# The API over a real Unix socket: the envelope, bad lines, a second
# daemon on the same path, and a socket a dead daemon left behind.
class Api_socket_Test < Test::Unit::TestCase
  include VXLAN

  def setup
    @dir = File.join(ENV['TMPDIR'] || '/tmp', "vtep4r-t#{Process.pid}-#{rand(1 << 16)}")
    @path = File.join(@dir, 'v.sock')
    config = Daemon::Config.new('local' => '10.255.0.11', 'vnis' => [{ 'vni' => 100, 'ports' => [] }])
    @vtepd = Daemon::Vtepd.new(config, ports: Vtep::Ports.new({}),
                                       tunnel: Vtep::MemoryTunnel.new('10.255.0.11', Vtep::MemoryTunnel::Fabric.new),
                                       logger: ->(*) {}, age_every: nil).start
    @api = Daemon::Api.new(@vtepd, path: @path).start
  end

  def teardown
    @api.stop
    @vtepd.stop
    FileUtils.rm_rf(@dir)
  end

  def test_a_client_calls_two_methods_on_one_connection
    c = Daemon::Client.new(@path)
    assert_equal 1, c.call('api.info')['api']
    assert_equal [100], c.call('show.status')['vnis']
  ensure
    c&.close
  end

  def test_the_socket_is_born_0660
    assert_equal 0o660, File.stat(@path).mode & 0o777
  end

  # The exact line routescope's one-line client writes and reads.
  def test_bad_lines_are_answered_and_the_connection_goes_on
    s = UNIXSocket.new(@path)
    s.write("not json\n")
    assert_match(/\A\{"error":"bad JSON/, s.gets)
    s.write("[1,2]\n")
    assert_equal %({"error":"a request is a JSON object"}\n), s.gets
    s.write(%({"id":3,"method":"show.status","params":{}}\n))
    r = JSON.parse(s.gets)
    assert_equal 3, r['id']
    assert_equal '10.255.0.11', r['result']['local']
  ensure
    s&.close
  end

  def test_a_second_daemon_on_the_same_path_is_refused
    assert_raise(Daemon::Api::InUse) { Daemon::Api.new(@vtepd, path: @path).start }
  end

  def test_a_socket_left_by_a_dead_daemon_is_replaced
    @api.stop
    UNIXServer.new(@path) # a socket file nothing answers on once closed
               .close
    @api = Daemon::Api.new(@vtepd, path: @path).start
    assert_equal 1, Daemon::Client.new(@path).call('api.info')['api']
  end
end
