# inline_l2

## Requirements
AD server running to have DNS resolution.

## Global config steps
1. Configure sixth interface as inline interface with NAT, DHCP and DNS.
1. [ ] Configure SNAT (inline) on first interface (configured as dhcp-listener) not
       management.
1. Restart haproxy-port, pfdns, iptables, pfdhcp and pfdhcplistener services

## Scenario steps
Add steps

## Teardown steps
Add steps
