# This Dockerfile can be translated to `docker/dockerfile:1.0-experimental` syntax for enabling cache mounts:
# $ ./hack/translate-dockerfile-runopt-directive.sh < Dockerfile  | DOCKER_BUILDKIT=1 docker build  -f -  .

### Version definitions
# 03/20/2019 (v0.3.0-beta.0)
ARG ROOTLESSKIT_COMMIT=ed2671442965115b84ecf82d4831cc48747d89b8
# 03/14/2019 (v0.3.0-beta.1)
ARG SLIRP4NETNS_COMMIT=831c9002880c2fd350c38788fe0663995bd3e75a
# 03/14/2019
ARG RUNC_COMMIT=f56b4cbeadc407e715d9b2ba49e62185bd81cef4
# 03/01/2019
ARG MOBY_COMMIT=7c197c18d30e1683767709d69397ad1c0a5b2164
ARG DOCKER_CLI_RELEASE=18.09.4-rc1
# 03/21/2019
ARG CONTAINERD_COMMIT=ceba56893a76f22cf0126c46d835c80fb3833408
# 03/22/2019
ARG CRIO_COMMIT=af8f12daf73df0a203440c94f6e88725d13ab582
# 03/21/2018
ARG CNI_PLUGINS_COMMIT=82a0651d0a4d86738e9d6c8e27fa38eab07351ef
# 03/22/2019
ARG KUBERNETES_COMMIT=ab35bd06689744ee275fbec4d43cc7a30f5cca4d
# Kube's build script requires KUBE_GIT_VERSION to be set to a semver string
ARG KUBE_GIT_VERSION=v1.15-usernetes
ARG BAZEL_RELEASE=0.23.2
# 01/23/2017 (v.1.7.3.2)
ARG SOCAT_COMMIT=cef0e039a89fe3b38e36090d9fe4be000973e0be
ARG FLANNEL_RELEASE=v0.11.0
ARG ETCD_RELEASE=v3.3.12
ARG GOTASK_RELEASE=v2.5.0

ARG BASEOS=ubuntu

### Common base images (common-*)
FROM golang:1.12-alpine AS common-golang-alpine
RUN apk add --no-cache git

FROM common-golang-alpine AS common-golang-alpine-heavy
RUN apk --no-cache add btrfs-progs-dev bash build-base linux-headers libseccomp-dev

### RootlessKit (rootlesskit-build)
FROM common-golang-alpine AS rootlesskit-build
RUN git clone https://github.com/rootless-containers/rootlesskit.git /go/src/github.com/rootless-containers/rootlesskit
WORKDIR /go/src/github.com/rootless-containers/rootlesskit
ARG ROOTLESSKIT_COMMIT
RUN git pull && git checkout ${ROOTLESSKIT_COMMIT}
ENV CGO_ENABLED=0
RUN mkdir /out && \
  go build -o /out/rootlesskit github.com/rootless-containers/rootlesskit/cmd/rootlesskit && \
  go build -o /out/rootlessctl github.com/rootless-containers/rootlesskit/cmd/rootlessctl && \
  go build -o /out/rootlesskit-docker-proxy github.com/rootless-containers/rootlesskit/cmd/rootlesskit-docker-proxy

#### slirp4netns (slirp4netns-build)
FROM alpine:3.8 AS slirp4netns-build
RUN apk add --no-cache git build-base autoconf automake libtool linux-headers glib-dev glib-static
RUN git clone https://github.com/rootless-containers/slirp4netns.git /slirp4netns
WORKDIR /slirp4netns
ARG SLIRP4NETNS_COMMIT
RUN git pull && git checkout ${SLIRP4NETNS_COMMIT}
RUN ./autogen.sh && ./configure LDFLAGS="-static" && make && \
  mkdir /out && cp slirp4netns /out

### runc (runc-build)
FROM common-golang-alpine-heavy AS runc-build
RUN git clone https://github.com/opencontainers/runc.git /go/src/github.com/opencontainers/runc
WORKDIR /go/src/github.com/opencontainers/runc
ARG RUNC_COMMIT
RUN git pull && git checkout ${RUNC_COMMIT}
RUN make BUILDTAGS="seccomp" static && \
  mkdir /out && cp runc /out

### Moby (moby-build)
FROM common-golang-alpine-heavy AS moby-base
RUN git clone https://github.com/moby/moby.git /go/src/github.com/docker/docker
WORKDIR /go/src/github.com/docker/docker
ARG MOBY_COMMIT
RUN git pull && git checkout ${MOBY_COMMIT}

FROM moby-base AS moby-build-docker-init
RUN apk --no-cache add cmake
RUN hack/dockerfile/install/install.sh tini

FROM moby-base AS moby-build-docker-proxy
RUN hack/dockerfile/install/install.sh proxy

FROM moby-base AS moby-build
RUN mkdir /out
ENV DOCKER_BUILDTAGS="seccomp"
# runopt = --mount=type=cache,id=u7s-moby-build-cache,target=/root
RUN ./hack/make.sh .binary && cp -f bundles/.binary/dockerd-dev /out/dockerd
COPY --from=moby-build-docker-init /usr/local/bin/docker-init /out/
COPY --from=moby-build-docker-proxy /usr/local/bin/docker-proxy /out/

#### Docker CLI (dockercli-build)
ARG DOCKER_CLI_RELEASE
FROM docker:$DOCKER_CLI_RELEASE AS dockercli-build
RUN mkdir /out && cp /usr/local/bin/docker /out

### containerd (containerd-build)
FROM common-golang-alpine-heavy AS containerd-build
RUN git clone https://github.com/containerd/containerd.git /go/src/github.com/containerd/containerd
WORKDIR /go/src/github.com/containerd/containerd
ARG CONTAINERD_COMMIT
RUN git pull && git checkout ${CONTAINERD_COMMIT}
RUN make EXTRA_FLAGS="-buildmode pie" EXTRA_LDFLAGS='-extldflags "-fno-PIC -static"' BUILDTAGS="netgo osusergo static_build" && \
  mkdir /out && cp bin/containerd bin/containerd-shim bin/containerd-shim-runc-v1 bin/ctr /out

### CRI-O (crio-build)
# We don't use Alpine here so as to build cri-o linked with glibc rather than musl libc.
# TODO: use Alpine again when we figure out how to build cri-o as a static binary (rootless-containers/usernetes#19)
FROM golang:1.12 AS crio-build
RUN apt-get update && apt-get install -y build-essential libglib2.0-dev
RUN git clone https://github.com/kubernetes-incubator/cri-o.git /go/src/github.com/kubernetes-incubator/cri-o
WORKDIR /go/src/github.com/kubernetes-incubator/cri-o
ARG CRIO_COMMIT
RUN git pull && git checkout ${CRIO_COMMIT}
RUN make BUILDTAGS="exclude_graphdriver_btrfs exclude_graphdriver_devicemapper containers_image_openpgp" binaries && \
  mkdir /out && cp bin/conmon bin/crio /out

### CNI Plugins (cniplugins-build)
FROM common-golang-alpine-heavy AS cniplugins-build
RUN git clone https://github.com/containernetworking/plugins.git /go/src/github.com/containernetworking/plugins
WORKDIR /go/src/github.com/containernetworking/plugins
ARG CNI_PLUGINS_COMMIT
RUN git pull && git checkout ${CNI_PLUGINS_COMMIT}
RUN ./build_linux.sh -buildmode pie -ldflags "-extldflags \"-fno-PIC -static\"" && \
  mkdir /out && mv bin /out/cni

### Kubernetes (k8s-build)
FROM golang:1.12 AS k8s-build
RUN apt-get update && apt-get install -y -q patch
ARG BAZEL_RELEASE
ADD https://github.com/bazelbuild/bazel/releases/download/${BAZEL_RELEASE}/bazel-${BAZEL_RELEASE}-linux-x86_64 /usr/local/bin/bazel
RUN chmod +x /usr/local/bin/bazel
RUN git clone https://github.com/kubernetes/kubernetes.git /kubernetes
WORKDIR /kubernetes
ARG KUBERNETES_COMMIT
RUN git pull && git checkout ${KUBERNETES_COMMIT}
COPY ./src/patches/kubernetes /patches
# `git am` requires user info to be set
RUN git config user.email "nobody@example.com" && \
  git config user.name "Usernetes Build Script" && \
  git am /patches/* && git show --summary
ARG KUBE_GIT_VERSION
ENV KUBE_GIT_VERSION=${KUBE_GIT_VERSION}
# runopt = --mount=type=cache,id=u7s-k8s-build-cache,target=/root
RUN bazel build cmd/hyperkube && mkdir /out && cp bazel-bin/cmd/hyperkube/hyperkube /out

### socat (socat-build)
FROM ubuntu:18.04 AS socat-build
RUN apt-get update && apt-get install -y autoconf automake libtool build-essential git yodl
RUN git clone git://repo.or.cz/socat.git /socat
WORKDIR /socat
ARG SOCAT_COMMIT
RUN git pull && git checkout ${SOCAT_COMMIT}
RUN autoconf && ./configure LDFLAGS="-static" && make && strip socat && \
  mkdir -p /out && cp -f socat /out

#### flannel (flannel-build)
FROM busybox AS flannel-build
ARG FLANNEL_RELEASE
RUN mkdir -p /out && \
  wget -O /out/flanneld https://github.com/coreos/flannel/releases/download/${FLANNEL_RELEASE}/flanneld-amd64 && \
  chmod +x /out/flanneld

#### etcd (etcd-build)
FROM busybox AS etcd-build
ARG ETCD_RELEASE
RUN mkdir /tmp-etcd out && \
  wget -O - https://github.com/etcd-io/etcd/releases/download/${ETCD_RELEASE}/etcd-${ETCD_RELEASE}-linux-amd64.tar.gz | tar xz -C /tmp-etcd && \
  cp /tmp-etcd/etcd-${ETCD_RELEASE}-linux-amd64/etcd /tmp-etcd/etcd-${ETCD_RELEASE}-linux-amd64/etcdctl /out

#### go-task (gotask-build)
FROM busybox AS gotask-build
ARG GOTASK_RELEASE
RUN mkdir /tmp-task /out && \
  wget -O - https://github.com/go-task/task/releases/download/${GOTASK_RELEASE}/task_linux_amd64.tar.gz | tar xz  -C /tmp-task && \
  cp /tmp-task/task /out

### Binaries (bin-main)
FROM scratch AS bin-main
COPY --from=rootlesskit-build /out/* /
COPY --from=slirp4netns-build /out/* /
COPY --from=runc-build /out/* /
COPY --from=moby-build /out/* /
COPY --from=dockercli-build /out/* /
COPY --from=containerd-build /out/* /
COPY --from=crio-build /out/* /
# can't use wildcard here: https://github.com/rootless-containers/usernetes/issues/78
COPY --from=cniplugins-build /out/cni /cni
COPY --from=k8s-build /out/* /
COPY --from=socat-build /out/* /
COPY --from=flannel-build /out/* /
COPY --from=etcd-build /out/* /
COPY --from=gotask-build /out/* /

#### Test (test-main)
FROM ubuntu:18.04 AS test-main-ubuntu
# libglib2.0: require by conmon
RUN apt-get update && apt-get install -y -q git libglib2.0-dev iproute2 iptables uidmap

# fedora image is experimental
FROM fedora:29 AS test-main-fedora
# As of Jan 2019, fedora:29 has wrong permission bits on newuidmap newgidmap
RUN chmod +s /usr/bin/newuidmap /usr/bin/newgidmap
RUN dnf install -y git iproute iptables hostname procps-ng

FROM test-main-$BASEOS AS test-main
RUN useradd --create-home --home-dir /home/user --uid 1000 user
COPY . /home/user/usernetes
COPY --from=bin-main / /home/user/usernetes/bin
RUN mkdir -p /run/user/1000 /home/user/.local && \
  chown -R user:user /run/user/1000 /home/user
USER user
ENV HOME /home/user
ENV USER user
ENV XDG_RUNTIME_DIR=/run/user/1000
WORKDIR /home/user/usernetes
VOLUME /home/user/.local
ENTRYPOINT ["/home/user/usernetes/run.sh"]
