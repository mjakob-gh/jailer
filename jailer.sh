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

# load configuration file
# default values
. /usr/local/etc/jailer.conf

# initialise variables
JAIL_NAME=""
JAIL_CONF="/etc/jail.conf"

JAIL_IP=""
JAIL_UUID=$(uuidgen)
#NAME_SERVER=$(grep nameserver /etc/resolv.conf | tail -n 1 | awk '{print $2}')
NAME_SERVER=$(local-unbound-control list_forwards | grep -e '^\. IN' | awk '{print $NF}')

LOG_FILE=""
ABI_VERSION=$(pkg config abi)
PKGS=""
SERVICES=""
COPY_FILES=""
AUTO_START=false
BASE_UPDATE=false
PKG_UPDATE=false
PKG_QUIET=""

##################################
## functions                    ##
##################################

get_args()
{
    while getopts "a:t:r:n:i:c:x:e:bpsq" option
    do
        case $option in
            a)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > /dev/null; then
                    JAIL_IP=${OPTARG}
                    echo "IP: ${JAIL_IP}"
                else
                    echo "ERROR: invalid IP address (${OPTARG})"
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
            n)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > /dev/null; then
                    NAME_SERVER=${OPTARG}
                    echo "Nameserver: ${NAME_SERVER}"
                else
                    echo "INFO: invalid IP address for nameserver (${OPTARG}), using default ${NAME_SERVER}"
                fi
                ;;
            i)
                if [ ! X"${OPTARG}" = "X" ]; then
                    PKGS=${OPTARG}
                    echo "Install packages: ${PKGS}"
                else
                    echo "INFO: no packages specified."
                fi
                ;;
            c)
                if [ ! X"${OPTARG}" = "X" ]; then
                    COPY_FILES=${OPTARG}
                    echo "Copying files: ${COPY_FILES}"
                fi
                ;;
            x)
                if [ ! X"${OPTARG}" = "X" ]; then
                    ABI_VERSION=${OPTARG}
                    echo "ABI Version: ${ABI_VERSION}"
                else
                    echo "INFO: no ABI VERSION specified, using default (${ABI_VERSION})"
                fi
                ;;
            e)
                if [ ! X"${OPTARG}" = "X" ]; then
                    SERVICES=${OPTARG}
                    echo "Enabling services: ${SERVICES}"
                fi
                ;;
            b)
                BASE_UPDATE=true
                ;;
            p)
                PKG_UPDATE=true
                ;;
            s)
                AUTO_START=true
                ;;
            q)
                PKG_QUIET="--quiet"
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
    echo "  $PGM create jailname [-a <ipaddress> -t <timezone> -r <reponame> -n <ipaddress> -i \"list of packages\" -x <ABI_Version> -e \"list of services\" -s -q]"
    echo "       -a <ipaddress>          : set IP address of Jail"
    echo ""
    echo "       -t <timezone>           : set Timezone of Jail"
    echo "       -n <ipaddress>          : set DNS server IP address of Jail"
    echo ""
    echo "       -r <reponame>           : set pkg repository of Jail"
    echo "       -i \"list of packages\"   : packages to install in the Jail"
    echo ""
    echo "       -c \"/dirA/fileA:<JAIL_DIR>/root/,/dirB/fileB:<JAIL_DIR>:/otherdir/fileC\""
    echo "                               : copy files INTO the Jail"
    echo "                                 NOTE:"
    echo "                                 - consider beginning and trailing slashes"
    echo "                                 - consider the file permissions"
    echo "                                 - consider whitespace in the parameter string"
    echo ""
    echo "       -x <ABI_Version>        : set the ABI Version to match the"
    echo "                                 packages to be installed to the Jail *)"
    echo "       -e \"list of services\"   : enable existing or just installed (-p ...) services"
    echo ""
    echo "       -s                      : start the Jail after the installation is finished"
    echo "       -q                      : dont show messages of pkg command"
    echo ""
    echo "  $PGM destroy <jailname>"
    echo ""
    echo "  $PGM update <jailname> [-s]  : pkg update/upgrade Jail"
    echo "       -b                      : update the pkgbase system"
    echo "       -p                      : update the installed packages"
    echo "       -s                      : restart Jail after update"
    echo ""
    echo "  $PGM start <jailname>"
    echo "  $PGM stop <jailname>"
    echo "  $PGM restart <jailname>"
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
        echo "ERROR: Repository ${REPO_NAME} not found."
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
    zfs create -o compression=on ${JAIL_DATASET_ROOT}/${JAIL_NAME}
    echo ""
}

install_baseos_pkg()
{
    # Some additional basesystem pkgs, extend the list if needed
    EXTRA_PKGS="FreeBSD-libcasper FreeBSD-libexecinfo FreeBSD-vi FreeBSD-at FreeBSD-dma"

    echo "Install FreeBSD Base System pkgs: FreeBSD-runtime + ${EXTRA_PKGS}" | tee -a ${LOG_FILE}
    # Install the base system
    pkg --rootdir ${JAIL_DIR} -o ASSUME_ALWAYS_YES=true -o ABI=${ABI_VERSION} install ${PKG_QUIET} --repository ${REPO_NAME} FreeBSD-runtime ${EXTRA_PKGS} | tee -a ${LOG_FILE}
    echo ""
}

install_pkgs()
{
    if [ ! X"${PKGS}" = "X" ]; then
        echo "Install pkgs:"
        echo "-------------"
        # install the pkg package
        pkg --rootdir ${JAIL_DIR} -R ${JAIL_DIR}/etc/pkg/ -o ASSUME_ALWAYS_YES=true -o ABI=${ABI_VERSION} install ${PKG_QUIET} pkg | tee -a ${LOG_FILE}
        echo -n "pkg "
        for PKG in ${PKGS}
        {
            echo -n "${PKG} "
            #pkg --rootdir ${JAIL_DIR} -R ${JAIL_DIR}/etc/pkg/ -o ASSUME_ALWAYS_YES=true -o ABI=${ABI_VERSION} install ${PKG} | tee -a ${LOG_FILE}
            pkg -j ${JAIL_NAME} -o ASSUME_ALWAYS_YES=true install ${PKG_QUIET} ${PKG} | tee -a ${LOG_FILE}
            if [ $? -lt 0 ]; then
                 echo "ERROR: installation of ${PKG} failed"
            fi
        }
        echo ""
    fi
}

enable_services()
{
    if [ ! X"${SERVICES}" = "X" ]; then
        echo "Enabling Services:"
        echo "------------------"
        (
            for SERVICE in ${SERVICES}
            {
                #sysrc -R ${JAIL_DIR} "${SERVICE}_enable=YES"
                service -j ${JAIL_NAME} ${SERVICE} enable
            }
        ) | column -t
        echo ""
    fi
}

copy_files()
{
    if [ ! X"${COPY_FILES}" = "X" ]; then
        echo "Copying files:"
        echo "--------------"

        OLDIFS=$IFS
        IFS=","

        (
            for COPY_FILE in $COPY_FILES
            {
                SRC=${COPY_FILE%%:*}
                DST=${COPY_FILE##*:}
                echo "${SRC} -> ${JAIL_DIR}/${DST}"
                cp -a "${SRC}" "${JAIL_DIR}/${DST}"
            }
        ) | column -t
        IFS=$OLDIFS
        echo ""
    fi
}

create_jailconf_entry()
{
    echo "add jail configuration to ${JAIL_CONF}" | tee -a ${LOG_FILE}

    sed \
        -e "s|%%JAIL_NAME%%|${JAIL_NAME}|g" \
        -e "s|%%JAIL_UUID%%|${JAIL_UUID}|g" \
        -e "s|%%JAIL_IP%%|${JAIL_IP}|g"     \
        -e "s|%%JAIL_DIR%%|${JAIL_DIR}|g"   \
         ${TEMPLATE_DIR}/${JAIL_TEMPLATE} >> ${JAIL_CONF}

    echo ""
}

setup_system()
{
    echo "Setup jail: \"${JAIL_NAME}\"" | tee -a ${LOG_FILE}
    echo "----------------------------"
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

    # Mailing
    echo "configure dma mailer"
    (
        sysrc -R ${JAIL_DIR} sendmail_enable=NO
        sysrc -R ${JAIL_DIR} sendmail_submit_enable=NO
        sysrc -R ${JAIL_DIR} sendmail_outbound_enable=NO
        sysrc -R ${JAIL_DIR} sendmail_msp_queue_enable=NO
    ) | column -t

    # setup repository
    mkdir -p ${JAIL_DIR}/usr/local/etc/pkg/repos
    echo "FreeBSD: { enabled: yes }" > ${JAIL_DIR}/usr/local/etc/pkg/repos/FreeBSD.conf

    if [ -f ${TEMPLATE_DIR}/FreeBSD-base.conf ]; then
        cp -a ${TEMPLATE_DIR}/FreeBSD-base.conf ${JAIL_DIR}/usr/local/etc/pkg/repos
    else
        echo "WARNING: No pkgbase repo \"FreeBSD-base.conf\" found, please check \"${TEMPLATE_DIR}\""
    fi

    # mail configuration
    mkdir ${JAIL_DIR}/etc/mail/
    cp -a ${JAIL_DIR}/usr/share/examples/dma/mailer.conf ${JAIL_DIR}/etc/mail/
    echo ""
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
    echo ""
}

destroy_jailconf_entry()
{
    if check_jailconf; then
        echo "Deleting entry: ${JAIL_NAME}"
        sed  -i '' "/${JAIL_NAME} {/,/}/d" ${JAIL_CONF}
    else
        echo "ERROR: no entry ${JAIL_NAME} in \"${JAIL_CONF}\""
    fi
    echo ""
}

start_jail()
{

}

stop_jail()
{

}

restart_jail()
{

}

#####################################
# Main functions                    #
#####################################

create_log_file()
{
    LOG_FILE="/tmp/jailer_${ACTION}_${JAIL_NAME}_$(date +%Y%m%d%H%M).log"
    echo "INFO: Logs are written to: ${LOG_FILE}"
    echo ""
}

create_jail()
{
    if [ X"${JAIL_IP}" = "X" ]; then
        echo "ERROR: no ip adresse given (-a)"
        exit 2
    fi

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

        service jail start ${JAIL_NAME}
        service pf reload

        # install additional packages
        install_pkgs
        # enable services specified in -e argument
        enable_services

        service jail stop ${JAIL_NAME}

        # copy files into the jail specified in -c argument
        copy_files

        # start the jail when -s argument is set
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
    echo ""
}

update_jail()
{
    JAIL_DIR="${JAIL_DATASET_ROOT#zroot}/${JAIL_NAME}"

    if [ ${BASE_UPDATE} = "true" ]; then
        echo "Updating system"
        echo "---------------"
        pkg -j ${JAIL_NAME} -o ASSUME_ALWAYS_YES=true update  --repository ${REPO_NAME} ${PKG_QUIET} | tee -a ${LOG_FILE}
        pkg -j ${JAIL_NAME} -o ASSUME_ALWAYS_YES=true upgrade --repository ${REPO_NAME} ${PKG_QUIET} | tee -a ${LOG_FILE}
        echo ""
    fi

    if [ ${PKG_UPDATE} = "true" ]; then
        echo "Updating packages"
        echo "-----------------"
        pkg -j ${JAIL_NAME} -o ASSUME_ALWAYS_YES=true update  --repository FreeBSD ${PKG_QUIET} | tee -a ${LOG_FILE}
        pkg -j ${JAIL_NAME} -o ASSUME_ALWAYS_YES=true upgrade --repository FreeBSD ${PKG_QUIET} | tee -a ${LOG_FILE}
        echo ""
    fi

    if [ $? -lt 0 ]; then
        echo "ERROR: installation of ${PKG} failed"
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
    update)
        shift 2
        get_args "$@"
        update_jail
        if [ ${AUTO_START} = "true" ]; then
            service jail restart ${JAIL_NAME}
        fi
        ;;
    start)
        service jail start ${JAIL_NAME}
        ;;
    stop)
        service jail stop ${JAIL_NAME}
        ;;
    restart)
        service jail restart ${JAIL_NAME}
        ;;
    *) usage
esac
