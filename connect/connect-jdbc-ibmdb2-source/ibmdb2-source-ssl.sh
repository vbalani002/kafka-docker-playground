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

# https://docs.docker.com/compose/profiles/
profile_control_center_command=""
if [ -z "$ENABLE_CONTROL_CENTER" ]
then
  log "🛑 control-center is disabled"
else
  log "💠 control-center is enabled"
  log "Use http://localhost:9021 to login"
  profile_control_center_command="--profile control-center"
fi

profile_ksqldb_command=""
if [ -z "$ENABLE_KSQLDB" ]
then
  log "🛑 ksqldb is disabled"
else
  log "🚀 ksqldb is enabled"
  log "🔧 You can use ksqlDB with CLI using:"
  log "docker exec -i ksqldb-cli ksql http://ksqldb-server:8088"
  profile_ksqldb_command="--profile ksqldb"
fi

set_profiles
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} down -v --remove-orphans
log "Starting up ibmdb2 container to get db2jcc4.jar"
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} up -d ibmdb2

cd ../../connect/connect-jdbc-ibmdb2-source
rm -f db2jcc4.jar
log "Getting db2jcc4.jar"
docker cp ibmdb2:/opt/ibm/db2/V11.5/java/db2jcc4.jar db2jcc4.jar
cd -

playground container logs --container ibmdb2 --wait-for-log "Setup has completed" --max-wait 600
log "ibmdb2 DB has started!"

log "Enable SSL on DB2"
# https://stackoverflow.com/questions/63024640/db2-in-docker-container-problem-with-autostart-of-ssl-configuration-after-resta
# https://medium.datadriveninvestor.com/configuring-secure-sockets-layer-ssl-for-db2-server-and-client-3b317a033d71
docker exec -i ibmdb2 bash << EOF
su - db2inst1
gsk8capicmd_64 -keydb -create -db "server.kdb" -pw "confluent" -stash
gsk8capicmd_64 -cert -create -db "server.kdb" -pw "confluent" -label "myLabel" -dn "CN=ibmdb2" -size 2048 -sigalg SHA256_WITH_RSA
gsk8capicmd_64 -cert -extract -db "server.kdb" -pw "confluent" -label "myLabel" -target "server.arm" -format ascii -fips
gsk8capicmd_64 -cert -details -db "server.kdb" -pw "confluent" -label "myLabel"
db2 update dbm cfg using SSL_SVR_KEYDB /database/config/db2inst1/server.kdb
db2 update dbm cfg using SSL_SVR_STASH /database/config/db2inst1/server.sth
db2 update dbm cfg using SSL_SVCENAME 50002
db2 update dbm cfg using SSL_VERSIONS TLSv12
db2 update dbm cfg using SSL_SVR_LABEL myLabel
db2set -i db2inst1 DB2COMM=SSL,TCPIP
db2stop force
db2start
EOF

log "verifying DB2 SSL config"
docker exec -i ibmdb2 bash << EOF
su - db2inst1
gsk8capicmd_64 -cert -list -db "server.kdb" -stashed
db2 get dbm cfg|grep SSL
EOF
#-       myLabel
#  SSL server keydb file                   (SSL_SVR_KEYDB) = /database/config/db2inst1/server.kdb
#  SSL server stash file                   (SSL_SVR_STASH) = /database/config/db2inst1/server.sth
#  SSL server certificate label            (SSL_SVR_LABEL) = myLabel
#  SSL service name                         (SSL_SVCENAME) = 50002
#  SSL cipher specs                      (SSL_CIPHERSPECS) = 
#  SSL versions                             (SSL_VERSIONS) = TLSv12
#  SSL client keydb file                  (SSL_CLNT_KEYDB) = 
#  SSL client stash file                  (SSL_CLNT_STASH) = 

mkdir -p ${PWD}/security/
rm -rf ${PWD}/security/*

cd ${PWD}/security/
docker cp ibmdb2:/database/config/db2inst1/server.arm .

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
docker run --quiet --rm -v $PWD:/tmp ${CP_CONNECT_IMAGE}:${CP_CONNECT_TAG} keytool -import -trustcacerts -v -noprompt -alias myAlias -file /tmp/server.arm -keystore /tmp/truststore.jks -storepass 'confluent'
log "Displaying truststore"
docker run --quiet --rm -v $PWD:/tmp ${CP_CONNECT_IMAGE}:${CP_CONNECT_TAG} keytool -list -keystore /tmp/truststore.jks -storepass 'confluent' -v
cd -

set_profiles
docker compose -f ../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} up -d --quiet-pull
command="source ${DIR}/../../scripts/utils.sh && docker compose -f ${DIR}/../../environment/plaintext/docker-compose.yml ${KRAFT_DOCKER_COMPOSE_FILE_OVERRIDE} -f "${PWD}/docker-compose.plaintext.ssl.yml" ${profile_control_center_command} ${profile_ksqldb_command} ${profile_zookeeper_command}  ${profile_grafana_command} ${profile_kcat_command} up -d"
playground state set run.docker_command "$command"
playground state set run.environment "plaintext"
log "✨ If you modify a docker-compose file and want to re-create the container(s), run cli command 'playground container recreate'"


wait_container_ready

# Keep it for utils.sh
# PLAYGROUND_ENVIRONMENT=${PLAYGROUND_ENVIRONMENT:-"plaintext"}
#playground start-environment --environment "${PLAYGROUND_ENVIRONMENT}" --docker-compose-override-file "${PWD}/docker-compose.plaintext.ssl.yml"

# sample DB is used https://www.ibm.com/docs/en/db2/11.5?topic=samples-sample-database
log "List tables"
docker exec -i ibmdb2 bash << EOF
su - db2inst1
db2 connect to sample user db2inst1 using passw0rd
db2 LIST TABLES
EOF

# https://www.ibm.com/docs/en/db2/11.5?topic=dsdjsss-configuring-connections-under-data-server-driver-jdbc-sqlj-use-ssl
log "Creating JDBC IBM DB2 source connector"
playground connector create-or-update --connector ibmdb2-source  << EOF
{
  "connector.class": "io.confluent.connect.jdbc.JdbcSourceConnector",
  "tasks.max": "1",
  "connection.url":"jdbc:db2://ibmdb2:50002/sample:retrieveMessagesFromServerOnGetMessage=true;sslConnection=true;sslTrustStoreLocation=/etc/kafka/secrets/truststore.jks;sslTrustStorePassword=confluent;sslTrustStoreType=JKS;",
  "connection.user":"db2inst1",
  "connection.password":"passw0rd",
  "mode": "bulk",
  "topic.prefix": "db2-",
  "errors.log.enable": "true",
  "errors.log.include.messages": "true"
}
EOF

sleep 15

log "Verifying topic db2-PURCHASEORDER"
playground topic consume --topic db2-PURCHASEORDER --min-expected-messages 2 --timeout 60


