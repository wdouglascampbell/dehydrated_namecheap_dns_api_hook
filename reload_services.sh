#!/usr/bin/env bash

# Script to reloading services that use SSL certificates to ensure
# all services are using the latest versions of the certificates.

DOMAIN="${1}" KEYFILE="${2}" CERTFILE="${3}" FULLCHAINFILE="${4}" CHAINFILE="${5}" TIMESTAMP="${6}"

# Apache
#echo " + Reloading Apache configuration"
#systemctl reload apache2.service

# Nginx
#echo " + Reloading Nginx configuration"
#systemctl reload nginx.service

# cPanel
#function urlencode() {
#   cat "$1" | perl -MURI::Escape -ne 'print uri_escape($_)'
#}
#uapi SSL install_ssl "domain=$DOMAIN" "cert=$(urlencode "$CERTFILE")" "key=$(urlencode "$KEYFILE")"
