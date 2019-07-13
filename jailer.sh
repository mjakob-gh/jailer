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

# Number of arguments
ARG_NUM=$#

# Global exit status
SUCCESS=0
FAILURE=1

# initialise variables/set default values
JAIL_NAME=""
JAIL_CONF="/etc/jail.conf"
JAIL_DATASET_ROOT="zroot/jails"
JAIL_DIR="${JAIL_DATASET_ROOT#zroot}/${JAIL_NAME}"

JAIL_IP="127.0.0.1"
JAIL_UUID=$(uuidgen)
TIME_ZONE="Europe/Berlin"
#NAME_SERVER=$(grep nameserver /etc/resolv.conf | tail -n 1 | awk '{print $2}')
NAME_SERVER=$(local-unbound-control list_forwards | grep -e '^\. IN' | awk '{print $NF}')

LOG_FILE=""
ABI_VERSION=$(pkg config abi)
PKGS=""
AUTO_START=false

# see "/usr/local/etc/pkg/repos/..."
REPO_NAME="FreeBSD-base"

##################################
## functions                    ##
##################################

get_args()
{
    while getopts "i:t:r:d:p:a:s" option
    do
        case $option in
            i)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null; then
                    JAIL_IP=${OPTARG}
                    echo "IP: ${JAIL_IP}"
                else
                    echo "ERROR: invalid IP address ${JAIL_IP}"
                    exit 2
                fi
                ;;
            t)
                if [ ! X"${OPTARG}" = "X" ]; then
                    TIME_ZONE=${OPTARG}
                    echo "Timezone: ${TIME_ZONE}"
                else
                    echo "INFO: no timezone specified, using default ${TIME_ZONE}."
                fi
                ;;
            r)
                if [ ! X"${OPTARG}" = "X" ]; then
                    REPO_NAME=${OPTARG}
                    check_repo
                    echo "Pkg-Repository: ${REPO_NAME}"
                else
                    echo "INFO: no repository specified, using default ${REPO_NAME}."
                fi
                ;;
            d)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null; then
                    NAME_SERVER=${OPTARG}
                    echo "Nameserver: ${NAME_SERVER}"
                else
                    echo "INFO: invalid IP address for nameserver, using default ${NAME_SERVER}"
                fi
                ;;
            p)
                if [ ! X"${OPTARG}" = "X" ]; then
                    PKGS=${OPTARG}
                    echo "Install packages: ${PKGS}"
                else
                    echo "INFO: no packages specified."
                fi
                ;;
            a)
                if [ ! X"${OPTARG}" = "X" ]; then
                    ABI_VERSION=${OPTARG}
                    echo "ABI Version: ${ABI_VERSION}"
                else
                    echo "INFO: no ABI VERSION specified, using default (${ABI_VERSION})"
                fi
                ;;

            s)
                AUTO_START=true
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
    echo ""
    echo "  $PGM create jailname [-i ipaddress -t timezone -r reponame -d ipaddress -p \"list of packages\" -a <ABI_Version> -s]"
    echo "       -i ipaddress            : set IP address of Jail"
    echo ""
    echo "       -t timezone             : set Timezone of Jail"
    echo "       -d ipaddress            : set DNS server IP address of Jail"
    echo ""
    echo "       -r reponame             : set pkg repository of Jail"
    echo "       -p \"list of packages\"   : packages to install in the Jail"
    echo "       -a <ABI_Version>        : set the ABI Version to match the"
    echo "                                 packages to be installed to the Jail *)"
    echo "       -s                      : start the Jail after the installation is finished"
    echo ""
    echo "  $PGM destroy jailname"
    echo ""
    echo ""
    echo "  *) Possible values for ABI_VERSION: (x86, 64 Bit)"
    echo "    - FreeBSD:11:amd64"
    echo "    - FreeBSD:12:amd64"
    echo "    - FreeBSD:13:amd64"
    echo ""
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

install_baseos_pkg()
{
    # Some additional basesystem pkgs, extend the list if needed
    EXTRA_PKGS="FreeBSD-libcasper FreeBSD-libexecinfo FreeBSD-vi FreeBSD-at"

    echo "Install FreeBSD Base System pkgs: FreeBSD-runtime + ${EXTRA_PKGS}" | tee -a ${LOG_FILE}
    # Install the base system
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true -o ABI=${ABI_VERSION} install -r ${REPO_NAME} FreeBSD-runtime ${EXTRA_PKGS} | tee -a ${LOG_FILE}
    echo ""
}

install_pkgs()
{
    if [ ! X"${PKGS}" = "X" ]; then
        echo "Install pkgs:"
        echo "-------------"
        # install the pkg package
        pkg --rootdir ${JAIL_DIR} -R ${JAIL_DIR}/etc/pkg/ -o ASSUME_ALWAYS_YES=true -o ABI=${ABI_VERSION} install pkg | tee -a ${LOG_FILE}
        echo -n "pkg "
        for PKG in ${PKGS}
        {
            echo -n "${PKG} "
            pkg --rootdir ${JAIL_DIR} -R ${JAIL_DIR}/etc/pkg/ -o ASSUME_ALWAYS_YES=true -o ABI=${ABI_VERSION} install ${PKG} | tee -a ${LOG_FILE}
            if [ $? -lt 0 ]; then
                 echo "ERROR: installation of ${PKG} failed"
            fi
        }
    fi
}

create_jailconf_entry()
{
echo "add jail configuration to ${JAIL_CONF}" | tee -a ${LOG_FILE}
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
    echo "Setup jail: \"${JAIL_NAME}\"" | tee -a ${LOG_FILE}
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

    # set timezone in jail
    echo "Setup timezone: ${TIME_ZONE}" | tee -a ${LOG_FILE}
    tzsetup -sC ${JAIL_DIR} "${TIME_ZONE}"

    # Network
    echo "nameserver ${NAME_SERVER}" > ${JAIL_DIR}/etc/resolv.conf
}

setup_dma()
{
    # mailing
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true install -r ${REPO_NAME} FreeBSD-dma | tee -a ${LOG_FILE}

    # Mailing
    (
    sysrc -R ${JAIL_DIR} sendmail_enable=NO
    sysrc -R ${JAIL_DIR} sendmail_submit_enable=NO
    sysrc -R ${JAIL_DIR} sendmail_outbound_enable=NO
    sysrc -R ${JAIL_DIR} sendmail_msp_queue_enable=NO
    ) | column -t

    # mail configuration
    mkdir ${JAIL_DIR}/etc/mail/
    cp -a ${JAIL_DIR}/usr/share/examples/dma/mailer.conf ${JAIL_DIR}/etc/mail/
}

destroy_dataset()
{
    if check_dataset; then
        echo "Deleting dataset: ${JAIL_DATASET_ROOT}/${JAIL_NAME}" | tee -a ${LOG_FILE}
        # forcibly unmount the dataset to prevent problems
        # zfs "destroying" the dataset
        umount -f ${JAIL_DIR}
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

create_log_file()
{
    LOG_FILE="/tmp/jailer_${ACTION}_${JAIL_NAME}_$(date +%Y%m%d%H%M).log"
    echo "INFO: Logs are written to: ${LOG_FILE}"
}

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
        install_baseos_pkg
        setup_system
        setup_dma
        # install additional packages
        install_pkgs
        if [ ${AUTO_START} = "true" ]; then
            service jail start ${JAIL_NAME}
        fi
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

# check for numbers of arguments
# ACTION and JAILNAME are mandatory
# exit when less then 2 arguments
if [ $ARG_NUM -lt 2 ]; then
    usage
fi

ACTION="$1"
JAIL_NAME="$2"

case "$ACTION" in
    create)
        shift 2
        get_args "$@"
        create_log_file
        create_jail
        ;;
    destroy)
        shift 2
        get_args "$@"
        create_log_file
        destroy_jail
        ;;
    *) usage
esac
