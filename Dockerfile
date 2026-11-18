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

# vtep4r in a container: vtep4rd, vtep4r-cli and vtep4r-sim, and Ruby for
# the one-line API clients routescope runs here.
#
#   docker build -t vtep4r:latest --build-context datalink-socket=../datalink-socket .
#   docker run --rm --cap-add NET_RAW -v $PWD/vtep4rd.yml:/etc/vtep4r/vtep4rd.yml vtep4r
#   docker run --rm --entrypoint vtep4r-sim -v $PWD/sim.yml:/etc/vtep4r/sim.yml vtep4r -f /etc/vtep4r/sim.yml
#
# datalink-socket is a sibling checkout, handed in as a named build
# context, since the gem is not published: as isis4r's image.

ARG RUBY_VERSION=3.3
FROM ruby:${RUBY_VERSION}-slim AS base

LABEL org.opencontainers.image.title="vtep4r" \
      org.opencontainers.image.description="VXLAN in Ruby: a VTEP and an injector, for routing labs and protocol tests" \
      org.opencontainers.image.source="https://github.com/jeanmichel-gh/vtep4r" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

WORKDIR /app
COPY --from=datalink-socket lib/ /datalink-socket/lib/
COPY vtep4r.rb vtep4r.gemspec LICENSE.txt COPYING ./
COPY vxlan/ vxlan/
COPY exe/ exe/
COPY docs/ docs/
ENV PATH=/app/exe:$PATH \
    RUBYLIB=/app:/datalink-socket/lib \
    RUBYOPT=--disable-did_you_mean

# ---- tests: docker build --target test ...
# The unit tier, as CI runs it, so an image that builds is one whose
# library passes.
FROM base AS test
RUN gem install --no-document test-unit
COPY test/ test/
RUN ruby test/run_unit.rb && ruby --enable-frozen-string-literal test/run_unit.rb

# ---- runtime
# The ports need CAP_NET_RAW, granted at run time. iproute2 and tcpdump
# to look at the tunnel and the bridge side; ping for a lab's scenarios.
FROM base AS runtime
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends iproute2 tcpdump iputils-ping \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/vtep4r /run/vtep4r
ENTRYPOINT ["vtep4rd"]
CMD ["-f", "/etc/vtep4r/vtep4rd.yml"]
