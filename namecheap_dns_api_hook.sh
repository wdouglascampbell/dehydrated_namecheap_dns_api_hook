#!/usr/bin/env bash

# Namecheap API Credentials
apiusr=
apikey=
cliip=

function send_notification {
    local DOMAIN="${1}" TODAYS_DATE=`date` SENDER="sender@example.com" RECIPIENT="recipient@example.com"

    # send notification email
    cat << EOF | /usr/sbin/sendmail -t -f $SENDER
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
}

function deploy_challenge {
    local FIRSTDOMAIN="${1}"
    local SLD=`sed -E 's/(.*\.)*([^.]+)\..*/\2/' <<< "${FIRSTDOMAIN}"`
    local TLD=`sed -E 's/.*\.([^.]+)/\1/' <<< "${FIRSTDOMAIN}"`

    local SETHOSTS_URI="'https://api.namecheap.com/xml.response?apiuser=$apiusr&apikey=$apikey&username=$apiusr&Command=namecheap.domains.dns.setHosts&ClientIp=$cliip&SLD=$SLD&TLD=$TLD'"
    local POSTDATA=""
    
    local num=0
    
    # get list of current records for domain
    local records_list=`/usr/bin/curl -s "https://api.namecheap.com/xml.response?apiuser=$apiusr&apikey=$apikey&username=$apiusr&Command=namecheap.domains.dns.getHosts&ClientIp=$cliip&SLD=$SLD&TLD=$TLD" | sed -En 's/<host (.*)/\1/p'`

    # parse and store current records
    #    Namecheap's setHosts method requires ALL records to be posted.  Therefore, the required information for recreating ALL records
    #    is extracted.  In addition, to protect against unforeseen issues that may cause the setHosts method to err, this information is
    #    stored in the records_backup directory allowing easy reference if they need to be restored manually.
    OLDIFS=$IFS
    while read -r current_record; do
        ((num++))
        # extract record attributes and create comma-separate string
        record_params=`sed -E 's/^[^"]*"|"[^"]*$//g; s/"[^"]+"/,/g; s/ +/ /g' <<< "$current_record" | tee "records_backup/${FIRSTDOMAIN}_${num}_record.txt"`
        while IFS=, read -r hostid hostname recordtype address mxpref ttl associatedapptitle friendlyname isactive isddnsenabled; do
            if [[ "$recordtype" = "MX" ]]; then
                POSTDATA=$POSTDATA" --data-urlencode 'hostname$num=$hostname'"
                POSTDATA=$POSTDATA" --data-urlencode 'recordtype$num=$recordtype'"
                POSTDATA=$POSTDATA" --data-urlencode 'address$num=$address'"
                POSTDATA=$POSTDATA" --data-urlencode 'mxpref$num=$mxpref'"
                POSTDATA=$POSTDATA" --data-urlencode 'ttl$num=$ttl'"
            else
                POSTDATA=$POSTDATA" --data-urlencode 'hostname$num=$hostname'"
                POSTDATA=$POSTDATA" --data-urlencode 'recordtype$num=$recordtype'"
                POSTDATA=$POSTDATA" --data-urlencode 'address$num=$address'"
                POSTDATA=$POSTDATA" --data-urlencode 'ttl$num=$ttl'"
            fi
        done <<< "$record_params"
    done <<< "$records_list"
    IFS=$OLDIFS

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
        
        POSTDATA=$POSTDATA" --data-urlencode 'hostname$num=_acme-challenge.${SUB[$count]}'"
        POSTDATA=$POSTDATA" --data-urlencode 'recordtype$num=TXT'"
        POSTDATA=$POSTDATA" --data-urlencode 'address$num=${TOKEN_VALUE[$count]}'"
        POSTDATA=$POSTDATA" --data-urlencode 'ttl$num=60'"
        
        ((count++))
    done
    local items=$count
    
    local command="/usr/bin/curl -sv --request POST $SETHOSTS_URI $POSTDATA 2>&1 > /dev/null"
    eval $command
    
    # wait up to 30 minutes for DNS updates to be provisioned (check at 15 second intervals)
    timer=0
    count=0
    while [ $count -lt $items ]; do
        until dig @8.8.8.8 txt "_acme-challenge.${SUB[$count]}$SLD.$TLD" | grep "${TOKEN_VALUE[$count]}" 2>&1 > /dev/null; do
            if [[ "$timer" -ge 1800 ]]; then
                # time has exceeded 30 minutes
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

    local SETHOSTS_URI="'https://api.namecheap.com/xml.response?apiuser=$apiusr&apikey=$apikey&username=$apiusr&Command=namecheap.domains.dns.setHosts&ClientIp=$cliip&SLD=$SLD&TLD=$TLD'"
    local POSTDATA=""
    
    local num=0
    
    # get list of current records for domain
    local records_list=`/usr/bin/curl -s "https://api.namecheap.com/xml.response?apiuser=$apiusr&apikey=$apikey&username=$apiusr&Command=namecheap.domains.dns.getHosts&ClientIp=$cliip&SLD=$SLD&TLD=$TLD" | sed -En 's/<host (.*)/\1/p'`

    # remove challenge records from list
    records_list=`sed '/acme-challenge/d' <<< "$records_list"`

    # parse and store current records
    #    Namecheap's setHosts method requires ALL records to be posted.  Therefore, the required information for recreating ALL records
    #    is extracted.  In addition, to protect against unforeseen issues that may cause the setHosts method to err, this information is
    #    stored in the records_backup directory allowing easy reference if they need to be restored manually.
    OLDIFS=$IFS
    while read -r current_record; do
        ((num++))
        # extract record attributes and create comma-separate string
        record_params=`sed -E 's/^[^"]*"|"[^"]*$//g; s/"[^"]+"/,/g; s/ +/ /g' <<< "$current_record" | tee "records_backup/${FIRSTDOMAIN}_${num}_record.txt"`
        while IFS=, read -r hostid hostname recordtype address mxpref ttl associatedapptitle friendlyname isactive isddnsenabled; do
            if [[ "$recordtype" = "MX" ]]; then
                POSTDATA=$POSTDATA" --data-urlencode 'hostname$num=$hostname'"
                POSTDATA=$POSTDATA" --data-urlencode 'recordtype$num=$recordtype'"
                POSTDATA=$POSTDATA" --data-urlencode 'address$num=$address'"
                POSTDATA=$POSTDATA" --data-urlencode 'mxpref$num=$mxpref'"
                POSTDATA=$POSTDATA" --data-urlencode 'ttl$num=$ttl'"
            else
                POSTDATA=$POSTDATA" --data-urlencode 'hostname$num=$hostname'"
                POSTDATA=$POSTDATA" --data-urlencode 'recordtype$num=$recordtype'"
                POSTDATA=$POSTDATA" --data-urlencode 'address$num=$address'"
                POSTDATA=$POSTDATA" --data-urlencode 'ttl$num=$ttl'"
            fi
        done <<< "$record_params"
    done <<< "$records_list"
    IFS=$OLDIFS
    
    local command="/usr/bin/curl -sv --request POST $SETHOSTS_URI $POSTDATA 2>&1 > /dev/null"
    eval $command
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
    cp "${CERTFILE}" /etc/pki/tls/certs/$DOMAIN.crt
    echo " + certificate copied"

    # copy new key to /etc/pki/tls/private folder
    cp "${KEYFILE}" /etc/pki/tls/private/$DOMAIN.key
    echo " + key copied"

    # copy new chain file which contains the intermediate certificate(s)
    cp "${CHAINFILE}" /etc/pki/tls/certs/letsencrypt-intermediate-certificates.pem
    echo " + intermediate certificate chain copied"

    # restart Apache
    echo " + Reloading Apache configuration"
    systemctl reload httpd.service
    
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

HANDLER=$1; shift; $HANDLER $@
exit 0
