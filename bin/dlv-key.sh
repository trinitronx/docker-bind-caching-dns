#!/bin/bash
set -x
url="http://ftp.isc.org/isc/bind9/keys/9.8/bind.keys.v9_8"
sig="http://ftp.isc.org/isc/bind9/keys/9.8/bind.keys.v9_8.asc"
sha="http://ftp.isc.org/isc/bind9/keys/9.8/bind.keys.v9_8.sha256.asc"
key="0B7BAE00"
tmp=$(mktemp -d "/tmp/$(basename $0)-$$-XXXXXX")
echo "TMP=$tmp"
gpg="gpg --homedir $tmp --no-default-keyring --primary-keyring $tmp/pubring.gpg"

cd /tmp/

keyfile_name=$(basename $url)
sigfile_name=$(basename $sig)

$gpg --keyserver hkps://hkps.pool.sks-keyservers.net --recv-keys $key

curl -s $url > $keyfile_name
curl -s $sig > $sigfile_name

output=$( $gpg --trust-model direct --verify $sigfile_name  $keyfile_name 2>&1 )
if [[ $? != 0 ]]; then
	echo -e "FAIL\n\n${output}"
	exit 1
fi

echo OK

cat $keyfile_name >> /etc/bind/bind.keys
rm $keyfile_name $sigfile_name
rm -rf $tmp
