#!/bin/sh
# shellcheck disable=SC2039,SC2181

if [ "$( id -u )" -ne 0 ]; then
   echo "Must run as root!" >&2
   exit "${FAILURE}"
fi

########################
## Variabledefinition ##
########################

# remove comment for "Debug" mode
#set -x

# Program basename
PGM="${0##*/}" # Program basename

VERSION="1.2"

# Number of arguments
ARG_NUM=$#

# Global exit status
SUCCESS=0
FAILURE=1

# Create zfs pools with/without compression
# can be overwritten in jailer.conf
ZFS_COMPRESSION="on"

# Install the pkg tool at jail creation
INSTALL_PKGTOOL="YES"

# Default pkgbase repositoryname,
# can be overwritten in jailer.conf
REPO_NAME="FreeBSD-pkgbase"

# Repository where the "official" packages are hosted,
# defaults to the FreeBSD Projects repository. When a
# poudriere repo is hosted change the in jailer.conf
OFFICIAL_REPO_NAME=FreeBSD

# load configuration file
# default values
# check for config file                      
if [ ! -f /usr/local/etc/jailer.conf ]; then 
    echo "ERROR: config file does not exist!"
    exit 1                                   
else
    . /usr/local/etc/jailer.conf
fi

# initialise variables
JAIL_NAME=""
JAIL_CONF="/etc/jail.conf"

JAIL_IP=""
JAIL_UUID=$(uuidgen)

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

DESCR_ARG_LENGTH=22

VNET=false
MINIJAIL=false
INTERFACE_ID=0

# check if jails are enabled                     
if [ ! "$(sysrc -n jail_enable)" = "YES" ]; then
    echo "WARNING: jail service is not enabled."
fi

# check for template files
if [ ! -f /usr/local/share/jailer/jail.template ] || [ ! -f /usr/local/share/jailer/jail-vnet.template ] ; then
    echo "ERROR: template files do not exist!"
    exit 1
fi

##################################
## functions                    ##
##################################

#
# check
#
checkResult ()
{
    if [ "$1" -eq 0 ]; then
        printf "%s[OK]%s\n" "${GREEN}" "${COLOR_END}"
    else
        printf "%s[ERROR]%s\n" "${RED}" "${COLOR_END}"
    fi
}

#
# decipher the programm arguments
#
get_args()
{
    while getopts "i:t:r:n:P:c:a:e:mvbpsq" option
    do
        case $option in
            i)
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
            m)
                MINIJAIL=true
                ;;
            n)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > /dev/null; then
                    NAME_SERVER=${OPTARG}
                    echo "Nameserver: ${NAME_SERVER}"
                else
                    echo "ERROR: invalid IP address for nameserver (${OPTARG})"
                    exit 2
                fi
                ;;
            P)
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
            a)
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
            v)
                JAIL_TEMPLATE="jail-vnet.template"
                VNET=true
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

#
# print the usage message
#
usage()
{
    exec >&2
    echo   ""
    printf "%s Version: %s\n" "${PGM}" "${VERSION}"
    echo   ""
    echo   "Usage:"
    echo   ""
    printf "  %s create jailname -i <ipaddress> [-t <timezone> -r <reponame> -n <ipaddress> -v -P \"list of packages\" -a <ABI_Version> -e \"list of services\" -s -q]\n" "${PGM}"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-i" "<ipaddress>" "set IP address of Jail"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-t" "<timezone>" "set Timezone of Jail"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-n" "<ipaddress>" "set DNS server IP address of Jail"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-v" "" "create a VNET Jail"
    echo   ""

    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-r" "<reponame>" "set pkg repository of Jail"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-P" "\"list of packages\"" "packages to install in the Jail"
    echo   ""

    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-c" "\"source_file:target_file(,...)\"" "copy files INTO the Jail"
    echo   ""
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" "NOTE:"
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" " • use a comma seperated list for multiple copies"
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" " • consider beginning and trailing slashes"
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" " • consider the file permissions"
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" " • consider whitespaces in the parameter string"
    echo   ""

    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-a" "<ABI_Version>" "set the ABI Version to match the packages to be installed to the Jail"
    echo   ""
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" "NOTE: Possible values for ABI_VERSION"
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" " • FreeBSD:12:amd64"
    printf "\t%s %-${DESCR_ARG_LENGTH}s   %s\n" "" "" " • FreeBSD:13:amd64"
    echo   ""
            
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-m" "" "use minijail package"
    echo   ""

    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-e" "\"list of services\"" "enable existing or just installed (-P ...) services"
    echo   ""

    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-s" "" "start the Jail after the installation is finished"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-q" "" "dont show output of pkg"
    echo   ""

    printf "  %s destroy <jailname>\n" "${PGM}"
    echo   ""

    printf "  %s update <jailname> [-b -p -s]\n" "${PGM}"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-b" "" "update the pkgbase system"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-p" "" "update the installed packages"
    printf "\t%s %-${DESCR_ARG_LENGTH}s : %s\n" "-s" "" "restart Jail after update"
    echo   ""

    printf "  %s %-${DESCR_ARG_LENGTH}s   : %s\n" "${PGM}" "list" "list jail status"
    echo   ""

    printf "  %s %-${DESCR_ARG_LENGTH}s   : %s\n" "${PGM}" "start" "start jail"
    echo   ""

    printf "  %s %-${DESCR_ARG_LENGTH}s   : %s\n" "${PGM}" "stop" "stop jail"
    echo   ""

    printf "  %s %-${DESCR_ARG_LENGTH}s   : %s\n" "${PGM}" "restart" "restart jail"
    echo   ""

    exit $FAILURE
}

#
# check the jailer setup
#
validate_setup()
{
    # check if jails are enabled
    if [ ! "$(sysrc -n jails_enable)" = "YES" ]; then
        echo "WARNING: jails service is not enabled." 
    fi

    # check for config file
    if [ ! -f /usr/local/etc/jailer.conf ]; then
        echo "ERROR: config file does not exist!"
	exit 1
    fi

    #check for template file
    #if [ ! -f /usr/local/share/jailer/*.template ]; then
    #    echo "ERROR: template files do not exist!"
    #    exit 1
    #fi
}

#
# check if repository configuration exists
#
check_repo()
{
    if [ ! -f "/usr/local/etc/pkg/repos/${REPO_NAME}.conf" ]; then
        echo "ERROR: no repository ${REPO_NAME} found."
        exit 2
    fi
}

#
# check if given jailname already exits in jail.conf
#
check_jailconf()
{
    if grep -e "^${JAIL_NAME} {" ${JAIL_CONF} > /dev/null 2>&1; then
        return $SUCCESS
    else
        return $FAILURE
    fi
}

#
# check if given jaildataset already exits
#
check_dataset()
{
    if zfs list "${JAIL_DATASET_ROOT}/${JAIL_NAME}" > /dev/null 2>&1; then
        return $SUCCESS
    else
        return $FAILURE
    fi
}

#
# create the dataset
#
create_dataset()
{
    echo -n "create zfs data-set: ${JAIL_DATASET_ROOT}/${JAIL_NAME} "
    zfs create -o compression="${ZFS_COMPRESSION}" "${JAIL_DATASET_ROOT}/${JAIL_NAME}"
    checkResult $?
    echo ""
}

#
# install the pkgbase pkgs
#
install_baseos_pkg()
{
    if [ $MINIJAIL = "true" ]; then
        REPO_NAME="FreeBSD-basecore"
        CORE_PKGS="FreeBSD-basecore"
        EXTRA_PKGS=""
    else
        # EXTRA_PKGS: Some additional basesystem pkgs, extend the list if needed
        case "${ABI_VERSION}" in
            *12*)
                # FreeBSD 12
                CORE_PKGS="FreeBSD-runtime"
                EXTRA_PKGS="FreeBSD-libcasper FreeBSD-libexecinfo FreeBSD-vi FreeBSD-at FreeBSD-dma"
                ;;
            *13*)
                # FreeBSD 13
                CORE_PKGS="FreeBSD-utilities"
                EXTRA_PKGS="FreeBSD-rc FreeBSD-dma FreeBSD-libexecinfo FreeBSD-vi FreeBSD-at"
                ;;
            *)
                echo "ERROR: invalid OS Version detectet: ${ABI_VERSION}"
                exit 1
                ;;
        esac
    fi

    echo "Using repository: ${REPO_NAME}" | tee -a "${LOG_FILE}"
    echo "Install FreeBSD Base System pkgs: ${CORE_PKGS} ${EXTRA_PKGS}" | tee -a "${LOG_FILE}"
    # Install the base system
    set -o pipefail
    # the packages must be passed to pkg as multiple parameters, so dont use quotes and ignore the shellcheck error
    # shellcheck disable=SC2086
    pkg --rootdir "${JAIL_DIR}" -o ASSUME_ALWAYS_YES=true -o ABI="${ABI_VERSION}" install ${PKG_QUIET} --repository "${REPO_NAME}" ${CORE_PKGS} ${EXTRA_PKGS} | tee -a "${LOG_FILE}"
    if [ $? -lt 0 ]; then
        echo "ERROR: pkgbase ${PKG} failed"
        exit 2
    fi

    pkg --rootdir "${JAIL_DIR}" -o ASSUME_ALWAYS_YES=true clean | tee -a "${LOG_FILE}"

    set +o pipefail
    echo ""
}

# 
# install pkg programm
#
install_pkgtool()
{
    # install the pkg package
    set -o pipefail
    pkg --rootdir "${JAIL_DIR}" -R "${JAIL_DIR}/etc/pkg/" -o ASSUME_ALWAYS_YES=true -o ABI="${ABI_VERSION}" install ${PKG_QUIET} --repository "${OFFICIAL_REPO_NAME}" pkg | tee -a "${LOG_FILE}"
    pkg --rootdir "${JAIL_DIR}" -R "${JAIL_DIR}/etc/pkg/" -o ASSUME_ALWAYS_YES=true ${PKG_QUIET} clean --all --quiet | tee -a "${LOG_FILE}"
    set +o pipefail
    printf "pkg "
}

#
# install additional packages
#
install_pkgs()
{
    if [ ! X"${PKGS}" = "X" ]; then
        echo "Install pkgs:"
        echo "-------------"

        # install the pkg package
        install_pkgtool

        for PKG in ${PKGS}
        do
            printf "%s " "${PKG}"
            set -o pipefail
            pkg -j "${JAIL_NAME}" -o ASSUME_ALWAYS_YES=true install ${PKG_QUIET} --repository "${OFFICIAL_REPO_NAME}" "${PKG}" | tee -a "${LOG_FILE}"
            if [ $? -lt 0 ]; then
                 echo "ERROR: installation of ${PKG} failed"
            fi
            set +o pipefail
        done
        pkg -j "${JAIL_NAME}" -o ASSUME_ALWAYS_YES=true ${PKG_QUIET} clean --all --quiet | tee -a "${LOG_FILE}"

        echo ""
    fi
}

#
# enable given services
#
enable_services()
{
    if [ ! X"${SERVICES}" = "X" ]; then
        echo "Enabling Services:"
        echo "------------------"
        (
            for SERVICE in ${SERVICES}
            do
                #sysrc -R ${JAIL_DIR} "${SERVICE}_enable=YES"
                service -j "${JAIL_NAME}" "${SERVICE}" enable
            done
        ) | column -t
        echo ""
    fi
}

#
# copy files into the jail
#
copy_files()
{
    if [ ! X"${COPY_FILES}" = "X" ]; then
        echo "Copying files:"
        echo "--------------"

        OLDIFS=$IFS
        IFS=","

        (
            for COPY_FILE in $COPY_FILES
            do
                SRC=${COPY_FILE%%:*}
                DST=${COPY_FILE##*:}
                echo "${SRC} -> ${JAIL_DIR}/${DST}"
                cp -a "${SRC}" "${JAIL_DIR}/${DST}"
            done
        ) | column -t
        IFS=$OLDIFS
        echo ""
    fi
}

#
# get next interface ID
#
get_next_interface_id()
{
    #LAST_ID=$(gt.interface /etc/jail.conf | sed -e 's/[[:space:]]*vnet.interface[[:space:]]*=[[:space:]]*"e//g' -e 's/b_[[:alnum:]]*\";//g' | sort -n | tail -1)
    LAST_ID=$(ifconfig | awk '/IFID/{gsub("IFID=","",$2); print $2}' | sort -n | tail -1)
    if [ ! X"${LAST_ID}" = "X" ]; then
        NEXT_ID=$(( LAST_ID + 1 ))
        INTERFACE_ID=${NEXT_ID}
    else
        INTERFACE_ID=0
    fi
}

#
# add the jail configuration to jail.conf
#
create_jailconf_entry()
{
    get_next_interface_id

    echo "add jail configuration to ${JAIL_CONF}" | tee -a "${LOG_FILE}"

    sed \
        -e "s|%%JAIL_NAME%%|${JAIL_NAME}|g"           \
        -e "s|%%JAIL_INTERFACE%%|${JAIL_INTERFACE}|g" \
        -e "s|%%JAIL_UUID%%|${JAIL_UUID}|g"           \
        -e "s|%%JAIL_IP%%|${JAIL_IP}|g"               \
        -e "s|%%JAIL_DIR%%|${JAIL_DIR}|g"             \
        -e "s|%%INTERFACE_ID%%|${INTERFACE_ID}|g"     \
        -e "s|%%BRIDGE%%|${BRIDGE}|g"                 \
        -e "s|%%GATEWAY%%|${GATEWAY}|g"               \
        "${TEMPLATE_DIR}/${JAIL_TEMPLATE}" >> "${JAIL_CONF}"

    echo ""
}

#
# change some additional settings
#
setup_system()
{
    echo "Setup jail: \"${JAIL_NAME}\"" | tee -a "${LOG_FILE}"
    echo "----------------------------"
    # add some default values for /etc/rc.conf
    # but first create the file, so sysrc wont show an error
    touch "${JAIL_DIR}/etc/rc.conf"

    # System
    sysrc -R "${JAIL_DIR}" syslogd_flags="-ss"

    # remove /boot directory, not needed in a jail
    if [ ! X"${JAIL_DIR}" = "X" ] && [ -d "${JAIL_DIR}/boot/" ]; then
        rm -r "${JAIL_DIR:?}/boot/"
    fi

    # remove man pages
    if [ ! X"${JAIL_DIR}" = "X" ] && [ -d "${JAIL_DIR}/usr/share/man/" ]; then
        rm -r "${JAIL_DIR:?}"/usr/share/man/*
    fi

    # remove test files
    if [ ! X"${JAIL_DIR}" = "X" ] && [ -d "${JAIL_DIR}/usr/tests/" ]; then
        rm -r "${JAIL_DIR:?}"/usr/tests/*
    fi

    # create directory "/usr/share/keys/pkg/revoked/"
    # or pkg inside the jail wont work.
    #mkdir ${JAIL_DIR}/usr/share/keys/pkg/revoked/

    # set timezone in jail
    echo "Setup timezone: ${TIME_ZONE}" | tee -a "${LOG_FILE}"
    tzsetup -sC "${JAIL_DIR}" "${TIME_ZONE}"

    # Network
    echo "nameserver ${NAME_SERVER}" > "${JAIL_DIR}/etc/resolv.conf"

    if [ ${VNET} = "true" ]; then
        echo "Adding VNET IP ${JAIL_IP}"
        #sysrc -R ${JAIL_DIR} =${JAIL_IP}
    fi

    # Mailing
    echo "configure dma mailer"
    (
        sysrc -R "${JAIL_DIR}" sendmail_enable=NO
        sysrc -R "${JAIL_DIR}" sendmail_submit_enable=NO
        sysrc -R "${JAIL_DIR}" sendmail_outbound_enable=NO
        sysrc -R "${JAIL_DIR}" sendmail_msp_queue_enable=NO
    ) | column -t

    # mail configuration
    if [ ! -d "${JAIL_DIR}/etc/mail/" ]; then
        mkdir "${JAIL_DIR}/etc/mail/"
    fi

    echo "sendmail  /usr/libexec/dma" >  "${JAIL_DIR}/etc/mail/mailer.conf"
    echo "mailq     /usr/libexec/dma" >> "${JAIL_DIR}/etc/mail/mailer.conf"
    echo ""
}

#
# setup the repository
#
setup_repository()
{
    # setup repository
    echo "configure pkg repositories:"

    echo "enable official FreeBSD pkg repository"
    mkdir -p "${JAIL_DIR}/usr/local/etc/pkg/repos"
    echo "FreeBSD: { enabled: yes }" > "${JAIL_DIR}/usr/local/etc/pkg/repos/FreeBSD.conf"

    echo "enable pkbase repository: ${REPO_NAME}"
    if [ -f "${TEMPLATE_DIR}/FreeBSD-repo.conf.template" ]; then
        sed \
            -e "s|%%REPO_NAME%%|${REPO_NAME}|g"  \
            -e "s|%%REPO_HOST%%|${REPO_HOST}|g" \
            "${TEMPLATE_DIR}/FreeBSD-repo.conf.template" >> "${JAIL_DIR}/usr/local/etc/pkg/repos/${REPO_NAME}.conf"
    else
        echo "WARNING: \"FreeBSD-repo.conf.template\" not found, please check \"${TEMPLATE_DIR}\""
    fi
}

#
# delete the jail dataset
#
destroy_dataset()
{
    if check_dataset; then
        echo "Deleting dataset: ${JAIL_DATASET_ROOT}/${JAIL_NAME}" | tee -a "${LOG_FILE}"
        # forcibly unmount the dataset to prevent problems
        # zfs "destroying" the dataset
        umount -f "${JAIL_DIR}"
        zfs destroy "${JAIL_DATASET_ROOT}/${JAIL_NAME}"
    else
        echo "ERROR: no dataset ${JAIL_DATASET_ROOT}/${JAIL_NAME}"
    fi
    echo ""
}

#
# remove the jail configuration from jail.conf
#
destroy_jailconf_entry()
{
    if check_jailconf; then
        echo "Deleting entry: ${JAIL_NAME}"
        sed  -i '' "/^${JAIL_NAME}[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/d" "${JAIL_CONF}"
    else
        echo "ERROR: no entry ${JAIL_NAME} in \"${JAIL_CONF}\""
    fi
    echo ""
}

#
# create a logfile to protocol the script run
#
create_log_file()
{
    LOG_FILE="/tmp/jailer_${ACTION}_${JAIL_NAME}_$(date +%Y%m%d%H%M).log"
    echo "INFO: Logs are written to: ${LOG_FILE}"
    echo ""
}


create_jail()
{
    if [ X"${JAIL_IP}" = "X" ]; then
        echo "ERROR: no ip adresse given (-i)"
        exit 2
    fi

    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"
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
        setup_repository 

        if [ "${INSTALL_PKGTOOL}" = "YES" ]; then
            install_pkgtool
        fi

        service jail start "${JAIL_NAME}"
	if [ "$(sysrc -n pf_enable)" = "YES" ]; then
            service pf reload
	fi

        # install additional packages
        install_pkgs
        # enable services specified in -e argument
        enable_services

        service jail stop "${JAIL_NAME}"

        # copy files into the jail specified in -c argument
        copy_files

        # start the jail when -s argument is set
        if [ ${AUTO_START} = "true" ]; then
            service jail start "${JAIL_NAME}"
        fi
    fi
}

destroy_jail()
{
    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"

    if ! check_jailconf; then
        echo "ERROR: $JAIL_NAME does not exist."
        exit 2
    elif ! check_dataset; then
        echo "ERROR: dataset ${JAIL_DATASET_ROOT}/${JAIL_NAME} does not exist."
        exit 2
    else
        service jail stop "${JAIL_NAME}"
        destroy_jailconf_entry
        destroy_dataset
    fi
    echo ""
}

update_jail()
{
    if [ $MINIJAIL = "true" ]; then
        REPO_NAME="FreeBSD-basecore"
    fi

    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"

    if [ "${BASE_UPDATE}" = "true" ]; then
        echo "Updating system"
        echo "---------------"
        set -o pipefail
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true update  --repository "${REPO_NAME}" ${PKG_QUIET} | tee -a "${LOG_FILE}"
        #pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true update  ${PKG_QUIET} | tee -a "${LOG_FILE}"
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true upgrade --repository "${REPO_NAME}" ${PKG_QUIET} | tee -a "${LOG_FILE}"
        #pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true upgrade ${PKG_QUIET} | tee -a "${LOG_FILE}"
        set +o pipefail
        echo ""
    fi

    if [ ${PKG_UPDATE} = "true" ]; then
        echo "Updating packages"
        echo "-----------------"
        set -o pipefail
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true update  --repository FreeBSD ${PKG_QUIET} | tee -a "${LOG_FILE}"
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true upgrade --repository FreeBSD ${PKG_QUIET} | tee -a "${LOG_FILE}"
        set +o pipefail
        echo ""
    fi

    if [ $? -lt 0 ]; then
        echo "ERROR: installation of ${PKG} failed"
    fi
}

ACTION="$1"
JAIL_NAME="$2"

# check for numbers of arguments
# ACTION and JAILNAME are mandatory
# exit when less then 2 arguments
# or the ACTION is not the list command
if [ $ARG_NUM -lt 2 ] && [ ! "${ACTION}" == "list" ] ; then
    usage
fi

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
        create_log_file
        update_jail
        if [ "${AUTO_START}" = "true" ]; then
            service jail restart "${JAIL_NAME}"
        fi
        ;;
    list)
        jls -N
        ;;
    start)
        service jail start "${JAIL_NAME}"
	if [ "$(sysrc -n pf_enable)" = "YES" ]; then
            service pf reload
	fi
        ;;
    stop)
        service jail stop "${JAIL_NAME}"
        ;;
    restart)
        service jail restart "${JAIL_NAME}"
	if [ "$(sysrc -n pf_enable)" = "YES" ]; then
            service pf reload
	fi
        ;;
    *) usage
esac
