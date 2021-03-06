# shellcheck shell=bash
# launching a worker node
#
# all launch_worker__* functions will be called with parameters: $prefix, $masterContainerName, $workerContainerName
#




launch_worker__00_start_it() {
    local prefix=$1
    local masterContainer=$2
    local container=$3

    info "  starting container"
    
    checkResources
        
    # we'll deduce the image name from the master, regardless of any --k8s-version parameter    
    local imageName
    local masterImage
    masterImage=$(lxc query "$LXD_REMOTE/1.0/containers/$masterContainer" | jq -r '.config["volatile.base_image"]')
    local masterImageName
    masterImageName=$(lxc query "$LXD_REMOTE/1.0/images/$masterImage" | jq -r '.aliases[].name' | grep -E '\-master$')
    test -n "$masterImageName"

    imageName=${masterImageName/-master/-worker}
    launchK8SContainer "$container" "$imageName" "$masterContainer"
}


launch_worker__04_create_kubeadm_config() {
    local prefix=$1
    local masterContainer=$2
    local container=$3

    info "  creating kubeadm config file"

    token=$(lxc config get "$LXD_REMOTE$masterContainer" user.kubeadm.token)
    if [ -z "$token" ]; then
        bail "Can't find token in master container's config"
    fi
    
    # better use hostname instead of IP, since we might not have it always the same
    # (of course, until we fix that too :-) )
    # SEEME: I think config files still end up with IP ...
    #masterIP=$(lxdGetIp $masterContainer)
    masterIP="$masterContainer.lxd"

    if [ -z "$masterIP" ]; then
        bail "Is master container ($masterContainer) running? Can't get its IP"    
    fi

    # let's prepare kubeadm config - we need more than command args can support
    # FIXME: MaxPerCode still not taken into account
    cfg=$(mktemp)
    cat >"$cfg" << EOS
apiVersion: kubeadm.k8s.io/v1beta1
discovery:
  bootstrapToken:
    apiServerEndpoint: $masterIP:6443
    token: $token
    unsafeSkipCAVerification: true
kind: JoinConfiguration
# Supported from v1beta2 onward (kubeadm 1.15+)
#nodeRegistration:
#  ignorePreflightErrors:
#  - FileContent--proc-sys-net-bridge-bridge-nf-call-iptables
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
Conntrack:
  MaxPerCore: 0
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false

EOS
       
    lxc file push "$cfg" "$LXD_REMOTE$container/$TMP_KUBEADM_CONFIG"
    rm "$cfg"
}


launch_worker__08_run_kubeadm() {
    local prefix=$1
    local masterContainer=$2
    local container=$3

    info "  running kubeadm"

    local ignore
    ignore=$(kubeadmCommonIgnoredPreflightChecks)

    kubeAdmParams=("--ignore-preflight-errors=$ignore")
    kubeAdmParams+=(--config "$TMP_KUBEADM_CONFIG")
    
    lxcExec "$container" kubeadm join "${kubeAdmParams[@]}"
    lxcExec "$container" rm "$TMP_KUBEADM_CONFIG"
}


launch_worker__10_setup_network() {
    local prefix=$1
    local masterContainer=$2
    local container=$3

    setupCniNetwork "$container" worker
}

launch_worker__12_push_shell_files() {
    local container=$2
    lxdPushShellFiles "$container"
}


launch_worker__20_wait_node() {
    prefix=$1
    masterContainer=$2
    container=$3

    waitNodeReady "$masterContainer" "$container"
}


launch_worker__30_change_auth_mode() {
    prefix=$1
    masterContainer=$2
    container=$3

    if [ "$KUBELET_AUTH_CHANGE" == "1" ]; then
        kubeletChangeAuthMode "$container"
    fi
}


messages_worker_node__10_hostpath() {
    info "You might want to mount a disk with a local path, to be used as 'hostpath' storage in your containers."
    info "   like: lxc config device add $container data disk path=/data source=/home/USER/PROJECT/storage"
    info "   Or, better, use one of the '${BOLD_START}local-storag-class${COLOR_END}', '${BOLD_START}nfs-client-provisioner${COLOR_END}' addons"
}


launchWorker() {
    local prefix=$1
    
    local masterContainer
    masterContainer=$(master_container "$prefix")
    
    lxcCheckContainerIsRunning "$masterContainer"
    
    # let's NOT reuse worker names - I think k8s gets confused if you remove a container then
    # later you add a container with the same name
 
    local lastWorkerId
    lastWorkerId=$(lxc config get "$LXD_REMOTE$masterContainer" user.worker.lastId)

    (( lastWorkerId = "$lastWorkerId" + 1 ))
    lxc config set "$LXD_REMOTE$masterContainer" user.worker.lastId "$lastWorkerId"
    
    local container="$prefix-worker-${lastWorkerId}"
    
    info "Creating a new worker node: $BOLD_START$container$COLOR_END"

    lxdCheckProfileVersion
    
    runFunctions '^launch_worker__' "$prefix" "$masterContainer" "$container"

    info "${EMOTICON_HAPPY}Node '$container' added!"
    echo
    runFunctions '^messages_worker_node__' "$prefix" "$masterContainer" "$container"

    enjoyMsg    
}

