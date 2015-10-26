# natganker
KISS NAT takeover for Amazon AWS

## High-Level Overview

```
┌─────────────────────────────────────────────────────────┐
│                       Amazon VPC                        │
│     ┏━━━━━━━━━━┓                           ┌ ─ ─ ─ ─ ─  │
│     ┃ nat-gw-1 ┃─────ssh/ping heartbeat────  nat-gw-2 │ │
│     ┗━━━━━━━━━━┛                           └ ─ ─ ─ ─ ─  │
│           │                                             │
│           │                                             │
│           ├────────────────────────┐                    │
│           │                        │                    │
│           │                        │                    │
│           │                        │                    │
│ ┌─── rtr-table-a ──┐     ┌─── rtr-table-b ──┐           │
│ │ ┌~~~~~~~~~~~~~~┐ │     │ ┌~~~~~~~~~~~~~~┐ │           │
│ │ │   subnet 1   │ │     │ │   subnet 3   │ │           │
│ │ └~~~~~~~~~~~~~~┘ │     │ └~~~~~~~~~~~~~~┘ │           │
│ │ ┌~~~~~~~~~~~~~~┐ │     │ ┌~~~~~~~~~~~~~~┐ │           │
│ │ │   subnet 2   │ │     │ │   subnet 4   │ │           │
│ │ └~~~~~~~~~~~~~~┘ │     │ └~~~~~~~~~~~~~~┘ │           │
│ └──────────────────┘     └──────────────────┘           │
└─────────────────────────────────────────────────────────┘
                             │
                             │heartbeat failure
                             │
                             ▼
┌─────────────────────────────────────────────────────────┐
│                       Amazon VPC                        │
│     ┌ ─ ─ ─ ─ ─                            ┏━━━━━━━━━━┓ │
│       nat-gw-1 │─────ssh/ping heartbeat────┃ nat-gw-2 ┃ │
│     └ ─ ─ ─ ─ ─                            ┗━━━━━━━━━━┛ │
│                                                  │      │
│                                                  │      │
│           ┌────────────────────────┬─────────────┘      │
│           │                        │                    │
│           │                        │                    │
│           │                        │                    │
│ ┌─── rtr-table-a ──┐     ┌─── rtr-table-b ──┐           │
│ │ ┌~~~~~~~~~~~~~~┐ │     │ ┌~~~~~~~~~~~~~~┐ │           │
│ │ │   subnet 1   │ │     │ │   subnet 3   │ │           │
│ │ └~~~~~~~~~~~~~~┘ │     │ └~~~~~~~~~~~~~~┘ │           │
│ │ ┌~~~~~~~~~~~~~~┐ │     │ ┌~~~~~~~~~~~~~~┐ │           │
│ │ │   subnet 2   │ │     │ │   subnet 4   │ │           │
│ │ └~~~~~~~~~~~~~~┘ │     │ └~~~~~~~~~~~~~~┘ │           │
│ └──────────────────┘     └──────────────────┘           │
└─────────────────────────────────────────────────────────┘

Created with Monodraw
```

## Requirements

* Two NAT gateways:
    - Primary: actively forwards traffic and is associated with an elastic IP.
    - Secondary: runs natganker to passively monitor the primary instance and takeover if a healthcheck fails.

* Both gateways must be able to perform healthchecks over the internal IP, this usually requires ping or SSH among the NAT gateway nodes over the internal IP.

* The primary NAT gateway instance should be the default route for routing tables in the region.

* Both NAT instances requires the following IAM roles:
    - ec2:DescribeInstances
    - ec2:ModifyInstanceAttribute
    - ec2:DescribeAddresses
    - ec2:AssociateAddress
    - ec2:DisassociateAddress
    - ec2:DescribeSubnets
    - ec2:DescribeRouteTables
    - ec2:CreateRoute
    - ec2:ReplaceRoute

## Usage

There are three ways to run natganker:

1. Run on secondary NAT gateway and perform ping health check:
    - `./natganker.sh <primary-nat-instance-id> <primary-nat-elastic-ip>`

2. Run on secondary NAT gateway and perform SSH health check:
    - `./natganker.sh <primary-nat-instance-id> <primary-nat-elastic-ip> ssh`

3. Force failover to secondary NAT gateway:
    - `./natganker.sh <primary-nat-instance-id> <primary-nat-elastic-ip> forcefail`

In (1) and (2) if a healthcheck fails, then the secondary NAT will replace itself as default route for all route tables defaulting to the primary NAT gateway. The script is idempotent so it can be rerun and will perform any necessary operations until the secondary NAT has the associated elastic IP and is the default route for all associated routing tables.

### Using Monit

To ensure the script runs persistently you can use [monit](http://mmonit.com/).

Here is an example configuration file which is placed in `/etc/monit.d/natganker`:

```
check process natganker matching bash.*natganker
   start program = "/root/natganker/natganker.sh <primary-nat-instance-id> <primary-nat-elastic-ip>" as uid "root" and gid "root"
   stop program = "/usr/bin/pkill -f bash.*natganker" as uid "root" and gid "root"
```
