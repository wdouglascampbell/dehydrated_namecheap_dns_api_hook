#!/usr/bin/env bash
#set -x

function deploy_challenge {
    local FIRSTDOMAIN="${1}"
    local SLD=`sed -E 's/(.*\.)*([^.]+)\..*/\2/' <<< "${FIRSTDOMAIN}"`
    local TLD=`sed -E 's/.*\.([^.]+)/\1/' <<< "${FIRSTDOMAIN}"`

    local POSTDATA=" --data-urlencode apiuser=$apiusr --data-urlencode apikey=$apikey --data-urlencode username=$apiusr --data-urlencode ClientIp=$cliip --data-urlencode SLD=$SLD --data-urlencode TLD=$TLD"
    local HOSTS_URI="https://api.namecheap.com/xml.response"

    local num=0

    # get list of current records for domain
    local records_list=`$CURL $POSTDATA --data-urlencode 'Command=namecheap.domains.dns.getHosts' "$HOSTS_URI" | sed -En 's/<host (.*)/\1/p'`

    # create $RECORDS_BACKUP directory if it doesn't yet exist
    mkdir -p $RECORDS_BACKUP

    # parse and store current records
    #    Namecheap's setHosts method requires ALL records to be posted.  Therefore, the required information for recreating ALL records
    #    is extracted.  In addition, to protect against unforeseen issues that may cause the setHosts method to err, this information is
    #    stored in the $RECORDS_BACKUP directory allowing easy reference if they need to be restored manually.
    POSTDATA=$POSTDATA" --data-urlencode Command=namecheap.domains.dns.setHosts"
    OLDIFS="$IFS"
    while read -r current_record; do
        ((num++))
        # extract record attributes and create comma-separate string
        record_params=`sed -E 's/^[^"]*"|"[^"]*$//g; s/"[^"]+"/,/g; s/ +/ /g' <<< "$current_record" | tee "${RECORDS_BACKUP}/${FIRSTDOMAIN}_${num}_record.txt"`
        while IFS=, read -r hostid hostname recordtype address mxpref ttl associatedapptitle friendlyname isactive isddnsenabled; do
            if [[ "$recordtype" = "MX" ]]; then
                POSTDATA=$POSTDATA" --data-urlencode hostname$num=$hostname"
                POSTDATA=$POSTDATA" --data-urlencode recordtype$num=$recordtype"
                POSTDATA=$POSTDATA" --data-urlencode address$num=$address"
                POSTDATA=$POSTDATA" --data-urlencode mxpref$num=$mxpref"
                POSTDATA=$POSTDATA" --data-urlencode ttl$num=$ttl"
            else
                POSTDATA=$POSTDATA" --data-urlencode hostname$num=$hostname"
                POSTDATA=$POSTDATA" --data-urlencode recordtype$num=$recordtype"
                POSTDATA=$POSTDATA" --data-urlencode address$num=$address"
                POSTDATA=$POSTDATA" --data-urlencode ttl$num=$ttl"
            fi
        done <<< "$record_params"
    done <<< "$records_list"
    IFS="$OLDIFS"

    # add challenge records to post data
    local count=0
    while (( "$#" >= 3 )); do
        ((num++))

        # DOMAIN
        #   The domain name (CN or subject alternative name) being validated.
        DOMAIN="${1}"; shift
        # TOKEN_FILENAME
        #   The name of the file containing the token to be served for HTTP
        #   validation. Should be served by your web server as
        #   /.well-known/acme-challenge/${TOKEN_FILENAME}.
        TOKEN_FILENAME="${1}"; shift
        # TOKEN_VALUE
        #   The token value that needs to be served for validation. For DNS
        #   validation, this is what you want to put in the _acme-challenge
        #   TXT record. For HTTP validation it is the value that is expected
        #   be found in the $TOKEN_FILENAME file.
        TOKEN_VALUE[$count]="${1}"; shift

        SUB[$count]=`sed -E "s/$SLD.$TLD//" <<< "${DOMAIN}"`
        CHALLENGE_HOSTNAME=`sed -E "s/\.$//" <<< "${SUB[$count]}"`

        POSTDATA=$POSTDATA" --data-urlencode hostname$num=_acme-challenge.${CHALLENGE_HOSTNAME}"
        POSTDATA=$POSTDATA" --data-urlencode recordtype$num=TXT"
        POSTDATA=$POSTDATA" --data-urlencode address$num=${TOKEN_VALUE[$count]}"
        POSTDATA=$POSTDATA" --data-urlencode ttl$num=60"

        ((count++))
    done
    local items=$count

    $CURL --request POST  $POSTDATA "$HOSTS_URI" 2>&1 > /dev/null
    

    # wait up to 30 minutes for DNS updates to be provisioned (check at 15 second intervals)
    timer=0
    count=0
    while [ $count -lt $items ]; do
        until dig @1.1.1.1 txt "_acme-challenge.${SUB[$count]}$SLD.$TLD" | grep "${TOKEN_VALUE[$count]}" 2>&1 > /dev/null; do
            if [[ "$timer" -ge 1800 ]]; then
                # time has exceeded 30 minutes
                send_error $FIRSTDOMAIN
                break
            else
                echo " + DNS not propagated. Waiting 15s for record creation and replication... Total time elapsed has been $timer seconds."
                ((timer+=15))
                sleep 15
            fi
        done
        ((count++))
    done
}

function clean_challenge {
    local DOMAIN="${1}" TOKEN_FILENAME="${2}" TOKEN_VALUE="${3}"

    # This hook is called after attempting to validate each domain,
    # whether or not validation was successful. Here you can delete
    # files or DNS records that are no longer needed.
    #
    # The parameters are the same as for deploy_challenge.

    local FIRSTDOMAIN="${1}"
    local SLD=`sed -E 's/(.*\.)*([^.]+)\..*/\2/' <<< "${FIRSTDOMAIN}"`
    local TLD=`sed -E 's/.*\.([^.]+)/\1/' <<< "${FIRSTDOMAIN}"`

    local POSTDATA=" --data-urlencode apiuser=$apiusr --data-urlencode apikey=$apikey --data-urlencode username=$apiusr --data-urlencode ClientIp=$cliip --data-urlencode SLD=$SLD --data-urlencode TLD=$TLD"
    local HOSTS_URI="https://api.namecheap.com/xml.response"
    local num=0

    # get list of current records for domain
    local records_list=`$CURL $POSTDATA --data-urlencode 'Command=namecheap.domains.dns.getHosts' "$HOSTS_URI" | sed -En 's/<host (.*)/\1/p'`

    # remove challenge records from list
    records_list=`sed '/acme-challenge/d' <<< "$records_list"`

    # parse and store current records
    #    Namecheap's setHosts method requires ALL records to be posted.  Therefore, the required information for recreating ALL records
    #    is extracted.  In addition, to protect against unforeseen issues that may cause the setHosts method to err, this information is
    #    stored in the $RECORDS_BACKUP allowing easy reference if they need to be restored manually.
    POSTDATA=$POSTDATA" --data-urlencode Command=namecheap.domains.dns.setHosts"
    OLDIFS="$IFS"
    while read -r current_record; do
        ((num++))
        # extract record attributes and create comma-separate string
        record_params=`sed -E 's/^[^"]*"|"[^"]*$//g; s/"[^"]+"/,/g; s/ +/ /g' <<< "$current_record" | tee "${RECORDS_BACKUP}/${FIRSTDOMAIN}_${num}_record.txt"`
        while IFS=, read -r hostid hostname recordtype address mxpref ttl associatedapptitle friendlyname isactive isddnsenabled; do
            if [[ "$recordtype" = "MX" ]]; then
                POSTDATA=$POSTDATA" --data-urlencode hostname$num=$hostname"
                POSTDATA=$POSTDATA" --data-urlencode recordtype$num=$recordtype"
                POSTDATA=$POSTDATA" --data-urlencode address$num=$address"
                POSTDATA=$POSTDATA" --data-urlencode mxpref$num=$mxpref"
                POSTDATA=$POSTDATA" --data-urlencode ttl$num=$ttl"
            else
                POSTDATA=$POSTDATA" --data-urlencode hostname$num=$hostname"
                POSTDATA=$POSTDATA" --data-urlencode recordtype$num=$recordtype"
                POSTDATA=$POSTDATA" --data-urlencode address$num=$address"
                POSTDATA=$POSTDATA" --data-urlencode ttl$num=$ttl"
            fi
        done <<< "$record_params"
    done <<< "$records_list"
    IFS="$OLDIFS"

    $CURL --request POST $POSTDATA "$HOSTS_URI" 2>&1 > /dev/null
}

function deploy_cert {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"

    # This hook is called once for each certificate that has been
    # produced. Here you might, for instance, copy your new certificates
    # to service-specific locations and reload the service.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - KEYFILE
    #   The path of the file containing the private key.
    # - CERTFILE
    #   The path of the file containing the signed certificate.
    # - FULLCHAINFILE
    #   The path of the file containing the full certificate chain.
    # - CHAINFILE
    #   The path of the file containing the intermediate certificate(s).
    # - TIMESTAMP
    #   Timestamp when the specified certificate was created.

    echo "Deploying certificate for ${DOMAIN}..."
    # copy new certificate to /etc/pki/tls/certs folder
    cp "${CERTFILE}" "${DEPLOYED_CERTDIR}/${DOMAIN}.crt"
    echo " + certificate copied"

    # copy new key to /etc/pki/tls/private folder
    cp "${KEYFILE}" "${DEPLOYED_KEYDIR}/${DOMAIN}.key"
    echo " + key copied"

    # copy new chain file which contains the intermediate certificate(s)
    cp "${CHAINFILE}" "${DEPLOYED_CERTDIR}/letsencrypt-intermediate-certificates.pem"
    echo " + intermediate certificate chain copied"

    # combine certificate and chain file (used by Nginx)
    cat "${CERTFILE}" "${CHAINFILE}" > "${DEPLOYED_CERTDIR}/${DOMAIN}-chain.crt"
    echo " + combine certificate and intermediate certificate chain"

    # reload services
    echo " + Reloading Services"
    "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/reload_services.sh"

    # send email notification
    send_notification $DOMAIN
}

function unchanged_cert {
    local DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}"

    # This hook is called once for each certificate that is still
    # valid and therefore wasn't reissued.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - KEYFILE
    #   The path of the file containing the private key.
    # - CERTFILE
    #   The path of the file containing the signed certificate.
    # - FULLCHAINFILE
    #   The path of the file containing the full certificate chain.
    # - CHAINFILE
    #   The path of the file containing the intermediate certificate(s).
}

function invalid_challenge() {
    local DOMAIN="${1}" RESPONSE="${2}"

    # This hook is called if the challenge response has failed, so domain
    # owners can be aware and act accordingly.
    #
    # Parameters:
    # - DOMAIN
    #   The primary domain name, i.e. the certificate common
    #   name (CN).
    # - RESPONSE
    #   The response that the verification server returned
}

function request_failure() {
    local STATUSCODE="${1}" REASON="${2}" REQTYPE="${3}"

    # This hook is called when an HTTP request fails (e.g., when the ACME
    # server is busy, returns an error, etc). It will be called upon any
    # response code that does not start with '2'. Useful to alert admins
    # about problems with requests.
    #
    # Parameters:
    # - STATUSCODE
    #   The HTML status code that originated the error.
    # - REASON
    #   The specified reason for the error.
    # - REQTYPE
    #   The kind of request that was made (GET, POST...)
}

function startup_hook() {
  # This hook is called before the cron command to do some initial tasks
  # (e.g. starting a webserver).

  :
}

function exit_hook() {
  # This hook is called at the end of the cron command and can be used to
  # do some final (cleanup or other) tasks.

  :
}

# Setup default config values, load configuration file
function load_config() {
    # Default values
    apiusr=
    apikey=
    DEBUG=no
    RECORDS_BACKUP=${BASEDIR}/records_backup
    SENDER="sender@example.com"
    RECIPIENT="recipient@example.com"
    DEPLOYED_CERTDIR=/etc/pki/tls/certs
    DEPLOYED_KEYDIR=/etc/pki/tls/private
    MAIL_METHOD=SENDMAIL
    SMTP_DOMAIN=localhost
    SMTP_SERVER=

    # Check if config file exists
    if [[ ! -f "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/config" ]]; then
        echo "#" >&2
        echo "# !! WARNING !! No main config file found, using default config!" >&2
        echo "#" >&2
    else
        . "$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/config"
    fi
}

function send_error {
    local DOMAIN="${1}" TODAYS_DATE=`date`

    # set message content
    MSG_CONTENT=$(cat << EOF
Content-Type:text/html;charset='UTF-8'
Content-Transfer-Encoding:7bit
From:SSL Certificate Renewal Script<$SENDER>
To:<$RECIPIENT>
Subject: New Certificate Deployment Failed - $DOMAIN - $TODAYS_DATE

<html>
<p>A new certificate for the domain, <b>${FIRSTDOMAIN}</b>, has failed.</p>
<p>DNS record did not propagate.  Unable to verify domain is yours.</p>
</html>
EOF
)
IFS='
'

    if [ "${MAIL_METHOD}" == "SENDMAIL" ]; then
        # send notification email
        cat << EOF | /usr/sbin/sendmail -t -f $SENDER
$MSG_CONTENT
EOF
    else
        # prepare notification email message
        a=$(cat << EOF
HELO $SMTP_DOMAIN
MAIL FROM: <$SENDER>
RCPT TO: <$RECIPIENT>
DATA
$MSG_CONTENT
.
QUIT
.
EOF
)
IFS='
'

        # send notification email
        exec 1<>/dev/tcp/$SMTP_SERVER/25
        declare -a b=($a)
        for x in "${b[@]}"
        do
            echo $x
            sleep .1
        done
    fi
}

function send_notification {
    local DOMAIN="${1}" TODAYS_DATE=`date`

    # set message content
    MSG_CONTENT=$(cat << EOF
Content-Type:text/html;charset='UTF-8'
Content-Transfer-Encoding:7bit
From:SSL Certificate Renewal Script<$SENDER>
To:<$RECIPIENT>
Subject: New Certificate Deployed - $TODAYS_DATE

<html>
<p>A new certificate for the domain, <b>${DOMAIN}</b>, has been deployed.</p>
<p>Please confirm certificate is working as expected.</p>
</html>
EOF
)
IFS='
'

    if [ "${MAIL_METHOD}" == "SENDMAIL" ]; then
        # send notification email
        cat << EOF | /usr/sbin/sendmail -t -f $SENDER
$MSG_CONTENT
EOF
    else
        # prepare notification email message
        a=$(cat << EOF
HELO $SMTP_DOMAIN
MAIL FROM: <$SENDER>
RCPT TO: <$RECIPIENT>
DATA
$MSG_CONTENT
.
QUIT
.
EOF
)
IFS='
'

        # send notification email
        exec 1<>/dev/tcp/$SMTP_SERVER/25
        declare -a b=($a)
        for x in "${b[@]}"
        do
            echo $x
            sleep .1
        done
    fi
}

# load config values
load_config

if [[ "${DEBUG}" == "yes" ]]; then
    CURL="/usr/bin/curl -sv"
else
    CURL="/usr/bin/curl -s"
fi

# get this client's ip address
cliip=`$CURL -s https://v4.ifconfig.co/ip`

HANDLER="$1"; shift
if [[ "${HANDLER}" =~ ^(deploy_challenge|clean_challenge|deploy_cert|unchanged_cert|invalid_challenge|request_failure|startup_hook|exit_hook)$ ]]; then
  "$HANDLER" "$@"
fi
exit 0
