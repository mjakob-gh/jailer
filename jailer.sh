#!/bin/sh
# shellcheck disable=SC2039,SC2059,SC2181

########################
## Variabledefinition ##
########################

# remove comment for "Debug" mode
#set -x

# jailer configuration file
JAILER_CONF_DIR="/usr/local/etc"

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

# define messagestrings
INFO_STRING=""
ERROR_STRING="[ERROR]"
WARN_STRING="[WARN]"

# Program basename
PGM="${0##*/}" # Program basename

VERSION="2.5"

# Number of arguments
ARG_NUM=$#

# Global exit status
SUCCESS=0
FAILURE=1

# Default netmask for VNET jails
# can be overwritten in jailer.conf
JAIL_NETMASK="24"

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

# Write actions of the script to a logfile: YES/NO
# DEFAULT: NO
WRITE_LOGFILE="NO"

# Make jail managable via ansible by
# - install python37 package
# - adding an user ansible (uid: 3456, group :wheel, password login: disabled)
#   Defaults: see jailer.conf
ENABLE_ANSIBLE="NO"

# enable sshd
# DEFAULT: NO
ENABLE_SSHD="NO"

# load configuration file
# default values
# check for config file                      
if [ ! -f "${JAILER_CONF_DIR}/jailer.conf" ]; then 
    printf "${RED}${ERROR_STRING}${ANSI_END} config file ${BOLD}${WHITE}${JAILER_CONF_DIR}/jailer.conf${ANSI_END} does not exist!"
    exit ${FAILURE}                                   
else
    # shellcheck source=/dev/null
    . "${JAILER_CONF_DIR}/jailer.conf"
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
AUTO_START="NO"
BASE_UPDATE="NO"
PKG_UPDATE="NO"
PKG_QUIET=""
ADD_USER="NO"
USER_NAME=""
USER_ID=3001
VNET="NO"
MINIJAIL="NO"
INTERFACE_ID=0
USE_PAGER="NO"

# if domainname is not set in jailer.conf
# set it to hosts domain.name
# can be overwritten with the parameter -d
if [ "${JAIL_DOMAINNAME}" = "" ] ; then
    JAIL_DOMAINNAME=$( hostname -d )
fi

##################################
## functions                    ##
##################################

#
# check
#
checkResult()
{
    if [ "$1" -eq 0 ]; then
        printf "${GREEN}[OK]${ANSI_END}\n"
    else
        printf "${RED}${ERROR_STRING}${ANSI_END}\n"
    fi
}

#
# decipher the programm arguments
#
get_args()
{
    while getopts "a:c:d:e:h:i:m:N:P:r:t:u:AblMpqsSv" option
    do
        case $option in
            a)
                if [ ! X"${OPTARG}" = "X" ]; then
                    ABI_VERSION=${OPTARG}
                fi
                ;;
            A)
                ENABLE_ANSIBLE="YES"
                ;;
            b)
                BASE_UPDATE="YES"
                ;;
            c)
                if [ ! X"${OPTARG}" = "X" ]; then
                    COPY_FILES=${OPTARG}
                fi
                ;;
            d)
                if [ ! X"${OPTARG}" = "X" ]; then
                    JAIL_DOMAINNAME=${OPTARG}
                fi
                ;;
            e)
                if [ ! X"${OPTARG}" = "X" ]; then
                    SERVICES="${SERVICES} ${OPTARG}"
                fi
                ;;
            h)
                if [ ! X"${OPTARG}" = "X" ]; then
                    JAIL_HOSTNAME=${OPTARG}
                fi
                ;;
            i)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > /dev/null; then
                    JAIL_IP=${OPTARG}
                else
                    printf "${RED}${ERROR_STRING}${ANSI_END} Invalid IP address ${BOLD}${WHITE}${OPTARG}${ANSI_END}\n"
                    exit 2
                fi
                ;;
            l)
                USE_PAGER="YES"
                ;;
            m)
                if [ ! X"${OPTARG}" = "X" ]; then
                    if ( echo "${OPTARG}" | grep -E -q '^(254|252|248|240|224|192|128)\.0\.0\.0|255\.(254|252|248|240|224|192|128|0)\.0\.0|255\.255\.(254|252|248|240|224|192|128|0)\.0|255\.255\.255\.(254|252|248|240|224|192|128|0)' ); then
                        JAIL_NETMASK=" netmask ${OPTARG}"
                    elif [ ! -z "${OPTARG##*[!0-9]*}" ] && [ "${OPTARG}" -ge 0 ] && [ "${OPTARG}" -le 30 ] 2>/dev/null; then
                        JAIL_NETMASK="${OPTARG}"
                    else
                        printf "${RED}${ERROR_STRING}${ANSI_END} invalid netmask: ${BOLD}${WHITE}${OPTARG}${ANSI_END}\n"
                        exit 1
                    fi
                fi
                ;;
            M)
                MINIJAIL="YES"
                ;;
            N)
                if expr "${OPTARG}" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > /dev/null; then
                    NAME_SERVER=${OPTARG}
                else
                    printf "${RED}${ERROR_STRING}${ANSI_END} Invalid IP address for nameserver ${BOLD}${WHITE}${OPTARG}${ANSI_END}\n"
                    exit 2
                fi
                ;;
            p)
                PKG_UPDATE="TRUE"
                ;;
            P)
                if [ ! X"${OPTARG}" = "X" ]; then
                    PKGS=${OPTARG}
                else
                    printf "${BLUE}${INFO_STRING}${ANSI_END}No packages specified.\n"
                fi
                ;;
            r)
                if [ ! X"${OPTARG}" = "X" ]; then
                    REPO_NAME=${OPTARG}
                    check_repo
                else
                    printf "${BLUE}${INFO_STRING}${ANSI_END}No repository specified, using default ${BOLD}${WHITE}${REPO_NAME}${ANSI_END}\n"
                fi
                ;;
            q)
                PKG_QUIET="--quiet"
                ;;
            s)
                AUTO_START="YES"
                ;;
            S)
                ENABLE_SSHD="YES"
                ;;
            t)
                if [ ! X"${OPTARG}" = "X" ]; then
                    TIME_ZONE=${OPTARG}
                else
                    printf "${BLUE}${INFO_STRING}${ANSI_END}No timezone specified, using default ${BOLD}${WHITE}${TIME_ZONE}${ANSI_END}\n"
                fi
                ;;
            u)
                if [ ! X"${OPTARG}" = "X" ]; then
                    USER_NAME=${OPTARG}
                    ADD_USER="YES"
                fi
                ;;
            v)
                JAIL_TEMPLATE="jail-vnet.template"
                VNET="YES"
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
    printf "  ${BOLD}${PGM}${ANSI_END} – create, destroy and update FreeBSD jails\n"
    echo   ""

    ### SYNOPSIS
    printf "${BOLD}SYNOPSIS${ANSI_END}\n"
    printf "  ${BOLD}${PGM} create jailname${ANSI_END} ${BOLD}-i${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} [${BOLD}-h${ANSI_END} ${UNDERLINE}hostname${ANSI_END} ${BOLD}-d${ANSI_END} ${UNDERLINE}domainname${ANSI_END} ${BOLD}-t${ANSI_END} ${UNDERLINE}timezone${ANSI_END} ${BOLD}-r${ANSI_END} ${UNDERLINE}reponame${ANSI_END} ${BOLD}-n${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} ${BOLD}-v -P${ANSI_END} ${UNDERLINE}\"list of packages\"${ANSI_END} ${BOLD}-a${ANSI_END} ${UNDERLINE}ABI_Version${ANSI_END} ${BOLD}-e${ANSI_END} ${UNDERLINE}\"list of services\"${ANSI_END} ${BOLD}-s -q -o${ANSI_END}]\n" "${PGM}"
    printf "  ${BOLD}${PGM} destroy${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n"
    printf "  ${BOLD}${PGM} update${ANSI_END} ${UNDERLINE}jailname${ANSI_END} [-${BOLD}b -p -s${ANSI_END}]\n"
    printf "  ${BOLD}${PGM} list${ANSI_END}\n"
    printf "  ${BOLD}${PGM} start${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n"
    printf "  ${BOLD}${PGM} stop${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n"
    printf "  ${BOLD}${PGM} restart${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n"
    printf "  ${BOLD}${PGM} reloadpf${ANSI_END}\n"
    printf "  ${BOLD}${PGM} login${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n"
    printf "  ${BOLD}${PGM} exec${ANSI_END} ${UNDERLINE}jailname${ANSI_END} ${UNDERLINE}command${ANSI_END}\n"
    printf "  ${BOLD}${PGM} repos${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n"
    printf "  ${BOLD}${PGM} help${ANSI_END} [${BOLD}-l${ANSI_END}]\n"
    echo   ""

    ### DESCRIPTION
    printf "${BOLD}DESCRIPTION${ANSI_END}\n"
    printf "\tThe ${BOLD}${PGM}${ANSI_END} command creates, destroys and controls FreeBSD jails build from a pkgbase or basecore repositories.\n"
    echo   ""

    printf "  ${BOLD}${PGM} create jailname${ANSI_END} ${BOLD}-i${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} [${BOLD}-t${ANSI_END} ${UNDERLINE}timezone${ANSI_END} ${BOLD}-r${ANSI_END} ${UNDERLINE}reponame${ANSI_END} ${BOLD}-n${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END} ${BOLD}-v -P${ANSI_END} ${UNDERLINE}\"list of packages\"${ANSI_END} ${BOLD}-a${ANSI_END} ${UNDERLINE}ABI_Version${ANSI_END} ${BOLD}-e${ANSI_END} ${UNDERLINE}\"list of services\"${ANSI_END} ${BOLD}-s -q${ANSI_END}]\n"
    printf "\t${BOLD}-i${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END}\n\t\tSet IP address of jail.\n"
    echo   ""
    printf "\t${BOLD}-m${ANSI_END} ${UNDERLINE}netmask${ANSI_END}\n\t\tSet netmask of VNET ip address. use CIDR form (e.g. /24) or \"longform\" (e.g. 255.255.255.0)\n"
    echo   ""
    printf "\t${BOLD}-t${ANSI_END} ${UNDERLINE}timezone${ANSI_END}\n\t\tSet Timezone of jail.\n"
    echo   ""
    printf "\t${BOLD}-N${ANSI_END} ${UNDERLINE}ipaddress${ANSI_END}\n\t\tSet DNS server IP address of jail.\n"
    echo   ""
    printf "\t${BOLD}-v${ANSI_END} \tcreate a VNET jail.\n"
    echo   ""
    printf "\t${BOLD}-S${ANSI_END} \tenable SSH daemon in jail.\n"
    echo   ""
    printf "\t${BOLD}-r${ANSI_END} ${UNDERLINE}reponame${ANSI_END}\n\t\tSet pkg repository of jail.\n"
    echo   ""
    printf "\t${BOLD}-u${ANSI_END} ${UNDERLINE}username${ANSI_END}\n\t\tCreate user ${UNDERLINE}username${ANSI_END} in jail with uid ${USER_ID}. If -u argument is used, a value is mandatory.\n\t\tNOTE: password = username\n"
    echo   ""
    printf "\t${BOLD}-h${ANSI_END} ${UNDERLINE}hostname${ANSI_END}\n\t\tSet hostname of the jail. If not set, the jailname is used.\n"
    echo   ""
    printf "\t${BOLD}-d${ANSI_END} ${UNDERLINE}domainname${ANSI_END}\n\t\tSet domainname of the jail. If not set, the domain of the host is used.\n"
    echo   ""
    printf "\t${BOLD}-A${ANSI_END} \tprepare jail to be managed by ansible, so install necessary packages, create user ansible and load the ssh key to the jail.\n"
    echo   ""
    printf "\t${BOLD}-P${ANSI_END} ${UNDERLINE}\"list of packages\"${ANSI_END}\n\t\tPackages to install in the jail, the list is seperated by whitespace.\n"
    echo   ""

    printf "\t${BOLD}-c${ANSI_END} ${UNDERLINE}\"source_file:target_file(,...)\"${ANSI_END}\n\t\tCopy files INTO the jail.\n"
    echo   ""
    printf "\t\t%s\n" "NOTE:"
    printf "\t\t%s\n" " • use a comma seperated list for multiple copies"
    printf "\t\t%s\n" " • consider beginning and trailing slashes"
    printf "\t\t%s\n" " • consider the file permissions"
    printf "\t\t%s\n" " • consider whitespaces in the parameter string"
    echo   ""

    printf "\t${BOLD}-a${ANSI_END} ${UNDERLINE}ABI_Version${ANSI_END}\n\t\tSet the ABI Version to match the packages to be installed to the jail.\n"
    echo   ""
    printf "\t\t%s\n" "NOTE: Possible values for ABI_VERSION"
    printf "\t\t%s\n" " • FreeBSD:13:amd64"
    printf "\t\t%s\n" " • FreeBSD:14:amd64"
    echo   ""
            
    printf "\t${BOLD}-M${ANSI_END}\tuse minimal basecore package. (see: ${UNDERLINE}https://github.com/mjakob-gh/create-basecore-pkg${ANSI_END})\n"
    echo   ""

    printf "\t${BOLD}-e${ANSI_END} ${UNDERLINE}\"list of services\"${ANSI_END}\n\t\tEnable existing or just now installed services (see -P parameter), the list is seperated by whitespace.\n"
    echo   ""

    printf "\t${BOLD}-s${ANSI_END}\tStart the jail after the installation is finished.\n"
    echo   ""
    printf "\t${BOLD}-q${ANSI_END}\tDo not show output of pkg.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} destroy${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n\t\tThe jail is stopped, the dataset destroyed and the ${UNDERLINE}jailname${ANSI_END} removed from jail.conf\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} update${ANSI_END} ${UNDERLINE}jailname${ANSI_END} [-${BOLD}b -p -s${ANSI_END}]\n"
    printf "\t${BOLD}-b${ANSI_END}\tUpdate the pkgbase system.\n"
    echo   ""
    printf "\t${BOLD}-p${ANSI_END}\tUpdate the installed packages.\n"
    echo   ""
    printf "\t${BOLD}-s${ANSI_END}\tRestart jail after update.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} list${ANSI_END}\n\t\tList status of all running jails.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} start${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n\t\tStart all jails, or only given ${UNDERLINE}jailname${ANSI_END}.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} stop${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n\t\tStop all jails, or only given ${UNDERLINE}jailname${ANSI_END}.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} restart${ANSI_END} [${UNDERLINE}jailname${ANSI_END}]\n\t\tRestart all jails, or only given ${UNDERLINE}jailname${ANSI_END}.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} reloadpf${ANSI_END}\n\t\tReload pf firewall rules.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} login${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n\t\tLogin to ${UNDERLINE}jailname${ANSI_END} as user root.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} exec${ANSI_END} ${UNDERLINE}jailname${ANSI_END} ${UNDERLINE}command${ANSI_END}\n\t\tExecutes ${UNDERLINE}command${ANSI_END} inside the jail ${UNDERLINE}jailname${ANSI_END}.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} repos${ANSI_END} ${UNDERLINE}jailname${ANSI_END}\n\t\tview the repos configured inside the jail ${UNDERLINE}jailname${ANSI_END}.\n"
    echo   ""
    echo   ""

    printf "  ${BOLD}${PGM} help${ANSI_END} [${BOLD}-l${ANSI_END}]\n\t\tPrint this help message.\n"
    printf "\t${BOLD}-l${ANSI_END}\tOpen help message in pager.\n"
    echo   ""

    ### DESCRIPTION
    printf "${BOLD}DESCRIPTION${ANSI_END}\n"
    printf "\tThe ${BOLD}${PGM}${ANSI_END} command creates, destroys and manages FreeBSD jails.\n"
    echo   ""

    ### FILES
    printf "${BOLD}FILES${ANSI_END}\n"
    printf "\t${JAILER_CONF_DIR}/jailer.conf\n\t${JAILER_TEMPLATE_DIR}/*\n"
    echo   ""

    ### EXIT STATUS
    printf "${BOLD}EXIT STATUS${ANSI_END}\n"
    printf "\tThe ${BOLD}${PGM}${ANSI_END} utility exit 0 on success, 1 if there are problems with the installation and 2 if the wrong arguments are given.\n"
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
        printf "${RED}${ERROR_STRING}${ANSI_END} ${PGM} must run as root!\n"
        exit "${FAILURE}"
    fi

    # check if jails are enabled
    if [ ! "$( sysrc -n jail_enable )" = "YES" ] ; then
        printf "${YELLOW}${WARN_STRING}${ANSI_END}  jails service is not enabled.\n"
    fi

    # check for template file
    if [ "$( find "${JAILER_TEMPLATE_DIR}" -name '*.template' | wc -l | sed 's/[[:space:]]//g' )" -eq 0 ] ; then
        printf "${RED}${ERROR_STRING}${ANSI_END} template files \"${JAILER_TEMPLATE_DIR}/*\" do not exist!\n"
        exit ${FAILURE}
    fi
}

#
# check if repository configuration exists
#
check_repo()
{
    if [ ! -f "/usr/local/etc/pkg/repos/${REPO_NAME}.conf" ]; then
        printf "${RED}${ERROR_STRING}${ANSI_END} no repository ${BOLD}${WHITE}${REPO_NAME}${ANSI_END} found!"
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
    
    printf "${BLUE}${INFO_STRING}${ANSI_END}Create zfs dataset: ${BOLD}${WHITE}${JAIL_DATASET_ROOT}/${JAIL_NAME}${ANSI_END}\n"
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

    if [ $MINIJAIL = "YES" ]; then
        REPO_NAME="FreeBSD-basecore"
        CORE_PKGS="FreeBSD-basecore"
        EXTRA_PKGS=""
    else
        # EXTRA_PKGS: Some additional basesystem pkgs, extend the list if needed
        case "${ABI_VERSION}" in
            *13*|*14*)
                # FreeBSD 13/14
                CORE_PKGS="FreeBSD-utilities"
                EXTRA_PKGS="FreeBSD-rc FreeBSD-dma FreeBSD-libexecinfo FreeBSD-ssh FreeBSD-vi FreeBSD-at FreeBSD-zoneinfo"
                ;;
            *)
                printf "${RED}${ERROR_STRING}${ANSI_END} invalid OS Version detectet: ${BOLD}${WHITE}${ABI_VERSION}${ANSI_END}\n"
                exit ${FAILURE}
                ;;
        esac
    fi

    printf "${BLUE}${INFO_STRING}${ANSI_END}Using repository:   ${BOLD}${WHITE}${REPO_NAME}${ANSI_END}\n"
    printf "${BLUE}${INFO_STRING}${ANSI_END}Install pkg:        ${BOLD}${WHITE}${CORE_PKGS} ${EXTRA_PKGS}${ANSI_END}\n"
    echo   ""

    # Install the base system
    set -o pipefail
    # the packages must be passed to pkg as multiple parameters, so dont use quotes and ignore the shellcheck error
    # shellcheck disable=SC2086
    pkg --rootdir "${JAIL_DIR}" -o ASSUME_ALWAYS_YES=true -o ABI="${ABI_VERSION}" install ${PKG_QUIET} --repository "${REPO_NAME}" ${CORE_PKGS} ${EXTRA_PKGS} | tee -a "${LOG_FILE}"
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
    echo ""
}

#
# install additional packages
#
install_pkgs()
{
    _PKGS=$1

    pkg --jail "${JAIL_NAME}" -o ASSUME_ALWAYS_YES=true update -f ${PKG_QUIET} --repository "${OFFICIAL_REPO_NAME}"

    if [ ! X"${_PKGS}" = "X" ]; then
        printf "\n${BLUE}${INFO_STRING}${ANSI_END}Install pkgs:\n"
        # install the pkg package
        install_pkgtool

        for PKG in ${_PKGS}
        do
            printf "${BLUE}Installing %s${ANSI_END}\n" "${PKG}"
            set -o pipefail
            pkg --jail "${JAIL_NAME}" -o ASSUME_ALWAYS_YES=true install ${PKG_QUIET} --repository "${OFFICIAL_REPO_NAME}" "${PKG}" | tee -a "${LOG_FILE}"
            if [ $? -lt 0 ]; then
                printf "${RED}${ERROR_STRING}${ANSI_END} installation of ${BOLD}${WHITE}%s${ANSI_END} failed" "${PKG}"
            fi
            set +o pipefail
        done
        pkg --jail "${JAIL_NAME}" -o ASSUME_ALWAYS_YES=true ${PKG_QUIET} clean --all --quiet | tee -a "${LOG_FILE}"
    fi
}

#
# enable given services
#
enable_services()
{
    if [ ! X"${SERVICES}" = "X" ]; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}Enabling services: "
        for SERVICE in ${SERVICES}
        do
            printf "${BLUE}${INFO_STRING}${ANSI_END}${BOLD}${WHITE}${SERVICE}${ANSI_END} "
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
        printf "${BLUE}${INFO_STRING}${ANSI_END}Copying files:\n"
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
    # Check for IFIDs in jail.conf AND in the actual network configuration,
    # to avoid unintentional duplicates
    ID_IFCONFIG=$( ifconfig | awk '/IFID/{gsub("IFID=","",$2); print $2}' | sort -u | tail -1 )
    ID_JAILCONF=$( awk '/IFID=/ {print $6}' /etc/jail.conf | sed 's#.IFID=##g' | sort -u | tail -1 )

    # there are no IFIDs on any networkinterfaces
    if [ -z "${ID_IFCONFIG}" ] ; then
        ID_IFCONFIG=-1
    fi
    # there are no IFIDs in jail.conf
    if [ -z "${ID_JAILCONF}" ] ; then
        ID_JAILCONF=-1
    fi
    # so set the value to -1 to start the IFIDs with 0

    # the IFIDs are identical, pick one and add 1
    if [ ${ID_IFCONFIG} -eq ${ID_JAILCONF} ] ; then
        INTERFACE_ID=$(( ID_IFCONFIG + 1 ))
    # the IFID in ID_IFCONFIG is larger, so pick the larger one and add 1
    elif [ ${ID_IFCONFIG} -gt ${ID_JAILCONF} ] ; then
        INTERFACE_ID=$(( ID_IFCONFIG + 1 ))
    # the IFID in ID_IFCONFIG is smaller, so pick the larger one and add 1
    elif [ ${ID_IFCONFIG} -lt ${ID_JAILCONF} ] ; then
        INTERFACE_ID=$(( ID_JAILCONF + 1 ))
    # there is no yet any IFID, so start with 0
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

    if [ "${JAIL_HOSTNAME}" = "" ] ; then
        JAIL_HOSTNAME="${JAIL_NAME}"
    fi

    printf "${BLUE}${INFO_STRING}${ANSI_END}Jail config:       ${BOLD}${WHITE}${JAIL_CONF}${ANSI_END}\n"

    sed -e "s|%%JAIL_NAME%%|${JAIL_NAME}|g"             \
        -e "s|%%JAIL_DOMAINNAME%%|${JAIL_DOMAINNAME}|g" \
        -e "s|%%JAIL_HOSTNAME%%|${JAIL_HOSTNAME}|g"     \
        -e "s|%%JAIL_INTERFACE%%|${JAIL_INTERFACE}|g"   \
        -e "s|%%JAIL_UUID%%|${JAIL_UUID}|g"             \
        -e "s|%%JAIL_IP%%|${JAIL_IP}|g"                 \
        -e "s|%%JAIL_NETMASK%%|${JAIL_NETMASK}|g"       \
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
    printf "${BLUE}${INFO_STRING}${ANSI_END}Setup jail:        ${BOLD}${WHITE}${JAIL_NAME}${ANSI_END}\n"
    # add some default values for /etc/rc.conf
    # but first create the file, so sysrc wont show an error
    touch "${JAIL_DIR}/etc/rc.conf"

    # System
    printf "${BLUE}${INFO_STRING}${ANSI_END}Configure syslog:  ${BOLD}${WHITE}syslogd_flags: -s -> -ss${ANSI_END}\n"
    sysrc -R "${JAIL_DIR}" syslogd_flags="-ss" > /dev/null

    # set timezone in jail
    printf "${BLUE}${INFO_STRING}${ANSI_END}Setup timezone:    ${BOLD}${WHITE}${TIME_ZONE}${ANSI_END}\n"
    tzsetup -sC "${JAIL_DIR}" "${TIME_ZONE}"

    # Network
    printf "${BLUE}${INFO_STRING}${ANSI_END}Add nameserver:    ${BOLD}${WHITE}${NAME_SERVER}${ANSI_END}\n"
    echo "nameserver ${NAME_SERVER}" > "${JAIL_DIR}/etc/resolv.conf"

    # print the IP Adress
    if [ ${VNET} = "YES" ]; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}Add VNET IP:       ${BOLD}${WHITE}${JAIL_IP}${ANSI_END}\n"
        printf "${BLUE}${INFO_STRING}${ANSI_END}Use netmask:       ${BOLD}${WHITE}${JAIL_NETMASK}${ANSI_END}\n"
    fi

    # configure mailing
    printf "${BLUE}${INFO_STRING}${ANSI_END}Disable mailer:    ${BOLD}${WHITE}sendmail${ANSI_END}\n"
    printf "${BLUE}${INFO_STRING}${ANSI_END}Enable mailer:     ${BOLD}${WHITE}dma${ANSI_END}\n"
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

    # enable "improved" .cshrc for root
    cp "${JAILER_TEMPLATE_DIR}/dot.cshrc" "${JAIL_DIR}/.cshrc"

    
    if [ ! -d "${JAIL_DIR}/usr/include" ] ; then
        mkdir "${JAIL_DIR}/usr/include"
    fi

    # modify motd entry
    MOTD_FILE="${JAIL_DIR}/etc/motd.template"
    printf "\n\t\"Go directly to Jail. Do not pass GO, do not collect \$200\"\n\n" > "${MOTD_FILE}"
}

#
# setup the pkg repository
#
setup_repository()
{
    if [ $MINIJAIL = "YES" ]; then
        REPO_NAME="FreeBSD-basecore"
    else
        REPO_NAME="FreeBSD-pkgbase"
    fi

    # setup repository
    printf "${BLUE}${INFO_STRING}${ANSI_END}Enable repository: ${BOLD}${WHITE}FreeBSD${ANSI_END}\n"

    mkdir -p "${JAIL_DIR}/usr/local/etc/pkg/repos"
    echo 'FreeBSD: { enabled: yes }' > "${JAIL_DIR}/usr/local/etc/pkg/repos/FreeBSD.conf"

    printf "${BLUE}${INFO_STRING}${ANSI_END}Enable repository: ${BOLD}${WHITE}${REPO_NAME}${ANSI_END}\n"
    if [ -f "${TEMPLATE_DIR}/FreeBSD-repo.conf.template" ]; then
        sed -e "s|%%REPO_NAME%%|${REPO_NAME}|g"  \
            -e "s|%%REPO_HOST%%|${REPO_HOST}|g" \
            "${TEMPLATE_DIR}/FreeBSD-repo.conf.template" >> "${JAIL_DIR}/usr/local/etc/pkg/repos/FreeBSD-base.conf"
    else
        printf "${YELLOW}${WARN_STRING}${ANSI_END}  \"FreeBSD-repo.conf.template\" not found, please check ${BOLD}${WHITE}${TEMPLATE_DIR}${ANSI_END}\n"
    fi
    echo ""
}

#
# delete the jail dataset
#
destroy_dataset()
{
    if check_dataset; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}Deleting dataset: ${BOLD}${WHITE}${JAIL_DATASET_ROOT}/${JAIL_NAME}${ANSI_END}\n"
        # force the unmounting of the dataset to prevent problems
        # zfs "destroying" the dataset
        umount -f "${JAIL_DIR}"
        zfs destroy "${JAIL_DATASET_ROOT}/${JAIL_NAME}" | tee -a "${LOG_FILE}"
    else
        printf "${RED}${ERROR_STRING}${ANSI_END} No dataset ${BOLD}${WHITE}${JAIL_DATASET_ROOT}/${JAIL_NAME}${ANSI_END}\n"
    fi
}

#
# remove the jail configuration from jail.conf
#
destroy_jailconf_entry()
{
    if check_jailconf; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}Deleting entry:   ${BOLD}${WHITE}${JAIL_NAME}${ANSI_END}\n"
        sed -i '' "/^${JAIL_NAME}[[:space:]]*{/,/^[[:space:]]*}[[:space:]]*$/d" "${JAIL_CONF}"
    else
        printf "${RED}${ERROR_STRING}${ANSI_END} no entry ${BOLD}${WHITE}${JAIL_NAME}${ANSI_END} in ${BOLD}${WHITE}${JAIL_CONF}${ANSI_END}\n"
    fi
}

#
# create a logfile to protocol the script actions
#
create_log_file()
{
    if [ ${WRITE_LOGFILE} = "YES" ]; then
        LOG_FILE="/tmp/jailer_${ACTION}_${JAIL_NAME}_$(date +%Y%m%d%H%M).log"
        printf "${BLUE}${INFO_STRING}${ANSI_END}Creating logfile:   ${BOLD}${WHITE}${LOG_FILE}${ANSI_END}\n"
    else
        LOG_FILE="/dev/null"
    fi
}


#
# finally create the jail
#
create_jail()
{
    if [ X"${JAIL_IP}" = "X" ]; then
        printf "${RED}${ERROR_STRING}${ANSI_END} No ip adresse given (-i)\n"
        exit 2
    fi

    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"
    if check_jailconf; then
        printf "${RED}${ERROR_STRING}${ANSI_END} ${BOLD}${WHITE}${JAIL_NAME}${ANSI_END} already exists in ${BOLD}${WHITE}${JAIL_CONF}${ANSI_END}!\n"
        exit 2
    elif check_dataset; then
        printf "${RED}${ERROR_STRING}${ANSI_END} Dataset ${BOLD}${WHITE}${JAIL_DATASET_ROOT}/${JAIL_NAME}${ANSI_END} already exists!\n"
        exit 2
    else
        create_dataset
        install_baseos_pkg
        create_jailconf_entry
        setup_system
        setup_repository 

        if [ "${INSTALL_PKGTOOL}" = "YES" ]; then
            install_pkgtool
        fi

        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        start_jail "${JAIL_NAME}"

        if [ "$(sysrc -n pf_enable)" = "YES" ]; then
            service pf reload > /dev/null
        fi

        # install additional packages
        install_pkgs "${PKGS}"
        # enable services specified in -e argument
        enable_services

        # create the user when argument -u is set
        if [ "${ADD_USER}" = "YES" ]; then
            pw -R "${JAIL_DIR}" useradd -n "${USER_NAME}" -u ${USER_ID} -g wheel -c "Inside man" -s /bin/tcsh -m -w yes
        fi

        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        stop_jail "${JAIL_NAME}"

        # copy files into the jail specified in -c argument
        copy_files

        # start the jail when -s argument is set
        if [ ${AUTO_START} = "YES" ]; then
            printf "${BLUE}${INFO_STRING}${ANSI_END}"
            start_jail "${JAIL_NAME}"
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
        printf "${RED}${ERROR_STRING}${ANSI_END} Jail ${BOLD}${WHITE}${JAIL_NAME}${ANSI_END} does not exist!\n"
        exit 2
    elif ! check_dataset; then
        printf "${RED}${ERROR_STRING}${ANSI_END} Dataset ${BOLD}${WHITE}${JAIL_DATASET_ROOT}/${JAIL_NAME}${ANSI_END} does not exist!\n"
        exit 2
    else
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        stop_jail "${JAIL_NAME}"
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
    JAIL_DIR="$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )/${JAIL_NAME}"

    if [ "${BASE_UPDATE}" = "YES" ]; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}Updating system\n"
        set -o pipefail
        jexec -l "${JAIL_NAME}" pkg -o ASSUME_ALWAYS_YES=true update  --repository FreeBSD-base ${PKG_QUIET} | tee -a "${LOG_FILE}"
        jexec -l "${JAIL_NAME}" pkg -o ASSUME_ALWAYS_YES=true upgrade --repository FreeBSD-base ${PKG_QUIET} | tee -a "${LOG_FILE}"
        set +o pipefail
        if [ $? -lt 0 ]; then
            printf "${RED}${ERROR_STRING}${ANSI_END} Update of base failed!\n"
        fi
        echo ""
    fi

    if [ ${PKG_UPDATE} = "YES" ]; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}Updating packages\n"
        set -o pipefail
        jexec -l "${JAIL_NAME}" pkg -o ASSUME_ALWAYS_YES=true update  --repository FreeBSD ${PKG_QUIET} | tee -a "${LOG_FILE}"
        jexec -l "${JAIL_NAME}" pkg -o ASSUME_ALWAYS_YES=true upgrade --repository FreeBSD ${PKG_QUIET} | tee -a "${LOG_FILE}"
        set +o pipefail
        if [ $? -lt 0 ]; then
            printf "${RED}${ERROR_STRING}${ANSI_END} Update of the installed packages failed!\n"
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
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        service jail start
    else
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        service jail start "$1"
    fi
    if [ "$(sysrc -n pf_enable)" = "YES" ]; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        service pf reload
    fi
}

#
# stop all or a named jail
#
stop_jail()
{
    if [ "$1" = "" ] ; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        service jail stop
    else
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        service jail stop "$1"
    fi
    if [ "$(sysrc -n pf_enable)" = "YES" ]; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        service pf reload
    fi
}

#
# reload the pf rules, if pf is active
#
reload_pf()
{
    if [ "$(sysrc -n pf_enable)" = "YES" ]; then
        printf "${BLUE}${INFO_STRING}${ANSI_END}"
        service pf reload
    fi
}

#
# setup system to be managed by ansible
#
enable_ansible()
{
    install_pkgs "${ANSIBLE_PKGS}"

    # ansible is best used via ssh, so enable
    # sshd when installing ansible
    ENABLE_SSHD="YES"

    # create ansible user
    printf "add user ${WHITE}${ANSIBLE_USER_NAME}${ANSI_END} (UID: ${WHITE}${ANSIBLE_USER_UID}${ANSI_END})     "
    pw -R "${JAIL_DIR}" useradd -n "${ANSIBLE_USER_NAME}" -u "${ANSIBLE_USER_UID}" -g wheel -c "ansible user" -s /bin/sh -m -w random > /dev/null
    checkResult $?

    # "install" the default ssh public key of the ansible user
    printf "copy ssh public-key              "
    mkdir -p "${JAIL_DIR}/home/${ANSIBLE_USER_NAME}/.ssh"
    if [ -d "${JAIL_DIR}/home/${ANSIBLE_USER_NAME}/.ssh" ] ; then
        echo "${ANSIBLE_USER_PUBKEY}" > "${JAIL_DIR}/home/${ANSIBLE_USER_NAME}/.ssh/authorized_keys"
        chown -R ${ANSIBLE_USER_UID} "${JAIL_DIR}/home/${ANSIBLE_USER_NAME}/.ssh"
        checkResult $?
    else
        checkResult 1
    fi

    # allow the ansible user to use sudo without password
    printf "enable sudo                      "
    if [ -d "${JAIL_DIR}/usr/local/etc/sudoers.d/" ] ; then
        echo "${ANSIBLE_USER_NAME} ALL = (ALL) NOPASSWD: ALL" > "${JAIL_DIR}/usr/local/etc/sudoers.d/${ANSIBLE_USER_NAME}"
        checkResult $?
    else
        checkResult 1
    fi
}

enable_sshd()
{
    if [ ${ENABLE_SSHD} == "YES" ] ; then
        printf "enable sshd                      "
        sysrc -R "${JAIL_DIR}" sshd_enable=YES > /dev/null
        checkResult $?

        printf "sshd listen on                   ${WHITE}[${JAIL_IP}]${ANSI_END}\n"
        echo "ListenAddress ${JAIL_IP}" >> "${JAIL_DIR}/etc/ssh/sshd_config"
    fi
}

#
# print out the running jail "configuration"
#
get_list()
{
    {
    echo "name jid vnet ip4.addr host.hostname osrelease osreldate path"
    echo "---- --- ---- -------- ------------- --------- --------- ----"
        {
            for JID in $(jls -N jid); do
            _NAME=$(jls -N -j $JID name)
            _VNET=$(jls -N -j $JID vnet)
            _HOSTNAME=$(jls -N -j $JID host.hostname)
            _IPV4=$(jls -N -j $JID ip4.addr)
            _OSRELEASE=$(jexec -l $JID uname -r)
            _OSRELDATE=$(jexec -l $JID uname -U)
            _PATH=$(jls -N -j $JID path)

            if [ "$_IPV4" = "-" -a "$_VNET" = "new" ]; then
                _IPV4=$(jexec -l $JID ifconfig | awk '{ if ($1 == "inet" && $2 != "127.0.0.1") printf $2}')
            fi

            if [ "$_VNET" = "new" ]; then
                _VNET="true"
            else
                _VNET="false"
            fi

            echo "$_NAME $JID $_VNET $_IPV4 $_HOSTNAME $_OSRELEASE $_OSRELDATE $_PATH"
        done
        } | sort
    } | column -t
}

#
# print some host and jailer information
#
get_info()
{
    printf "${BLUE}Host configuration${ANSI_END}\n"
    printf "Jail dataset:      ${WHITE}${JAIL_DATASET_ROOT}${ANSI_END} mounted on ${WHITE}%s${ANSI_END}\n" "$( zfs get -H -o value mountpoint "${JAIL_DATASET_ROOT}" )"
    printf "Disk Usage:        ${WHITE}%s${ANSI_END} used of ${WHITE}%s${ANSI_END} available\n" "$( zfs get -H -o value used "${JAIL_DATASET_ROOT}" )" "$( zfs get -H -o value avail "${JAIL_DATASET_ROOT}" )"
    printf "Jails enabled:     ${WHITE}%s${ANSI_END}\n" "$( sysrc -n jail_enable )"
    printf "ABI version:       ${WHITE}${ABI_VERSION}${ANSI_END}\n"
    printf "Timezone:          ${WHITE}${TIME_ZONE}${ANSI_END}\n"
    printf "Domainname:        ${WHITE}%s${ANSI_END}\n" "$( hostname -d )"
    echo   ""
    printf "${BLUE}Network configuration${ANSI_END}\n"
    printf "Firewall enabled:  ${WHITE}%s${ANSI_END}\n" "$( sysrc -n pf_enable )"
    printf "Network interface: ${WHITE}${JAIL_INTERFACE}${ANSI_END}\n"
    printf "VNET bridge:       ${WHITE}${BRIDGE}${ANSI_END}\n"
    printf "VNET gateway:      ${WHITE}${GATEWAY}${ANSI_END}\n"
    printf "Nameserver:        ${WHITE}${NAME_SERVER}${ANSI_END}\n"
    echo   ""
    printf "${BLUE}Jailer configuration${ANSI_END}\n"
    printf "Jailer version:    ${WHITE}${VERSION}${ANSI_END}\n"
    printf "Jailer repos:      ${WHITE}%s${ANSI_END}\n" "$( grep -h -B 10 "enabled: yes" /usr/local/etc/pkg/repos/FreeBSD-*base*.conf | grep ": {" | awk -F":" '{printf $1 " "}' )"
    printf "Template dir:      ${WHITE}${TEMPLATE_DIR}${ANSI_END}\n"
    printf "Jailer templates:  ${WHITE}%s${ANSI_END}\n" "$( find "${JAILER_TEMPLATE_DIR}" -type f -name 'jail*.template' -exec basename {} \; | awk '{printf $1 " "}' )"
    printf "ZFS compression:   ${WHITE}${ZFS_COMPRESSION}${ANSI_END}\n"
}

ACTION="$1"
JAIL_NAME="$2"

# check for number of arguments
# No Arguments:
if [ $ARG_NUM -eq 0 ] ; then
    printf "${RED}${ERROR_STRING}${ANSI_END} Missing command!\n"
    printf "${BLUE}${INFO_STRING}${ANSI_END}Use ${BOLD}${WHITE}${PGM} help${ANSI_END} to view usage.\n"
    echo ""
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
        stop_jail "${JAIL_NAME}"
        start_jail "${JAIL_NAME}"
        [ "${ENABLE_ANSIBLE}" = "YES" ] && enable_ansible
        [ "${ENABLE_SSHD}" = "YES" ]    && enable_sshd
        stop_jail "${JAIL_NAME}"
        start_jail "${JAIL_NAME}"
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
        if [ "${AUTO_START}" = "YES" ]; then
            printf "${BLUE}${INFO_STRING}${ANSI_END}"
            stop_jail "${JAIL_NAME}"
            printf "${BLUE}${INFO_STRING}${ANSI_END}"
            start_jail "${JAIL_NAME}"
        fi
        ;;
    list)
        #jls -h jid name vnet ip4.addr host.hostname osrelease osreldate path | column -t
        get_list
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
    login)
        if [ ! "${JAIL_NAME}" = "" ]; then
            jexec -l "${JAIL_NAME}" login -f root
        else
            printf "${RED}${ERROR_STRING}${ANSI_END} no jail specified.\n"
            echo ""
            exit 2
        fi
        ;;
    exec)
        shift 2
        if [ ! "${JAIL_NAME}" = "" ]; then
            jexec -l "${JAIL_NAME}" "$@"
        else
            printf "${RED}${ERROR_STRING}${ANSI_END} no jail specified.\n"
            echo ""
            exit 2
        fi
        ;;
    repos)
        shift 2
        printf "Following repositories are configured in ${BOLD}${WHITE}${JAIL_NAME}${ANSI_END}:\n"
        JAIL_REPOS=$(pkg --jail "${JAIL_NAME}" -vv | awk '/^  .*: \{/ {gsub(":","", $1); printf  $1 " "}')
        ( for JAIL_REPO in $JAIL_REPOS
        {
            REPO_URL=$(pkg --jail "${JAIL_NAME}" -vv | grep -A 1 "  ${JAIL_REPO}:" | awk -F'"' '/url/ {print $2}')

            printf "${JAIL_REPO}: ${WHITE}${REPO_URL}${ANSI_END}\n"
        } ) | column -t
        echo   ""
        ;;
    *)
        printf "${RED}${ERROR_STRING}${ANSI_END} Invalid command ${BOLD}${WHITE}${ACTION}${ANSI_END}!\n"
        printf "${BLUE}${INFO_STRING}${ANSI_END}Use ${BOLD}${WHITE}${PGM} help${ANSI_END} to view usage.\n"
        exit 2
esac