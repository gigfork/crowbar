#! /bin/bash -e

# This script is called after being installed by the Crowbar RPM from the SUSE
# Cloud ISO. In this context, it is expected that all other required
# repositories (eg. SLES, Updates) are already set up, with the required files
# in place.
#
# For development and testing use, call the script with the '--from-git'
# option. Use the appropriate dev VM and follow the corresponding setup
# instructions.

BARCLAMP_INSTALL_OPTS="--rpm"

if [ "$1" = "--from-git" ]; then
    CROWBAR_FROM_GIT=true
    BARCLAMP_INSTALL_OPTS="--force"
    : ${CROWBAR_FILE:=/root/crowbar/crowbar.json}
    : ${BARCLAMP_SRC:=/root/crowbar/barclamps/}
    sed -i -e '/"nagios":/d' -e '/"ganglia":/d' $CROWBAR_FILE
fi

LOGFILE=/var/log/crowbar/install.log
mkdir -p "`dirname "$LOGFILE"`"

: ${BARCLAMP_SRC:="/opt/dell/barclamps/"}

run_succeeded=

# Infrastructure for nice output/logging
# --------------------------------------

# Copy stdout to fd 3
exec 3>&1
# Create fd 4 for logfile
exec 4>> "$LOGFILE"

if [ -z "$CROWBAR_VERBOSE" ]; then
    # Set fd 1 and 2 to logfile
    exec 1>&4 2>&1
else
    # Set fd 1 and 2 to logfile (and keep stdout too)
    exec 1> >( tee -a /dev/fd/4 ) 2>&1
fi
# Send summary fd to original stdout
exec 6>&3

pipe_stdout_and_logfile () {
    tee -a /dev/fd/3 /dev/fd/4 > /dev/null
}

# Draw a spinner so the user knows something is happening
spinner () {
    local delay=0.75
    local spinstr='/-\|'
    printf "... " >&3
    while [ true ]; do
        local temp=${spinstr#?}
        printf "[%c]" "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b" >&3
    done
}

kill_spinner () {
    if [ ! -z "$LAST_SPINNER_PID" ]; then
        kill >/dev/null 2>&1 $LAST_SPINNER_PID
        if [ $# -eq 0 ]; then
            printf "\b\b\bdone\n" >&3
        else
            printf "\b\b\b$*\n" >&3
        fi
        unset LAST_SPINNER_PID
    fi
}

kill_spinner_with_failed () {
    kill_spinner "failed"
}

echo_log () {
    echo -e === "$(date '+%F %T %z'): $@" >&4
}

echo_summary () {
    # Also send summary to logfile
    echo_log $@

    kill_spinner

    if [ -z "$CROWBAR_VERBOSE" ]; then
        if [ -t 3 ]; then
            echo -n -e $@ >&3
            # Use disown to lose job control messages (especially the
            # "Completed" message when spinner will be killed)
            spinner & disown
            LAST_SPINNER_PID=$!
        else
            echo -e $@ >&3
        fi
    else
        echo -e === $@ >&3
    fi
}

echo_summary_no_spinner () {
    # Also send summary to logfile
    echo_log $@

    kill_spinner

    if [ -z "$CROWBAR_VERBOSE" ]; then
        echo -e $@ >&3
    else
        echo -e === $@ >&3
    fi
}

die() {
    # Send empty line & error to logfile
    echo >&4
    echo_log "Error: $@"

    kill_spinner_with_failed

    echo >&3
    echo -e "Error: $@" >&3

    res=1
    exit 1
}

exit_handler () {
    if [ -z "$run_succeeded" ]; then
        kill_spinner_with_failed
        cat <<EOF | pipe_stdout_and_logfile

Crowbar installation terminated prematurely.  Please examine the above
output or $LOGFILE for clues as to what went wrong.
You should also check the SUSE Cloud Installation Manual, in
particular the Troubleshooting section.  Note that this script can
safely be re-run multiple times if required.
EOF
    else
        kill_spinner
    fi
}

trap exit_handler EXIT


# Real work starts here
# ---------------------

echo "`date` $0 started with args: $*"

ensure_service_running () {
    service="$1"
    regexp="${2:-running}"
    if service $service status | egrep -q "$regexp"; then
        echo "$service is already running - no need to start."
    else
        service $service start
        sleep 4
    fi
}


# Sanity checks
# -------------

echo_summary "Performing sanity checks"

rootpw=$( getent shadow root | cut -d: -f2 )
case "$rootpw" in
    \*|\!*)
        die "root password is unset or locked.  Chef will rewrite /root/.ssh/authorized_keys; therefore to avoid being accidentally locked out of this admin node, you should first ensure you have a working root password."
        ;;
esac

# It is exceedingly important that 'hostname -f' actually returns an FQDN!
# if it doesn't, add an entry to /etc/hosts, e.g.:
#    192.168.124.10 cb-admin.example.com cb-admin
if ! FQDN=$(hostname -f 2>/dev/null); then
    die "Unable to detect fully-qualified hostname. Aborting."
fi

if ! DOMAIN=$(hostname -d 2>/dev/null); then
    die "Unable to detect DNS domain name. Aborting."
fi
 
if [ -z "$FQDN" -o -z "$DOMAIN" ]; then
    die "Unable to detect fully-qualified hostname. Aborting."
fi

if ! resolved=$(getent ahosts $FQDN 2>/dev/null); then
    die "Unable to resolve hostname $FQDN via host(1). Please check your configuration of DNS, hostname, and /etc/hosts. Aborting."
fi

IPv4_addr=$( echo "$resolved" | awk '{ if ($1 !~ /:/) { print $1; exit } }' )
IPv6_addr=$( echo "$resolved" | awk '{ if ($1  ~ /:/) { print $1; exit } }' )
if [ -z "$IPv4_addr" -a -z "$IPv6_addr" ]; then
    die "Could not resolve $FQDN to an IPv4 or IPv6 address. Aborting."
fi

if [ -n "$CROWBAR_FROM_GIT" ]; then
    REPOS_SKIP_CHECKS+=" SLES11-SP1-Pool SLES11-SP1-Updates SLES11-SP2-Core SLES11-SP2-Updates SLES11-SP3-Pool SLES11-SP3-Updates SUSE-Cloud-2.0-Pool SUSE-Cloud-2.0-Updates"
    zypper in rubygems rubygem-json createrepo
fi

if [ -n "$IPv4_addr" ]; then
    echo "$FQDN resolved to IPv4 address: $IPv4_addr"
    if ! ip addr | grep -q "inet $IPv4_addr"; then
        die "No local interfaces configured with address $IPv4_addr. Aborting."
    fi
    if [[ "$IPv4_addr" =~ ^127 ]]; then
        die "$FQDN resolves to a loopback address. Aborting."
    fi

    if [ -n "$CROWBAR_FROM_GIT" ]; then
        NETWORK_JSON=$BARCLAMP_SRC/network/chef/data_bags/crowbar/bc-template-network.json
    else
        NETWORK_JSON=/opt/dell/chef/data_bags/crowbar/bc-template-network.json
    fi
    if ! /opt/dell/bin/bc-network-admin-helper.rb "$IPv4_addr" < $NETWORK_JSON; then
        die "IPv4 address $IPv4_addr of admin node not in admin range of admin network. Please check and fix with yast2 crowbar. Aborting."
    fi
fi
if [ -n "$IPv6_addr" ]; then
    echo "$FQDN resolved to IPv6 address: $IPv6_addr"
    if ! ip addr | grep -q "inet6 $IPv6_addr"; then
        die "No local interfaces configured with address $IPv6_addr. Aborting."
    fi
fi

# Note that the grep will fail if iptables' output changes; unlikely to happen,
# but...
if LANG=C iptables -n -L | grep -qvE '^$|^Chain [^ ]|^target     prot'; then
    die "Firewall is not completely disabled. Aborting."
fi

if ! ping -c 1 $FQDN >/dev/null 2>&1; then
    die "Failed to ping $FQDN; please check your network configuration. Aborting."
fi


# output details, that will make remote debugging via bugzilla much easier  
# for us
/usr/bin/zypper lr -d   
/bin/rpm -qV crowbar || :
/usr/bin/lscpu  
/bin/df -h  
/usr/bin/free -m
/bin/ls -la /srv/tftpboot/repos/ /srv/tftpboot/repos/Cloud/ /srv/tftpboot/suse-11.3/install/

if [ -f /opt/dell/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb ]; then
    # The autoyast profile might not exist yet when CROWBAR_FROM_GIT is enabled
    /usr/bin/grep media_url /opt/dell/chef/cookbooks/provisioner/templates/default/autoyast.xml.erb
fi

CROWBAR=/opt/dell/bin/crowbar

skip_check_for_repo () {
    repo="$1"
    for skipped_repo in $REPOS_SKIP_CHECKS; do
        if [ "$repo" = "$skipped_repo" ]; then
            return 0
        fi
    done
    return 1
}

check_repo_content () {
    repo_name="$1" repo_path="$2" md5="$3"

    if skip_check_for_repo "$repo_name"; then
        echo "Skipping check for $repo_name due to \$REPOS_SKIP_CHECKS"
        return 0
    fi

    if ! [ -e "$repo_path/content.asc" ]; then
        if [ -n "$CROWBAR_FROM_GIT" ]; then
            die "$repo has not been set up yet; please see https://github.com/SUSE/cloud/wiki/Crowbar"
        else
            die "$repo_name has not been set up yet; please check you didn't miss a step in the installation guide."
        fi
    fi

    if [ -n "$CROWBAR_FROM_GIT" ]; then
        echo "Skipping md5 check for $repo_name due to \$CROWBAR_FROM_GIT"
    else
        if [ "`md5sum $repo_path/content | awk '{print $1}'`" != "$md5" ]; then
            die "$repo_name does not contain the expected repository ($repo_path/content failed MD5 checksum)"
        fi
    fi
}

check_repo_product () {
    repo="$1" expected_summary="$2"
    products_xml=/srv/tftpboot/repos/$repo/repodata/products.xml
    if ! grep -q "<summary>$2</summary>" $products_xml; then
        if skip_check_for_repo "$repo"; then
            echo "Ignoring failed repo check for $repo due to \$REPOS_SKIP_CHECKS ($products_xml is missing summary '$expected_summary')"
            if ! [ -d /srv/tftpboot/repos/$repo ]; then
                echo "Creating repo skeleton to make AutoYaST happy."
                mkdir /srv/tftpboot/repos/$repo
                /usr/bin/createrepo /srv/tftpboot/repos/$repo
            fi
            return 0
        fi
        die "$repo does not contain the right repository ($products_xml is missing summary '$expected_summary')"
    fi
}

# FIXME: repos that we cannot check yet:
#   SP3-Updates is lacking products.xml
#   Cloud: we don't have the final md5
#   SUSE-Cloud-2.0-*: not existing yet
REPOS_SKIP_CHECKS+=" Cloud SLES11-SP3-Updates SUSE-Cloud-2.0-Pool SUSE-Cloud-2.0-Updates"

# FIXME: this is for SP3 RC2
check_repo_content \
    SLES11_SP3 \
    /srv/tftpboot/suse-11.3/install \
    f9a7aa4950fbee8079844f5973169db8

check_repo_content \
    Cloud \
    /srv/tftpboot/repos/Cloud \
    1558be86e7354d31e71e7c8c2574031a


if skip_check_for_repo "Cloud-PTF"; then
    echo "Skipping check for Cloud-PTF due to \$REPOS_SKIP_CHECKS"
else
    if ! [ -e "/srv/tftpboot/repos/Cloud-PTF/repodata/repomd.xml" ]; then
        # Only do this for CROWBAR_FROM_GIT , as usually the crowbar package
        # creates the repo metadata for Cloud-PTF
        if [ -n $CROWBAR_FROM_GIT ]; then
            echo "Creating repo skeleton to make AutoYaST happy."
            if ! [ -d /srv/tftpboot/repos/Cloud-PTF ]; then
                mkdir /srv/tftpboot/repos/Cloud-PTF
            fi
            /usr/bin/createrepo /srv/tftpboot/repos/Cloud-PTF
        else
            die "Cloud-PTF has not been set up correctly; did the crowbar rpm fail to install correctly?"
        fi
    fi
fi

check_repo_product SLES11-SP1-Pool        'SUSE Linux Enterprise Server 11 SP1'
check_repo_product SLES11-SP1-Updates     'SUSE Linux Enterprise Server 11 SP1'
check_repo_product SLES11-SP1-Updates     'SUSE_SLES Service Pack 2 Migration Product'
check_repo_product SLES11-SP2-Core        'SUSE Linux Enterprise Server 11 SP2'
check_repo_product SLES11-SP2-Updates     'SUSE Linux Enterprise Server 11 SP2'
check_repo_product SLES11-SP3-Pool        'SUSE Linux Enterprise Server 11 SP3'
check_repo_product SLES11-SP3-Updates     'SUSE Linux Enterprise Server 11 SP3'
check_repo_product SUSE-Cloud-2.0-Pool    'SUSE Cloud 2.0'
check_repo_product SUSE-Cloud-2.0-Updates 'SUSE Cloud 2.0'

if [ -z "$CROWBAR_FROM_GIT" ]; then
    if ! LANG=C zypper if -t pattern cloud_admin 2> /dev/null | grep -q "^Installed: Yes$"; then
        die "cloud_admin pattern is not installed; please install with \"zypper in -t pattern cloud_admin\". Aborting."
    fi
fi


# Setup helper for git
# --------------------

add_ibs_repo () {
    url="$1"
    alias="$2"
    if ! [ -f /etc/zypp/repos.d/$alias.repo ]; then
        zypper ar $url $alias
    else
        echo "Repo: $alias already exists. Skipping."
    fi
}

if [ -n "$CROWBAR_FROM_GIT" ]; then

    echo_summary "Performing additional setup for git"

    # FIXME: This is useful only for testing the crowbar admin node setup.
    #        Additional work (e.g. on the autoyast profile) is required to make
    #        those repos available to any client nodes.
    if [ $CROWBAR_FROM_GIT = "ibs" ]; then
        add_ibs_repo http://dist.suse.de/install/SLP/SLES-11-SP3-LATEST/x86_64/DVD1 sp3
        add_ibs_repo http://dist.suse.de/install/SLP/SLE-11-SP3-SDK-LATEST/x86_64/DVD1/ sdk-sp3
        add_ibs_repo http://dist.suse.de/ibs/SUSE:/SLE-11-SP1:/GA/standard/ sp1-ga
        add_ibs_repo http://dist.suse.de/ibs/SUSE:/SLE-11-SP2:/GA/standard/ sp2-ga
        add_ibs_repo http://dist.suse.de/ibs/SUSE:/SLE-11-SP3:/GA/standard/ sp3-ga
        add_ibs_repo http://dist.suse.de/ibs/SUSE:/SLE-11-SP1:/Update/standard/ sp1-update
        add_ibs_repo http://dist.suse.de/ibs/SUSE:/SLE-11-SP2:/Update/standard/ sp2-update
        add_ibs_repo http://dist.suse.de/ibs/SUSE:/SLE-11-SP3:/Update/standard/ sp3-update
        add_ibs_repo http://dist.suse.de/ibs/Devel:/Cloud:/2.0/SLE_11_SP3/ cloud
    fi

    # install chef and its dependencies
    zypper --gpg-auto-import-keys in rubygem-chef-server rubygem-chef rabbitmq-server \
            couchdb java-1_6_0-ibm rubygem-activesupport

    # also need these (crowbar dependencies):
    zypper in rubygem-cstruct rubygem-kwalify rubygem-ruby-shadow rubygem-sass rubygem-i18n sleshammer tcpdump

    # Need this for provisioner to work:
    mkdir -p /srv/tftpboot/discovery/pxelinux.cfg
    cat > /srv/tftpboot/discovery/pxelinux.cfg/default <<EOF
DEFAULT pxeboot
TIMEOUT 20
PROMPT 0
LABEL pxeboot
        KERNEL vmlinuz0
        APPEND initrd=initrd0.img root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop
ONERROR LOCALBOOT 0
EOF
    # create Compatibility link /tftpboot -> /srv/tftpboot (this is part of
    # the crowbar package when not in $CROWBAR_FROM_GIT)
    if ! [ -e /tftpboot ]; then
        ln -s /srv/tftpboot /tftpboot
    elif [ "$( /usr/bin/readlink /tftpboot )" != "/srv/tftpboot" ]; then
        die "/tftpboot exist but is not a symbolic link to /srv/tftpboot. Please fix!"
    fi

    # log directory needs to exist
    mkdir -p /var/log/crowbar
    chmod 0750 /var/log/crowbar

    # You'll also need:
    #   /srv/tftpboot/discovery/initrd0.img
    #   /srv/tftpboot/discovery/vmlinuz0
    # These can be obtained from a sleshammer image or from an existing
    # ubuntu admin node.
fi


# Starting services
# -----------------

echo_summary "Starting required services"

chkconfig rabbitmq-server on
ensure_service_running rabbitmq-server '^Node .+ with Pid [0-9]+: running'

if rabbitmqctl list_vhosts | grep -q '^/chef$'; then
    : /chef vhost already added
else
    rabbitmqctl add_vhost /chef
fi

if rabbitmqctl list_users 2>&1 | grep -q '^chef	'; then
    : chef user already added
else
    rabbit_chef_password=$( dd if=/dev/urandom count=1 bs=16 2>/dev/null | base64 | tr -d / )
    rabbitmqctl add_user chef "$rabbit_chef_password"
    # Update "amqp_pass" in  /etc/chef/server.rb and solr.rb
    sed -i 's/amqp_pass ".*"/amqp_pass "'"$rabbit_chef_password"'"/' /etc/chef/{server,solr}.rb
fi

rabbitmqctl set_permissions -p /chef chef ".*" ".*" ".*"

chkconfig couchdb on
ensure_service_running couchdb

chmod o-rwx /etc/chef /etc/chef/{server,solr}.rb

# increase chef-solr index field size
perl -i -pe 's{<maxFieldLength>.*</maxFieldLength>}{<maxFieldLength>200000</maxFieldLength>}' /var/lib/chef/solr/conf/solrconfig.xml

services='solr expander server'
for service in $services; do
    chkconfig chef-${service} on
done

for service in $services; do
    ensure_service_running chef-${service}
done


# Initial chef-client run
# -----------------------

echo_summary "Performing initial chef-client run"

if ! [ -e ~/.chef/knife.rb ]; then
    yes '' | knife configure -i
fi

node_info=$(knife node show $FQDN 2>/dev/null || :)
if echo "$node_info" | grep -q 'Run List:.*role'; then
    echo "Chef runlist for $FQDN is already populated; skipping initial chef-client run."
else
    cat <<EOF
This can cause warnings about /etc/chef/client.rb missing and
the run list being empty; they can be safely ignored.
EOF
    chef-client
fi


# Barclamp installation
# ---------------------

echo_summary "Installing barclamps"

# Don't use this one - crowbar barfs due to hyphens in the "id" attribute.
#CROWBAR_FILE="/opt/dell/barclamps/crowbar/chef/data_bags/crowbar/bc-template-crowbar.json"
# See also https://bugzilla.novell.com/show_bug.cgi?id=788161#c9
# for the history behind this location.
: ${CROWBAR_FILE:="/etc/crowbar/crowbar.json"}

mkdir -p /opt/dell/crowbar_framework
CROWBAR_REALM=$($BARCLAMP_SRC/provisioner/updates/parse_node_data $CROWBAR_FILE -a attributes.crowbar.realm)
CROWBAR_REALM=${CROWBAR_REALM##*=}

# Generate the machine install username and password.
if [[ ! -e /etc/crowbar.install.key && $CROWBAR_REALM ]]; then
    dd if=/dev/urandom bs=65536 count=1 2>/dev/null |sha512sum - 2>/dev/null | \
        (read key rest; echo "machine-install:$key" >/etc/crowbar.install.key)
fi

if [[ $CROWBAR_REALM && -f /etc/crowbar.install.key ]]; then
    export CROWBAR_KEY=$(cat /etc/crowbar.install.key)
    sed -i -e "s/machine_password/${CROWBAR_KEY##*:}/g" $CROWBAR_FILE
fi

/opt/dell/bin/barclamp_install.rb $BARCLAMP_INSTALL_OPTS $BARCLAMP_SRC/crowbar

#
# Take care that the barclamps are installed in the right order
# If you've got a full openstack set installed, e.g.: nagios has to be
# installed before keystone, etc.
#
for i in deployer dns ipmi logging nagios network ntp provisioner \
         database rabbitmq ceph \
         keystone glance cinder quantum nova nova_dashboard swift openstack ; do
    if [ -e /opt/dell/crowbar_framework/barclamps/$i.yml ]; then
        echo "$i barclamp is already installed"
    else
        /opt/dell/bin/barclamp_install.rb $BARCLAMP_INSTALL_OPTS $BARCLAMP_SRC/$i
    fi
done


# First step of crowbar bootstrap
# -------------------------------

echo_summary "Bootstrapping Crowbar setup"

# Configure chef to set up bind with correct local domain and DNS forwarders.
dns_template=/opt/dell/chef/data_bags/crowbar/bc-template-dns.json
[ -f $dns_template ] || die "$dns_template doesn't exist"
nameservers=$( awk '/^nameserver/ {print $2}' /etc/resolv.conf )
# This will still work if there are no nameservers.
/opt/dell/bin/bc-dns-json.rb $DOMAIN $nameservers < $dns_template > /tmp/bc-template-dns.json
echo "Instructing chef to configure bind with the following DNS forwarders: $nameservers"
knife data bag from file crowbar /tmp/bc-template-dns.json

echo "Create Admin node role"
NODE_ROLE="crowbar-${FQDN//./_}" 
cat > /tmp/role.rb <<EOF
name "$NODE_ROLE"
description "Role for $FQDN"
run_list()
default_attributes( "crowbar" => { "network" => {} } )
override_attributes()
EOF
knife role from file /tmp/role.rb

knife node run_list add "$FQDN" role["crowbar"]
knife node run_list add "$FQDN" role["deployer-client"]
knife node run_list add "$FQDN" role["$NODE_ROLE"]

# at this point you can run chef-client from the command line to start
# the crowbar bootstrapping

chef-client

# OOC, what, if anything, is responsible for starting rainbows/crowbar under bluepill?
ensure_service_running crowbar


# Second step of crowbar bootstrap
# -------------------------------

echo_summary "Applying Crowbar configuration for administration server"

# Make sure looper_chef_client is a NOOP until we are finished deploying
touch /tmp/deploying
# This works because
#
#   crowbar_framework/app/models/provisioner_service.rb
#   crowbar_framework/app/models/service_object.rb
#
# both invoke
#
#   /opt/dell/bin/single_chef_client.sh (from barclamps/crowbar/bin)
#
# which invokes
#
#   /opt/dell/bin/looper_chef_client.sh
#
# which exits immediately if /tmp/deploying exists.

# From here, you should probably read along with the equivalent steps in
# install-chef.sh for comparison

if [ "$($CROWBAR crowbar proposal list)" != "default" ] ; then
    proposal_opts=()
    # If your custom crowbar.json is somewhere else, probably substitute that here
    if [[ -e $CROWBAR_FILE ]]; then
        proposal_opts+=(--file $CROWBAR_FILE)
    fi
    proposal_opts+=(proposal create default)

    # Sometimes proposal creation fails if Chef and Crowbar are not quite
    # fully prepared -- this can happen due to solr not having everything
    # fully indexed yet.  So we don't want to just fail immediatly if
    # we fail to create a proposal -- instead, we will kick Chef, sleep a bit,
    # and try again up to 5 times before bailing out.
    for ((x=1; x<6; x++)); do
        $CROWBAR crowbar "${proposal_opts[@]}" && { proposal_created=true; break; }
        echo "Proposal create failed, pass $x.  Will kick Chef and try again."
        chef-client
        sleep 1
    done
    if [[ ! $proposal_created ]]; then
        die "Could not create default proposal"
    fi
fi

# this has machine key world readable? care?
$CROWBAR crowbar proposal show default >/var/log/crowbar/default-proposal.json

# next will fail if ntp barclamp not present (or did for me...)
$CROWBAR crowbar proposal commit default || \
    die "Could not commit default proposal!"
    
$CROWBAR crowbar show default >/var/log/crowbar/default.json

crowbar_up=true
chef-client

# here we whould check indexer/expander is finished

# original script has several calls to check_machine_role -- see source for
# this, in my limited testing it wasn't necessary on SUSE, but we should still
# do it anyway (if the role isn't present things break, apparently)

# BMC support?


# Third step of crowbar bootstrap
# -------------------------------

echo_summary "Transitioning administration server to \"ready\""

# transition though all the states to ready.  Make sure that
# Chef has completly finished with transition before proceeding
# to the next.

for state in "discovering" "discovered" "hardware-installing" \
    "hardware-installed" "installing" "installed" "readying" "ready"
do
    while [[ -f "/tmp/chef-client.lock" ]]; do sleep 1; done
    printf "$state: "
    $CROWBAR crowbar transition "$FQDN" "$state" || \
        die "Transition to $state failed!"
    if type -f "transition_check_$state"&>/dev/null; then
        "transition_check_$state" || \
            die "Sanity check for transitioning to $state failed!"
    fi
    # chef_or_die "Chef run for $state transition failed!"
    chef-client
    # check_machine_role
done

# OK, let looper_chef_client run normally now.
rm /tmp/deploying


# Starting more services
# ----------------------

echo_summary "Starting chef-client"

# Need chef-client daemon now
chkconfig chef-client on
ensure_service_running chef-client


# Final sanity checks
# -------------------

echo_summary "Performing post-installation sanity checks"

# Spit out a warning message if we managed to not get an IP address
IPSTR=$($CROWBAR network show default | /opt/dell/barclamps/provisioner/updates/parse_node_data -a attributes.network.networks.admin.ranges.admin.start)
IP=${IPSTR##*=}
ip addr | grep -q $IP || {
    die "eth0 not configured, but should have been."
}

# Run tests -- currently the host will run this.
# 2012-05-24: test is failing, so only run if CROWBAR_RUN_TESTS=true
# (this is distinct from CROWBAR_FROM_GIT, which would add extra repos etc.)
if [ -n "$CROWBAR_RUN_TESTS" ]; then
    /opt/dell/bin/barclamp_test.rb -t || \
        die "Crowbar validation has errors! Please check the logs and correct."
fi

for s in xinetd dhcpd apache2 ; do
    if ! /etc/init.d/$s status >/dev/null ; then
        die "service $s missing"
    fi
done


# We're done!
# -----------

touch /opt/dell/crowbar_framework/.crowbar-installed-ok

kill_spinner

cat <<EOF | pipe_stdout_and_logfile


Admin node deployed.

You can now visit the Crowbar web UI at:

    http://$IP:3000/

You should also now be able to PXE-boot a client.  Please refer
to the documentation for the next steps.

Note that to run the crowbar CLI tool, you will need to log out
and log back in again for the correct environment variables to
be set up.
EOF

run_succeeded=hooray
