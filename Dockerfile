# syntax=docker/dockerfile:1
FROM swift:6.1-jammy AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY RelayPackage.swift ./Package.swift
RUN swift package resolve
COPY Sources ./Sources
RUN swift build -c release --product continuum-relay

FROM swift:6.1-jammy-slim
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home relay && mkdir -p /data && chown relay:relay /data
COPY --from=build /src/.build/release/continuum-relay /usr/local/bin/continuum-relay
USER relay
ENV PORT=8080 RELAY_ADMIN_PORT=9090 RELAY_DATABASE_PATH=/data/relay.sqlite
EXPOSE 8080 9090
ENTRYPOINT ["/usr/local/bin/continuum-relay"]
