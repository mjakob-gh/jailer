#!/bin/sh

if [ "$( id -u )" -ne 0 ]; then
   echo "Must run as root!" >&2
   exit $FAILURE
fi

########################
## Variabledefinition ##
########################

# Program basename
PGM="${0##*/}" # Program basename

# Global exit status
SUCCESS=0
FAILURE=1

# initialise variables/set default values
JAIL_NAME="dummy"
JAIL_CONF="/etc/jail.conf"
JAIL_DATASET_ROOT="zroot/jails"
JAIL_DIR="${JAIL_DATASET_ROOT#zroot}/${JAIL_NAME}"

JAIL_IP=""
JAIL_UUID=$(uuidgen)
TIME_ZONE="Europe/Berlin"
NAME_SERVER=$(grep nameserver /etc/resolv.conf | tail -1 | awk '{print $2}')

# see "/usr/local/etc/pkg/repos/..."
REPO_NAME="FreeBSD-base"

##################################
## functions                    ##
##################################

get_args()
{
    while getopts "n:i:t:r:d:" option
    do
        case $option in
            n)
                JAIL_NAME=${OPTARG}
                echo "Name: $JAIL_NAME"
                ;;
            i)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null; then
                    JAIL_IP=${OPTARG}
                    echo "IP: $JAIL_IP"
                else
                    echo "ERROR: invalid IP address $JAIL_IP for JAIL_IP."
                    exit 2
                fi
                ;;
            t)
                TIME_ZONE=${OPTARG}
                echo "Timezone: $TIME_ZONE"
                ;;
            r)
                REPO_NAME=${OPTARG}
                check_repo
                echo "Pkg-Repository: $REPO_NAME"
                ;;
            d)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null; then
                    NAME_SERVER=${OPTARG}
                    echo "Nameserver: $NAME_SERVER"
                else
                    echo "ERROR: invalid IP $NAME_SERVER address NAME_SERVER."
                    exit 2
                fi
                ;;
            *)
                usage
                ;;
        esac
    done
    shift $((OPTIND - 1))
}

usage()
{
    echo "Usage:"
    echo "  $PGM create [-n jailname -i ipaddress]"
    echo "       -n jailname : set name of Jail"
    echo "       -i ipadress : set IP address of Jail"
    echo "       -t timezone : set Timezone of Jail"
    echo "       -r reponame : set pkg repository of Jail"
    echo "       -d ipadress : set DNS server IP address of Jail"
    echo ""
    echo "  $PGM destroy [-n jailname]"
    echo "       -n jailname : name of Jail"
    exit $FAILURE
}

check_repo()
{
    if [ ! -f /usr/local/etc/pkg/repos/${REPO_NAME}.conf ]; then
        echo "ERROR: Repo ${REPO_NAME} not found."
        exit 2
    fi
}

check_jailconf()
{
    if grep -e "^${JAIL_NAME} {" ${JAIL_CONF} > /dev/null 2>&1; then
        return $SUCCESS
    else
        return $FAILURE
    fi
}

check_dataset()
{
    if zfs list ${JAIL_DATASET_ROOT}/${JAIL_NAME} > /dev/null 2>&1; then
        return $SUCCESS
    else
        return $FAILURE
    fi
}

create_dataset()
{
    echo "create zfs data-set: ${JAIL_DATASET_ROOT}/${JAIL_NAME}"
    zfs create -o compress=lz4 ${JAIL_DATASET_ROOT}/${JAIL_NAME}
    echo ""
}

install_runtime_pkg()
{
    echo "Install FreeBSD-runtime pkg"
    # Install the base system
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true install -r ${REPO_NAME} FreeBSD-runtime
    echo ""
}

install_extra_pkg()
{
    echo "Install additional pkg"
    # neccessary for ping(?)
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true install -r ${REPO_NAME} FreeBSD-libcasper

    # install vi
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true install -r ${REPO_NAME} FreeBSD-vi

    # 
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true install -r ${REPO_NAME} FreeBSD-libexecinfo
    echo ""
}

create_jailconf_entry()
{
echo "add jail configuration to ${JAIL_CONF}"
cat << EOF >> ${JAIL_CONF}

${JAIL_NAME} {
    # Hostname
    host.hostname = "${JAIL_NAME}.local";
    host.hostuuid = "${JAIL_UUID}";

    # Network
    interface = re0;
    ip4.addr = ${JAIL_IP};
    allow.raw_sockets;

    # Systemvalues
    devfs_ruleset = 4;

    sysvmsg = new;
    sysvsem = new;
    sysvshm = new;

    path = "${JAIL_DIR}";
    allow.mount.zfs;

    # Start Script
    exec.start  = "/bin/sh /etc/rc";
    exec.stop   = "/bin/sh /etc/rc.shutdown";
}
EOF
echo ""
}

setup_system()
{
    echo "Setup jail: \"${JAIL_NAME}\""
    # add some default values for /etc/rc.conf
    # but first create the file, so sysrc wont show an error
    touch ${JAIL_DIR}/etc/rc.conf

    # System
    sysrc -R ${JAIL_DIR} syslogd_flags="-ss"

    # remove /boot directory, no need in jail
    rm -r /jails/${JAIL_NAME}/boot/

    # create directory "/usr/share/keys/pkg/revoked/"
    # or pkg inside the jail wont work.
    mkdir ${JAIL_DIR}/usr/share/keys/pkg/revoked/

    # Timezine
    echo "Setup timezone: ${TIME_ZONE}"
    tzsetup -sC ${JAIL_DIR} "${TIME_ZONE}"

    # Network
    echo "nameserver ${NAME_SERVER}" > ${JAIL_DIR}/etc/resolv.conf
}

setup_dma()
{
    # mailing
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true install -r ${REPO_NAME} FreeBSD-dma

    # Mailing
    sysrc -R ${JAIL_DIR} sendmail_enable="NO"
    sysrc -R ${JAIL_DIR} sendmail_submit_enable="NO"
    sysrc -R ${JAIL_DIR} sendmail_outbound_enable="NO"
    sysrc -R ${JAIL_DIR} sendmail_msp_queue_enable="NO"

    # mail configuration
    mkdir ${JAIL_DIR}/etc/mail/
    cp -a ${JAIL_DIR}/usr/share/examples/dma/mailer.conf ${JAIL_DIR}/etc/mail/
}

destroy_dataset()
{
    if check_dataset; then
        echo "Deleting dataset: ${JAIL_DATASET_ROOT}/${JAIL_NAME}"
        zfs destroy ${JAIL_DATASET_ROOT}/${JAIL_NAME}
    else
        echo "ERROR: no dataset ${JAIL_DATASET_ROOT}/${JAIL_NAME}"
    fi
}

destroy_jailconf_entry()
{
    if check_jailconf; then
        echo "Deleting entry: ${JAIL_NAME}"
        sed  -i '' "/${JAIL_NAME} {/,/}/d" ${JAIL_CONF}
    else
        echo "ERROR: no entry ${JAIL_NAME} in \"${JAIL_CONF}\""
    fi
}

#####################################
# Main functions                    #
#####################################

create_jail()
{
    JAIL_DIR="${JAIL_DATASET_ROOT#zroot}/${JAIL_NAME}"
    if check_jailconf; then
        echo "ERROR: $JAIL_NAME already exists in ${JAIL_CONF}."
        exit 2
    elif check_dataset; then
        echo "ERROR: dataset ${JAIL_DATASET_ROOT}/${JAIL_NAME} already exists."
        exit 2
    else
        create_dataset
        create_jailconf_entry
        install_runtime_pkg
        install_extra_pkg
        setup_system
        setup_dma
    fi
}

destroy_jail()
{
    JAIL_DIR="${JAIL_DATASET_ROOT#zroot}/${JAIL_NAME}"
    if ! check_jailconf; then
        echo "ERROR: $JAIL_NAME does not exist."
        exit 2
    elif ! check_dataset; then
        echo "ERROR: dataset ${JAIL_DATASET_ROOT}/${JAIL_NAME} does not exist."
        exit 2
    else
        service jail stop ${JAIL_NAME}
        destroy_jailconf_entry
        destroy_dataset
    fi
}

ACTION="$1"

case "$ACTION" in
    create)
        shift 1
        get_args "$@"
        create_jail
        ;;
    destroy)
        shift 1
        get_args "$@"
        destroy_jail
        ;;
    *) usage
esac
