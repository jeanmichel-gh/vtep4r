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
require 'stringio'
require 'vxlan/daemon/cli'

class Cli_Test < Test::Unit::TestCase
  CLI = VXLAN::Daemon::CLI

  class FakeClient
    attr_reader :calls

    def initialize(result = { 'ok' => true }, error: nil)
      @result = result
      @error = error
      @calls = []
    end

    def call(method, params)
      @calls << [method, params]
      raise VXLAN::Daemon::Client::Error, @error if @error

      @result
    end

    def close; end
  end

  def run_cli(argv, client = FakeClient.new)
    out = StringIO.new
    err = StringIO.new
    status = CLI.new(out, err, client).start(argv, {})
    [status, out.string, err.string, client]
  end

  def test_params_as_key_value
    assert_equal({ 'vni' => 100, 'vtep' => '10.0.0.2' }, CLI.params(%w[vni=100 vtep=10.0.0.2]))
    assert_equal({ 'mac' => '02:00:00:00:01:09' }, CLI.params(%w[mac=02:00:00:00:01:09]))
  end

  def test_params_as_json
    assert_equal({ 'vni' => 100, 'origin' => 'api' }, CLI.params(['{"vni":100,', '"origin":"api"}']))
  end

  def test_bad_params
    assert_raise(ArgumentError) { CLI.params(%w[vni]) }
    assert_raise(JSON::ParserError) { CLI.params(['{"vni":']) }
  end

  def test_a_method_call_prints_json
    status, out, _, client = run_cli(%w[show.macs vni=100])
    assert_equal 0, status
    assert_equal %({"ok":true}\n), out
    assert_equal [['show.macs', { 'vni' => 100 }]], client.calls
  end

  def test_pretty
    _, out, = run_cli(%w[--pretty api.info])
    assert_equal %({\n  "ok": true\n}\n), out
  end

  def test_the_daemons_error_is_printed_and_the_status_is_one
    status, _, err, = run_cli(%w[show.foo], FakeClient.new(error: 'unknown method "show.foo"'))
    assert_equal 1, status
    assert_equal %(vtep4r-cli: unknown method "show.foo"\n), err
  end

  def test_no_method_is_usage
    status, _, err, = run_cli([])
    assert_equal 1, status
    assert_match(/Usage: vtep4r-cli/, err)
  end

  def test_help_and_version
    assert_equal 0, run_cli(%w[-h])[0]
    assert_equal "#{VXLAN::VERSION}\n", run_cli(%w[-v])[1]
  end

  def test_a_value_in_json
    assert_equal({ 'ports' => %w[eth3], 'vni' => 200 }, CLI.params(['ports=["eth3"]', 'vni=200']))
  end

  class FakeStream < FakeClient
    def stream(method, params)
      @calls << [method, params]
      yield({ 'id' => 1, 'result' => { 'seq' => 4 } })
      yield({ 'event' => { 'kind' => 'mac' } })
      yield({ 'id' => 2, 'error' => 'show.vnis refused' })
    end

    def unsubscribe; end
  end

  def test_events_subscribe_prints_each_line_and_stops_on_an_error
    status, out, err, client = run_cli(%w[events.subscribe kinds=mac], FakeStream.new)
    assert_equal [['events.subscribe', { 'kinds' => 'mac' }]], client.calls
    assert_equal %({"id":1,"result":{"seq":4}}\n{"event":{"kind":"mac"}}\n), out
    assert_equal 1, status
    assert_match(/show.vnis refused/, err)
  end
end
