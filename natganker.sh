#!/bin/bash

# Notes:
#   - we need to know elastic ip
#   - we need to know the instance id to scan routing tables
#     and take over any straggling routing tables still pointing
#     to old instance id
#     (therefore it is noy sufficient to only use elastic ip)

usage="usage: $0 <partner-instance-id> <shared-elastic-ip> [ping|ssh|forcefail]"

. /etc/profile.d/aws-apitools-common.sh

# if stdout is a terminal then set as "interactive mode"
# which redirects all output to the terminal (instead of syslog)
[ ! -t 1 ]
interactive_mode=$?

script_name=$(basename $0)

function log
{
    if [ $interactive_mode -eq 1 ]
    then
        echo "$1" >&2
    else
        logger -t $script_name -- $1;
    fi
}

function die
{
    [ -n "$1" ] && log "$1"
    log "$0 terminated due to failure"
    exit 1
}

function configure_pat
{
    local instance_id=$(ec2-metadata -i | awk '{print $2}') \
        || die "Failed to find my instance id"

    local eth0_mac=$(cat /sys/class/net/eth0/address) \
        || die "Unable to determine MAC address on eth0."
    log "eth0_mac=$eth0_mac"

    local vpc_cidr_uri="http://169.254.169.254/latest/meta-data/network/interfaces/macs/${eth0_mac}/vpc-ipv4-cidr-block"

    local vpc_cidr_range=$(curl --retry 3 --silent --fail ${vpc_cidr_uri})
    if [ $? -ne 0 ]
    then
        log "Unable to retrive VPC CIDR range from ${vpc_cidr_uri} falling back to 0.0.0.0/0"
        vpc_cidr_range='0.0.0.0/0'
    else
        log "Retrieved VPC CIDR range ${vpc_cidr_range} from meta-data."
    fi

    aws ec2 modify-instance-attribute --instance-id $instance_id \
        --source-dest-check '{ "Value": false }'                 \
        || die "failed to disable source destination check for $instance_id"
    log "disabled source destination check for $1"

    sysctl -q -w net.ipv4.ip_forward=1 net.ipv4.conf.eth0.send_redirects=0 || die "failed to run sysctl"
    if ! iptables -t nat -C POSTROUTING -o eth0 -s ${vpc_cidr_range} -j MASQUERADE 2> /dev/null
    then
        iptables -t nat -A POSTROUTING -o eth0 -s ${vpc_cidr_range} -j MASQUERADE \
            || die "failed to run iptables"
    fi
    log "enabled PAT"

    log "$(sysctl net.ipv4.ip_forward net.ipv4.conf.eth0.send_redirects)"
    log "$(iptables -n -t nat -L POSTROUTING)"

}

# immediately fail (for testing/simulation)
function test_forcefail_connection
{
    false
}

# this is an alternative to using test_ping_connection,
# useful if ICMP is blocked
function test_ssh_connection
{
    nc -w2 $1 22 2>&1 | egrep -iq 'SSH'
}

# ping will return with non-zero exit code if packet loss > 0%.
function test_ping_connection
{
    ping -w 4 -c 4 $1 >/dev/null 2>&1
}

function discover_routing_table_ids
{
    aws ec2 describe-route-tables                                     \
        --filters Name=route.destination-cidr-block,Values=0.0.0.0/0, \
                  Name=route.instance-id,Values=$1                    \
        --output json                                                 \
        | jq .RouteTables | jq -r .[].RouteTableId
}

# usage: replace_default_routes <instance-id> <routing-table-id> ...
function replace_default_routes
{
    local instance_id="$1"
    shift

    while [ $# -gt 0 ]
    do
    	aws ec2 replace-route --route-table-id $1 \
            --destination-cidr-block 0.0.0.0/0    \
            --instance-id $instance_id

        if [ $? -eq 0 ]
        then
            log "replaced default route for $1 to $instance_id"
        else
            log "failed to replace default route for $1 to $instance_id"
        fi

        shift
    done
}

log "starting $0"

[ "x$1" = x -o "x$2" = x ] && die "$usage"

partner_instance_id="$1"
elastic_ip="$2" 

log "partner_instance_id=$partner_instance_id"
log "elastic_ip=$elastic_ip"

health_check="$3"
health_check_func=test_ping_connection
if [ "x$health_check" != x ]
then
    case $health_check in
        ssh)
            health_check_func=test_ssh_connection
            log "health_check_func=test_ssh_connection"
            ;;
        ping)
            health_check_func=test_ping_connection
            log "health_check_func=test_ping_connection"
            ;;
        forcefail)
            health_check_func=test_forcefail_connection
            log "health_check_func=test_forcefail_connection"
            ;;
        *)
            die "$usage"
            ;;
    esac
fi

export AWS_DEFAULT_REGION=$(ec2-metadata -z | awk '{print $2}' | sed -e 's/[a-z]\+$//g')
[ -z "$AWS_DEFAULT_REGION" ] && die "failed to get AWS_DEFAULT_REGION"
log "AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"

log "[configuring PAT]"
configure_pat
log "[configuring PAT complete]"

my_instance_id=$(ec2-metadata -i | awk '{print $2}')
[ -z "$my_instance_id" ] && die "failed to get my_instance_id"
log "my_instance_id=$my_instance_id"

elastic_ip_allocation_id="$(
    aws ec2 describe-addresses                        \
        --filters Name=public-ip,Values="$elastic_ip" \
        --output json                                 \
        | grep 'AllocationId' | cut -d\" -f4          \
)"
[ -z "$elastic_ip_allocation_id" ] && die "failed to get elastic_ip_allocation_id"
log "elastic_ip_allocation_id=$elastic_ip_allocation_id"

elastic_ip_instance_id="$(
    aws ec2 describe-addresses                        \
        --filters Name=public-ip,Values="$elastic_ip" \
        --output json                                 \
        | grep InstanceId | cut -d\" -f4              \
)" || die 'failed to get elastic_ip_instance_id'
[ -z "$elastic_ip_instance_id" ] && die "failed to get elastic_ip_instance_id"
log "elastic_ip_instance_id=$elastic_ip_instance_id"

partner_instance_ip="$(
    aws ec2 describe-addresses                        \
        --filters Name=public-ip,Values="$elastic_ip" \
        --output json                                 \
        | grep PrivateIpAddress | cut -d\" -f4        \
)" || die 'failed to get partner_instance_ip'
[ -z "$partner_instance_ip" ] && die "failed to get partner_instance_ip"
log "partner_instance_ip=$partner_instance_ip"


# Outline:
#
# - (1) if the elastic ip is associated with our instance id then
#       * run idempotent takeover function, send alarm, exit
# - (2) if the elastic ip is not associated with the partner instance id (from cli argument)
#       * prematurely exit because this is an invalid state
# - (3) otherwise the elastic ip is associated with the partner instance id
#       * continuously perform health checks on partner
#       * if we reach a failure conditioin, run takeover funtion, send alarm, exit

# define idempotent takeover function
function takeover
{
    log "[commencing takeover]"
    log "ganking $elastic_ip from $elastic_ip_instance_id and associate with $my_instance_id"

    aws ec2 associate-address --instance-id $my_instance_id \
        --allocation-id $elastic_ip_allocation_id           \
        --allow-reassociation                               \
        || die "failed to associate address"

    log "[replacing route tables that default to $partner_instance_id]"
    routing_tables="$(discover_routing_table_ids $partner_instance_id)"
    for rtable in $routing_tables
    do
        log "  - replacing default route on $rtable from $partner_instance_id to $my_instance_id"
        replace_default_routes $my_instance_id $rtable
    done

    # log all routing tables that belong to this instance
    log "[verify route tables that default to $my_instance_id]"
    routing_tables="$(discover_routing_table_ids $my_instance_id)"
    for rtable in $routing_tables
    do
        log "  - $rtable defaults to $my_instance_id"
    done
    log "[commencing takeover complete]"

    exit 0
}

# - (1) if the elastic ip is associated with our instance id then
#       * run idempotent takeover function, send alarm, exit
if [ "$elastic_ip_instance_id" = "$my_instance_id" ]
then
    log "ERROR: The $elastic_ip is already associated with $my_instance_id - performing takeover"
    takeover
fi


# - (2) if the elastic ip is not associated with the partner instance id (from cli argument)
#       * prematurely exit because this is an invalid state
if [ "$elastic_ip_instance_id" != "$partner_instance_id" ]
then
    log "ERROR: The $elastic_ip is not associated with partner ($partner_instance_id) or myself ($my_instance_id) - invalid state, bailing"
    exit 1
fi


log "[begin healthcheck mode]"
# - (3) otherwise the elastic ip is associated with the partner instance id
#       * continuously perform health checks on partner
#       * if we reach a failure conditioin, run takeover funtion, send alarm, exit
while true
do
    if ! $health_check_func $partner_instance_ip
    then
        log "ERROR: $health_check_func $partner_instance_ip failed - performing takeover"
        takeover
    fi

    log "$(date +%s) $partner_instance_ip ($partner_instance_id) responded to $health_check"
    sleep 5
done

log "ERROR: invalid state"
exit 1
