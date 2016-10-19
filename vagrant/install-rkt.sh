#!/bin/bash
set -e
set -x

cd $(mktemp -d)

rkt_version="1.10.1"
k8s_version="v1.3.5_coreos.1"

dnf -y install \
    openssl \
    systemd-container

kurl="https://storage.googleapis.com/kubernetes-release/release/v1.3.5/bin/linux/amd64"

curl -O -L "${kurl}"/kubectl
install -Dm755 kubectl /usr/bin/kubectl

curl -O -L "${kurl}"/hyperkube
install -Dm755 hyperkube /usr/bin/hyperkube

curl -O -L https://github.com/containernetworking/cni/releases/download/v0.3.0/cni-v0.3.0.tgz
mkdir --parents /opt/cni/bin
tar -xzf cni-v0.3.0.tgz --directory /opt/cni/bin

curl -sSL https://coreos.com/dist/pubkeys/app-signing-pubkey.gpg | gpg2 --import -
key=$(gpg2 --with-colons --keyid-format LONG -k security@coreos.com | egrep ^pub | cut -d ':' -f5)

curl -O -L https://github.com/coreos/rkt/releases/download/v"${rkt_version}"/rkt-v"${rkt_version}".tar.gz
curl -O -L https://github.com/coreos/rkt/releases/download/v"${rkt_version}"/rkt-v"${rkt_version}".tar.gz.asc

gpg2 --trusted-key "${key}" --verify-files *.asc

tar xvzf rkt-v"${rkt_version}".tar.gz

for flavor in fly coreos kvm; do
    install -Dm644 rkt-v${rkt_version}/stage1-${flavor}.aci /usr/lib/rkt/stage1-images/stage1-${flavor}.aci
done

install -Dm755 rkt-v${rkt_version}/rkt /usr/bin/rkt

for f in rkt-v${rkt_version}/manpages/*; do
    install -Dm644 "${f}" "/usr/share/man/man1/$(basename $f)"
done

install -Dm644 rkt-v${rkt_version}/bash_completion/rkt.bash /usr/share/bash-completion/completions/rkt
install -Dm644 rkt-v${rkt_version}/init/systemd/tmpfiles.d/rkt.conf /usr/lib/tmpfiles.d/rkt.conf

for unit in rkt-gc.{timer,service} rkt-metadata.{socket,service}; do
    install -Dm644 rkt-v${rkt_version}/init/systemd/$unit /usr/lib/systemd/system/$unit
done

for unit in {socket,service}; do
    install -Dm644 /vagrant/rkt-api.${unit} /usr/lib/systemd/system/rkt-api.${unit}
done

for unit in etcd.service apiserver.service controller-manager.service kubelet.service scheduler.service proxy.service; do
    install -Dm644 /vagrant/${unit} /usr/lib/systemd/system/${unit}
done

groupadd --force --system rkt-admin
groupadd --force --system rkt

./rkt-v"${rkt_version}"/scripts/setup-data-dir.sh

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
mkdir --parents /var/lib/etcd

cp /vagrant/resolv.conf /etc/kubernetes/resolv.conf
cp /vagrant/k8s.conf /etc/rkt/net.d
cp /vagrant/bashrc /home/vagrant/.bashrc
chown vagrant:vagrant ~/.bashrc

sudo cp -r /vagrant/etc-wait-for /etc/wait-for
install -Dm644 /vagrant/wait-for@.service /usr/lib/systemd/system/wait-for@.service
install -Dm755 /vagrant/wait-for /usr/bin/wait-for

openssl genrsa -out /etc/kubernetes/kube-serviceaccount.key 2048

rkt trust --trust-keys-from-https --prefix "quay.io/coreos/etcd"
rkt trust --trust-keys-from-https --prefix "quay.io/coreos/hyperkube"
rkt trust --trust-keys-from-https --prefix "coreos.com/rkt/stage1-fly"
rkt trust --trust-keys-from-https --prefix "coreos.com/rkt/stage1-coreos"

rkt fetch quay.io/coreos/hyperkube:"${k8s_version}"
rkt fetch coreos.com/rkt/stage1-fly:${rkt_version}
rkt fetch coreos.com/rkt/stage1-coreos:${rkt_version}
rkt fetch quay.io/coreos/etcd:v2.3.7

rkt fetch --insecure-options=image docker://gcr.io/google_containers/kubedns-amd64:1.3
rkt fetch --insecure-options=image docker://gcr.io/google_containers/kube-dnsmasq-amd64:1.3
rkt fetch --insecure-options=image docker://gcr.io/google_containers/exechealthz-amd64:1.0

systemctl daemon-reload
systemd-tmpfiles --create /usr/lib/tmpfiles.d/rkt.conf

for unit in rkt-api etcd apiserver controller-manager kubelet scheduler proxy; do
    systemctl enable ${unit}
    systemctl start ${unit}
done

wait-for kubelet
kubectl create -f /vagrant/skydns.yaml
