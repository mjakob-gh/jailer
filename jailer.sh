#!/bin/sh
# shellcheck disable=SC2039,SC2059,SC2181

########################
## Variabledefinition ##
########################

# remove comment for "Debug" mode
#set -x

# jailer configuration file
JAILER_CONF="/usr/local/etc/jailer.conf"

# template directory
JAILER_TEMPLATE_DIR="/usr/local/share/jailer"

# ANSI Color Codes
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
WHITE="\033[0;37m"

# Bold an underline
BOLD="\033[1m"
UNDERLINE="\033[4m"

# End ofANSI Code
ANSI_END="\033[0m"

# Program basename
PGM="${0##*/}" # Program basename

VERSION="2.1"

# Number of arguments
ARG_NUM=$#

# Global exit status
SUCCESS=0
FAILURE=1

# Create zfs pools with/without compression
# can be overwritten in jailer.conf
ZFS_COMPRESSION="YES"

# Install the pkg tool at jail creation
INSTALL_PKGTOOL="YES"

# Default pkgbase repositoryname,
# can be overwritten in jailer.conf
REPO_NAME="FreeBSD-pkgbase"

# Repository where the "official" packages are hosted,
# defaults to the FreeBSD Projects repository. When a
# poudriere repo is hosted change the in jailer.conf
OFFICIAL_REPO_NAME="FreeBSD"

# load configuration file
# default values
# check for config file                      
if [ ! -f ${JAILER_CONF} ]; then 
    printf "${RED}[ERROR]${ANSI_END} config file ${BOLD}${WHITE}%s${ANSI_END} does not exist!" "${JAILER_CONF}"
    exit ${FAILURE}                                   
else
    . ${JAILER_CONF}
fi

# initialise variables
JAIL_NAME=""
JAIL_CONF="/etc/jail.conf"

JAIL_IP=""
JAIL_UUID=$( uuidgen )

NAME_SERVER=$( local-unbound-control list_forwards | awk '/^. IN/ {print $NF}' )

LOG_FILE=""
ABI_VERSION=$( pkg config abi )
PKGS=""
SERVICES=""
COPY_FILES=""
AUTO_START=false
BASE_UPDATE=false
PKG_UPDATE=false
PKG_QUIET=""

VNET=false
MINIJAIL=false
INTERFACE_ID=0

USE_PAGER="NO"

##################################
## functions                    ##
##################################

#
# check
#
checkResult ()
{
    if [ "$1" -eq 0 ]; then
        printf "${GREEN}[OK]${ANSI_END}\n"
    else
        printf "${RED}[ERROR]${ANSI_END}\n"
    fi
}

#
# decipher the programm arguments
#
get_args()
{
    while getopts "a:c:e:i:n:P:r:t:blmpqsv" option
    do
        case $option in
            a)
                if [ ! X"${OPTARG}" = "X" ]; then
                    ABI_VERSION=${OPTARG}
                else
                    printf "${BLUE}[INFO]${ANSI_END}  no ABI VERSION specified, using default ${BOLD}${WHITE}%s${ANSI_END}\n." "${ABI_VERSION}"
                fi
                ;;
            b)
                BASE_UPDATE=true
                ;;
            c)
                if [ ! X"${OPTARG}" = "X" ]; then
                    COPY_FILES=${OPTARG}
                    printf "${BLUE}[INFO]${ANSI_END}  Copying files: ${BOLD}${WHITE}%s${ANSI_END}\n." "${COPY_FILES}"
                fi
                ;;
            e)
                if [ ! X"${OPTARG}" = "X" ]; then
                    SERVICES=${OPTARG}
                fi
                ;;
            i)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > /dev/null; then
                    JAIL_IP=${OPTARG}
                else
                    printf "${RED}[ERROR]${ANSI_END} invalid IP address ${BOLD}${WHITE}%s${ANSI_END}\n." "${OPTARG}"
                    exit 2
                fi
                ;;
            l)
                USE_PAGER="YES"
                ;;
            m)
                MINIJAIL=true
                ;;
            n)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > /dev/null; then
                    NAME_SERVER=${OPTARG}
                else
                    printf "${RED}[ERROR]${ANSI_END} invalid IP address for nameserver ${BOLD}${WHITE}%s${ANSI_END}\n." "${OPTARG}"
                    exit 2
                fi
                ;;
            p)
                PKG_UPDATE=true
                ;;
            P)
                if [ ! X"${OPTARG}" = "X" ]; then
                    PKGS=${OPTARG}
                else
                    printf "${BLUE}[INFO]${ANSI_END}  no packages specified.\n"
                fi
                ;;
            r)
                if [ ! X"${OPTARG}" = "X" ]; then
                    REPO_NAME=${OPTARG}
                    check_repo
                else
                    printf "${BLUE}[INFO]${ANSI_END}  no repository specified, using default ${BOLD}${WHITE}%s${ANSI_END}\n." "${REPO_NAME}"
                fi
                ;;
            q)
                PKG_QUIET="--quiet"
                ;;
            s)
                AUTO_START=true
                ;;
            t)
                if [ ! X"${OPTARG}" = "X" ]; then
                    TIME_ZONE=${OPTARG}
                else
                    printf "${BLUE}[INFO]${ANSI_END}  no timezone specified, using default ${BOLD}${WHITE}%s${ANSI_END}\n." "${TIME_ZONE}"
                fi
                ;;
            v)
                JAIL_TEMPLATE="jail-vnet.template"
                VNET=true
                ;;
            *)
             
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
    ### NAME
    printf "${BOLD}NAME${ANSI_END}\n"
    printf "  ${BOLD}%s${ANSI_END} – %s\n" "${PGM}" "create, destroy and update FreeBSD jails"
    echo   ""

    ### SYNOPSIS
    printf "${BOLD}SYNOPSIS${ANSI_END}\n"
    printf "  ${BOLD}%s create jailname${ANSI_END} ${BOLD}-i${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} [${BOLD}-t${ANSI_END} ${UNDERLINE}timezone${ANSI_END} ${BOLD}-r${ANSI_END} ${UNDERLINE}reponame${ANSI_END} ${BOLD}-n${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} ${BOLD}-v -P${ANSI_END} ${UNDERLINE}\"list of packages\"${ANSI_END} ${BOLD}-a${ANSI_END} ${UNDERLINE}ABI_Version${ANSI_END} ${BOLD}-e${ANSI_END} ${UNDERLINE}\"list of services\"${ANSI_END} ${BOLD}-s -q${ANSI_END}]\n" "${PGM}"
    printf "  ${BOLD}%s destroy${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n" "${PGM}"
    printf "  ${BOLD}%s update${ANSI_END} ${UNDERLINE}jailname${ANSI_END} [-${BOLD}b -p -s${ANSI_END}]\n" "${PGM}"
    printf "  ${BOLD}%s list${ANSI_END}\n" "${PGM}"
    printf "  ${BOLD}%s start${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n" "${PGM}"
    printf "  ${BOLD}%s stop${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n" "${PGM}"
    printf "  ${BOLD}%s restart${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n" "${PGM}"
    printf "  ${BOLD}%s reloadpf${ANSI_END}\n" "${PGM}"
    printf "  ${BOLD}%s shell${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n" "${PGM}"
    printf "  ${BOLD}%s shell${ANSI_END} ${UNDERLINE}jailname${ANSI_END} ${UNDERLINE}command${ANSI_END}\n" "${PGM}"
    printf "  ${BOLD}%s help${ANSI_END} [${BOLD}-l${ANSI_END}]\n" "${PGM}"
    echo   ""

    ### DESCRIPTION
    printf "${BOLD}DESCRIPTION${ANSI_END}\n"
    printf "\tthe ${BOLD}%s${ANSI_END} command creates, destroys and controls FreeBSD jails build from a pkgbase or basecore repositories.\n" "${PGM}"
    echo   ""

    printf "  ${BOLD}%s create jailname${ANSI_END} ${BOLD}-i${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} [${BOLD}-t${ANSI_END} ${UNDERLINE}timezone${ANSI_END} ${BOLD}-r${ANSI_END} ${UNDERLINE}reponame${ANSI_END} ${BOLD}-n${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} ${BOLD}-v -P${ANSI_END} ${UNDERLINE}\"list of packages\"${ANSI_END} ${BOLD}-a${ANSI_END} ${UNDERLINE}ABI_Version${ANSI_END} ${BOLD}-e${ANSI_END} ${UNDERLINE}\"list of services\"${ANSI_END} ${BOLD}-s -q${ANSI_END}]\n" "${PGM}"
    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\t%s\n" "-i" "ipaddress" "set IP address of jail."
    echo   ""
    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\t%s\n" "-t" "timezone" "set Timezone of jail."
    echo   ""
    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\t%s\n" "-n" "ipaddress" "set DNS server IP address of jail."
    echo   ""
    printf "\t${BOLD}%s${ANSI_END} %s\t%s\n" "-v" "" "create a VNET jail."
    echo   ""
    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\t%s\n" "-r" "reponame" "set pkg repository of jail."
    echo   ""
    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\t%s\n" "-P" "\"list of packages\"" "packages to install in the jail, the list is seperated by whitespace."
    echo   ""

    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\t%s\n" "-c" "\"source_file:target_file(,...)\"" "copy files INTO the jail."
    echo   ""
    printf "\t\t%s\n" "NOTE:"
    printf "\t\t%s\n" " • use a comma seperated list for multiple copies"
    printf "\t\t%s\n" " • consider beginning and trailing slashes"
    printf "\t\t%s\n" " • consider the file permissions"
    printf "\t\t%s\n" " • consider whitespaces in the parameter string"
    echo   ""

    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\t%s\n" "-a" "ABI_Version" "set the ABI Version to match the packages to be installed to the jail."
    echo   ""
    printf "\t\t%s\n" "NOTE: Possible values for ABI_VERSION"
    printf "\t\t%s\n" " • FreeBSD:12:amd64"
    printf "\t\t%s\n" " • FreeBSD:13:amd64"
    echo   ""
            
    printf "\t${BOLD}%s${ANSI_END}\t%s\n" "-m" "use minijail package."
    echo   ""

    printf "\t${BOLD}%s${ANSI_END} ${UNDERLINE}%s${ANSI_END}\n\t\tenable existing or just now installed services (see -P parameter), the list is seperated by whitespace.\n" "-e" "\"list of services\""
    echo   ""

    printf "\t${BOLD}%s${ANSI_END}\t%s\n" "-s" "start the jail after the installation is finished."
    echo   ""
    printf "\t${BOLD}%s${ANSI_END}\t%s\n" "-q" "dont show output of pkg."
    echo   ""
    echo   ""

    printf "  ${BOLD}%s destroy${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n\t\tthe jail is stopped, the dataset destroyed and the ${UNDERLINE}jailname${ANSI_END} removed from jail.conf\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s update${ANSI_END} ${UNDERLINE}jailname${ANSI_END} [-${BOLD}b -p -s${ANSI_END}]\n" "${PGM}"
    printf "\t${BOLD}%s${ANSI_END}\t%s\n" "-b" "update the pkgbase system"
    echo   ""
    printf "\t${BOLD}%s${ANSI_END}\t%s\n" "-p" "update the installed packages"
    echo   ""
    printf "\t${BOLD}%s${ANSI_END}\t%s\n" "-s" "restart jail after update"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s list${ANSI_END}\n\t\tlist status of all running jails\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s start${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n\t\tstart all jails, or only given ${UNDERLINE}jailname${ANSI_END}.\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s stop${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n\t\tstop all jails, or only given ${UNDERLINE}jailname${ANSI_END}.\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s restart${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n\t\trestart all jails, or only given ${UNDERLINE}jailname${ANSI_END}.\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s reloadpf${ANSI_END}\n\t\treload pf firewall rules.\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s shell${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n\t\tget shell access to given ${UNDERLINE}jailname${ANSI_END}.\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s exec${ANSI_END} ${UNDERLINE}jailname${ANSI_END} ${UNDERLINE}command${ANSI_END}\n\t\texecutes ${UNDERLINE}command${ANSI_END} inside the jail identified by its ${UNDERLINE}jailname${ANSI_END}.\n" "${PGM}"
    echo   ""
    echo   ""

    printf "  ${BOLD}%s help${ANSI_END} [${BOLD}-l${ANSI_END}]\n\t\tprint this help message.\n" "${PGM}"
    printf "\t${BOLD}%s${ANSI_END}\t%s\n" "-l" "open help message in pager.\n"
    echo   ""

    ### DESCRIPTION
    printf "${BOLD}DESCRIPTION${ANSI_END}\n"
    printf "\tthe ${BOLD}%s${ANSI_END} command creates, destroys and manages FreeBSD jails.\n" "${PGM}"
    echo   ""

    ### FILES
    printf "${BOLD}FILES${ANSI_END}\n"
    printf "\t${JAILER_CONF}\n\t${JAILER_TEMPLATE_DIR}/*\n"
    echo   ""

    ### EXIT STATUS
    printf "${BOLD}EXIT STATUS${ANSI_END}\n"
    printf "\tthe ${BOLD}%s${ANSI_END} utility exit 0 on success, 1 if there are problems with the installation and 2 if the wrong arguments are given.\n" "${PGM}"
    echo   ""

    ### SEE ALSO
    printf "${BOLD}SEE ALSO${ANSI_END}\n"
    printf "\tjail(8), jail.conf(5), rc.conf(5), zfs(8)\n"
    echo   ""

    exit ${SUCCESS}
}

#
# check the jailer setup
#
validate_setup()
{
    # only root can start the programm
    if [ "$( id -u )" -ne 0 ]; then
        printf "${RED}[ERROR]${ANSI_END} ${PGM} must run as root!\n"
        exit "${FAILURE}"
    fi

    # check if jails are enabled
    if [ ! "$( sysrc -n jail_enable )" = "YES" ] ; then
        printf "${YELLOW}[WARN]${ANSI_END}  jails service is not enabled.\n"
    fi

    # check for template file
    if [ "$( find "${JAILER_TEMPLATE_DIR}" -name '*.template' | wc -l | sed 's/[[:space:]]//g' )" -eq 0 ] ; then
        printf "${RED}[ERROR]${ANSI_END} template files \"%s/*\" do not exist!\n" "${JAILER_TEMPLATE_DIR}"
        exit ${FAILURE}
    fi
}

#
# check if repository configuration exists
#
check_repo()
{
    if [ ! -f "/usr/local/etc/pkg/repos/${REPO_NAME}.conf" ]; then
        printf "${RED}[ERROR]${ANSI_END} no repository ${BOLD}${WHITE}%s${ANSI_END} found!" "${JAILER_TEMPLATE_DIR}" "${REPO_NAME}"
        exit 2
    fi
}

#
# check if given jailname already exists in jail.conf
#
check_jailconf()
{
    if grep -e "^${JAIL_NAME} {" ${JAIL_CONF} > /dev/null 2>&1; then
        return ${SUCCESS}
    else
        return ${FAILURE}
    fi
}

#
# check if given jaildataset already exists
#
check_dataset()
{
    if zfs list "${JAIL_DATASET_ROOT}/${JAIL_NAME}" > /dev/null 2>&1; then
        return ${SUCCESS}
    else
        return ${FAILURE}
    fi
}

#
# create the dataset
#
create_dataset()
{
    if [ "${ZFS_COMPRESSION}" = "NO" ] ; then
        COMPRESS="off"
    else
        COMPRESS="on"
    fi
    
    printf "${BLUE}[INFO]${ANSI_END}  create zfs dataset: ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_DATASET_ROOT}/${JAIL_NAME}"
    set -o pipefail
    zfs create -o compression="${COMPRESS}" "${JAIL_DATASET_ROOT}/${JAIL_NAME}" | tee -a "${LOG_FILE}"
    set +o pipefail
}

#
# install the pkgbase pkgs
#
install_baseos_pkg()
{
    # create "${JAIL_DIR}/var/cache/pkg", or pkg complains
    mkdir -p "${JAIL_DIR}/var/cache/pkg" || exit 1

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
                printf "${RED}[ERROR]${ANSI_END} invalid OS Version detectet: ${BOLD}${WHITE}%s${ANSI_END}\n" "${ABI_VERSION}"
                exit ${FAILURE}
                ;;
        esac
    fi

    printf "${BLUE}[INFO]${ANSI_END}  using repository:   ${BOLD}${WHITE}%s${ANSI_END}\n" "${REPO_NAME}"
    printf "${BLUE}[INFO]${ANSI_END}  install pkg:        ${BOLD}${WHITE}%s %s${ANSI_END}\n" "${CORE_PKGS}" "${EXTRA_PKGS}"
    echo   ""

    # Install the base system
    set -o pipefail
    # the packages must be passed to pkg as multiple parameters, so dont use quotes and ignore the shellcheck error
    # shellcheck disable=SC2086
    pkg --rootdir "${JAIL_DIR}" -o ASSUME_ALWAYS_YES=true -o ABI="${ABI_VERSION}" install ${PKG_QUIET} --repository "${REPO_NAME}" ${CORE_PKGS} ${EXTRA_PKGS} | tee -a "${LOG_FILE}"
    pkg --rootdir "${JAIL_DIR}" -o ASSUME_ALWAYS_YES=true clean | tee -a "${LOG_FILE}"
    echo ""

    set +o pipefail
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
    echo ""
}

#
# install additional packages
#
install_pkgs()
{
    if [ ! X"${PKGS}" = "X" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  Install pkgs:\n"
        # install the pkg package
        install_pkgtool

        for PKG in ${PKGS}
        do
            printf "%s " "${PKG}"
            set -o pipefail
            pkg -j "${JAIL_NAME}" -o ASSUME_ALWAYS_YES=true install ${PKG_QUIET} --repository "${OFFICIAL_REPO_NAME}" "${PKG}" | tee -a "${LOG_FILE}"
            if [ $? -lt 0 ]; then
                printf "${RED}[ERROR]${ANSI_END} installation of ${BOLD}${WHITE}%s${ANSI_END} failed" "${PKG}"
            fi
            set +o pipefail
        done
        pkg -j "${JAIL_NAME}" -o ASSUME_ALWAYS_YES=true ${PKG_QUIET} clean --all --quiet | tee -a "${LOG_FILE}"
    fi
}

#
# enable given services
#
enable_services()
{
    if [ ! X"${SERVICES}" = "X" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  Enabling Services:\n"
        for SERVICE in ${SERVICES}
        do
            printf "${BLUE}[INFO]${ANSI_END}  ${BOLD}${WHITE}%s${ANSI_END}\n" "${SERVICE}"
            service -j "${JAIL_NAME}" "${SERVICE}" enable > /dev/null
        done
        echo ""
    fi
}

#
# copy files into the jail
#
copy_files()
{
    if [ ! X"${COPY_FILES}" = "X" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  Copying files:\n"
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

    printf "${BLUE}[INFO]${ANSI_END}  add jail config:    ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_CONF}"

    sed -e "s|%%JAIL_NAME%%|${JAIL_NAME}|g"             \
        -e "s|%%JAIL_DOMAINNAME%%|${JAIL_DOMAINNAME}|g" \
        -e "s|%%JAIL_INTERFACE%%|${JAIL_INTERFACE}|g"   \
        -e "s|%%JAIL_UUID%%|${JAIL_UUID}|g"             \
        -e "s|%%JAIL_IP%%|${JAIL_IP}|g"                 \
        -e "s|%%JAIL_DIR%%|${JAIL_DIR}|g"               \
        -e "s|%%INTERFACE_ID%%|${INTERFACE_ID}|g"       \
        -e "s|%%BRIDGE%%|${BRIDGE}|g"                   \
        -e "s|%%GATEWAY%%|${GATEWAY}|g"                 \
        "${TEMPLATE_DIR}/${JAIL_TEMPLATE}" >> "${JAIL_CONF}"
}

#
# change and do some additional things
#
setup_system()
{
    printf "${BLUE}[INFO]${ANSI_END}  setup jail:        ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_NAME}"
    # add some default values for /etc/rc.conf
    # but first create the file, so sysrc wont show an error
    touch "${JAIL_DIR}/etc/rc.conf"

    # System
    printf "${BLUE}[INFO]${ANSI_END}  configure syslog:  ${BOLD}${WHITE}syslogd_flags: -s -> -ss${ANSI_END}\n"
    sysrc -R "${JAIL_DIR}" syslogd_flags="-ss" > /dev/null

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
        rm -r "${JAIL_DIR:?}/usr/tests/*"
    fi

    # set timezone in jail
    printf "${BLUE}[INFO]${ANSI_END}  setup timezone:    ${BOLD}${WHITE}%s${ANSI_END}\n" "${TIME_ZONE}"
    tzsetup -sC "${JAIL_DIR}" "${TIME_ZONE}"

    # Network
    printf "${BLUE}[INFO]${ANSI_END}  add nameserver:    ${BOLD}${WHITE}%s${ANSI_END}\n" "${NAME_SERVER}"
    echo "nameserver ${NAME_SERVER}" > "${JAIL_DIR}/etc/resolv.conf"

    # print the IP Adress
    if [ ${VNET} = "true" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  add VNET IP:       ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_IP}"
    fi

    # configure mailing
    printf "${BLUE}[INFO]${ANSI_END}  disable mailer:    ${BOLD}${WHITE}sendmail${ANSI_END}\n"
    printf "${BLUE}[INFO]${ANSI_END}  enable mailer:     ${BOLD}${WHITE}DMA mailer${ANSI_END}\n"
    (
        sysrc -R "${JAIL_DIR}" sendmail_enable=NO
        sysrc -R "${JAIL_DIR}" sendmail_submit_enable=NO
        sysrc -R "${JAIL_DIR}" sendmail_outbound_enable=NO
        sysrc -R "${JAIL_DIR}" sendmail_msp_queue_enable=NO
    ) > /dev/null

    # mail configuration
    if [ ! -d "${JAIL_DIR}/etc/mail/" ]; then
        mkdir "${JAIL_DIR}/etc/mail/"
    fi

    echo "sendmail  /usr/libexec/dma" >  "${JAIL_DIR}/etc/mail/mailer.conf"
    echo "mailq     /usr/libexec/dma" >> "${JAIL_DIR}/etc/mail/mailer.conf"
}

#
# setup the pkg repository
#
setup_repository()
{
    # setup repository
    printf "${BLUE}[INFO]${ANSI_END}  enable repository: ${BOLD}${WHITE}FreeBSD${ANSI_END}\n"

    mkdir -p "${JAIL_DIR}/usr/local/etc/pkg/repos"
    echo "FreeBSD: { enabled: yes }" > "${JAIL_DIR}/usr/local/etc/pkg/repos/FreeBSD.conf"

    printf "${BLUE}[INFO]${ANSI_END}  enable repository: ${BOLD}${WHITE}%s${ANSI_END}\n" "${REPO_NAME}"
    if [ -f "${TEMPLATE_DIR}/FreeBSD-repo.conf.template" ]; then
        sed -e "s|%%REPO_NAME%%|${REPO_NAME}|g"  \
            -e "s|%%REPO_HOST%%|${REPO_HOST}|g" \
            "${TEMPLATE_DIR}/FreeBSD-repo.conf.template" >> "${JAIL_DIR}/usr/local/etc/pkg/repos/${REPO_NAME}.conf"
    else
        printf "${YELLOW}[WARN]${ANSI_END}  \"FreeBSD-repo.conf.template\" not found, please check ${BOLD}${WHITE}%s${ANSI_END}\n" "${TEMPLATE_DIR}"
    fi
    echo ""
}

#
# delete the jail dataset
#
destroy_dataset()
{
    if check_dataset; then
        printf "${BLUE}[INFO]${ANSI_END}  Deleting dataset: ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_DATASET_ROOT}/${JAIL_NAME}"
        # forcibly unmount the dataset to prevent problems
        # zfs "destroying" the dataset
        umount -f "${JAIL_DIR}"
        zfs destroy "${JAIL_DATASET_ROOT}/${JAIL_NAME}" | tee -a "${LOG_FILE}"
    else
        printf "${RED}[ERROR]${ANSI_END} no dataset ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_DATASET_ROOT}/${JAIL_NAME}"
    fi
}

#
# remove the jail configuration from jail.conf
#
destroy_jailconf_entry()
{
    if check_jailconf; then
        printf "${BLUE}[INFO]${ANSI_END}  Deleting entry: ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_NAME}"
        sed -i '' "/^${JAIL_NAME}[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/d" "${JAIL_CONF}"
    else
        printf "${RED}[ERROR]${ANSI_END} no entry ${BOLD}${WHITE}%s${ANSI_END} in ${BOLD}${WHITE}%s${ANSI_END}\n" "${JAIL_NAME}" "${JAIL_CONF}"
    fi
}

#
# create a logfile to protocol the script run
#
create_log_file()
{
    LOG_FILE="/tmp/jailer_${ACTION}_${JAIL_NAME}_$(date +%Y%m%d%H%M).log"
    printf "${BLUE}[INFO]${ANSI_END}  creating logfile:   ${BOLD}${WHITE}%s${ANSI_END}\n" "${LOG_FILE}"
}


#
# finally create the jail
#
create_jail()
{
    if [ X"${JAIL_IP}" = "X" ]; then
        printf "${RED}[ERROR]${ANSI_END} no ip adresse given (-i)\n"
        exit 2
    fi

    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"
    if check_jailconf; then
        printf "${RED}[ERROR]${ANSI_END} ${BOLD}${WHITE}%s${ANSI_END} already exists in ${BOLD}${WHITE}%s${ANSI_END}!\n" "${JAIL_NAME}" "${JAIL_CONF}"
        exit 2
    elif check_dataset; then
        printf "${RED}[ERROR]${ANSI_END} dataset ${BOLD}${WHITE}%s${ANSI_END} already exists!\n" "${JAIL_DATASET_ROOT}/${JAIL_NAME}"
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

        printf "${BLUE}[INFO]${ANSI_END}  "
        service jail start "${JAIL_NAME}"
	if [ "$(sysrc -n pf_enable)" = "YES" ]; then
            service pf reload > /dev/null
	fi

        # install additional packages
        install_pkgs
        # enable services specified in -e argument
        enable_services

        printf "${BLUE}[INFO]${ANSI_END}  "
        service jail stop "${JAIL_NAME}"

        # copy files into the jail specified in -c argument
        copy_files

        # start the jail when -s argument is set
        if [ ${AUTO_START} = "true" ]; then
            printf "${BLUE}[INFO]${ANSI_END}  "
            service jail start "${JAIL_NAME}"
        fi
    fi
}

#
# remove the jail from the system
#
destroy_jail()
{
    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"

    if ! check_jailconf; then
        printf "${RED}[ERROR]${ANSI_END} jail ${BOLD}${WHITE}%s${ANSI_END} does not exist!\n" "${JAIL_NAME}"
        exit 2
    elif ! check_dataset; then
        printf "${RED}[ERROR]${ANSI_END} dataset ${BOLD}${WHITE}%s${ANSI_END} does not exist!\n" "${JAIL_DATASET_ROOT}/${JAIL_NAME}"
        exit 2
    else
        printf "${BLUE}[INFO]${ANSI_END}  "
        service jail stop "${JAIL_NAME}"
        destroy_jailconf_entry
        destroy_dataset
    fi
    echo ""
}

#
# update the base jail and/or installed packages
#
update_jail()
{
    if [ $MINIJAIL = "true" ]; then
        REPO_NAME="FreeBSD-basecore"
    fi

    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"

    if [ "${BASE_UPDATE}" = "true" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  Updating system\n"
        set -o pipefail
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true update  --repository "${REPO_NAME}" ${PKG_QUIET} | tee -a "${LOG_FILE}"
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true upgrade --repository "${REPO_NAME}" ${PKG_QUIET} | tee -a "${LOG_FILE}"
        set +o pipefail
        if [ $? -lt 0 ]; then
            printf "${RED}[ERROR]${ANSI_END} update of base failed!\n"
        fi
        echo ""
    fi

    if [ ${PKG_UPDATE} = "true" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  Updating packages\n"
        set -o pipefail
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true update  --repository FreeBSD ${PKG_QUIET} | tee -a "${LOG_FILE}"
        pkg -j "${JAIL_NAME}" -o ABI="${ABI_VERSION}" -o ASSUME_ALWAYS_YES=true upgrade --repository FreeBSD ${PKG_QUIET} | tee -a "${LOG_FILE}"
        set +o pipefail
        if [ $? -lt 0 ]; then
            printf "${RED}[ERROR]${ANSI_END} update of the installaed packages failed!\n"
        fi
        echo ""
    fi
}

#
# start all or a named jail
#
start_jail()
{
    if [ "$1" = "" ] ; then
        printf "${BLUE}[INFO]${ANSI_END}  "
        service jail start
    else
        printf "${BLUE}[INFO]${ANSI_END}  "
        service jail start "$1"
    fi
    if [ "$(sysrc -n pf_enable)" = "YES" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  "
        service pf reload
    fi
}

#
# stop all or a named jail
#
stop_jail()
{
    if [ "$1" = "" ] ; then
        printf "${BLUE}[INFO]${ANSI_END}  "
        service jail stop
    else
        printf "${BLUE}[INFO]${ANSI_END}  "
        service jail stop "$1"
    fi
    if [ "$(sysrc -n pf_enable)" = "YES" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  "
        service pf reload
    fi
}

#
# reload the pf rules, if pf is active
#
reload_pf()
{
    if [ "$(sysrc -n pf_enable)" = "YES" ]; then
        printf "${BLUE}[INFO]${ANSI_END}  "
        service pf reload
    fi
}

#
# print some host an jailer information
#
get_info()
{
    printf "${BLUE}Host configuration${ANSI_END}\n"
    printf "Jail dataset:      ${WHITE}%s${ANSI_END} mounted on ${WHITE}%s${ANSI_END}\n" "${JAIL_DATASET_ROOT}" "$( zfs get -H -o value mountpoint ${JAIL_DATASET_ROOT} )"
    printf "Jails enabled:     ${WHITE}%s${ANSI_END}\n" "$( sysrc -n jail_enable )"
    printf "ABI version:       ${WHITE}%s${ANSI_END}\n" "${ABI_VERSION}"
    printf "Timezone:          ${WHITE}%s${ANSI_END}\n" "${TIME_ZONE}"
    echo   ""
    printf "${BLUE}Network configuration${ANSI_END}\n"
    printf "Firewall enabled:  ${WHITE}%s${ANSI_END}\n" "$( sysrc -n pf_enable )"
    printf "Network interface: ${WHITE}%s${ANSI_END}\n" "${JAIL_INTERFACE}"
    printf "VNET bridge:       ${WHITE}%s${ANSI_END}\n" "${BRIDGE}"
    printf "VNET gateway:      ${WHITE}%s${ANSI_END}\n" "${GATEWAY}"
    printf "Nameserver:        ${WHITE}%s${ANSI_END}\n" "${NAME_SERVER}"
    echo   ""
    printf "${BLUE}Jailer configuration${ANSI_END}\n"
    printf "Jailer version:    ${WHITE}%s${ANSI_END}\n" "${VERSION}"
    printf "Jailer repos:      ${WHITE}%s${ANSI_END}\n" "$( grep -h -B 10 "enabled: yes" /usr/local/etc/pkg/repos/FreeBSD-*base*.conf | grep ": {" | awk -F":" '{printf $1 " "}' )"
    printf "Template dir:      ${WHITE}%s${ANSI_END}\n" "${TEMPLATE_DIR}"
    printf "Jailer templates:  ${WHITE}%s${ANSI_END}\n" "$( find "${JAILER_TEMPLATE_DIR}" -type f -name 'jail*.template' -exec basename {} \; | awk '{printf $1 " "}' )"
    printf "ZFS compression:   ${WHITE}%s${ANSI_END}\n" "${ZFS_COMPRESSION}"
}

ACTION="$1"
JAIL_NAME="$2"

# check for number of arguments
# No Arguments:
if [ $ARG_NUM -eq 0 ] ; then
    printf "${RED}[ERROR]${ANSI_END} missing command!\n"
    printf "${BLUE}[INFO]${ANSI_END}  use ${BOLD}${WHITE}%s help${ANSI_END} to view help.\n" "${PGM}"
    exit 2
fi

# check if jailer is setup correctly
validate_setup

# now really get going
case "${ACTION}" in
    help)
        shift 1
        get_args "$@"
        if [ "${USE_PAGER}" = "YES" ] ; then
            usage | less -R
        else
            usage
        fi
        ;;
    info)
        get_info
        ;;
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
            printf "${BLUE}[INFO]${ANSI_END}  "
            service jail stop "${JAIL_NAME}"
            printf "${BLUE}[INFO]${ANSI_END}  "
            service jail start "${JAIL_NAME}"
        fi
        ;;
    list)
        jls -h -N jid name ip4.addr host.hostname vnet osrelease path | column -t
        ;;
    start)
        start_jail "${JAIL_NAME}"
        reload_pf
        ;;
    stop)
        stop_jail "${JAIL_NAME}"
        reload_pf
        ;;
    restart)
        stop_jail "${JAIL_NAME}"
        start_jail "${JAIL_NAME}"
        reload_pf
        ;;
    reloadpf)
        reload_pf
        ;;
    shell)
        jexec -l "${JAIL_NAME}"
        ;;
    exec)
        shift 2 
        jexec -l "${JAIL_NAME}" "$@"
        ;;
    *)
        printf "${RED}[ERROR]${ANSI_END} invalid command ${BOLD}${WHITE}%s${ANSI_END}!\n" "${ACTION}"
        printf "${BLUE}[INFO]${ANSI_END}  use ${BOLD}${WHITE}%s help${ANSI_END} to view help.\n" "${PGM}"
        exit 2
esac