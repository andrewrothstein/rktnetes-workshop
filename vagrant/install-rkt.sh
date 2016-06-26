#!/bin/bash
set -e
set -x

wait_for_url() {
  local url=$1
  local prefix=${2:-}
  local wait=${3:-1}
  local times=${4:-30}

  which curl >/dev/null || {
    echo "curl must be installed"
    exit 1
  }

  local i
  for i in $(seq 1 $times); do
    local out
    if out=$(curl -fs $url 2>/dev/null); then
      echo "On try ${i}, ${prefix}: ${out}"
      return 0
    fi
    sleep ${wait}
  done
  echo "Timed out waiting for ${prefix} to answer at ${url}; tried ${times} waiting ${wait} between each"
  return 1
}

cd $(mktemp -d)

version="1.9.1"

dnf -y install \
    openssl \
    systemd-container

curl -O -L https://storage.googleapis.com/kubernetes-release/release/v1.3.0-beta.2/bin/linux/amd64/kubectl
install -Dm755 kubectl /usr/bin/kubectl

curl -O -L https://storage.googleapis.com/kubernetes-release/release/v1.3.0-beta.2/bin/linux/amd64/hyperkube
install -Dm755 hyperkube /usr/bin/hyperkube

curl -O -L https://github.com/containernetworking/cni/releases/download/v0.3.0/cni-v0.3.0.tgz
mkdir --parents /opt/cni/bin
tar -xzf cni-v0.3.0.tgz --directory /opt/cni/bin

curl -sSL https://coreos.com/dist/pubkeys/app-signing-pubkey.gpg | gpg2 --import -
key=$(gpg2 --with-colons --keyid-format LONG -k security@coreos.com | egrep ^pub | cut -d ':' -f5)

curl -O -L https://github.com/coreos/rkt/releases/download/v"${version}"/rkt-v"${version}".tar.gz
curl -O -L https://github.com/coreos/rkt/releases/download/v"${version}"/rkt-v"${version}".tar.gz.asc

gpg2 --trusted-key "${key}" --verify-files *.asc

tar xvzf rkt-v"${version}".tar.gz

for flavor in fly coreos kvm; do
    install -Dm644 rkt-v${version}/stage1-${flavor}.aci /usr/lib/rkt/stage1-images/stage1-${flavor}.aci
done

install -Dm755 rkt-v${version}/rkt /usr/bin/rkt

for f in rkt-v${version}/manpages/*; do
    install -Dm644 "${f}" "/usr/share/man/man1/$(basename $f)"
done

install -Dm644 rkt-v${version}/bash_completion/rkt.bash /usr/share/bash-completion/completions/rkt
install -Dm644 rkt-v${version}/init/systemd/tmpfiles.d/rkt.conf /usr/lib/tmpfiles.d/rkt.conf

for unit in rkt-gc.{timer,service} rkt-metadata.{socket,service}; do
    install -Dm644 rkt-v${version}/init/systemd/$unit /usr/lib/systemd/system/$unit
done

for unit in {socket,service}; do
    install -Dm644 /vagrant/rkt-api.${unit} /usr/lib/systemd/system/rkt-api.${unit}
done

for unit in etcd.service apiserver.service controller-manager.service kubelet.service scheduler.service proxy.service; do
    install -Dm644 /vagrant/${unit} /usr/lib/systemd/system/${unit}
done

groupadd --force --system rkt-admin
groupadd --force --system rkt

./rkt-v"${version}"/scripts/setup-data-dir.sh

systemctl daemon-reload
systemd-tmpfiles --create /usr/lib/tmpfiles.d/rkt.conf

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

cp /vagrant/resolv.conf.conf /etc/rkt/net.d
cp /vagrant/k8s.conf /etc/rkt/net.d
cp /vagrant/bashrc /home/vagrant/.bashrc
cp /vagrant/resolv.conf /etc/kubernetes/resolv.conf
chown vagrant:vagrant ~/.bashrc

openssl genrsa -out /etc/kubernetes/kube-serviceaccount.key 2048

rkt trust --trust-keys-from-https --prefix "quay.io/coreos/etcd"
rkt trust --trust-keys-from-https --prefix "quay.io/coreos/hyperkube"
rkt trust --trust-keys-from-https --prefix "coreos.com/rkt/stage1-fly"
rkt trust --trust-keys-from-https --prefix "coreos.com/rkt/stage1-coreos"

rkt fetch quay.io/coreos/hyperkube:v1.3.0-beta.2_coreos.0
rkt fetch coreos.com/rkt/stage1-fly:${version}
rkt fetch coreos.com/rkt/stage1-coreos:${version}
rkt fetch quay.io/coreos/etcd:v2.3.7

rkt fetch --insecure-options=image docker://gcr.io/google_containers/kubedns-amd64:1.3
rkt fetch --insecure-options=image docker://gcr.io/google_containers/kube-dnsmasq-amd64:1.3
rkt fetch --insecure-options=image docker://gcr.io/google_containers/exechealthz-amd64:1.0

for unit in rkt-api etcd apiserver controller-manager kubelet scheduler proxy; do
    systemctl enable ${unit}
    systemctl start ${unit}
done

wait_for_url "http://127.0.0.1:8080/healthz" "apiserver" 1 30

kubectl create -f /vagrant/skydns-svc.yaml
kubectl create -f /vagrant/skydns-rc.yaml
