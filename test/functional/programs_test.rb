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

require 'test/unit'
require 'fileutils'
require 'rbconfig'

# The two programs as a person runs them: exe/vtep4rd from a file, and
# exe/vtep4r-cli against its socket. A vtep4rd with no ports opens no
# raw socket, and port 4789 on 127.0.0.31 needs no root.
class Programs_Test < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @dir = File.join(ENV['TMPDIR'] || '/tmp', "vtep4r-p#{Process.pid}-#{rand(1 << 16)}")
    FileUtils.mkdir_p(@dir)
    @sock = File.join(@dir, 'v.sock')
    @file = File.join(@dir, 'vtep4rd.yml')
    File.write(@file, "local: 127.0.0.31\nsocket: #{@sock}\nvnis:\n  - vni: 100\n    ports: []\n    flood: [127.0.0.32]\n")
    @log = File.join(@dir, 'log')
    @pid = spawn(RbConfig.ruby, File.join(ROOT, 'exe/vtep4rd'), '-f', @file, out: @log, err: @log)
    50.times { File.socket?(@sock) ? break : sleep(0.1) }
  end

  def teardown
    Process.kill('TERM', @pid) rescue nil
    Process.wait(@pid) rescue nil
    FileUtils.rm_rf(@dir)
  end

  def cli(*args)
    IO.popen([RbConfig.ruby, File.join(ROOT, 'exe/vtep4r-cli'), '-s', @sock, *args], err: %i[child out], &:read)
  end

  def test_the_cli_reads_the_daemon
    assert File.socket?(@sock), "vtep4rd did not start: #{File.read(@log)}"
    assert_match(/"api":1/, cli('api.info'))
    assert_match(/"remote_vteps":\["127.0.0.32"\]/, cli('show.vnis'))
    assert_match(/"changed":true/, cli('vni.flood.add', 'vni=100', 'vtep=127.0.0.33'))
    assert_match(/unknown method "show.nope"/, cli('show.nope'))
  end

  def test_term_stops_it_and_removes_the_socket
    assert File.socket?(@sock), "vtep4rd did not start: #{File.read(@log)}"
    Process.kill('TERM', @pid)
    _, status = Process.wait2(@pid)
    assert_equal 0, status.exitstatus
    refute File.exist?(@sock)
    assert_match(/vtep4rd answers on .*v.sock/, File.read(@log))
  end
end
