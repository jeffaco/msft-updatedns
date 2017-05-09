#! /bin/sh

# updatedns.sh: Update dynamic DHCP addresses to scx.com DNS server
#

VERSION=1.0.5

set -e

# Can't use something like 'readlink -e $0' because that doesn't work everywhere
# And HP doesn't define $PWD in a sudo environment, so we define our own
case $0 in
    /*|~*)
        SCRIPT_INDIRECT="`dirname $0`"
        ;;
    *)
        PWD="`pwd`"
        SCRIPT_INDIRECT="`dirname $PWD/$0`"
        ;;
esac

BASEDIR="`(cd \"$SCRIPT_INDIRECT\"; pwd -P)`"
SCRIPTNAME=$BASEDIR/`basename $0`
LOGFILE=${BASEDIR}/`basename $SCRIPTNAME .sh`.log
ROTATESCRIPT=${BASEDIR}/.`basename $SCRIPTNAME .sh`.logrotate
ROTATESTATE=${BASEDIR}/.`basename $SCRIPTNAME .sh`.logrotatestate
STRICT_UNCONFIGURE=0
TEMPFILE=/tmp/updatedns_$$

CONFIGURE=0
DELETE=0
DELETENAME=0
FORCE=0
LOGROTATE=0
QUERYONLY=0
UNCONFIGURE=0
VERBOSE=0

ACTUAL_IP=""
DNS_ADDRESS=""
HOSTNAME=""

cleanExit()
{
    local exitCode=$1

    [ -z "$exitCode" ] && exitCode=0

    rm -f $TEMPFILE

    exit $exitCode
}

logMessage()
{
    #
    # Takes two parameters:
    #
    #   1:  Message Disposition:
    #         F: Force output even if not verbose
    #         V: Only output if verbosity is set (not to logfile)
    #         N: Output message to logfile and to terminal in verbose mode
    #   2:  Mesage header
    #   3:  Mesage detail (optional)
    #

    local DISP="$1"
    local HEADER="$2"
    local DETAIL="$3"

    if [ -z "$HEADER" ]; then
	echo "FATAL: logMessage requires at least one parameter (message to log)" 1>& 2
        cleanExit 1
    fi

    if [ -z "$TIMESTAMP" ]; then
	echo "FATAL: Logic error (logMessage called without \$TIMESTAMP initialized)" 1>& 2
	cleanExit 1
    fi

    [ -z "$DISP" ] && DISP=N
    case "$DISP" in
	F | V | N)
	    ;;

	*)
	    echo "FATAL: Invalid message disposition in logMessage" 1>& 2
	    cleanExit 1
	    ;;
    esac

    # Now log the message

    if [ -n "$DETAIL" ]; then
	if [ "$DISP" != "V" ]; then
	    printf '%s %-25s %s\n' "$TIMESTAMP" "${HEADER}:" "$DETAIL" >> $LOGFILE
	fi

	if [ $VERBOSE -ne 0 -o "$DISP" = "F" ]; then
	    printf '%-25s %s\n' "${HEADER}:" "$DETAIL"
	fi
    else
	if [ "$DISP" != "V" ]; then
	    echo "${TIMESTAMP} $HEADER" >> $LOGFILE
	fi

	if [ $VERBOSE -ne 0 -o $DISP = "F" ]; then
	    echo "$HEADER"
	fi
    fi
}

rotateLog()
{
    if [ "$LOGROTATE" -ne 1 ]; then
	return
    fi

    # If the log file isn't big enough, just return
    if [ -f ${LOGFILE} ]; then
	if [ `uname -s` != "Darwin" ]; then
	    FILESIZE=`stat --printf=%s ${LOGFILE}`
	else
	    FILESIZE=`stat -nf %z ${LOGFILE}`
	fi

	if [ $FILESIZE -lt 50000 ]; then
	    return
	fi
    fi

    # If we're not on our "run dates", just return
    CURRENT_DAY=`date +%d`
    if [ ${CURRENT_DAY} -ne 1 -a ${CURRENT_DAY} -ne 15 ]; then
	return
    fi

    # Looks like we need to log; first rotate existing log files

    [ -f ${LOGFILE}.3.gz ] && mv ${LOGFILE}.3.gz ${LOGFILE}.4.gz
    [ -f ${LOGFILE}.2.gz ] && mv ${LOGFILE}.2.gz ${LOGFILE}.3.gz
    [ -f ${LOGFILE}.1.gz ] && mv ${LOGFILE}.1.gz ${LOGFILE}.2.gz

    # Now move the current logfile and compress it

    mv ${LOGFILE} ${LOGFILE}.1
    gzip ${LOGFILE}.1

    logMessage N "Performed log file rotation"
}

getDNSAddress()
{
    HOSTNAME=`hostname -s`
    if echo $HOSTNAME | grep -q "\\."; then
	logMessage F "Host name contains FQDN, and it should not; host name must be changed"
	cleanExit 1
    fi
    if echo $HOSTNAME | egrep -qi '^localhost$'; then
        logMessage F "Host name should not be 'localhost'; host name must be changed"
        cleanExit 1
    fi
    logMessage V "Hostname for system" "${HOSTNAME}"

    # Fetch our DNS address from the DNS server

    DNS_ADDRESS=`dig @10.228.124.13 ${HOSTNAME}.scx.com +short`

    if [ -n "${DNS_ADDRESS}" ]; then
	logMessage V "TCP/IP address from DNS" "${DNS_ADDRESS}"
    else
        logMessage V "TCP/IP address from DNS" "<Undefined>"
    fi
}

getCurrentIPAddress()
{
    # There are a number of ways to get the current actual TCP/IP address, none
    # "portable". Various methods:
    #
    #   1. Something like "ifconfig eth0 | grep "inet " | sed 's/inet //g' | awk '{print $1}'
    #      This can require tweaking due to ethernet name and exact format of 'ifconfig' output.
    #      This is used by most SCX lab systems.
    #
    #   2. ip -4 route get 1
    #      Less tweaking needed, but older Linux systems and no UNIX systems understand this

    #ACTUAL_IP=`ifconfig eth0 | grep "inet " | sed -e 's/inet //g' | awk '{print $1}'`

    case `uname -s` in
	Darwin)
	    # Mac OS/X, when running VMware Fusion, is a little tricky ...
	    # First we need to find the Ethernet interface with an address

	    for i in `seq 0 8`; do
		if /sbin/ifconfig en$i | grep -q "inet "; then
		    INTERFACE=en$i
		    break
		fi
	    done

	    ACTUAL_IP=`/sbin/ifconfig $INTERFACE | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}'`
	    ;;

	*)
	    ACTUAL_IP=`/sbin/ip -4 route get 1 | awk '{print $NF; exit}'`
	    ;;
    esac

    logMessage V "Actual TCP/IP address" "${ACTUAL_IP}"
}

deleteIPAddress()
{
    if [ -z "${DNS_ADDRESS}" ]; then
	logMessage N "Host ${HOSTNAME} is not defined in the DNS server"
	cleanExit 1
    fi

    if /usr/bin/nsupdate <<EOF; then
server 10.228.124.13
zone scx.com
update delete ${HOSTNAME}.scx.com. A
send
EOF
	DNS_ADDRESS=""
	logMessage N "Host ${HOSTNAME} deleted from DNS server"
	cleanExit 0
    else
	logMessage N "nsupdate failed to delete host ${HOSTNAME} from DNS server"
	cleanExit 1
    fi
}

updateIPAddress()
{
    # Now check if we should update our DNS address

    if [ -z "$DNS_ADDRESS" ]; then
	logMessage N "Host address not found in DNS"
    fi

    if [ "${DNS_ADDRESS}" = "${ACTUAL_IP}" ]; then
	logMessage N "DNS address (${DNS_ADDRESS}) matches actual TCP/IP address"
	[ ${FORCE} -eq 0 ] && return
	logMessage N "DNS address will be updated to due --force qualifier"
    fi

    #
    # DNS address and actual TCP/IP address do not match; update is needed
    #

    if ! /usr/bin/nsupdate <<EOF; then
server 10.228.124.13
zone scx.com
update delete ${HOSTNAME}.scx.com. A
update add ${HOSTNAME}.scx.com. 300 A ${ACTUAL_IP}
send
EOF
	logMessage N "Failed to update DNS address with ${ACTUAL_IP}"
    else
        logMessage N "Set DNS for host ${HOSTNAME} to ${ACTUAL_IP}"
    fi
}

updateResolvConf()
{
    cat > $TEMPFILE <<EOF
domain scx.com
search scx.com
nameserver 10.228.124.13
nameserver 10.177.9.182
EOF

    local updFlag=0
    local resolvConf=/etc/resolv.conf

    if [ ! -f $resolvConf ]; then
	updFlag=1
    elif ! cmp -s $resolvConf $TEMPFILE; then
	updFlag=1
    fi

    if [ $updFlag -ne 0 ]; then 
	logMessage N "Updating /etc/resolv.conf file"

	if [ `id -u` -eq 0 ]; then
	    cp $TEMPFILE $resolvConf
	    chmod 644 $resolvConf
	else
	    sudo cp $TEMPFILE $resolvConf
	    sudo chmod 644 $resolvConf
	fi
    else
	logMessage V "File /etc/resolv.conf is up to date"
    fi
}

checkConfiguration()
{
    if ! crontab -l 2> /dev/null | grep -q "$SCRIPTNAME" ; then
	return 1
    fi

    return 0
}

configure()
{
    if checkConfiguration; then
	logMessage F "System already configured to run $SCRIPTNAME automatically"
	return
    fi

    cat > $ROTATESCRIPT <<EOF
$LOGFILE {
        missingok
	notifempty
	compress
        size 50k
        copytruncate
        rotate 4
	weekly
}
EOF

    crontab -l > $TEMPFILE 2> /dev/null || true

    # Some platforms (Mac OS/X) do not have logrorate.
    # If we don't find it, then use our own

    if [ -f /usr/sbin/logrotate ]; then
	echo "@reboot         ${SCRIPTNAME}" >> $TEMPFILE
	echo "*/15 * * * *    ${SCRIPTNAME}" >> $TEMPFILE
	echo "2 0 * * 0       /usr/sbin/logrotate --state ${ROTATESTATE} $ROTATESCRIPT" >> $TEMPFILE
    else
	echo "@reboot         ${SCRIPTNAME} --logrotate" >> $TEMPFILE
	echo "*/15 * * * *    ${SCRIPTNAME} --logrotate" >> $TEMPFILE
    fi

    crontab $TEMPFILE

    logMessage N "Crontab configured to run $SCRIPTNAME automatically"
}

unconfigure()
{
    if ! checkConfiguration; then
	logMessage F "System not configured to run $SCRIPTNAME automatically"
	return
    fi

    crontab -l > $TEMPFILE 2> /dev/null || true

    # We can unconfigure in two ways:
    # 1. "Strict" unconfigure
    #    Full paths are matched on removal, causing issues if the repo
    #    is moved without unconfiguring first. To recover from this,
    #    you must manually edit (or delete) your crontab configuration.
    #
    # 2. "Permissive" unconfigure
    #    Match anything about updatedns. This is easier when moving the
    #    repository without unconfigurating first. BUT: If you have
    #    several versions of this repo in different places, we may
    #    unconfigure "too much" from the crontab file.
    #
    # This behavior is controlled by variable STRICT_UNCONFIGURE.

    if [ $STRICT_UNCONFIGURE -eq 1 ]; then
        egrep -v "${SCRIPTNAME}|${ROTATESCRIPT}" $TEMPFILE | crontab
    else
        local SCRIPTNAME_BASE=`basename $SCRIPTNAME .sh`
        egrep -v "${SCRIPTNAME_BASE}" $TEMPFILE | crontab
    fi

    rm -f $ROTATESCRIPT $ROTATESTATE

    logMessage N "Crontab unconfigured to run $SCRIPTNAME automatically"
}

usage()
{
    # Consider adding: Configure, unconfigure
    # Todo: clean up logging on update, add reverse DNS updates
    echo "usage: $1 [OPTIONS]"
    echo "Options:"
    echo "  --configure            Configure to run automatically via cron."
    echo "  -d, --delete           Delete current host name from DNS server."
    echo "  -dn, --deletename      Delete specified host name from DNS server."
    echo "  -f, --force            Force DNS update even if not required."
    echo "  -q, --queryonly        Only query current IP address (implies verbose)."
    echo "  -l, --logrotate        Rotate logs ourselves (don't use logrotate program)"
    echo "  --unconfigure          Unconfigure to run automatically via cron."
    echo "  -v, --verbose          Run in verbose mode (produce output)."
    echo "  --version              Show verison number."
    echo
    echo "  -h, --help             shows this usage text."
}

while [ $# -ne 0 ]
do
    case "$1" in
	--configure)
	    CONFIGURE=1
	    shift 1
	    ;;

	-d | --delete)
	    DELETE=1
	    shift 1
	    ;;

        -dn | --deletename)
            DELETENAME=1
            HOSTNAME=$2
            DNS_ADDRESS=0.0.0.0
	    VERBOSE=1

            if [ -z "${HOSTNAME}" ]; then
	        echo "FATAL: no hostname specified to delete" 1>& 2
                cleanExit 1
            fi

            if echo $HOSTNAME | egrep -q -- '^-'; then
	        echo "FATAL: Host name '${HOSTNAME}' is not valid" 1>& 2
                cleanExit 1
            fi

            shift 2
            ;;

	-f | --force)
	    FORCE=1
	    shift 1
	    ;;

	-l | --logrotate)
	    LOGROTATE=1
	    shift 1
	    ;;

	-q | --queryonly)
	    QUERYONLY=1
	    VERBOSE=1
	    shift 1
	    ;;

	--unconfigure)
	    UNCONFIGURE=1
	    shift 1
	    ;;

        -v | --verbose)
	    VERBOSE=1
            shift 1
            ;;

	--version)
	    echo `basename $0` version $VERSION
	    cleanExit 0
	    ;;

        -h | --help)
            usage `basename $0` >&2
            cleanExit 0
            ;;

        *)
            echo "Invalid option, try: `basename $0` -h" >& 2
            cleanExit 1
            ;;
    esac
done

# Get a timestamp for logging purposes
if ! TIMESTAMP=`date +%F\ %T`; then
    echo "Unable to get timestamp using 'date' command" 1>& 2
    cleanExit 1
fi

# Delete named host if requested
# (This must be done early to not overwrite specified hostname)

if [ ${DELETENAME} -ne 0 ]; then
    deleteIPAddress
fi

# Rotate log file manually if appropriate
rotateLog

logMessage V "Logfile name" "${LOGFILE}"

# Check if we're confgured to run automatically

if checkConfiguration; then
    logMessage V "Configuration" "Okay"
else
    logMessage V "Configuration" "<Unconfigured>"
fi

# Grab our current DNS address

getDNSAddress

# Grab our actual TCP/IP address

getCurrentIPAddress

# Query Only?

if [ ${QUERYONLY} -ne 0 ]; then
    cleanExit 0
else
    logMessage V " "
fi

# Configure/unconfigure if requested

[ ${UNCONFIGURE} -ne 0 ] && unconfigure
[ ${CONFIGURE} -ne 0 ] && configure

# Delete TCP/IP address if so requested

if [ ${DELETE} -ne 0 ]; then
    deleteIPAddress
fi

# Update TCP/IP address if needed

updateIPAddress

# Update /etc/resolv.conf if needed (requires 'sudo' permissions or root account)

updateResolvConf

cleanExit 0
