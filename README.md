# vtep4r

VXLAN in Ruby (RFC 7348): a library to build, parse and send VXLAN,
valid or not, for routing labs and protocol tests. Two programs are
built on it: a VTEP, `vtep4rd`, and an injector, `vtep4r-sim`.
`docs/design/vtep4r.md` is the plan.

## vtep4rd

```sh
vtep4rd -f vtep4rd.yml                       # needs CAP_NET_RAW for its ports
vtep4r-cli show.vnis                         # each VNI, its ports and flood list
vtep4r-cli show.macs vni=100                 # a VNI's MAC table
vtep4r-cli show.counters                     # frames per port and peer, drops
vtep4r-cli mac.add vni=100 mac=02:00:00:00:01:09 vtep=10.255.0.13
vtep4r-cli vni.add vni=200 ports='["eth3"]'  # a VNI at run time
vtep4r-cli config.reload                     # the file again; SIGHUP does the same
vtep4r-cli vni.labels vni=200 unicast=25000 bum=25001   # an MPLS VNI's two labels
vtep4r-cli mac.add vni=200 mac=02:00:00:00:02:02 vtep=10.255.0.12 label=26000
vtep4r-cli show.labels                       # the MPLS labels given out
vtep4r-cli events.subscribe kinds=mac        # MACs learned, moved and aged, as they happen
```

```yaml
local: 10.255.0.11
vnis:
  - vni: 100
    ports: [eth2]
    flood: [10.255.0.12]
  - vni: 200                 # EVPN over MPLS (docs/mpls.md)
    ports: [eth3]
    mode: evpn
    encap: mpls
    labels: { unicast: 25000, bum: 25001 }
```

An MPLS VNI's frames for a remote PE are dropped (`no_mpls_edge`) until
its edge is built.

## vtep4r-sim

An injector: crafted packets and generated traffic, over HTTP on the
loopback, as bgp4r-sim. It keeps no MAC table, and it never binds the
VXLAN port, so it runs beside a vtep4rd.

```sh
vtep4r-sim -f sim.yml                        # local: 10.255.0.11
post() { ruby -rnet/http -e 'r = Net::HTTP.post(URI("http://127.0.0.1:8080#{ARGV[0]}"), ARGV[1], "X-VTEP4R" => "routescope"); puts r.body' "$@"; }
post /api/fault '{"to":"10.255.0.12","case":"r_bit_set","vni":100}'
post /api/generate '{"to":"10.255.0.12","spec":{"vni":100,"macs":1000},"per_second":500}'
post /api/stop '{}'
```

## The library

The header and the packet:

```ruby
require 'vtep4r'

h = VXLAN::Header.new(100)
h.to_shex                       #=> "0800000000006400"
h.to_s                          #=> "VXLAN, flags [I] (0x08), vni 100"

# Any flags and reserved bits, for testing a receiver.
VXLAN::Header.new(vni: 100, flags: 0x0c, reserved2: 1).to_shex
#=> "0c00000000006401"

pk = VXLAN::Packet.new(octets)  # a UDP payload from port 4789
pk.header.vni                   #=> 100
pk.frame                        #=> a Datalink::Frame, or nil
pk.to_hash                      #=> { header: { vni: 100 }, inner: "ffff..." }
VXLAN::Packet.new(pk.to_hash).encode == octets   #=> true

# What a received packet got wrong, with the RFC section.
pk.errors                       #=> [] or [#<Finding name=:no_i_flag ...>]
VXLAN::Validation.decide(pk, policy: :rfc)       #=> :deliver or :drop

# Crafted packets, and what RFC 7348 expects of a receiver.
VXLAN::Fault.names              #=> [:no_i_flag, :r_bit_set, ...]
VXLAN::Fault.wire(:r_bit_set, vni: 100)          # octets to send

# Generated traffic: a spec in plain JSON types, the same octets every run.
g = VXLAN::Gen.new('vni' => { 'cycle' => [100, 200] }, 'macs' => 1000)
g.each { |pk| socket.send(pk.encode, 0, vtep, 4789) }
g.expected                      #=> [{ vni: 100, src: "02:00:00:00:00:01", dst: "ff:ff:ff:ff:ff:ff" }, ...]
```

EVPN over MPLS, what follows EtherType 0x8847 (`docs/mpls.md`):

```ruby
include VXLAN::Mpls

l = Label.new(label: 25001, s: 1)
l.to_shex                       #=> "061a9140"
l.to_s                          #=> "(label 25001, tc 0, [S], ttl 64)", tcpdump's form

pk = Packet.new([16002, 25001], ControlWord.new, frame)  # S bit on the last
pk.to_shex                      #=> "03e82040061a914000000000..."
Packet.new(octets)              # a control word expected after the bottom label
Packet.new(octets, control_word: false)

pk.errors                       #=> [] or [#<Finding name=:no_bottom ...>]
Fault.names                     #=> [:no_bottom, :no_control_word, :control_word_nibble, ...]
Fault.wire(:ipv4_explicit_null, label: 25001)    # octets to send
```

Tests: `ruby test/run_unit.rb` under Bundler, or with `DATALINK_LIB`
set to a datalink-socket checkout's `lib/`. The lab tier,
`test/lab/`, runs the programs against the kernel's VXLAN and needs
root. CLAUDE.md has the details.

**`docs/fault-matrix.md`** says what vtep4rd and the Linux kernel (and
so FRR) do with each crafted packet, against RFC 7348. On Linux 7.0 the
kernel drops packets whose reserved bits are set, where the RFC says to
ignore them; vtep4rd ignores them.

The image: `docker build -t vtep4r:latest --build-context
datalink-socket=../datalink-socket .`

GPL 3 or later, for now. See LICENSE.txt.
