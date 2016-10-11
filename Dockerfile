FROM ubuntu:16.04

ENV DEBIAN_FRONTEND noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN true

RUN apt-get update

# Set UTF-8 locale & timezone
COPY build/preseed.txt /root/preseed.txt
RUN debconf-set-selections /root/preseed.txt && \
    apt-get -y install tzdata locales ; \
    locale-gen "en_US.UTF-8" ; \
    dpkg-reconfigure tzdata locales

RUN apt-get -y install bind9 bind9utils dnsutils ca-certificates libxml2 libxml2-dev libjson-c2 libjson-c-dev

ADD bin/dlv-key.sh /tmp/dlv-key.sh

ADD bin/update-gpg-keyserver-root-ca-certs.sh /tmp/

RUN apt-get -y install curl gnupg-curl && \
    bash /tmp/update-gpg-keyserver-root-ca-certs.sh && \
    bash /tmp/dlv-key.sh ; \
    rm /tmp/dlv-key.sh ; rm /tmp/update-gpg-keyserver-root-ca-certs.sh ; \
    apt-get -y remove curl ; \
    apt-get -y autoremove

RUN mkdir -p /run/named && chmod 0775 /run/named && chown root:bind /run/named
COPY etc/named.conf /etc/named.conf

CMD ["/usr/sbin/named", "-f", "-u", "bind", "-g"]