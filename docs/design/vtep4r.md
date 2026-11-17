# vtep4r, VXLAN in Ruby

Status: draft, 2026-11-17. Waiting for the owner's approval.

The lab plan, with the trials behind this design, is routescope
`docs/design/evpn-vxlan-lab.md`. This document is vtep4r's part of it.
vtep4r follows bgp4r's principles (CLAUDE.md), so where this document
says "as bgp4r", bgp4r's CLAUDE.md and docs are the detail.

## What it must do

- Build, parse and send VXLAN packets, valid or not.
- Run a VTEP: bridge host ports to VXLAN tunnels, one bridge domain per
  VNI, learning MACs from the data plane or taking them from bgp4rd's
  EVPN.
- Inject crafted packets and generated traffic, from a separate
  program.
- Show its state to routescope and to a shell.
- Record what other implementations do with each fault.

## What exists

Measured on ospflab, 2026-11-17, kernel 7.0.0-43:

- **A trial VTEP worked.** A 40-line Ruby trial on datalink-socket,
  with a stdlib `UDPSocket`, talked VXLAN to the kernel's `vxlan100`.
  h1 pinged h2: 5 of 5, 1.1 ms average.
- **The trial forwarded its own frames.** datalink-socket's Linux
  backend reads `ETH_P_ALL` and drops `recvfrom`'s address, so the
  trial could not tell a frame it received from one its namespace sent.
  datalink-socket must fix this first.
- **The kernel's answers to five headers**, one packet each:

  | Header | Kernel 7.0 |
  | --- | --- |
  | flags 0x08 (I), VNI 100 | delivered |
  | flags 0x00 | dropped |
  | VNI 200, not configured | dropped |
  | flags 0x08, first reserved octet 1 | dropped |
  | flags 0x0c (I and one R bit) | dropped |

  RFC 7348 section 5 says the R bits and reserved fields "MUST be set
  to zero on transmission and ignored on receipt". These are the first
  rows of the fault matrix below.
- **A capture to test against.** tcpdump on the FRR trial's spine:
  `10.255.0.11.42900 > 10.255.0.12.4789: VXLAN, flags [I] (0x08),
  vni 100`, an outer IP length of 134 for an inner of 84. The first
  pull request with code records it again as hex, from the lab, for the
  round-trip tests.
- **`isis4r:latest`** has Ruby 3.3 and datalink-socket 1.0.0.

## The library

### `VXLAN::Header`

The eight octets of RFC 7348 section 5: flags, 24 reserved bits, the
24-bit VNI and 8 reserved bits.

```ruby
VXLAN::Header.new(vni: 100)                         # I set, reserved zero
VXLAN::Header.new(vni: 100, flags: 0x0c)            # an R bit set, on purpose
VXLAN::Header.new(vni: 100, reserved1: 0xff0000, reserved2: 1)
VXLAN::Header.new("\x08\x00\x00\x00\x00\x00\x64\x00".b)  # from the wire
VXLAN::Header.new(h.to_hash)                        # from its hash
```

- `encode` gives the eight octets. `to_hash` gives `{vni: 100}` for an
  ordinary header, and adds `flags`, `reserved1` and `reserved2` only
  when they differ from the default. `to_s` gives
  `VXLAN flags [I] (0x08), vni 100`, tcpdump's form.
- Built three ways, plus another instance, as bgp4r's classes are.
- Nothing is validated on build. `vni` above 24 bits is refused,
  because it cannot be represented.

### `VXLAN::Packet`

A header and the inner frame, a `Datalink::Frame`. Built the same three
ways. `encode` is the UDP payload. The outer IP and UDP are the
socket's, so they are not in the object.

### `VXLAN::Validation`

The receive-side rules, one place, each with its RFC section:

| Finding | Rule |
| --- | --- |
| `short` | fewer than 8 octets, or no whole Ethernet header after them |
| `no_i_flag` | RFC 7348 section 5: the I flag "MUST be set to 1 for a valid VXLAN Network ID" |
| `reserved_set` | an R bit or a reserved field set. Reported, never a drop: section 5 says to ignore them on receipt |

`errors` lists the findings. A receive policy decides what to do:
`:rfc` (the default: drop on `short` and `no_i_flag`, ignore
`reserved_set`), `:strict` (raise on any finding) or `:lenient`
(deliver everything). An unknown VNI is the VTEP's business, not the
codec's.

Read RFC 7348 sections 4 and 5 into `specs/` before writing this, and
check each line above against them.

### `VXLAN::Fault`

The catalog of crafted packets, as bgp4r's `BGP::Fault::CATALOG`. Each
entry has a name, a description, the RFC section, what the RFC expects
(`deliver`, `drop` or `ignore`), and a block that builds the packet:

```ruby
VXLAN::Fault::CATALOG[:r_bit_set]
# {name: :r_bit_set, description: "an R bit set in the flags",
#  rfc: "RFC 7348 5", expect: :ignore, build: #<Proc>}
```

The first entries: `no_i_flag`, `r_bit_set`, `reserved1_set`,
`reserved2_set`, `unknown_vni`, `short_header`, `no_inner_frame`,
`inner_too_short`, `oversize_inner`.

### The fault matrix

`test/lab/fault_matrix_test.rb` sends each catalog entry to a receiver
and records what it did. It also writes `docs/fault-matrix.md`, which
says what each implementation does: `vtep4rd`, the kernel and FRR. This
is bgp4r's `docs/protocol-testing.md`, "What three implementations do".
Trial 1 is its first five rows for the kernel.

### `VXLAN::Gen`

A pure module, as bgp4r's `bgp/gen`: a spec in, frames out, with no
socket, thread or clock. A spec is plain JSON types, so it is the same
as a scenario step, an HTTP body or a Hash in a test.

| Key | What |
| --- | --- |
| `vni`, `header` | the header, or any `Header` hash |
| `inner` | `arp`, `broadcast`, `unicast`, or hex |
| `macs` | N source MACs from `start`, for filling a table |
| `count`, `per_second` | how many, how fast (the sim paces, not the module) |
| `seed` | required when a pattern is random |

It answers `packets` and `expected`: what it meant to send, as data.

## The VTEP, `vtep4rd`

### Its parts

| Part | What it does |
| --- | --- |
| `Vtep::BridgeDomain` | one per VNI: its ports, MAC table, flood list and mode, `learn` or `evpn` |
| `Vtep::MacTable` | MAC to a local port or a remote VTEP, with its origin (`learned` or `api`), age and sequence |
| `Vtep::Forwarder` | the pure function: a frame or packet in, actions out (`Deliver`, `Tunnel`, `Learn`, `Drop` with a reason) |
| Ports | datalink-socket Linux sockets, skipping frames this namespace sent |
| Tunnel | one UDP socket on the loopback, port 4789 |
| Ager | the timer, 300 s by default, as the kernel's (trial 2's `ip -d link`) |
| Counters | received and sent per port and per peer; drops by reason |

### Forwarding

From a host port, with a frame on VNI V:

1. Learn the source MAC on that port, unless V is in `evpn` mode.
2. A known unicast destination: deliver to its port, or tunnel to its
   VTEP.
3. Otherwise (broadcast, multicast, unknown unicast): deliver to every
   other port of V, and tunnel one copy to each VTEP in V's flood list.
   That is ingress replication.

From the tunnel:

1. Parse, validate under the receive policy, count each finding.
2. A VNI this VTEP does not serve: drop, `unknown_vni`.
3. Learn the inner source MAC behind the outer source address, unless
   the VNI is in `evpn` mode.
4. Deliver to the destination's port, or to every port of the VNI.
   Never back into the tunnel. That is what keeps ingress replication
   free of loops.

On the way out:

- The header is `Header.new(vni: V)`: the I flag set, every reserved
  bit zero.
- The UDP source port is a hash of the inner Ethernet header, in
  49152 to 65535, so ECMP spreads the flows (RFC 7348 section 5).
- The UDP checksum is zero (RFC 7348 section 5).
- It never fragments (RFC 7348 section 4.3). A frame too large is
  dropped, `too_big`.

### Its API

JSON lines on a Unix socket, `/run/vtep4r/vtep4rd.sock`, with
`vtep4r-cli` as its client, as `bgp4rd` and `bgp4r-cli`.

| Method | Answers or does |
| --- | --- |
| `api.info` | version, API number, methods: routescope's contract |
| `show.status` | local address, VNIs, uptime |
| `show.vnis` | per VNI: ports, mode, flood list, MAC count, ageing |
| `show.macs` | per VNI: MAC, `local` or `remote`, port or VTEP, origin, age, sequence |
| `show.counters` | per port and per peer; drops and findings by reason |
| `vni.add`, `vni.del` | a bridge domain |
| `vni.flood.add`, `vni.flood.del` | a VTEP in a flood list |
| `mac.add`, `mac.del`, `mac.flush` | entries, for EVPN |
| `config.reload` | the file again, as SIGHUP |
| `events` | a stream: `mac.learned`, `mac.moved`, `mac.aged`, `drop` |

`show.vnis` and `show.macs` give routescope's `evpn_vnis` and
`evpn_macs` columns. It has no `inject`. That is the sim's.

### Its file

```yaml
local: 10.255.0.11
socket: /run/vtep4r/vtep4rd.sock
receive_policy: rfc
ageing: 300
vnis:
  - vni: 100
    ports: [eth2]
    mode: learn            # or evpn
    flood: [10.255.0.12]   # static, for learn mode
```

It needs `CAP_NET_RAW` for its ports, unlike bgp4rd, which needs no
privilege. A container has it.

## The injector, `vtep4r-sim`

An HTTP API on the loopback, as `bgp4r-sim`'s, so `docker exec` reaches
it with one Ruby line.

| Action | Does |
| --- | --- |
| `send` | one packet: a `Header` hash and an inner frame, to a VTEP |
| `fault` | one catalog entry, by name, to a VTEP |
| `generate` | a `VXLAN::Gen` spec, paced |
| `stop` | the running generation |
| `show.sent` | what it sent, by action, with `expected` |

It keeps no MAC table and forwards nothing. Its file refuses the
`vnis`, `ports` and `ageing` keys by name, as `bgp4r-sim` refuses a
Loc-RIB's. It sends from the address it is told, so it can pose as a
VTEP that does not exist.

## Tests

- **Unit**, no root: each class's round trips, the validation rules,
  the catalog, `Gen`, the forwarder case by case on given bytes, the
  MAC table with a fake clock, the config.
- **Functional**, no root: two `vtep4rd` and one `vtep4r-sim` in one
  process, with datalink-socket's loopback backend and an in-memory
  tunnel. A host pings across, a MAC moves, every fault is counted.
- **Lab**, root: `vtep4rd` against the kernel's `vxlan` in two network
  namespaces, as bgp4r's `fib_test.rb`. The fault matrix against the
  kernel and FRR.

## Work

Each step needs the owner's approval of this document and of
routescope's.

1. datalink-socket: telling sent frames from received ones.
2. Here: the skeleton (gemspec, Rakefile, test runner, CI on 3.3, 3.4
   and 4.0, the frozen-string-literal run), `Header`, `Packet` and
   their round trips.
3. `Validation` and `Fault`, with their tests.
4. The VTEP: the forwarder, the MAC table, the edges, `vtep4rd`,
   `vtep4r-cli`, the functional tests.
5. `Gen` and `vtep4r-sim`.
6. The image, the lab tier and the fault matrix.
7. `vtep4r capture`, which dissects VXLAN with the inner frame.

## Open questions

- **The license.** bgp4r's is GPL 3 or later. Same here?
- **Speed.** The trial's round trip was 1.1 ms against the kernel's
  0.4. Labs need correctness, not line rate. Is a target wanted?
- **VLAN tags.** 802.1Q on a port, mapping a VLAN to a VNI.
  datalink-socket's `Frame` has the tags. Later?
- **IPv6 underlay.** IPv4 VTEP addresses first.
- **ARP suppression**, for bgp4rd's type 2 routes that carry an IP.
  Later.
- **VXLAN-GPE and GBP.** Other documents give the R bits meanings.
  The kernel may drop them because of those. Not read yet, so not
  claimed.
