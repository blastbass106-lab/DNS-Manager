# DNS Manager
This is my first script to automate my Install for a DNS Server with the option to choose between Debain 13 (Trixie) and Fedora

# BIND9 DNS Manager & Zap Tracker

A robust, menu-driven Bash script designed to automate the installation, configuration, and management of a BIND9 DNS server on Debian (Trixie/Sid) and Fedora systems.
This tool was specifically developed to handle the transition from DHCP to Static IP while providing a "Zap Journal" to track deployment events for system auditing and personal sanity.


## Features

- One-Touch Installation: Automates package installation, firewall-ready BIND options, and zone file generation.
- Intelligent Network Setup: Handles the transition to a Static IP and configures systemd-resolved to use the local DNS.
- Zone Management: Easily add or delete host entries (A records and PTR records) with automatic serial number incrementing to ensure zone propagation.
- Zap Journaling: Automatically logs the exact time of installations and purges to zap_tracker.log, helping you monitor the intervals between system "Zaps".
- Factory Reset: A full purge option that reverts the system to DHCP and removes all BIND configurations.


# 🛠 Prerequisites

- A fresh or existing install of Debian or Fedora.
- Root or sudo privileges.
- An active internet connection for the initial "Bootstrap" phase.

