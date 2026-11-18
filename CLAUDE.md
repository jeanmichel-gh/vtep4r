# CLAUDE.md

A guide for AI agents working on vtep4r. Read it before changing
anything.

## What this is

vtep4r is a pure Ruby library to build, parse and speak VXLAN
(RFC 7348). It is used to script VTEPs for testing and research, in the
same way bgp4r scripts BGP peers. Its runtime gems are `logger`, which
ships with Ruby, and datalink-socket, the owner's layer 2 library.

Programs are built on the library, as in bgp4r:

| Program | What it is |
| --- | --- |
| `vtep4rd` | a VTEP: bridge domains, MAC tables, flood lists. It answers its state and takes orders |
| `vtep4r-sim` | an injector and fault source. It sends what it is told and keeps no MAC table |
| `vtep4r-cli` | `vtep4rd`'s client, over its socket |
| `vtep4r` | the umbrella: `sim`, `capture`, `version` |

It is one of the owner's routing repositories, with bgp4r, ospfv2, isis
and datalink-socket. routescope, the web console for their labs, reads
both programs. bgp4rd will drive `vtep4rd` for EVPN (bgp4r's P5).

The plan is routescope `docs/design/evpn-vxlan-lab.md`. This
repository's own design is `docs/design/vtep4r.md`.

**Status: design approved, 2026-11-17.** Step 1 is done in
datalink-socket (#7). Step 2, the skeleton with `Header` and `Packet`,
is this repository's first code.

**bgp4r is the model.** Its CLAUDE.md, `docs/building-objects.md`,
`docs/protocol-testing.md` and `docs/daemon.md` are the long form of
the rules below. When this file does not say, do what bgp4r does.

## Layout

Built so far: the entry point, `version.rb`, `header.rb`, `packet.rb`,
`validation.rb`, `fault.rb`, `gen.rb` and `gen/vary.rb`, `vtep.rb` and `vtep/` (`actions.rb`,
`mac_table.rb`, `bridge_domain.rb`, `forwarder.rb`, `switch.rb`,
`ports.rb`, `tunnel.rb`), `logging.rb`, `daemon/` (`config.rb`,
`vtepd.rb`, `events.rb`, `api.rb`, `client.rb`, `cli.rb`,
`server.rb`), `sim/` (`config.rb`, `injector.rb`, `http.rb`,
`server.rb`), `exe/vtep4rd`, `exe/vtep4r-cli` and `exe/vtep4r-sim`, the
unit tier, six functional tests, `specs/rfc7348.txt` and one capture
in `test/fixtures/`. The rest is planned.

```
vtep4r.rb                entry point, requires everything
vxlan/version.rb         VXLAN::VERSION, the one place for it
vxlan/header.rb          the 8-octet VXLAN header
vxlan/packet.rb          a header and its inner Ethernet frame, kept as octets
vxlan/logging.rb         the injected logger, log(level, message)
vxlan/validation.rb      every receive-side rule, with its RFC section
vxlan/fault.rb           the fault catalog, VXLAN::Fault::CATALOG
vxlan/gen.rb, gen/       traffic generation: a spec in, frames out
vxlan/vtep/              the VTEP: bridge domain, MAC table, forwarder
vxlan/daemon/            vtep4rd: config, socket server, method table
vxlan/sim/               vtep4r-sim: the injector and its HTTP API
vxlan/capture/           dissecting a capture
exe/                     vtep4rd, vtep4r-sim, vtep4r-cli, vtep4r
test/unit/               one file per source file, no privileges
test/functional/         whole programs in one process, in-memory edges
test/lab/                against the kernel's VXLAN and FRR
test/fixtures/           captures: kernel-vxlan.pcap, the kernel's VXLAN on Linux 7.0
specs/                   the RFCs, as text, to cite from
docs/                    one guide per feature; docs/design/ for specs
```

## Conventions

- **Building and encoding are never validated, and that is a feature.**
  This library is for negative testing. It must put on the wire any
  flags octet, any reserved bits, any VNI, any inner frame, so a real
  VTEP can be watched handling them. Never add a check to a
  constructor, to `encode` or to `to_hash` that refuses something
  merely invalid.
  - Validation lives in one place, `vxlan/validation.rb`, and runs only
    on what was received. It reports findings through `errors`, each
    with its RFC section. It raises only under the `:strict` receive
    policy.
  - A constructor may refuse only what it cannot represent at all, such
    as a VNI above 24 bits, since the alternative is silently sending
    another value. Wire bytes stay open.
- **Keep what you cannot read, and write it back.** A header parsed
  from the wire keeps every bit, and its hash adds `flags`, `reserved1`
  or `reserved2` only when that field is not its default, so an
  ordinary header hashes as `{ vni: 100 }`. A packet keeps its inner
  frame as the octets that came and parses them only on demand; fewer
  octets than a header are kept whole as `short`. `encode` gives back
  what arrived, byte for byte.
  Echoing a reserved field is intended: bgp4r's owner confirmed it on
  2026-10-29, for the same reason as the first bullet.
- **The receiver ignores what RFC 7348 says to ignore.** Section 5 says
  the R bits and reserved fields are "set to zero on transmission and
  ignored on receipt". `vtep4rd` does that. Kernel 7.0 drops them
  (routescope's trial, 2026-11-17), so that is a row of the fault
  matrix, not a rule to copy.
- **Every class is built three ways:** from field values, from a hash,
  and from its wire bytes. Most also take another instance. `encode`
  returns wire bytes. `to_hash` returns a hash that round trips through
  `new`. `to_s` returns the human form. bgp4r's
  `docs/building-objects.md` is the guide.
  - **A String is always wire bytes here.** No field of a `Header` or a
    `Packet` is a String, so a String argument can only be octets.
    vtep4r therefore has no mark on packed strings and does not patch
    `Array#pack`, where bgp4r does. Keep it that way: a class whose
    field is a String takes it as a keyword in a hash.
  - **A constructor does not consume its String.** It reads with
    `byteslice`, never `slice!`, so the caller's octets are unchanged.
- **Tests check round trips:** build, encode, parse back, compare. Use
  real hex captures, from tcpdump or Wireshark, where there is one. One
  test file per source file, with the same name and `_test.rb`.
- **A working round trip needs a test.** If `Klass.new(obj.to_hash)`
  gives back `obj`'s bytes, its test file asserts it.
- **A log line goes through `log(level, message)`**, from
  `VXLAN::Logging`, with a settable logger that is a plain callable
  `->(level, message)`. Two VTEPs in one process then log apart.
- **Two programs, not one.** `vtep4rd` answers and acts as a VTEP.
  `vtep4r-sim` injects. A node that does both has state no reader can
  trust in the middle of a scenario (bgp4r `docs/daemon.md`). The sim
  refuses the keys that would make it forward or learn.
- **Every number routescope shows is reachable with one command**, and
  every action routescope takes is a command too.
- **The forwarding decision is a pure function.** A frame or a packet
  goes in, and a list of actions comes out. Sockets, threads and clocks
  are at the edges, and a test swaps each for an in-memory stand-in.
- **The thread that reads a port must not block.** Work that can be
  slow goes to a worker, as bgp4r's RIB work does.
- **Runtime gems:** `logger` and datalink-socket, nothing else. No JSON
  gem, no web framework, no event machine. The socket server is
  `UNIXServer` with one thread per client. Before requiring a standard
  library, check that it is still a default gem.
- Do not redefine methods of standard library classes.
- Do not mutate string literals. CI runs with
  `--enable-frozen-string-literal`. An octet buffer is `String.new`,
  which is binary, never `+''`.
- Two space indent.
- A new Ruby file or Dockerfile starts with the GPL header from bgp4r's
  `bgp/observable.rb`, with `Copyright 2026 Jean-Michel Esnault.` and
  "This file is part of VTEP4R". The license for now is GPL 3 or
  later. The owner's rule (2026-11-17): a new repository takes the more
  restrictive license, and licenses across the repositories are
  reviewed together at the end. bgp4r itself is dual: GPL, or the
  conditions in its `LICENSE.txt`.

## Other daemons are for interop

The kernel's VXLAN and FRR are what vtep4r is tested against, in the
fault matrix and in routescope's labs. They do not replace it.

## Running tests

Ruby 3.3, 3.4 and 4.0, with test-unit. CI runs the unit tier twice,
the second time with `--enable-frozen-string-literal`.

```sh
BUNDLE_PATH=~/.cache/bundle-vtep4r bundle install   # outside the repo
BUNDLE_PATH=~/.cache/bundle-vtep4r bundle exec ruby test/run_unit.rb
```

datalink-socket is not on RubyGems yet, so the Gemfile takes it from its
repository. Without Bundler, point `DATALINK_LIB` at a checkout's
`lib/`:

```sh
DATALINK_LIB=~/datalink-socket/lib ruby test/run_unit.rb
DATALINK_LIB=~/datalink-socket/lib ruby -I. -I$DATALINK_LIB test/unit/header_test.rb
```

Check the test count against `grep -c 'def test_'`: a test defined twice
in one class, or after `private`, never runs and nothing says so.

The functional tier runs whole programs, threads and all, in one
process: hosts on datalink-socket's loopback wires and VTEPs on an
in-memory tunnel. No root. CI runs each file:

```sh
DATALINK_LIB=~/datalink-socket/lib ruby -I. test/functional/two_vteps_test.rb
DATALINK_LIB=~/datalink-socket/lib ruby -I. test/functional/api_socket_test.rb
DATALINK_LIB=~/datalink-socket/lib ruby -I. test/functional/programs_test.rb
DATALINK_LIB=~/datalink-socket/lib ruby -I. test/functional/events_stream_test.rb
DATALINK_LIB=~/datalink-socket/lib ruby -I. test/functional/sim_test.rb
DATALINK_LIB=~/datalink-socket/lib ruby -I. test/functional/sim_program_test.rb
```

`programs_test.rb` and `sim_program_test.rb` run the programs as a
person does, SIGHUP included. A vtep4rd with no ports opens no raw
socket, and UDP port 4789 on 127.0.0.x needs no root, so they run
anywhere. `sim_test.rb` drives the sim over HTTP with the headers
routescope's one-line client sends, into a vtep4rd over real UDP.

A test that starts threads is run many times before it is trusted:
`two_vteps_test.rb` passed 20 of 20 when it was written, and the six
files together 10 of 10 when the last was added. A test that waits for
something a thread sends waits with a deadline, so a regression fails
it rather than hanging it.

Planned: the lab tier needs root and the kernel's `vxlan`, or FRR.
`docs/running-tests.md` will be generated from the test list, as
bgp4r's is.

## Rules for agents

- Work on a branch named `claude/<short-topic>`. Never push to master.
- Do not stack a pull request on another one's branch.
- One topic per pull request. Small diffs.
- Run the full unit suite before opening a pull request. All tests
  must pass.
- New behaviour needs a test. A fix needs a test that failed before it.
  **Check that the proof proved something:** break the code on
  purpose and see the test fail. Commit before you break it.
- Larger work starts with a design in `docs/design/<topic>.md`,
  approved by the owner before any code.
- Update a branch by rebasing on `origin/master` and pushing with
  `--force-with-lease`. Do not merge master into it.
- Cite the RFC section in a comment when you write wire format logic.
  Open the RFC and check the section against its text. Never cite from
  memory.
- Work out what the code was built to do before concluding it is
  wrong. Say "I do not know why this is like this" until you know.
- Do not delete or weaken a test to make a change pass.
- If you find a bug you are not fixing, list it in the pull request.
- Edit this file with the `Edit` tool, one passage at a time.
- A plan that spans sessions goes under "Where the work is going", as
  phases with their status.
- Keep this file true in the pull request that makes it false.
- Write in plain, short sentences: code comments, documents, pull
  requests.

## Where the work is going

The phases are in `docs/design/vtep4r.md`, "Work".

| Step | Status |
| --- | --- |
| 1. datalink-socket: sent frames | Done, datalink-socket #7 |
| 2. Skeleton, `Header`, `Packet` | Done, #2 |
| 3. `Validation` and `Fault` | Done, #3 |
| 4a. The VTEP's pure core | Done, #4 |
| 4b. The edges and the daemon loop | Done, #5 |
| 4c. The control API, `vtep4rd`, `vtep4r-cli` | Done, #6 |
| 4d. Events, `vni.add`/`del`, `config.reload` | Done, #7 |
| 5a. `VXLAN::Gen` | Done, #8 |
| 5b. `vtep4r-sim` | This pull request |
| 6. Image, lab tier, fault matrix | Not started |
| 7. `vtep4r capture` | Not started |
