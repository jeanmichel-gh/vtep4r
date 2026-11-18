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
require 'json'
require 'net/http'

# exe/vtep4r-sim as a lab runs it, driven over HTTP as routescope
# drives bgp4r-sim. No root: it sends from 127.0.0.51.
class Sim_program_Test < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)

  def setup
    @dir = File.join(ENV['TMPDIR'] || '/tmp', "vtep4r-s#{Process.pid}-#{rand(1 << 16)}")
    FileUtils.mkdir_p(@dir)
    @port = 20_000 + rand(20_000)
    @file = File.join(@dir, 'sim.yml')
    File.write(@file, "local: 127.0.0.51\napi: 127.0.0.1:#{@port}\n")
    @log = File.join(@dir, 'log')
    @pid = spawn(RbConfig.ruby, File.join(ROOT, 'exe/vtep4r-sim'), '-f', @file, out: @log, err: @log)
    50.times do
      break if up?

      sleep 0.1
    end
  end

  def teardown
    Process.kill('TERM', @pid) rescue nil
    Process.wait(@pid) rescue nil
    FileUtils.rm_rf(@dir)
  end

  def up?
    Net::HTTP.get(URI("http://127.0.0.1:#{@port}/api/status"))
    true
  rescue SystemCallError
    false
  end

  def test_it_answers_and_sends
    assert up?, "vtep4r-sim did not start: #{File.read(@log)}"
    assert_equal '127.0.0.51', JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{@port}/api/status")))['local']
    r = Net::HTTP.post(URI("http://127.0.0.1:#{@port}/api/fault"), '{"to":"127.0.0.52","case":"no_i_flag","vni":7}',
                       'X-VTEP4R' => 'routescope', 'Content-Type' => 'application/json')
    assert_equal ['200', 'drop'], [r.code, JSON.parse(r.body)['expect']]
    Process.kill('TERM', @pid)
    _, status = Process.wait2(@pid)
    assert_equal 0, status.exitstatus
    assert_match(%r{API on http://127.0.0.1:#{@port}}, File.read(@log))
  end

  def test_a_vteps_key_in_its_file_stops_it
    bad = File.join(@dir, 'bad.yml')
    File.write(bad, "local: 127.0.0.51\nvnis: []\n")
    out = IO.popen([RbConfig.ruby, File.join(ROOT, 'exe/vtep4r-sim'), '-f', bad], err: %i[child out], &:read)
    assert_equal 1, $?.exitstatus
    assert_match(/\Avtep4r-sim: vnis: an injector keeps no MAC table/, out)
  end
end
