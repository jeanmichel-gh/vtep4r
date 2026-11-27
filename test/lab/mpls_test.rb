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
require 'json'
require 'fileutils'
require 'tmpdir'
require 'io/wait'
require 'rbconfig'

# EVPN over MPLS against the kernel's own label switching: the measured
# cases of bgp4r docs/design/evpn-mpls.md as tests, with vtep4rd, the real
# program, on both PEs. Five network namespaces:
#
#   vm4H1 --- vm4A ---------- vm4P ---------- vm4B --- vm4H2
#   host 1    pe1 vtep4rd     the kernel's    pe2 vtep4rd  host 2
#             10.255.0.1      label switching 10.255.0.2
#
# pe1 reaches pe2 by its node SID 16002, which P pops (PHP), and pe2
# reaches pe1 by 16001. pe1 gave 25000 and 25001, pe2 26000 and 26001;
# each is told the other's, as bgp4rd will, through vtep4r-cli. Neither
# PE's kernel takes MPLS input: what reaches them is vtep4rd's alone.
#
# Root and ip netns, else it omits itself; VTEP4R_LAB_REQUIRED makes
# that a failure, as kernel_test.rb.
class Mpls_Test < Test::Unit::TestCase
  ROOT = File.expand_path('../..', __dir__)
  RUBY = RbConfig.ruby
  NS = %w[vm4H1 vm4A vm4P vm4B vm4H2].freeze
  SOCK = { 'vm4A' => "/tmp/vm4A-#{Process.pid}.sock", 'vm4B' => "/tmp/vm4B-#{Process.pid}.sock" }.freeze

  def self.sh(*argv)
    system(*argv, out: File::NULL, err: File::NULL)
  end

  def self.usable?
    return @usable unless @usable.nil?

    @usable = Process.uid.zero? && sh('ip', 'netns', 'add', 'vm4probe') && sh('ip', 'netns', 'del', 'vm4probe') &&
              sh('modprobe', 'mpls_router') && sh('modprobe', 'mpls_iptunnel')
  end

  def self.env
    ENV['DATALINK_LIB'] ? { 'DATALINK_LIB' => ENV['DATALINK_LIB'] } : {}
  end

  def self.startup
    return unless usable?

    NS.each { |n| sh('ip', 'netns', 'del', n) }
    NS.each { |n| sh('ip', 'netns', 'add', n) }
    ip = ->(*a) { sh('ip', *a) or raise "ip #{a.join(' ')} failed" }
    sysctl = ->(ns, kv) { sh('ip', 'netns', 'exec', ns, 'sysctl', '-qw', kv) or raise "sysctl #{kv} failed" }
    { %w[h1 vm4H1 ah vm4A] => nil, %w[a0 vm4A p0 vm4P] => nil, %w[p1 vm4P b0 vm4B] => nil, %w[bh vm4B h2 vm4H2] => nil }.each_key do |a, an, b, bn|
      ip.('link', 'add', a, 'netns', an, 'type', 'veth', 'peer', 'name', b, 'netns', bn)
    end
    { 'vm4H1' => %w[h1 lo], 'vm4A' => %w[ah a0 lo], 'vm4P' => %w[p0 p1 lo], 'vm4B' => %w[b0 bh lo], 'vm4H2' => %w[h2 lo] }.each do |n, ls|
      ls.each { |l| ip.('-n', n, 'link', 'set', l, 'up') }
    end
    ip.('-n', 'vm4H1', 'link', 'set', 'h1', 'address', '02:00:00:00:01:01')
    ip.('-n', 'vm4H2', 'link', 'set', 'h2', 'address', '02:00:00:00:01:02')
    ip.('-n', 'vm4H1', 'addr', 'add', '172.16.100.1/24', 'dev', 'h1')
    ip.('-n', 'vm4H2', 'addr', 'add', '172.16.100.2/24', 'dev', 'h2')
    ip.('-n', 'vm4A', 'addr', 'add', '10.255.0.1/32', 'dev', 'lo')
    ip.('-n', 'vm4B', 'addr', 'add', '10.255.0.2/32', 'dev', 'lo')
    ip.('-n', 'vm4A', 'addr', 'add', '10.0.1.1/24', 'dev', 'a0')
    ip.('-n', 'vm4P', 'addr', 'add', '10.0.1.2/24', 'dev', 'p0')
    ip.('-n', 'vm4P', 'addr', 'add', '10.0.2.1/24', 'dev', 'p1')
    ip.('-n', 'vm4B', 'addr', 'add', '10.0.2.2/24', 'dev', 'b0')
    sysctl.('vm4P', 'net.mpls.platform_labels=100000')
    sysctl.('vm4P', 'net.mpls.conf.p0.input=1')
    sysctl.('vm4P', 'net.mpls.conf.p1.input=1')
    ip.('-n', 'vm4P', '-f', 'mpls', 'route', 'add', '16002', 'via', 'inet', '10.0.2.2', 'dev', 'p1')
    ip.('-n', 'vm4P', '-f', 'mpls', 'route', 'add', '16001', 'via', 'inet', '10.0.1.1', 'dev', 'p0')
    ip.('-n', 'vm4A', 'route', 'add', '10.255.0.2/32', 'encap', 'mpls', '16002', 'via', '10.0.1.2', 'dev', 'a0')
    ip.('-n', 'vm4B', 'route', 'add', '10.255.0.1/32', 'encap', 'mpls', '16001', 'via', '10.0.2.1', 'dev', 'b0')
    # The gateways' MACs: in a lab the IGP's and BGP's own traffic fills
    # these; here one ping each.
    sh('ip', 'netns', 'exec', 'vm4A', 'ping', '-c1', '-W1', '10.0.1.2')
    sh('ip', 'netns', 'exec', 'vm4B', 'ping', '-c1', '-W1', '10.0.2.1')

    @dir = File.join(ENV['TMPDIR'] || '/tmp', "vm4lab-#{Process.pid}")
    FileUtils.mkdir_p(@dir)
    @pids = { 'vm4A' => ['10.255.0.1', 'ah', 'a0', 25_000], 'vm4B' => ['10.255.0.2', 'bh', 'b0', 26_000] }.map do |ns, (local, port, core, label)|
      file = File.join(@dir, "#{ns}.yml")
      File.write(file, "local: #{local}\nsocket: #{SOCK[ns]}\ncore: [#{core}]\nvnis:\n  - vni: 100\n    ports: [#{port}]\n" \
                       "    mode: evpn\n    encap: mpls\n    labels: { unicast: #{label}, bum: #{label + 1} }\n")
      log = File.join(@dir, "#{ns}.log")
      spawn(env, 'ip', 'netns', 'exec', ns, RUBY, File.join(ROOT, 'exe', 'vtep4rd'), '-f', file, out: log, err: log)
    end
    50.times { SOCK.values.all? { |s| File.socket?(s) } ? break : sleep(0.1) }
  end

  def self.shutdown
    return unless usable?

    Array(@pids).each { |p| Process.kill('TERM', p) rescue nil }
    Array(@pids).each { |p| Process.wait(p) rescue nil }
    NS.each { |n| sh('ip', 'netns', 'del', n) }
    FileUtils.rm_rf(@dir) if @dir
  end

  def setup
    unless self.class.usable?
      flunk('VTEP4R_LAB_REQUIRED is set, and the lab tier needs root, ip netns and the mpls modules') if ENV['VTEP4R_LAB_REQUIRED']
      omit('the lab tier needs root, ip netns and the mpls modules')
    end
    # What bgp4rd would set from each other's type 3 and type 2 routes.
    cli('vm4A', 'vni.flood.add', 'vni=100', 'vtep=10.255.0.2', 'label=26001')
    cli('vm4B', 'vni.flood.add', 'vni=100', 'vtep=10.255.0.1', 'label=25001')
    cli('vm4A', 'mac.add', 'vni=100', 'mac=02:00:00:00:01:02', 'vtep=10.255.0.2', 'label=26000')
    cli('vm4B', 'mac.add', 'vni=100', 'mac=02:00:00:00:01:01', 'vtep=10.255.0.1', 'label=25000')
  end

  def cli(ns, *args)
    JSON.parse(IO.popen(self.class.env, [RUBY, File.join(ROOT, 'exe/vtep4r-cli'), '-s', SOCK.fetch(ns), *args], &:read))
  end

  def in_ns(ns, *argv)
    IO.popen(['ip', 'netns', 'exec', ns, *argv], err: %i[child out], &:read)
  end

  def ping(ns, to)
    system('ip', 'netns', 'exec', ns, 'ping', '-c1', '-W2', to, out: File::NULL, err: File::NULL)
  end

  def wait_for(seconds = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until (v = yield)
      flunk('not within the deadline') if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.1
    end
    v
  end

  # The frames tcpdump wrote in +ns+ on +dev+ while the block ran, as
  # octets, from a classic pcap file. The block runs once tcpdump says it
  # is listening: a fixed wait missed one-off frames on a loaded VM.
  def capture(ns, dev, filter = 'mpls')
    pcap = File.join(Dir.tmpdir, "vm4-#{Process.pid}-#{rand(1 << 20)}.pcap")
    r, w = IO.pipe
    pid = spawn('ip', 'netns', 'exec', ns, 'tcpdump', '-U', '-i', dev, '-w', pcap, filter, out: File::NULL, err: w)
    w.close
    ready = r.wait_readable(10) && r.gets
    flunk("tcpdump in #{ns} on #{dev} did not start") unless ready&.include?('listening on')
    yield
    # tcpdump stopped too soon counts a frame "received by filter" and
    # never writes it, on a loaded VM: wait for the file to grow first.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.1 until File.size?(pcap).to_i > 24 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.5
    Process.kill('INT', pid)
    Process.wait(pid)
    r.close
    data = File.binread(pcap)
    frames = []
    at = 24
    while at + 16 <= data.bytesize
      len = data.byteslice(at + 8, 4).unpack1('V')
      frames << data.byteslice(at + 16, len)
      at += 16 + len
    end
    frames
  ensure
    File.delete(pcap) if pcap && File.exist?(pcap)
  end

  def test_both_pes_resolve_the_other
    a = wait_for { (r = cli('vm4A', 'show.transport')).any? { |h| h['error'].nil? } && r }
    assert_equal [{ 'pe' => '10.255.0.2', 'labels' => [16_002], 'gateway' => '10.0.1.2', 'dev' => 'a0', 'mtu' => 1500, 'error' => nil }],
                 a.map { |h| h.slice('pe', 'labels', 'gateway', 'dev', 'mtu', 'error') }
    assert_equal in_ns('vm4P', 'cat', '/sys/class/net/p0/address').strip, a[0]['mac']
  end

  def test_pings_cross_both_ways
    wait_for { cli('vm4A', 'show.transport').any? { |h| h['error'].nil? } }
    wait_for { cli('vm4B', 'show.transport').any? { |h| h['error'].nil? } }
    assert wait_for(8) { ping('vm4H1', '172.16.100.2') }
    assert ping('vm4H2', '172.16.100.1')
  end

  # The spec's gate: on P's link from pe1, pe2's node SID, the EVPN label,
  # the control word and h1's frame.
  def test_what_p_sees
    wait_for(8) { ping('vm4H1', '172.16.100.2') }
    frames = capture('vm4P', 'p0') { ping('vm4H1', '172.16.100.2') }
    stacks = frames.map { |f| f.byteslice(14, 12).unpack('NNN') }
    request = frames.zip(stacks).find { |f, s| s[0] >> 12 == 16_002 && s[1] >> 12 == 26_000 && f.byteslice(26, 6) == ["020000000102"].pack('H*') }
    assert_not_nil request, "frames seen: #{stacks.map { |s| s.map { |w| w >> 12 } }.inspect}"
    f, s = request
    assert_equal [0, 1], [(s[0] >> 8) & 1, (s[1] >> 8) & 1], 'S on the EVPN label only'
    assert_equal 0, s[2], 'the control word, four zero octets'
    assert_equal ['020000000102', '020000000101'], [f.byteslice(26, 6), f.byteslice(32, 6)].map { |m| m.unpack1('H*') }
  end

  # RFC 7432 section 18's case: a frame whose destination MAC starts with
  # 4, as an IPv4 header does, crosses intact.
  def test_a_mac_starting_with_4_crosses_intact
    wait_for(8) { ping('vm4H1', '172.16.100.2') }
    frame = %w[460000000102 020000000101 88b5].join + ('ab' * 46)
    got = capture('vm4H2', 'h2', 'ether dst 46:00:00:00:01:02') do
      in_ns('vm4H1', 'python3', '-c', "import socket;s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW);s.bind(('h1',0));" \
                                      "s.send(bytes.fromhex('#{frame}'))")
    end
    assert_equal [frame], got.map { |g| g.unpack1('H*') }
  end

  # RFC 4182 section 2: P swaps pe2's node SID for an IPv4 explicit null
  # instead of popping it, and pe2 still takes the frame.
  def test_an_explicit_null_from_p
    wait_for(8) { ping('vm4H1', '172.16.100.2') }
    in_ns('vm4P', 'ip', '-f', 'mpls', 'route', 'change', '16002', 'as', '0', 'via', 'inet', '10.0.2.2', 'dev', 'p1')
    frames = capture('vm4B', 'b0') { ping('vm4H1', '172.16.100.2') }
    assert frames.any? { |f| f.byteslice(14, 4).unpack1('N') >> 12 == 0 }, 'the null is on the wire'
    assert ping('vm4H1', '172.16.100.2')
  ensure
    in_ns('vm4P', 'ip', '-f', 'mpls', 'route', 'change', '16002', 'via', 'inet', '10.0.2.2', 'dev', 'p1')
  end

  # The resolution's timing: a new label on pe1's route to pe2 is used
  # within a second and a little, the time `ip` takes.
  def test_a_new_transport_label_is_used_within_the_resolution_period
    wait_for(8) { ping('vm4H1', '172.16.100.2') }
    in_ns('vm4P', 'ip', '-f', 'mpls', 'route', 'add', '16012', 'via', 'inet', '10.0.2.2', 'dev', 'p1')
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    in_ns('vm4A', 'ip', 'route', 'change', '10.255.0.2/32', 'encap', 'mpls', '16012', 'via', '10.0.1.2', 'dev', 'a0')
    wait_for(3) { cli('vm4A', 'show.transport')[0]['labels'] == [16_012] }
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    puts format("\n  the new label in show.transport after %.2f s", took)
    assert_operator took, :<, 2.0
    assert ping('vm4H1', '172.16.100.2')
  ensure
    in_ns('vm4A', 'ip', 'route', 'change', '10.255.0.2/32', 'encap', 'mpls', '16002', 'via', '10.0.1.2', 'dev', 'a0')
    in_ns('vm4P', 'ip', '-f', 'mpls', 'route', 'del', '16012')
  end

  # pe2's kernel takes no MPLS input and drops these frames; vtep4rd has
  # its copy all the same (the spec's measurement).
  def test_the_pes_kernel_drops_what_vtep4rd_takes
    wait_for(8) { ping('vm4H1', '172.16.100.2') }
    assert_equal '0', in_ns('vm4B', 'sysctl', '-n', 'net.mpls.conf.b0.input').strip
    assert_operator cli('vm4B', 'show.counters')['core']['b0']['rx'], :>, 0
  end
end
