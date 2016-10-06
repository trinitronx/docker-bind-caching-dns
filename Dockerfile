FROM ubuntu:16.04

ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN true

RUN apt-get update
RUN apt-get -y install bind9 bind9utils dnsutils ca-certificates

ADD etc/named.conf /etc/named.conf

ADD bin/dlv-key.sh /tmp/dlv-key.sh

ADD bin/update-gpg-keyserver-root-ca-certs.sh /tmp/

RUN apt-get -y install curl gnupg-curl && \
    bash /tmp/update-gpg-keyserver-root-ca-certs.sh && \
    bash /tmp/dlv-key.sh ; \
    rm /tmp/dlv-key.sh ; rm /tmp/update-gpg-keyserver-root-ca-certs.sh ; \
    apt-get -y remove curl ; \
    apt-get -y autoremove
