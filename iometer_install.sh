#!/usr/bin/env bash
# This script will auto-detect the OS and Version
# It will update system packages and install iometer


# Some options can be passed via environment variables:
# SKIP_REBOOT="true"    ..... skip require reboot (except on selinux/centos)
# SKIP_CONFIRM="true"   ..... skip installer confirmation

set -o pipefail
set -e

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as user root"
    echo "Please change to root using: 'sudo su -' and re-run the script"
    exit 1
fi

export NEWT_COLORS='
window=,
'

declare -g IOMETER_PLAYBOOK_DIR="/opt/iometer-playbook"

clear
cat <<'EOF'

                                    
 ___ ___  __  __ _____ _____ _____ ____  
|_ _/ _ \|  \/  | ____|_   _| ____|  _ \ 
 | | | | | |\/| |  _|   | | |  _| | |_) |
 | | |_| | |  | | |___  | | | |___|  _ < 
|___\___/|_|  |_|_____| |_| |_____|_| \_\
                                         

          _|                      _|                            _|
_|_|_|    _|    _|_|_|  _|    _|  _|_|_|      _|_|      _|_|    _|  _|
_|    _|  _|  _|    _|  _|    _|  _|    _|  _|    _|  _|    _|  _|_|
_|    _|  _|  _|    _|  _|    _|  _|    _|  _|    _|  _|    _|  _|  _|
_|_|_|    _|    _|_|_|    _|_|_|  _|_|_|      _|_|      _|_|    _|    _|
_|                            _|
_|                        _|_|

EOF

cat <<EOF
Welcome to IOmeter Installer!
1. By pressing 'y' you agree to install the IOmeter on your system.
2. By pressing 'y' you aknowledge that this installer requires a CLEAN operating system

EOF

if [[ "$SKIP_CONFIRM" != true ]]
then
    read -p "Do you wish to proceed? [y/N] " yn
    if echo "$yn" | grep -v -iq "^y"; then
        echo Cancelled
        exit 1
    fi
fi

#################
### Functions ###
#################
function set_dist() {
    if [ -f /etc/os-release ]; then
        # freedesktop.org and systemd
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        # linuxbase.org
        OS=$(lsb_release -si)
        VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        # For some versions of Debian/Ubuntu without lsb_release command
        . /etc/lsb-release
        OS=$DISTRIB_ID
        VER=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        # Older Debian/Ubuntu/etc.
        OS=Debian
        VER=$(cat /etc/debian_version)
    elif [ -f /etc/SuSe-release ]; then
        # Older SuSE/etc.
        echo "Unsupported OS."
        exit 1
    elif [ -f /etc/redhat-release ]; then
        # Older Red Hat, CentOS, etc.
        echo "Old OS version. Minimum required is 7."
        exit 1
    else
        # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
        OS=$(uname -s)
        VER=$(uname -r)
    fi
}

function wait_apt(){
    local i=0
    tput sc
    while fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1 ; do
        case $(($i % 4)) in
          0 ) j="-" ;;
          1 ) j="\\" ;;
          2 ) j="|" ;;
          3 ) j="/" ;;
        esac
        tput rc
        echo -en "\r[$j] System packages being updated to newest version, this can take a moment..."
        sleep 0.5
        ((i=i+1))
    done
    echo
}

function init_centos_7(){
    echo "Updating system packages..."
    yum update -y

    echo "Install epel-release..."
    yum install epel-release -y

    echo "Update epel packages..."
    yum update -y

    set +e
    set +o pipefail
    if $(needs-restarting -r 2>&1 | grep -q "Reboot is required"); then
        [[ "$SKIP_REBOOT" != true ]] && { inform_reboot; exit 0; }
    fi
    set -o pipefail
    set -e

    echo "Installing wine..."
    yum install -y wine
}

function init_centos_8(){
    echo "Updating system packages..."
    dnf update -y --nobest

    echo "Install epel-release..."
    dnf install epel-release -y

    echo "Update epel packages..."
    dnf update -y --nobest

    echo "Enabled yum PowerTools..."
    dnf config-manager --set-enabled PowerTools
    
	echo "Enabled rhel-8-for-x86_64-appstream-rpms repo"
    subscription-manager repos --enable=rhel-8-for-x86_64-appstream-rpms

    local OUTPUT=$(needs-restarting)
    if [[ "$OUTPUT" != "" ]]; then
        [[ "$SKIP_REBOOT" != true ]] && { inform_reboot; exit 0; }
    fi

    echo "Installing gnome-tweaks..."
    dnf install -y gnome-tweaks

    echo "Installing wine..."
    dnf install -y wine
}

function init_ubuntu(){
    # We have to test a few times because apt is unexpected upon update
    # of many packages (especially during update of old node)
    wait_apt && echo "Ensuring no package managers ..." && sleep 5 && wait_apt

    echo "Updating system packages..."
    apt update -qqy --fix-missing
    apt-get upgrade -y
    apt-get clean
    apt-get autoremove -y --purge

    echo "Check reboot required..."
    if [ -f /var/run/reboot-required ]; then
        [[ "$SKIP_REBOOT" != true ]] && { inform_reboot; exit 0; }
    fi

    echo "Installing wine..."
    apt-get install software-properties-common -y
    add-apt-repository universe -y
    apt-get update -y
    apt-get install wine -y
}

function init_debian(){
    # We have to test a few times because apt is unexpected upon update
    # of many packages (especially during update of old node)
    wait_apt && echo "Ensuring no package managers ..." && sleep 5 && wait_apt

    echo "Updating system packages..."
    apt update -qqy --fix-missing
    apt-get upgrade -y
    apt-get clean
    apt-get autoremove -y --purge

    echo "Check reboot required..."
    if [ -f /var/run/reboot-required ]; then
        [[ "$SKIP_REBOOT" != true ]] && { inform_reboot; exit 0; }
    fi

    echo "Installing wine..."
    apt-get update -y
    apt-get install wine -y
}

function display_requirements_url() {
    echo "Only Debian, Ubuntu 18.04LTS, Ubuntu 19.x, Raspbian, CentOS 7 and 8 are supported."
}

function check_arch() {
    # Check architecture
    ARCH=$(uname -m)
    local REGEXP="x86_64|armv8l|aarch64"
    if [[ ! "$ARCH" =~ $REGEXP ]]; then
        echo "ERROR: $ARCH architecture not supported"
        display_requirements_url
        exit 1
    fi
}

#####################
### End Functions ###
#####################

### Get OS and version
set_dist

# Check OS version compatibility
if [[ "$OS" =~ ^(CentOS|Red) ]]; then
    if [[ ! "$VER" =~ ^(7|8) ]]; then
        echo "ERROR: $OS version $VER not supported"
        display_requirements_url
        exit 1
    fi
    check_arch
    init_centos_$VER
elif [[ "$OS" =~ ^Ubuntu ]]; then
    if [[ ! "$VER" =~ ^(16|17|18|19|20) ]]; then
        echo "ERROR: $OS version $VER not supported"
        display_requirements_url
        exit 1
    fi
    check_arch
    init_ubuntu
elif [[ "$OS" =~ ^Debian ]]; then
    if [[ ! "$VER" =~ ^(9|10) ]]; then
        echo "ERROR: $OS version $VER not supported"
        display_requirements_url
        exit 1
    fi
    check_arch
    init_debian
elif [[ "$OS" =~ ^Raspbian ]]; then
    if [[ ! "$VER" =~ ^(9|10) ]]; then
        echo "ERROR: $OS version $VER not supported"
        display_requirements_url
        exit 1
    fi
    check_arch

    # Workaround to make sure we detect
    # if reboot is needed
    apt install unattended-upgrades -y

    # Same setup for respbian as debian
    init_debian

    # remove workaround
    apt remove unattended-upgrades -y
else
    echo "$OS not supported"
    exit 1
fi

echo "Copy IOmeter Prebuild binaries..."
cd /opt

# Backup any existing iometer-playbook directory
if [ -d iometer-playbook ]; then
    echo "Backing up older iometer-playbook directory..."
    rm -rf iometer-playbook.backup
    mv -- iometer-playbook "iometer-playbook.backup.$(date +%s)"
fi

# Copy IOmeter Prebuild binaries...
mkdir "${IOMETER_PLAYBOOK_DIR}"
cd "${IOMETER_PLAYBOOK_DIR}"
wget https://nchc.dl.sourceforge.net/project/iometer/iometer-stable/1.1.0/iometer-1.1.0-linux.x86_64-bin.tar.bz2
wget https://nchc.dl.sourceforge.net/project/iometer/iometer-stable/1.1.0/iometer-1.1.0-win64.x86_64-bin.zip
tar jxvf iometer-1.1.0-linux.x86_64-bin.tar.bz2
unzip iometer-1.1.0-win64.x86_64-bin.zip

mkdir ~/Desktop/IOmeter-linux

cp iometer-1.1.0-linux.x86_64-bin/dynamo ~/Desktop/IOmeter-linux
cp iometer-1.1.0-win64.x86_64-bin/IOmeter.exe ~/Desktop/IOmeter-linux

cd ~/Desktop/IOmeter-linux

echo -e "\nRunning IOmeter..."
wine IOmeter.exe


