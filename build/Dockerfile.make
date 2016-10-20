# This Dockerfile is used to include build dependencies,
# and provide a containerized build environment for
# running the `container-*` make targets. It includes
# ONBUILD instructions to ADD the Current Working Directory,
# and ADD the docker registry credentials for the `container-ship` target.
# This image is meant to be used as a minimal build-dep base container,
# and does not ADD the project source or `.docker/config.json` for security.
#
## Usage: Set REPO to your repo name, then build this using:
##     docker build -f build/Dockerfile.make -t "$(REPO):build" .
##     docker push "$(REPO):build"
##   Then, in your project's source code repo or CI/CD server's workspace:
##     docker build -
FROM trinitronx/build-tools:ubuntu-1404

WORKDIR /root

ENV KUBERNETES_VERSION=1.2.3
ENV DOCKER_VERSION=1.9.1

RUN sed -i'' -e '/-backports/ s/^#[[:space:]]*//' /etc/apt/sources.list
RUN printf "deb http://archive.ubuntu.com/ubuntu/ $(lsb_release -c -s)-backports universe\ndeb-src http://archive.ubuntu.com/ubuntu/ $(lsb_release -c -s)-backports universe\n" \
    > /etc/apt/sources.list.d/backports.list
RUN apt-get update -qq && apt-get -y install curl

RUN \
    curl -SL https://github.com/kubernetes/kubernetes/releases/download/v${KUBERNETES_VERSION}/kubernetes.tar.gz \
    | tar xz kubernetes/platforms/linux/amd64/kubectl && \
    mv kubernetes/platforms/linux/amd64/kubectl /usr/local/bin && chmod +x /usr/local/bin/kubectl && \
    rm -rf kubernetes

RUN \
    curl -o /usr/bin/docker-${DOCKER_VERSION} https://get.docker.com/builds/Linux/x86_64/docker-${DOCKER_VERSION} && \
    ln -s /usr/bin/docker-${DOCKER_VERSION} /usr/bin/docker && chmod +x /usr/bin/docker /usr/bin/docker-${DOCKER_VERSION}

ONBUILD ADD . /src
ONBUILD ADD .docker/config.json /root/.docker/config.json
ONBUILD WORKDIR /src

ENTRYPOINT ["/bin/bash", "-c"]

# vim: set ft=dockerfile :
