#!/bin/sh
#
# Script for automatic setup of an IPsec VPN server on CentOS/RHEL 6 and 7.
# Works on any dedicated server or Virtual Private Server (VPS) except OpenVZ.
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC! THIS IS MEANT TO BE RUN
# ON A DEDICATED SERVER OR VPS!
#
# Copyright (C) 2015-2016 Lin Song <linsongui@gmail.com>
# Based on the work of Thomas Sarlandie (Copyright 2012)
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# =====================================================

# Define your own values for these variables
# - IPsec pre-shared key, VPN username and password
# - All values MUST be placed inside 'single quotes'
# - DO NOT use these characters within values:  \ " '

YOUR_IPSEC_PSK=''
YOUR_USERNAME=''
YOUR_PASSWORD=''
export YOUR_IPSEC_PSK=`cat ~/.vpn_ipsec_psk`
export YOUR_USERNAME=`cat ~/.vpn_user_name`
export YOUR_PASSWORD=`cat ~/.vpn_password`

# Important notes:   https://git.io/vpnnotes
# Setup VPN clients: https://git.io/vpnclients

# =====================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exiterr()  { echo "Error: ${1}" >&2; exit 1; }
exiterr2() { echo "Error: 'yum install' failed." >&2; exit 1; }
check_ip() {
  IP_REGEX="^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
  printf %s "${1}" | tr -d '\n' | grep -Eq "$IP_REGEX"
}

if [ ! -f /etc/redhat-release ]; then
  exiterr "This script only supports CentOS/RHEL."
fi

if ! grep -qs -e "release 6" -e "release 7" /etc/redhat-release; then
  exiterr "This script only supports CentOS/RHEL 6 and 7."
fi

if [ -f /proc/user_beancounters ]; then
  exiterr "This script does not support OpenVZ VPS."
fi

if [ "$(id -u)" != 0 ]; then
  exiterr "Script must be run as root. Try 'sudo sh $0'"
fi

em1_state=$(cat /sys/class/net/em1/operstate 2>/dev/null)
if [ -z "$em1_state" ] || [ "$em1_state" = "down" ]; then
cat 1>&2 <<'EOF'
Error: Network interface 'em1' is not available.

Please DO NOT run this script on your PC or Mac!

Run 'cat /proc/net/dev' to find the active network interface,
then use it to replace ALL 'em1' and 'em+' in this script.
EOF
  exit 1
fi

[ -n "$YOUR_IPSEC_PSK" ] && VPN_IPSEC_PSK="$YOUR_IPSEC_PSK"
[ -n "$YOUR_USERNAME" ] && VPN_USER="$YOUR_USERNAME"
[ -n "$YOUR_PASSWORD" ] && VPN_PASSWORD="$YOUR_PASSWORD"

if [ -z "$VPN_IPSEC_PSK" ] && [ -z "$VPN_USER" ] && [ -z "$VPN_PASSWORD" ]; then
  echo "VPN credentials not set by user. Generating random PSK and password..."
  echo
  VPN_IPSEC_PSK="$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)"
  VPN_USER=vpnuser
  VPN_PASSWORD="$(LC_CTYPE=C tr -dc 'A-HJ-NPR-Za-km-z2-9' < /dev/urandom | head -c 16)"
fi

if [ -z "$VPN_IPSEC_PSK" ] || [ -z "$VPN_USER" ] || [ -z "$VPN_PASSWORD" ]; then
  exiterr "All VPN credentials must be specified. Edit the script and re-enter them."
fi

case "$VPN_IPSEC_PSK $VPN_USER $VPN_PASSWORD" in
  *[\\\"\']*)
    exiterr "VPN credentials must not contain any of these characters: \\ \" '"
    ;;
esac

echo "VPN setup in progress... Please be patient."
echo

# Create and change to working dir
mkdir -p /opt/src
cd /opt/src || exiterr "Cannot enter /opt/src."

# Make sure basic commands exist
yum -y install wget bind-utils openssl || exiterr2
yum -y install iproute gawk grep sed net-tools || exiterr2

cat <<'EOF'

Trying to auto discover IPs of this server...

In case the script hangs here for more than a few minutes,
use Ctrl-C to interrupt. Then edit it and manually enter IPs.

EOF

# In case auto IP discovery fails, you may manually enter server IPs here.
# If your server only has a public IP, put that public IP on both lines.
PUBLIC_IP=${VPN_PUBLIC_IP:-''}
PRIVATE_IP=${VPN_PRIVATE_IP:-''}

# Try to auto discover IPs of this server
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(dig @resolver1.opendns.com -t A -4 myip.opendns.com +short)
[ -z "$PRIVATE_IP" ] && PRIVATE_IP=$(ip -4 route get 1 | awk '{print $NF;exit}')

# Check IPs for correct format
check_ip "$PUBLIC_IP" || PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://whatismyip.akamai.com)
check_ip "$PUBLIC_IP" || PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
check_ip "$PUBLIC_IP" || exiterr "Cannot find valid public IP. Edit the script and manually enter IPs."
check_ip "$PRIVATE_IP" || PRIVATE_IP=$(ifconfig em1 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')
check_ip "$PRIVATE_IP" || exiterr "Cannot find valid private IP. Edit the script and manually enter IPs."

# Add the EPEL repository
#yum -y install epel-release || exiterr2

# Install necessary packages
yum -y install nss-devel nspr-devel pkgconfig pam-devel \
  libcap-ng-devel libselinux-devel \
  curl-devel flex bison gcc make \
  fipscheck-devel unbound-devel xmlto || exiterr2
yum -y install ppp xl2tpd || exiterr2

# Install Fail2Ban to protect SSH server
yum -y install fail2ban || exiterr2

# Install libevent2 and systemd-devel
if grep -qs "release 6" /etc/redhat-release; then
  yum -y remove libevent-devel
  yum -y install libevent2-devel || exiterr2
elif grep -qs "release 7" /etc/redhat-release; then
  yum -y install libevent-devel systemd-devel || exiterr2
fi

# Compile and install Libreswan
#swan_ver=3.18
#swan_file="libreswan-$swan_ver.tar.gz"
#swan_url1="https://download.libreswan.org/$swan_file"
#swan_url2="https://github.com/libreswan/libreswan/archive/v$swan_ver.tar.gz"
#wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url1" || wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url2"
#[ "$?" != "0" ] && exiterr "Cannot download Libreswan source."
#/bin/rm -rf "/opt/src/libreswan-$swan_ver"
#tar xzf "$swan_file" && /bin/rm -f "$swan_file"
#cd "libreswan-$swan_ver" || exiterr "Cannot enter Libreswan source dir."
#echo "WERROR_CFLAGS =" > Makefile.inc.local
#make -s programs && make -s install

# Verify the install and clean up
#cd /opt/src || exiterr "Cannot enter /opt/src."
#/bin/rm -rf "/opt/src/libreswan-$swan_ver"
#/usr/local/sbin/ipsec --version 2>/dev/null | grep -qs "$swan_ver"
#[ "$?" != "0" ] && exiterr "Libreswan $swan_ver failed to build."

# Create IPsec (Libreswan) config
sys_dt="$(date +%Y-%m-%d-%H:%M:%S)"
/bin/cp -f /etc/ipsec.conf "/etc/ipsec.conf.old-$sys_dt" 2>/dev/null
cat > /etc/ipsec.conf <<EOF
version 2.0

config setup
  nat_traversal=yes
  virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:!192.168.42.0/23
  protostack=netkey
  nhelpers=0
  interfaces=%defaultroute
  uniqueids=no

conn shared
  left=$PRIVATE_IP
  leftid=$PUBLIC_IP
  right=%any
  forceencaps=yes
  authby=secret
  pfs=no
  rekey=no
  keyingtries=5
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear
  ike=3des-sha1,aes-sha1,aes256-sha2_512,aes256-sha2_256
  phase2alg=3des-sha1,aes-sha1,aes256-sha2_512,aes256-sha2_256
  sha2-truncbug=yes

conn l2tp-psk
  auto=add
  leftsubnet=$PRIVATE_IP/32
  leftnexthop=%defaultroute
  leftprotoport=17/1701
  rightprotoport=17/%any
  type=transport
  auth=esp
  also=shared

conn xauth-psk
  auto=add
  leftsubnet=0.0.0.0/0
  rightaddresspool=192.168.43.10-192.168.43.250
  modecfgdns1=10.200.0.1
  modecfgdns2=10.200.0.2
  leftxauthserver=yes
  rightxauthclient=yes
  leftmodecfgserver=yes
  rightmodecfgclient=yes
  modecfgpull=yes
  xauthby=file
  ike-frag=yes
  ikev2=never
  cisco-unity=yes
  also=shared
EOF

# Specify IPsec PSK
/bin/cp -f /etc/ipsec.secrets "/etc/ipsec.secrets.old-$sys_dt" 2>/dev/null
cat > /etc/ipsec.secrets <<EOF
$PUBLIC_IP  %any  : PSK "$VPN_IPSEC_PSK"
EOF

# Create xl2tpd config
/bin/cp -f /etc/xl2tpd/xl2tpd.conf "/etc/xl2tpd/xl2tpd.conf.old-$sys_dt" 2>/dev/null
cat > /etc/xl2tpd/xl2tpd.conf <<'EOF'
[global]
port = 1701

[lns default]
ip range = 192.168.42.10-192.168.42.250
local ip = 192.168.42.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# Set xl2tpd options
/bin/cp -f /etc/ppp/options.xl2tpd "/etc/ppp/options.xl2tpd.old-$sys_dt" 2>/dev/null
cat > /etc/ppp/options.xl2tpd <<'EOF'
ipcp-accept-local
ipcp-accept-remote
ms-dns 10.200.0.1
ms-dns 10.200.0.2
noccp
auth
crtscts
mtu 1280
mru 1280
lock
proxyarp
lcp-echo-failure 4
lcp-echo-interval 30
connect-delay 5000
EOF

# Create VPN credentials
/bin/cp -f /etc/ppp/chap-secrets "/etc/ppp/chap-secrets.old-$sys_dt" 2>/dev/null
cat > /etc/ppp/chap-secrets <<EOF
# Secrets for authentication using CHAP
# client  server  secret  IP addresses
"$VPN_USER" l2tpd "$VPN_PASSWORD" *
EOF

/bin/cp -f /etc/ipsec.d/passwd "/etc/ipsec.d/passwd.old-$sys_dt" 2>/dev/null
VPN_PASSWORD_ENC=$(openssl passwd -1 "$VPN_PASSWORD")
cat > /etc/ipsec.d/passwd <<EOF
$VPN_USER:$VPN_PASSWORD_ENC:xauth-psk
EOF

# Update sysctl settings
if ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf; then
  /bin/cp -f /etc/sysctl.conf "/etc/sysctl.conf.old-$sys_dt" 2>/dev/null
cat >> /etc/sysctl.conf <<'EOF'

# Added by hwdsl2 VPN script
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.shmmax = 68719476736
kernel.shmall = 4294967296

net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.lo.send_redirects = 0
net.ipv4.conf.em1.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.lo.rp_filter = 0
net.ipv4.conf.em1.rp_filter = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

net.core.wmem_max = 12582912
net.core.rmem_max = 12582912
net.ipv4.tcp_rmem = 10240 87380 12582912
net.ipv4.tcp_wmem = 10240 87380 12582912
EOF
fi

# Check if IPTables rules need updating
ipt_flag=0
if ! grep -qs "hwdsl2 VPN script" /etc/sysconfig/iptables; then
  ipt_flag=1
elif ! iptables -t nat -C POSTROUTING -s 192.168.42.0/24 -o em+ -j SNAT --to-source "$PRIVATE_IP" 2>/dev/null; then
  ipt_flag=1
elif ! iptables -t nat -C POSTROUTING -s 192.168.43.0/24 -o em+ -m policy --dir out --pol none -j SNAT --to-source "$PRIVATE_IP" 2>/dev/null; then
  ipt_flag=1
fi

# Create basic IPTables rules
# - If IPTables is "empty", write out the entire new rule set.
# - If *not* empty, insert only the required rules for the VPN.
if [ "$ipt_flag" = "1" ]; then
  service fail2ban stop >/dev/null 2>&1
  iptables-save > "/etc/sysconfig/iptables.old-$sys_dt"
  sshd_port="$(ss -nlput | grep sshd | awk '{print $5}' | head -n 1 | grep -Eo '[0-9]{1,5}$')"
  if [ "$(iptables-save | grep -c '^\-')" = "0" ] && [ "$sshd_port" = "22" ]; then
cat > /etc/sysconfig/iptables <<EOF
# Added by hwdsl2 VPN script
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -d 127.0.0.0/8 -j REJECT
-A INPUT -p icmp -j ACCEPT
-A INPUT -p udp --dport 67:68 --sport 67:68 -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p udp -m multiport --dports 500,4500 -j ACCEPT
-A INPUT -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
-A INPUT -p udp --dport 1701 -j DROP
-A INPUT -j DROP
-A FORWARD -m conntrack --ctstate INVALID -j DROP
# Uncomment to DROP traffic between VPN clients themselves
# -A FORWARD -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j DROP
# -A FORWARD -s 192.168.43.0/24 -d 192.168.43.0/24 -j DROP
-A FORWARD -i em+ -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -i ppp+ -o em+ -j ACCEPT
-A FORWARD -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j ACCEPT
-A FORWARD -i em+ -d 192.168.43.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -s 192.168.43.0/24 -o em+ -j ACCEPT
-A FORWARD -j DROP
COMMIT
*nat
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 192.168.42.0/24 -o em+ -j SNAT --to-source $PRIVATE_IP
-A POSTROUTING -s 192.168.43.0/24 -o em+ -m policy --dir out --pol none -j SNAT --to-source $PRIVATE_IP
COMMIT
EOF
  else
    iptables -I INPUT 1 -p udp -m multiport --dports 500,4500 -j ACCEPT
    iptables -I INPUT 2 -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
    iptables -I INPUT 3 -p udp --dport 1701 -j DROP
    iptables -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
    iptables -I FORWARD 2 -i em+ -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -I FORWARD 3 -i ppp+ -o em+ -j ACCEPT
    iptables -I FORWARD 4 -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j ACCEPT
    iptables -I FORWARD 5 -i em+ -d 192.168.43.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -I FORWARD 6 -s 192.168.43.0/24 -o em+ -j ACCEPT
    iptables -I FORWARD 7 -i em1 -s 10.200.0.0/24  -j ACCEPT
    iptables -I FORWARD 8 -o em1 -d 10.200.0.0/24  -j ACCEPT
    # Uncomment to DROP traffic between VPN clients themselves
    # iptables -I FORWARD 2 -i ppp+ -o ppp+ -s 192.168.42.0/24 -d 192.168.42.0/24 -j DROP
    # iptables -I FORWARD 3 -s 192.168.43.0/24 -d 192.168.43.0/24 -j DROP
    iptables -A FORWARD -j DROP
    iptables -t nat -I POSTROUTING -s 192.168.43.0/24 -o em+ -m policy --dir out --pol none -j SNAT --to-source "$PRIVATE_IP"
    iptables -t nat -I POSTROUTING -s 192.168.42.0/24 -o em+ -j SNAT --to-source "$PRIVATE_IP"
    echo "# Modified by hwdsl2 VPN script" > /etc/sysconfig/iptables
    iptables-save >> /etc/sysconfig/iptables
  fi
fi

# Create basic Fail2Ban rules
if [ ! -f /etc/fail2ban/jail.local ] ; then
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 600
findtime  = 600
maxretry = 5
backend = auto

[ssh-iptables]
enabled  = true
filter   = sshd
action   = iptables[name=SSH, port=ssh, protocol=tcp]
logpath  = /var/log/secure
EOF
fi

# Start services at boot
if ! grep -qs "hwdsl2 VPN script" /etc/rc.local; then
  /bin/cp -f /etc/rc.local "/etc/rc.local.old-$sys_dt" 2>/dev/null
cat >> /etc/rc.local <<'EOF'

# Added by hwdsl2 VPN script
iptables-restore < /etc/sysconfig/iptables
service fail2ban restart
service ipsec start
service xl2tpd start
echo 1 > /proc/sys/net/ipv4/ip_forward
EOF
fi

# Restore SELinux contexts
restorecon /etc/ipsec.d/*db 2>/dev/null
restorecon /usr/local/sbin -Rv 2>/dev/null
restorecon /usr/local/libexec/ipsec -Rv 2>/dev/null

# Reload sysctl.conf
sysctl -e -q -p

# Update file attributes
chmod +x /etc/rc.local
chmod 600 /etc/ipsec.secrets* /etc/ppp/chap-secrets* /etc/ipsec.d/passwd*

# Apply new IPTables rules
iptables-restore < /etc/sysconfig/iptables

# Restart services
service fail2ban stop >/dev/null 2>&1
service ipsec stop >/dev/null 2>&1
service xl2tpd stop >/dev/null 2>&1
service fail2ban start
service ipsec start
service xl2tpd start

cat <<EOF

================================================

IPsec VPN server is now ready for use!

Connect to your new VPN with these details:

Server IP: $PUBLIC_IP
IPsec PSK: $VPN_IPSEC_PSK
Username: $VPN_USER
Password: $VPN_PASSWORD

Write these down. You'll need them to connect!

Important notes:   https://git.io/vpnnotes
Setup VPN clients: https://git.io/vpnclients

================================================

EOF

exit 0
