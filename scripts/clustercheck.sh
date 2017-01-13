#!/bin/bash 
#
# Script to make a proxy (ie HAProxy) capable of monitoring Percona XtraDB Cluster nodes properly
#
# Authors:
# Raghavendra Prabhu <raghavendra.prabhu@percona.com>
# Olaf van Zandwijk <olaf.vanzandwijk@nedap.com>
#
# Based on the original script from Unai Rodriguez and Olaf (https://github.com/olafz/percona-clustercheck)
#
# Grant privileges required:
# GRANT PROCESS ON *.* TO 'clustercheckuser'@'localhost' IDENTIFIED BY 'clustercheckpassword!';


#### NOTE: THIS IS A MODIFIED SCRIPT THAT WILL ALSO MARK A NODE DOWN IF THE WSREP LOCAL SEND QUEUE IS HIGHER THAN 500

if [[ $1 == '-h' || $1 == '--help' ]];then
    echo "Usage: $0 <user> <pass> <available_when_donor=0|1> <log_file> <available_when_readonly=0|1> <defaults_extra_file>"
    exit
fi

MYSQL_USERNAME="${1-clustercheckuser}" 
MYSQL_PASSWORD="${2-clustercheckpassword!}" 
AVAILABLE_WHEN_DONOR=${3:-0}
ERR_FILE="${4:-/dev/null}" 
AVAILABLE_WHEN_READONLY=${5:-1}
DEFAULTS_EXTRA_FILE=${6:-/etc/my.cnf}
#Timeout exists for instances where mysqld may be hung
TIMEOUT=10

EXTRA_ARGS=""
if [[ -n "$MYSQL_USERNAME" ]]; then
    EXTRA_ARGS="$EXTRA_ARGS --user=${MYSQL_USERNAME}"
fi
if [[ -n "$MYSQL_PASSWORD" ]]; then
    EXTRA_ARGS="$EXTRA_ARGS --password=${MYSQL_PASSWORD}"
fi
if [[ -r $DEFAULTS_EXTRA_FILE ]];then 
    MYSQL_CMDLINE="mysql --defaults-extra-file=$DEFAULTS_EXTRA_FILE -nNE --connect-timeout=$TIMEOUT \
                    ${EXTRA_ARGS}"
else 
    MYSQL_CMDLINE="mysql -nNE --connect-timeout=$TIMEOUT ${EXTRA_ARGS}"
fi
#
# Perform the query to check the wsrep_local_state
#
WSREP_STATUS=($($MYSQL_CMDLINE -e "SHOW GLOBAL STATUS LIKE 'wsrep_%';"  \
    2>${ERR_FILE} | grep -A 1 -E 'wsrep_local_state$|wsrep_cluster_status$' \
    | sed -n -e '2p'  -e '5p' | tr '\n' ' '))

WSREP_SEND_QUEUE=($($MYSQL_CMDLINE -e "SHOW GLOBAL STATUS LIKE 'wsrep_local_send_queue';" 2>${ERR_FILE} | tail -n 1))

# add debug log, output the metrics collected above to a log file when WSREP_SEND_QUEUE is > 0
if [[ ${WSREP_SEND_QUEUE} -gt 0 ]]
then
    echo `date +"%x %H:%M:%S"`, ${WSREP_STATUS[0]}, ${WSREP_STATUS[1]}, ${WSREP_SEND_QUEUE} >> /data/clustercheck.log
fi

if [[ ${WSREP_STATUS[1]} == 'Primary' && ( ${WSREP_STATUS[0]} -eq 4 || \
    ( ${WSREP_STATUS[0]} -eq 2 && $AVAILABLE_WHEN_DONOR -eq 1 ) ) && \
    ${WSREP_SEND_QUEUE} -lt 501 ]]
then 

    # Check only when set to 0 to avoid latency in response.
    if [[ $AVAILABLE_WHEN_READONLY -eq 0 ]];then
        READ_ONLY=$($MYSQL_CMDLINE -e "SHOW GLOBAL VARIABLES LIKE 'read_only';" \
                    2>${ERR_FILE} | tail -1 2>>${ERR_FILE})

        if [[ "${READ_ONLY}" == "ON" ]];then 
            # Percona XtraDB Cluster node local state is 'Synced', but it is in
            # read-only mode. The variable AVAILABLE_WHEN_READONLY is set to 0.
            # => return HTTP 503
            # Shell return-code is 1
            echo -en "HTTP/1.1 503 Service Unavailable\r\n" 
            echo -en "Content-Type: text/plain\r\n" 
            echo -en "Connection: close\r\n" 
            echo -en "Content-Length: 43\r\n" 
            echo -en "\r\n" 
            echo -en "Percona XtraDB Cluster Node is read-only.\r\n" 
            sleep 0.1
            exit 1
        fi

    fi
    # Percona XtraDB Cluster node local state is 'Synced' => return HTTP 200
    # Shell return-code is 0
    echo -en "HTTP/1.1 200 OK\r\n" 
    echo -en "Content-Type: text/plain\r\n" 
    echo -en "Connection: close\r\n" 
    echo -en "Content-Length: 40\r\n" 
    echo -en "\r\n" 
    echo -en "Percona XtraDB Cluster Node is synced.\r\n" 
    sleep 0.1
    exit 0
else 
    # Percona XtraDB Cluster node local state is not 'Synced' => return HTTP 503
    # Shell return-code is 1
    echo -en "HTTP/1.1 503 Service Unavailable\r\n" 
    echo -en "Content-Type: text/plain\r\n" 
    echo -en "Connection: close\r\n" 
    echo -en "Content-Length: 57\r\n" 
    echo -en "\r\n" 
    echo -en "Percona XtraDB Cluster Node is not synced or non-PRIM or has a wsrep_local_send_queue > 500. \r\n" 
    sleep 0.1
    exit 1
fi 
