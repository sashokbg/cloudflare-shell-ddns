#!/bin/sh

ARGS=$(getopt -o 'z:,d:,a:,t:,y' -l 'zone:,domains:,account:,token:,yes' -- "$@")
eval set -- "$ARGS"

while true; do
  case "$1" in
  -z | --zone)
    zone_name="$2"
    shift 2
    ;;
  -d | --domains)
    domains="$2"
    shift 2
    ;;
  -a | --account)
    account="$2"
    shift 2
    ;;
  -t | --token)
    token="$2"
    shift 2
    ;;
  -y | --yes)
    autoconfirm="true"
    shift 1
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Error parsing arguments: $ARGS"
    exit 1
    ;;
  esac
done

ipv4=$(curl -4 -s ifconfig.co)
ipv6=$(curl -6 -s ifconfig.co)

findZone() {
  curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name&status=active&account.id=$account&page=1&per_page=1" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" >result.json

  zoneId=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$zone_name&status=active&account.id=$account&page=1&per_page=1" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

  if [ -z "$zoneId" ]; then
    echo "Error finding zone"
    exit 1
  fi
}

findDnsRecord() {
  dnsRecordId=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?type=A&name=$1&page=1&per_page=1" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

  dnsRecordIdv6=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records?type=AAAA&name=$1&page=1&per_page=1" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')
}

updateDnsRecord() {
  if [ ! -f "/tmp/ipv4_$1.dat" ]; then
    previous_ipv4=0
  else
    previous_ipv4=$(cat /tmp/ipv4_$1.dat)
  fi

  if [ "$previous_ipv4" = "$ipv4" ]; then
    echo "IPv4 not changed. Skipping."
    return
  fi

  curl -s -f -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$dnsRecordId" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$1\",\"content\":\"$ipv4\",\"ttl\":300,\"proxied\":false}"

  if [ $? -eq 0 ]; then
    echo "Successfully updated IPv4 to $ipv4"
    echo "$ipv4" >"/tmp/ipv4_$1.dat"
  else
    echo "Error updating IPv4 !"
  fi

}

updateDnsRecordv6() {
  if [ -z "$dnsRecordIdv6" ] || [ "$dnsRecordIdv6" = 'null' ]; then
    echo "No AAA record found. Skipping"
    return
  fi

  if [ ! -f "/tmp/ipv6_$1.dat" ]; then
    previous_ipv6=0
  else
    previous_ipv6=$(cat /tmp/ipv6_$1.dat)
  fi

  if [ "$previous_ipv6" = "$ipv6" ]; then
    echo "IPv6 not changed. Skipping."
    return
  fi

  curl -s -f -X PUT "https://api.cloudflare.com/client/v4/zones/$zoneId/dns_records/$dnsRecordIdv6" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"AAAA\",\"name\":\"$1\",\"content\":\"$ipv6\",\"ttl\":300,\"proxied\":false}"

  if [ $? -eq 0 ]; then
    echo "Successfully updated IPv6 to $ipv6"
    echo $ipv6 >/tmp/ipv6_$1.dat
  else
    echo "Error updating IPv6 !"
  fi
}

confirm() {
  if [ -n "$autoconfirm" ]; then
    return 0
  fi

  echo
  echo "Will update the following domains ($domains) in zone $zone_name. Confirm ? Y/n"
  while true; do
    printf "%s [Y/n]: " "$1"
    read -r response
    case $response in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) printf "Please enter Y or N.\n" ;;
    esac
  done
}

findZone

echo "Your ipv4 is $ipv4"
echo "Your ipv6 is $ipv6"

echo "Zone: $zone_name (id: $zoneId)"
echo "Domains: $domains"
echo "Account ID: $account"
echo "Token: <censored>"

if confirm "Continue"; then
  for subdomain in $(echo "$domains" | tr "," "\n"); do
    echo "============== UPDATING SUBDOMAIN: $subdomain ================"
    findDnsRecord "$subdomain"

    echo "DNS Zone Id: $zoneId"
    echo "DNS Record Id: $dnsRecordId"
    echo "IPv4: $ipv4"
    echo "IPv6: $ipv6"

    updateDnsRecord "$subdomain"
    updateDnsRecordv6 "$subdomain"
  done
fi
