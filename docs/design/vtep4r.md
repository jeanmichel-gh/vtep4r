# vtep4r, VXLAN in Ruby

Status: approved by the owner, 2026-11-17. No code yet: step 1 is
datalink-socket's.

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
entry has a name, a description, what RFC 7348 expects of the receiver
(`drop`, or `ignore` for bits it must ignore), the RFC section, and a
block that builds the packet for a receiver's VNI:

```ruby
VXLAN::Fault.catalog.find { |e| e[:name] == :r_bit_set }
# {name: :r_bit_set, description: "one R bit set beside the I flag",
#  expect: :ignore, rfc: "RFC 7348 5", build: #<Proc>, vtep: false}
VXLAN::Fault.build(:r_bit_set, vni: 100)   # a Packet, the kernel's ARP inside
VXLAN::Fault.wire(:r_bit_set, vni: 100)    # its octets
```

Built in step 3: `no_i_flag`, `r_bit_set`, `r_bits_all`,
`reserved1_set`, `reserved2_set`, `unknown_vni`, `short_header`,
`no_inner_frame`, `inner_too_short`.

- `unknown_vni` is marked `vtep`: the codec cannot judge it, since a
  VNI is valid only for the VTEP that serves it (RFC 7348 section 4.1).
- RFC 7348 says nothing of a cut packet. The three short entries expect
  a drop because a packet without a header and an inner frame cannot be
  passed on. That is our reading, and their descriptions say so.
- `oversize_inner` waits for the lab tier, step 6: what a receiver does
  with a large inner frame depends on the path's MTU, which only a lab
  has.

A unit test checks that the catalog and `Validation` agree: under the
`:rfc` policy, every entry but `unknown_vni` is dropped or delivered as
its `expect` says, and has a finding.

### The fault matrix

`test/lab/fault_matrix_test.rb` sends each catalog entry, and a valid
packet as a baseline, by vtep4r-sim to two receivers: vtep4rd and the
kernel's `vxlan`. It asserts vtep4rd against RFC 7348 and records the
kernel. It writes `docs/fault-matrix.md` when asked, as bgp4r's
`docs/protocol-testing.md`, "What three implementations do". Built in
step 6b.

FRR has no VXLAN data plane of its own: zebra programs the kernel's
`vxlan` device. So the matrix has two receivers, and the kernel's
column is FRR's too.

Delivered is judged by a learned MAC: each case sends its inner frame
from a source MAC of its own, and a receiver learns a source only from
a packet it accepted. Counters alone read the host's own frames as
deliveries.

Linux 7.0 on ospflab, 2026-11-18: the kernel drops all four
reserved-bit cases (`r_bit_set`, `r_bits_all`, `reserved1_set`,
`reserved2_set`), counting each as an rx error, where RFC 7348 section 5
says to ignore those bits. vtep4rd ignores them and delivers. Both drop
the I flag clear, an unknown VNI and the three cut packets.

### `VXLAN::Gen`

A pure module, as bgp4r's `bgp/gen`: a spec in, packets out, with no
socket, thread or clock. A spec is plain JSON types, so it is the same
as a scenario step, an HTTP body or a Hash in a test. Built in step 5a.

| Key | What |
| --- | --- |
| `vni` | required; a value or an integer pattern |
| `flags`, `reserved1`, `reserved2` | the header's other fields, values or patterns; any bits, on purpose |
| `inner` | `broadcast` (the default), `unicast` (needs `dst`) or `arp` |
| `src`, `macs` | `macs` distinct source MACs counting up from `src`, for filling a table |
| `count` | how many packets, `macs` by default; past `macs` the sources cycle |
| `dst`, `ethertype`, `size` | the destination MAC, the EtherType (0x88b5), the inner frame's octets (60; 42 for `arp`, as the kernel sends it) |
| `sender_ip`, `target_ip` | for `arp`: the sender steps with the source |
| `seed` | required when a pattern is random |

Integer patterns are bgp4r's five: `fixed`, `cycle`, `step`, `random`
and `every`. A value is a function of the packet's number and the seed
only. `random` is a fresh generator per value per packet, seeded with
FNV-1a 64 of the seed, the value's name and the number, so the same
spec gives the same octets on every Ruby; a test pins the values. A
spec is refused only when it cannot be read: an unknown key, a wrong
type, a value too wide for its field.

It answers `each` (one packet at a time), `packets` and `expected`:
`{vni, src, dst}` per packet, what it meant to send, as data. How fast
to send is the sim's, not the module's.

The design's `header` key became the three field keys, and the `hex`
inner frame is left out: `vtep4r-sim`'s `send` takes any octets.

## The VTEP, `vtep4rd`

### Its parts

| Part | What it does |
| --- | --- |
| `Vtep::BridgeDomain` | one per VNI: its ports, MAC table, flood list and mode, `learn` or `evpn` |
| `Vtep::MacTable` | MAC to a local port or a remote VTEP, with its origin (`learned` or `api`), age and sequence |
| `Vtep::Forwarder` | the pure function: a frame or packet in, actions out (`Deliver`, `Tunnel`, `Learn`, `Note` for an ignored finding, `Drop` with a reason). It reads the tables and never changes them |
| `Vtep::Switch` | the VTEP's state and the one place it changes: it asks the Forwarder, applies its `Learn` actions, records events (`learned`, `moved`, `aged`), counts drops and ignored findings, and hands `Deliver` and `Tunnel` to the edges |
| Ports | datalink-socket Linux sockets with `ignore_outgoing: true`, so the frames this namespace sends are skipped |
| Tunnel | a UDP socket on the VTEP's address, port 4789, to receive; to send, a pool of up to 64 sockets, one bound to each source port in use, since a UDP socket sends from the one port it is bound to. A port that cannot be bound falls back to the receiving socket |
| `Daemon::Vtepd` | one worker thread owns the `Switch`; each port, the tunnel and the ager have a thread that only queues work, so no reader blocks. Anything else that reads or changes the state runs on the worker, through `on_worker` |
| Ager | the timer, 300 s by default, as the kernel's (trial 2's `ip -d link`) |
| Counters | received and sent per port and per peer; drops by reason |

### Forwarding

From a host port, with a frame on VNI V:

1. Learn the source MAC on that port, in either mode. In `evpn` mode
   too: bgp4rd advertises local MACs as type 2 routes, so they must be
   learned. (Corrected in step 4a; the approved draft said "unless V is
   in `evpn` mode".)
2. A known unicast destination: deliver to its port, or tunnel to its
   VTEP. One on the port it came from is dropped, `same_port`.
3. Otherwise (broadcast, multicast, unknown unicast): deliver to every
   other port of V, and tunnel one copy to each VTEP in V's flood list.
   That is ingress replication.

Fewer than 14 octets is dropped, `not_a_frame`; a port in no VNI,
`unknown_port`.

From the tunnel:

1. Parse, validate under the receive policy, count each finding.
2. A VNI this VTEP does not serve: drop, `unknown_vni`.
3. Learn the inner source MAC behind the outer source address, unless
   the VNI is in `evpn` mode.
4. Deliver to the destination's port, or to every port of the VNI.
   Never back into the tunnel: a destination behind another VTEP is
   dropped, `split_horizon`. That is what keeps ingress replication
   free of loops.

On the way out:

- The header is `Header.new(vni: V)`: the I flag set, every reserved
  bit zero.
- The UDP source port is a hash of the inner Ethernet header, in
  49152 to 65535, so ECMP spreads the flows (RFC 7348 section 5).
- The UDP checksum is zero (RFC 7348 section 5).
- It never fragments (RFC 7348 section 4.3). A frame too large is
  dropped, `too_big`. The outer IPv4, UDP and VXLAN headers take 36
  octets of the underlay's MTU; the outer Ethernet header is not in
  it. So with an MTU of 1500, an inner frame of 1464 octets fits and
  one of 1465 does not.

### Its API

JSON lines on a Unix socket, `/run/vtep4r/vtep4rd.sock`, with
`vtep4r-cli` as its client, as `bgp4rd` and `bgp4r-cli`. The envelope
is bgp4rd's exactly (bgp4r `docs/daemon.md`, "The envelope"), so
routescope reads it with the same one-line client. The socket is born
0660; a bad line, an over-long line, a method that raises or a client
that goes away is answered or ignored without taking the daemon down.
Every method runs on `Vtepd`'s worker thread.

| Method | Answers or does | Step |
| --- | --- | --- |
| `api.info` | version, API number, methods: routescope's contract | 4c |
| `show.status` | local address, VNIs, MTU, receive policy, uptime | 4c |
| `show.vnis` | per VNI: `vni`, `type` (`L2`), `vtep_ip`, `ports`, `mode`, `remote_vteps`, `flood` (`HER`), `macs`, `ageing` | 4c |
| `show.macs` | per MAC, all VNIs or `vni`: `local` or `remote`, port or VTEP, origin, age, sequence, moves | 4c |
| `show.counters` | per port and per peer; drops and findings by reason | 4c |
| `vni.flood.add`, `vni.flood.del` | a VTEP in a flood list | 4c |
| `mac.add`, `mac.del`, `mac.flush` | entries, for EVPN; `mac.add` takes `vni`, `mac`, `vtep`, `seq` | 4c |
| `vni.add`, `vni.del` | a bridge domain, with a vnis entry's keys; its ports are opened or closed, and their readers started or stopped | 4d |
| `config.reload` | the file again, as SIGHUP. VNIs are added, removed, or replaced when their ports or mode changed (losing their MACs); a learn-mode VNI's flood list and any VNI's ageing are set in place. `local`, `mtu`, `receive_policy` and `socket` need a restart, and the answer names them rather than applying them | 4d |
| `events.subscribe`, `events.unsubscribe` | a stream, in bgp4rd's form and envelope: kinds `mac` (learned, moved, aged), `drop` (a reason, and the peer or port), `config` and `overflow`; `since` replays a backlog of 2000, with an overflow event for what is no longer kept; a keepalive line every 15 s of quiet | 4d |

`show.status` also lists the ports open, so a `vni.del` that left one
open shows.

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

An HTTP API on the loopback, as `bgp4r-sim`'s (bgp4r `docs/daemon.md`,
"The HTTP API"), so `docker exec` reaches it with one Ruby line and
routescope's driver is a copy of its `Bgp4rSim`. Built in step 5b.

- `127.0.0.1:8080` by default. GET for reads, POST for actions.
- A POST carries `X-VTEP4R: routescope`, matched case insensitively,
  since `Net::HTTP` sends it as `X-Vtep4r`; without it, 403.
- 400 for a request the caller can fix, 409 for a generation already
  running, each with `{"error": "..."}`.
- No web framework and no `webrick`: HTTP/1.1 over `TCPServer`.

| Path | Body keys | Does |
| --- | --- | --- |
| `POST /api/send` | `to`, `vni`, `flags`, `reserved1`, `reserved2`, `inner` (hex), `source_port` | one packet, any header, any inner octets (the kernel's ARP by default) |
| `POST /api/fault` | `to`, `case`, `vni`, `inner`, `source_port` | one catalog entry; answers what RFC 7348 expects of the receiver |
| `POST /api/generate` | `to`, `spec`, `per_second`, `source_port` | a `VXLAN::Gen` spec in a thread, paced from its start; one at a time |
| `POST /api/stop` | | ends the running generation; it wakes the pacing wait, so a slow rate does not hold it |
| `POST /api/plan` | `spec`, `offset`, `limit` | a dry run: `Gen#expected`, paged, nothing sent |
| `GET /api/status`, `/api/sent`, `/api/topology`, `/api/events?since=N`, `/` | | what it is, what it sent, what it can send, its events in bgp4r's shape, the paths |

Its file is `local`, `api` and `port`. It keeps no MAC table and
forwards nothing: the file refuses `vnis`, `ports`, `ageing`, `mtu`,
`receive_policy` and `socket` by name, as `bgp4r-sim` refuses a
Loc-RIB's.

It never binds the VXLAN port: it sends from the source port asked
for, the flow's hash by default, or an ephemeral one when that port is
taken. So it shares a namespace with a vtep4rd, which holds 4789. It
sends from `local`, an address the host has; to pose as a VTEP that
does not exist, the lab gives the namespace that address.

Checked live, 2026-11-17, beside a vtep4rd in one namespace and
against the kernel's `vxlan` in another: 50 generated MACs at 500 a
second, all learned by the kernel; 5 with an R bit set (flags 0x0c),
none learned, so kernel 7.0 drops them, as in routescope's trial 1;
5 valid after them, all learned.

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

1. datalink-socket: telling sent frames from received ones. Done,
   datalink-socket #7: `CapturedFrame#packet_type` and the Linux
   backend's `ignore_outgoing: true`.
2. Here: the skeleton (gemspec, Rakefile, test runner, CI on 3.3, 3.4
   and 4.0, the frozen-string-literal run), `Header`, `Packet` and
   their round trips. `Packet` keeps its inner frame as octets and
   parses it on demand, since a crafted packet's may not parse. The
   round trips run on the kernel's own packets,
   `test/fixtures/kernel-vxlan.pcap`.
3. `Validation` and `Fault`, with their tests. Done, #3.
4. The VTEP, in three pull requests, to keep each small:
   - 4a, the pure core: `MacTable`, `BridgeDomain`, `Forwarder`,
     `Switch`, unit tests on bytes with the time as an argument, and
     two switches wired through each other's tunnel actions. Done, #4.
   - 4b, the edges and the daemon loop: `Ports`, `UdpTunnel` and
     `MemoryTunnel`, `VXLAN::Logging`, `Daemon::Config`,
     `Daemon::Vtepd`, and a functional test of two of them in one
     process. Checked live against the kernel's `vxlan` in network
     namespaces, 2026-11-17: pings both ways, two MACs learned, no
     drops.
   - 4c, the control surface: the API on the Unix socket (the methods
     marked 4c above), its client, `vtep4r-cli`, `exe/vtep4rd` and
     `exe/vtep4r-cli`, with functional tests over a real socket and of
     the two programs run as a person runs them.
   - 4d, the rest of the API: the event stream, `vni.add` and
     `vni.del`, and `config.reload` with SIGHUP. `vtep4r-cli
     events.subscribe` follows a stream. Checked live against the
     kernel's `vxlan`, 2026-11-17: the stream's result and keepalive
     lines, and a reload that changed VNI 100's flood list.
5. The injector side, in two pull requests:
   - 5a, `VXLAN::Gen` and its patterns, `Gen::Vary`.
   - 5a, done, #8.
   - 5b, `vtep4r-sim`: its HTTP API, `send`, `fault`, `generate` with
     pacing, `stop` and `plan`, and the reads. routescope's driver and
     its `vxlan:` actions are routescope's work, step 3 of its plan.
6. In two pull requests:
   - 6a, the image and the lab tier. A `Dockerfile` as isis4r's, whose
     `test` stage runs the unit tier, and `test/lab/kernel_test.rb`:
     vtep4rd and vtep4r-sim, the real programs, against the kernel's
     `vxlan` in three namespaces, as root; pings both ways, each side
     learning the other, a broadcast from the host flooded into the
     tunnel, and the sim filling the kernel's table. CI runs it as
     root in a job of its own.
   - 6b, the fault matrix: every catalog entry sent by vtep4r-sim to
     vtep4rd and to the kernel, what each did recorded in
     `docs/fault-matrix.md`, generated. FRR has no VXLAN data plane of
     its own (zebra programs the kernel's `vxlan` device), so the
     kernel's row is FRR's too, and the document says so.
     `oversize_inner` is still out of the catalog: what a receiver does
     with it depends on its MTU, and the RFC sets no expectation for a
     receiver to assert. It waits for a reason to want it.
7. `vtep4r capture`, which dissects VXLAN with the inner frame.

## Open questions

- **The license.** GPL 3 or later for now, the more restrictive choice
  the owner wants for a new repository. Licenses across the
  repositories are reviewed together at the end (owner, 2026-11-17).
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
