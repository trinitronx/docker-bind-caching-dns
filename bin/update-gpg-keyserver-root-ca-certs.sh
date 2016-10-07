#!/bin/bash

gpg_keyserver=${1:-'hkps.pool.sks-keyservers.net'}
gpg_hkps_port='443'

keyserver_pool="$(dig ${gpg_keyserver} +short | sort | tr '\n' ' ')"

read -r -d '' stringify_ca_id <<-'EOPERLPROG'
  s/^\s*Issuer:\s*//;
  my @ca_long_id = split(",", $_);
  my @ca_id_arr = map { my @parts = split("=", $_); @parts[1]; } @ca_long_id ;
  my $ca_id = join("_", @ca_id_arr);
  chomp($ca_id);
  $ca_id =~ s/['",\.]//g;
  $ca_id =~ s/\s|\//_/g;
  print $ca_id . ".crt\n";
EOPERLPROG

for server in $keyserver_pool; do
  server_ca_cert="$(echo -n | openssl s_client -showcerts -connect ${server}:${gpg_hkps_port} 2>/dev/null  | perl  -ne 'if ( /-BEGIN CERTIFICATE-/../-END CERTIFICATE-/ ) { print $_ }')"
  ca_cert_filename=$(echo "$server_ca_cert" | openssl x509 -noout -text | grep "Issuer:" | perl -n -e "$stringify_ca_id")
  echo "Updating GPG Keyserver CA Cert: ${ca_cert_filename}"
  echo "$server_ca_cert" > /usr/local/share/ca-certificates/${ca_cert_filename}
done

update-ca-certificates --verbose
