# vtep4r

VXLAN in Ruby (RFC 7348): a library to build, parse and send VXLAN,
valid or not, for routing labs and protocol tests. A VTEP and an
injector will be built on it. `docs/design/vtep4r.md` is the plan.

Today it has the header and the packet:

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
```

Tests: `ruby test/run_unit.rb` under Bundler, or with `DATALINK_LIB`
set to a datalink-socket checkout's `lib/`. CLAUDE.md has the details.

GPL 3 or later, for now. See LICENSE.txt.
