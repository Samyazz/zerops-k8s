FROM ubuntu:24.04

ARG KUBERNETES_VERSION=1.36.2
ARG KUBERNETES_MINOR=1.36
ARG KUBERNETES_PACKAGE_VERSION=1.36.2-2.1
ARG CRI_TOOLS_PACKAGE_VERSION=1.36.0-1.1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        conntrack \
        cryptsetup \
        curl \
        dmsetup \
        ebtables \
        ethtool \
        gnupg \
        iproute2 \
        iptables \
        iputils-ping \
        jq \
        kmod \
        nfs-common \
        open-iscsi \
        openssl \
        socat \
        systemd \
        systemd-sysv \
        unattended-upgrades \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/deb/Release.key" \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        "kubeadm=${KUBERNETES_PACKAGE_VERSION}" \
        "kubectl=${KUBERNETES_PACKAGE_VERSION}" \
        "kubelet=${KUBERNETES_PACKAGE_VERSION}" \
        "cri-tools=${CRI_TOOLS_PACKAGE_VERSION}" \
        containerd \
    && apt-mark hold kubeadm kubectl kubelet cri-tools containerd \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl enable containerd kubelet \
    && systemctl enable iscsid \
    && mkdir -p /etc/containerd \
    && containerd config default > /etc/containerd/config.toml \
    && sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml \
    && systemctl mask \
        systemd-remount-fs.service \
        systemd-networkd-wait-online.service \
        systemd-pcrphase.service \
        systemd-pcrphase-sysinit.service \
        getty.target \
        console-getty.service \
    && rm -f /etc/machine-id

RUN printf '%s\n' \
        'APT::Periodic::Update-Package-Lists "1";' \
        'APT::Periodic::Unattended-Upgrade "1";' \
        'APT::Periodic::AutocleanInterval "7";' \
        'Unattended-Upgrade::Automatic-Reboot "false";' \
        > /etc/apt/apt.conf.d/20auto-upgrades \
    && printf '%s\n' \
        'Unattended-Upgrade::Origins-Pattern {' \
        '  "origin=Ubuntu,codename=${distro_codename}-security,label=Ubuntu";' \
        '};' \
        'Unattended-Upgrade::Package-Blacklist {' \
        '  "kubeadm";' \
        '  "kubectl";' \
        '  "kubelet";' \
        '  "cri-tools";' \
        '  "containerd";' \
        '};' \
        > /etc/apt/apt.conf.d/52zerops-k8s-security

COPY node/prepare-node.sh /usr/local/sbin/prepare-zerops-k8s-node
COPY node/entrypoint.sh /usr/local/sbin/zerops-k8s-entrypoint
RUN chmod 0755 /usr/local/sbin/prepare-zerops-k8s-node \
    /usr/local/sbin/zerops-k8s-entrypoint \
    && printf '%s\n' \
        '[Unit]' \
        'Description=Prepare Zerops Kubernetes node' \
        'Before=containerd.service kubelet.service' \
        '[Service]' \
        'Type=oneshot' \
        'ExecStart=/usr/local/sbin/prepare-zerops-k8s-node' \
        'RemainAfterExit=yes' \
        '[Install]' \
        'WantedBy=multi-user.target' \
        > /etc/systemd/system/zerops-k8s-prepare.service \
    && systemctl enable zerops-k8s-prepare.service

STOPSIGNAL SIGRTMIN+3
ENTRYPOINT ["/usr/local/sbin/zerops-k8s-entrypoint"]
