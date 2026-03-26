#!/bin/bash

LOG_FILE="Audit.log"

# --- 1. Bootstrap DNS ---
echo "Bootstrapping DNS to allow package downloads..."
sudo rm -f /etc/resolv.conf 
echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf > /dev/null

# --- OS Detection ---
if [ -f /etc/debian_version ]; then
    OS="Debian"
    PKGS="bind9 dnsutils systemd-resolved"
    BIND_SVC="bind9"
    BIND_DIR="/etc/bind"
    BIND_USER="bind"
elif [ -f /etc/fedora-release ]; then
    OS="Fedora"
    PKGS="bind bind-utils"
    BIND_SVC="named"
    BIND_DIR="/etc/named"
    BIND_USER="named"
else
    echo "Unsupported OS."
    exit 1
fi

# --- Interface Detection ---
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$INTERFACE" ]; then
    INTERFACE=$(ip -o link show | awk -F': ' '$3 !~ /lo|virbr/ && /state UP/ {print $2}' | head -n1)
fi

# --- THE LOOP ---
while true; do
    # NEW IMPROVED LOADER:
    if [ -f "$BIND_DIR/named.conf.local" ]; then
        # Looks for the domain name inside the quotes of the zone definition
        DOMAIN=$(grep 'zone "' "$BIND_DIR/named.conf.local" | head -n1 | awk -F'"' '{print $2}')
        # Looks for the reverse zone name
        REVERSE_ZONE=$(grep 'zone "' "$BIND_DIR/named.conf.local" | tail -n1 | awk -F'"' '{print $2}' | sed 's/.in-addr.arpa//')
    fi
    
    echo "------------------------------------------"
    echo " DNS MANAGER"
    echo " OS: $OS | Interface: $INTERFACE"
    echo " Domain: ${DOMAIN:-Not Set}"
    echo "------------------------------------------"
    echo "1) Install/Configure DNS & Static IP"
    echo "2) Uninstall & Full Purge (Factory Reset)"
    echo "3) Manage Host Entries (Add/Delete)"
    echo "4) Show current Host Entries"
    echo "0) Exit"
    echo "------------------------------------------"
    read -p "Selection: " CHOICE

    case $CHOICE in
        1)
            # Log the start for your Zap/Sanity tracker
            echo "[$(date)] START: Installation on $OS." >> "$LOG_FILE"

            if [ "$OS" == "Debian" ]; then
                sudo apt-get update -y
                sudo apt-get install -y $PKGS
            else
                sudo dnf install -y $PKGS
            fi

            read -p "Enter Static IP: " STATIC_IP
            read -p "Enter Gateway: " GATEWAY
            read -p "Enter Domain (e.g. stjosephs.sbs): " DOMAIN
            read -p "Enter Hostname (e.g. dns): " HOSTNAME

            REVERSE_ZONE=$(echo $STATIC_IP | awk -F. '{print $3"."$2"."$1}')
            HOST_PART=$(echo $STATIC_IP | awk -F. '{print $4}')

            if [ "$OS" == "Debian" ]; then
                sudo dhclient -r $INTERFACE 2>/dev/null || true
                sudo pkill dhclient || true
                sudo ip addr flush dev $INTERFACE
                sudo tee /etc/network/interfaces > /dev/null <<EOF
auto lo
iface lo inet loopback
auto $INTERFACE
iface $INTERFACE inet static
    address $STATIC_IP
    netmask 255.255.255.0
    gateway $GATEWAY
EOF
                sudo systemctl restart networking
            else
                sudo nmcli device modify "$INTERFACE" ipv4.method manual ipv4.addresses "$STATIC_IP/24" ipv4.gateway "$GATEWAY"
                sudo nmcli device down "$INTERFACE" && sudo nmcli device up "$INTERFACE"
            fi

            sudo mkdir -p "$BIND_DIR/zones"
            sudo tee "$BIND_DIR/named.conf.options" > /dev/null <<EOF
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-query { any; };
    forwarders { 8.8.8.8; 8.8.4.4; };
    dnssec-validation auto;
    listen-on-v6 { any; };
};
EOF

            sudo tee "$BIND_DIR/named.conf.local" > /dev/null <<EOF
zone "$DOMAIN" { type master; file "$BIND_DIR/zones/db.$DOMAIN"; };
zone "$REVERSE_ZONE.in-addr.arpa" { type master; file "$BIND_DIR/zones/db.$REVERSE_ZONE"; };
EOF
            
            read -p "Would you like to build your DNS host entries now? (y/n): " BUILD_ENTRIES
            if [[ "$BUILD_ENTRIES" =~ ^[Yy]$ ]]; then
                sudo tee "$BIND_DIR/zones/db.$DOMAIN" > /dev/null <<EOF
\$TTL 604800
@ IN SOA $HOSTNAME.$DOMAIN. root.$DOMAIN. ( 3 604800 86400 2419200 604800 )
@ IN NS $HOSTNAME.$DOMAIN.
$HOSTNAME IN A $STATIC_IP
EOF
                sudo tee "$BIND_DIR/zones/db.$REVERSE_ZONE" > /dev/null <<EOF
\$ORIGIN $REVERSE_ZONE.in-addr.arpa.
\$TTL 604800
@ IN SOA $HOSTNAME.$DOMAIN. root.$DOMAIN. ( 3 604800 86400 2419200 604800 )
@ IN NS $HOSTNAME.$DOMAIN.
$HOST_PART IN PTR $HOSTNAME.$DOMAIN.
EOF
                while true; do
                    read -p "Host Name (or 'done'): " NEW_HOST
                    [[ "$NEW_HOST" == "done" ]] && break
                    read -p "IP for $NEW_HOST: " NEW_IP
                    echo "$NEW_HOST IN A $NEW_IP" | sudo tee -a "$BIND_DIR/zones/db.$DOMAIN" > /dev/null
                    N_PART=$(echo $NEW_IP | awk -F. '{print $4}')
                    echo "$N_PART IN PTR $NEW_HOST.$DOMAIN." | sudo tee -a "$BIND_DIR/zones/db.$REVERSE_ZONE" > /dev/null
                done
            fi

            sudo chown -R $BIND_USER:$BIND_USER "$BIND_DIR"
            sudo systemctl enable --now systemd-resolved
            sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
            sudo systemctl restart $BIND_SVC
            sudo resolvectl dns $INTERFACE 127.0.0.1
            sudo resolvectl domain $INTERFACE $DOMAIN

            echo "[$(date)] SUCCESS: Deployment complete." >> "$LOG_FILE"
            read -p "Press Enter..." PAUSE
            ;;

        2)
            echo "Purging BIND and reverting to DHCP..."
            if [ "$OS" == "Debian" ]; then
                sudo tee /etc/network/interfaces > /dev/null <<EOF
auto lo
iface lo inet loopback
auto $INTERFACE
iface $INTERFACE inet dhcp
EOF
                sudo ip addr flush dev $INTERFACE
                sudo systemctl restart networking
                sudo apt-get purge -y $PKGS
                sudo rm -rf /etc/bind /var/cache/bind /var/lib/bind
                sudo apt-get autoremove -y
            else
                sudo nmcli device modify "$INTERFACE" ipv4.method auto
                sudo nmcli device up "$INTERFACE"
                sudo dnf remove -y bind
                sudo rm -rf /etc/named /var/named
            fi
            sudo rm -f /etc/resolv.conf
            sudo ip link set $INTERFACE down && sudo ip link set $INTERFACE up        
            echo "[$(date)] UNINSTALL: Clean purge completed." >> "$LOG_FILE"
            read -p "Press Enter..." PAUSE
            ;;

        3)
            if [ -z "$DOMAIN" ]; then echo "Run Option 1 first."; else
                F_ZONE="$BIND_DIR/zones/db.$DOMAIN"; R_ZONE="$BIND_DIR/zones/db.$REVERSE_ZONE"
                read -p "1) Add | 2) Delete: " MGMT
                read -p "Host: " M_HOST
                if [ "$MGMT" == "1" ]; then
                    read -p "IP: " M_IP
                    echo "$M_HOST IN A $M_IP" | sudo tee -a "$F_ZONE" > /dev/null
                    M_PART=$(echo $M_IP | awk -F. '{print $4}')
                    echo "$M_PART IN PTR $M_HOST.$DOMAIN." | sudo tee -a "$R_ZONE" > /dev/null
                else
                    sudo sed -i "/^$M_HOST[[:space:]]/d" "$F_ZONE"
                    sudo sed -i "/PTR[[:space:]]\+$M_HOST.$DOMAIN./d" "$R_ZONE"
                fi
                sudo systemctl restart $BIND_SVC
            fi
            read -p "Done. Press Enter..." PAUSE
            ;;

        4)
            echo "------------------------------------------"
            echo "   CURRENT DNS ENTRIES ($DOMAIN)"
            echo "------------------------------------------"
            printf "%-25s %-15s\n" "FQDN" "IP ADDRESS"
            echo "------------------------------------------"
            if [ -f "$BIND_DIR/zones/db.$DOMAIN" ]; then
                # This filter targets lines with 'IN A' and cleans up the hostname
                grep "IN[[:space:]]\+A" "$BIND_DIR/zones/db.$DOMAIN" | while read -r line; do
                    H=$(echo "$line" | awk '{print $1}')
                    I=$(echo "$line" | awk '{print $4}')
                    
                    # Logic: If the hostname already contains the domain, don't append it again
                    if [[ "$H" == *"$DOMAIN"* ]]; then
                        FULL_HOST="$H"
                    else
                        FULL_HOST="$H.$DOMAIN"
                    fi
                    
                    printf "%-25s %-15s\n" "$FULL_HOST" "$I"
                done
            else
                echo "No zone file found for $DOMAIN"
            fi
            echo "------------------------------------------"
            read -p "Press Enter to return to menu..."
            ;;

        0) exit 0 ;;
        *) echo "Invalid selection."; sleep 1 ;;
    esac
done