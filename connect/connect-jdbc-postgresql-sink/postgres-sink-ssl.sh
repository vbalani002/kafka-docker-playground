#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
source ${DIR}/../../scripts/utils.sh

if [ ! -z "$TAG_BASE" ] && version_gt $TAG_BASE "7.9.99" && [ ! -z "$CONNECTOR_TAG" ] && ! version_gt $CONNECTOR_TAG "10.7.99"
then
     logwarn "minimal supported connector version is 10.8.0 for CP 8.0"
     logwarn "see https://docs.confluent.io/platform/current/connect/supported-connector-version-8.0.html#supported-connector-versions-in-cp-8-0"
     exit 111
fi

cd ${DIR}/ssl
if [[ "$OSTYPE" == "darwin"* ]]
then
    # workaround for issue on linux, see https://github.com/vdesabou/kafka-docker-playground/issues/851#issuecomment-821151962
    chmod -R a+rw .
else
    # on CI, docker is run as runneradmin user, need to use sudo
    ls -lrt
    sudo chmod -R a+rw .
    ls -lrt
fi

rm -f server.crt
rm -f server.csr
rm -f server.key
rm -f ca.crt
rm -f ca.key

#https://blog.crunchydata.com/blog/ssl-certificate-authentication-postgresql-docker-containers
log "Creating a Root Certificate Authority (CA)"
docker run --quiet --rm -v $PWD:/tmp alpine/openssl req -new -x509 -days 365 -nodes -out /tmp/ca.crt -keyout /tmp/ca.key -subj "/CN=root-ca"

log "Generate the PostgreSQL server key and certificate"
docker run --quiet --rm -v $PWD:/tmp alpine/openssl req -new -nodes -out /tmp/server.csr -keyout /tmp/server.key -subj "/CN=postgres"
docker run --quiet --rm -v $PWD:/tmp alpine/openssl x509 -req -in /tmp/server.csr -days 365 -CA /tmp/ca.crt -CAkey /tmp/ca.key -CAcreateserial -out /tmp/server.crt

if [[ "$OSTYPE" == "darwin"* ]]
then
    # workaround for issue on linux, see https://github.com/vdesabou/kafka-docker-playground/issues/851#issuecomment-821151962
    chmod -R a+rw .
else
    # on CI, docker is run as runneradmin user, need to use sudo
    ls -lrt
    sudo chmod -R a+rw .
    ls -lrt
fi
rm server.csr

cd -

PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.ssl.yml"


log "Creating JDBC PostgreSQL sink connector"
playground connector create-or-update --connector postgres-sink  << EOF
{
               "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
               "tasks.max": "1",
               "connection.url": "jdbc:postgresql://postgres/postgres?user=myuser&password=mypassword&sslmode=verify-full&sslrootcert=/tmp/ca.crt",
               "topics": "orders",
               "auto.create": "true"
          }
EOF


log "Sending messages to topic orders"
playground topic produce -t orders --nb-messages 1 << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "id",
      "type": "int"
    },
    {
      "name": "product",
      "type": "string"
    },
    {
      "name": "quantity",
      "type": "int"
    },
    {
      "name": "price",
      "type": "float"
    }
  ]
}
EOF

playground topic produce -t orders --nb-messages 1 --forced-value '{"id":2,"product":"foo","quantity":2,"price":0.86583304}' << 'EOF'
{
  "type": "record",
  "name": "myrecord",
  "fields": [
    {
      "name": "id",
      "type": "int"
    },
    {
      "name": "product",
      "type": "string"
    },
    {
      "name": "quantity",
      "type": "int"
    },
    {
      "name": "price",
      "type": "float"
    }
  ]
}
EOF

sleep 5

log "Show content of ORDERS table:"
docker exec postgres bash -c "psql -U myuser -d postgres -c 'SELECT * FROM ORDERS'" > /tmp/result.log  2>&1
cat /tmp/result.log
grep "foo" /tmp/result.log