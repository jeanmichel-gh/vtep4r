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

require 'test/unit'
require 'vxlan/sim/http'
require 'vxlan/sim/config'

# The HTTP rules through #handle, with no socket.
class Http_Test < Test::Unit::TestCase
  include VXLAN

  class Recorder
    def send(*); end
  end

  def setup
    inj = Sim::Injector.new(Sim::Config.new('local' => '10.255.0.11'), sender: Recorder.new)
    @http = Sim::Http.new(inj)
  end

  POST = { 'x-vtep4r' => 'routescope' }.freeze

  def test_index
    s, a = @http.handle('GET', '/')
    assert_equal 200, s
    assert_equal 'X-VTEP4R: routescope', a[:post_header]
    assert_equal({ '/api/fault' => 'fault', '/api/generate' => 'generate', '/api/send' => 'send', '/api/stop' => 'stop' },
                 a[:actions])
  end

  def test_reads
    assert_equal 200, @http.handle('GET', '/api/status')[0]
    s, a = @http.handle('GET', '/api/events?since=0')
    assert_equal [200, 0], [s, a[:seq]]
  end

  def test_a_post_needs_the_header
    s, a = @http.handle('POST', '/api/fault', {}, '{}')
    assert_equal 403, s
    assert_match(/X-VTEP4R: routescope/, a[:error])
  end

  def test_an_action
    s, a = @http.handle('POST', '/api/fault', POST, '{"to":"10.255.0.12","case":"no_i_flag","vni":100}')
    assert_equal [200, :no_i_flag], [s, a[:case]]
  end

  def test_wrong_method_and_path
    assert_equal 405, @http.handle('POST', '/api/status', POST)[0]
    assert_equal 405, @http.handle('GET', '/api/send')[0]
    s, a = @http.handle('GET', '/api/nope')
    assert_equal 404, s
    assert_match(%r{/api/fault, /api/generate}, a[:error])
  end

  def test_a_bad_body_is_400
    assert_equal 400, @http.handle('POST', '/api/send', POST, 'not json')[0]
    assert_equal 400, @http.handle('POST', '/api/send', POST, '[1]')[0]
    assert_equal 400, @http.handle('POST', '/api/send', POST, '{"to":"10.0.0.1"}')[0]
  end

  def test_a_running_generation_is_409
    gate = Queue.new
    inj = Sim::Injector.new(Sim::Config.new('local' => '10.255.0.11'), sender: Recorder.new, sleeper: ->(_) { gate.pop })
    http = Sim::Http.new(inj)
    body = '{"to":"10.0.0.2","spec":{"vni":1,"macs":5},"per_second":1}'
    assert_equal 200, http.handle('POST', '/api/generate', POST, body)[0]
    assert_equal 409, http.handle('POST', '/api/generate', POST, body)[0]
    t = Thread.new { http.handle('POST', '/api/stop', POST, '') }
    5.times { gate.push(1) }
    assert_equal 200, t.value[0]
  end

  def test_plan
    s, a = @http.handle('POST', '/api/plan', POST, '{"spec":{"vni":7,"macs":2}}')
    assert_equal [200, 2], [s, a[:total]]
  end

  def test_address
    assert_equal({ bind: '127.0.0.1', port: 8080 }, Sim::Http.address('127.0.0.1:8080'))
    assert_equal({ bind: '127.0.0.1', port: 9000 }, Sim::Http.address('9000'))
    assert_equal({ bind: '::1', port: 8080 }, Sim::Http.address('[::1]:8080'))
    assert_raise(ArgumentError) { Sim::Http.address('x') }
  end
end
