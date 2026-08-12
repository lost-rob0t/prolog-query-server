FROM couchdb:3.5.2.1

USER root
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends swi-prolog-nox \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/prolog-query-server/src
COPY couchdb_query_server.pl /opt/prolog-query-server/couchdb_query_server.pl
COPY src/query_server_protocol.pl /opt/prolog-query-server/src/query_server_protocol.pl
RUN chown -R couchdb:couchdb /opt/prolog-query-server

ENV COUCHDB_QUERY_SERVER_PROLOG="/usr/bin/swipl -q -s /opt/prolog-query-server/couchdb_query_server.pl --"

USER couchdb
