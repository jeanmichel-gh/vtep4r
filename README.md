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
vtep4r-cli events.subscribe kinds=mac        # MACs learned, moved and aged, as they happen
```

```yaml
local: 10.255.0.11
vnis:
  - vni: 100
    ports: [eth2]
    flood: [10.255.0.12]
```

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

Tests: `ruby test/run_unit.rb` under Bundler, or with `DATALINK_LIB`
set to a datalink-socket checkout's `lib/`. CLAUDE.md has the details.

GPL 3 or later, for now. See LICENSE.txt.
