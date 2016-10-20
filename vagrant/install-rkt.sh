#!/bin/bash
set -e
set -x

cd $(mktemp -d)

rkt_version="1.17.0"
k8s_version="v1.4.3_coreos.0"
acbuild_version="0.4.0"

dnf -y install \
    openssl \
    systemd-container \
    go \
    git \
    rng-tools

curl -O -L https://github.com/containers/build/releases/download/v"${acbuild_version}"/acbuild-v"${acbuild_version}".tar.gz
tar -xzf acbuild-v"${acbuild_version}".tar.gz
install -Dm755 acbuild-v"${acbuild_version}"/acbuild /usr/bin/acbuild
install -Dm755 acbuild-v"${acbuild_version}"/acbuild-chroot /usr/bin/acbuild-chroot
install -Dm755 acbuild-v"${acbuild_version}"/acbuild-script /usr/bin/acbuild-script

kurl="https://storage.googleapis.com/kubernetes-release/release/v1.4.3/bin/linux/amd64"
curl -O -L "${kurl}"/kubectl
install -Dm755 kubectl /usr/bin/kubectl

curl -O -L https://github.com/coreos/rkt/releases/download/v"${rkt_version}"/rkt-"${rkt_version}"-1.x86_64.rpm
rpm -Uvh rkt-"${rkt_version}"-1.x86_64.rpm
install -Dm755 /vagrant/host-rkt /usr/bin/host-rkt

for unit in etcd.service apiserver.service controller-manager.service kubelet.service scheduler.service proxy.service; do
    install -Dm644 /vagrant/${unit} /usr/lib/systemd/system/${unit}
done

gpasswd -a vagrant rkt
gpasswd -a vagrant rkt-admin

cp /vagrant/selinux.config /etc/selinux/config
setenforce 0

mkdir --parents /etc/kubernetes
mkdir --parents /var/lib/docker
mkdir --parents /var/lib/kubelet
mkdir --parents /run/kubelet
mkdir --parents /var/run/kubernetes
mkdir --parents /etc/rkt/net.d
mkdir --parents /etc/cni/net.d
mkdir --parents /var/lib/etcd

cp /vagrant/resolv.conf /etc/kubernetes/resolv.conf
cp /vagrant/k8s.conf /etc/rkt/net.d
cp /vagrant/k8s.conf /etc/cni/net.d
cp /vagrant/bashrc /home/vagrant/.bashrc
chown vagrant:vagrant ~/.bashrc

sudo cp -r /vagrant/etc-wait-for /etc/wait-for
install -Dm644 /vagrant/wait-for@.service /usr/lib/systemd/system/wait-for@.service
install -Dm755 /vagrant/wait-for /usr/bin/wait-for

openssl genrsa -out /etc/kubernetes/kube-serviceaccount.key 2048

rkt trust --trust-keys-from-https --prefix "quay.io/coreos"

rkt fetch quay.io/coreos/hyperkube:"${k8s_version}"
rkt fetch quay.io/coreos/etcd:v2.3.7

systemctl daemon-reload

systemctl enable rkt-api
systemctl start rkt-api

systemctl enable rngd
systemctl start rngd

install -d --group=vagrant --owner=vagrant /home/vagrant/gopath /home/vagrant/gopath/src /home/vagrant/gopath/bin /home/vagrant/gopath/pkg
