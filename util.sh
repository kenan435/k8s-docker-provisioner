#!/bin/bash

# exit on any error
set -e

readonly ROOT=$(dirname "${BASH_SOURCE}")
source "${ROOT}/${KUBE_CONFIG_FILE:-"config-default.sh"}"
source "${ROOT}/openrc-default.sh"

DEFAULT_KUBECONFIG=~/.kube/config


# Verify prereqs on host machine
function verify-prereqs() {
 # Check the OpenStack command-line clients
 for client in heat nova kubectl;
 do
  if which $client >/dev/null 2>&1; then
    echo "$client client installed"
  else
    echo "$client client does not exist"
    echo "Please install $client client, and retry."
    exit 1
  fi
 done
}

# Instantiate a kubernetes cluster
#
# Assumed vars:
#   KUBERNETES_PROVIDER
function kube-up() {
    echo "kube-up for provider $KUBERNETES_PROVIDER"
    create-stack
}

# Periodically checks if cluster is created
#
# Assumed vars:
#   STACK_CREATE_TIMEOUT
#   STACK_NAME
function validate-cluster() {
  local sp="/-\|"
  SECONDS=0
  while (( ${SECONDS} < ${STACK_CREATE_TIMEOUT}*60 )) ;do
     local status=$(heat stack-show "${STACK_NAME}" | awk '$2=="stack_status" {print $4}')
     if [[ $status ]]; then
        if [ $status = "CREATE_COMPLETE" ]; then
          echo "Cluster status ${status}"
          configure-kubectl
          break
        elif [ $status = "CREATE_FAILED" ]; then
          echo "Cluster not created. Please check stack logs to find the problem"
          break
        fi
     else
       echo "Cluster not created. Please verify if process started correctly"
       break
     fi
     printf "\b${sp:SECONDS%${#sp}:1}"
     sleep 1
  done
}

# Create stack
function create-stack() {
  echo "[INFO] Execute commands to create Kubernetes cluster"

  add-keypair
  run-heat-script
}

# Create a new key pair for use with servers.
#
# Assumed vars:
#   KUBERNETES_KEYPAIR_NAME
#   CLIENT_PUBLIC_KEY_PATH
function add-keypair() {
  local status=$(nova keypair-show ${KUBERNETES_KEYPAIR_NAME})
  if [[ ! $status ]]; then
    nova keypair-add ${KUBERNETES_KEYPAIR_NAME} --pub-key ${CLIENT_PUBLIC_KEY_PATH}
    echo "[INFO] Key pair created"
  else
    echo "[INFO] Key pair already exists"
  fi
}

# Create a new kubernetes stack.
#
# Assumed vars:
#   STACK_NAME
#   KUBERNETES_KEYPAIR_NAME
#   DNS_SERVER
#   OPENSTACK_IMAGE_NAME
#   EXTERNAL_NETWORK
#   IMAGE_ID
#   MASTER_FLAVOR
#   MINION_FLAVOR
#   NUMBER_OF_MINIONS
#   MAX_NUMBER_OF_MINIONS
function run-heat-script() {

  local stack_status=$(heat stack-show ${STACK_NAME})

  if [[ ! $stack_status ]]; then
    echo "[INFO] Create stack ${STACK_NAME}"
    heat --api-timeout 60 stack-create \
      -P external_network=${EXTERNAL_NETWORK} \
      -P ssh_key_name=${KUBERNETES_KEYPAIR_NAME} \
      -P server_image=${IMAGE_ID} \
      -P master_flavor=${MASTER_FLAVOR} \
      -P minion_flavor=${MINION_FLAVOR} \
      -P number_of_minions=${NUMBER_OF_MINIONS} \
      -P max_number_of_minions=${MAX_NUMBER_OF_MINIONS} \
      -P dns_nameserver=${DNS_SERVER} \
      --template-file kubecluster.yaml \
      ${STACK_NAME}
  else
    echo "[INFO] Stack ${STACK_NAME} already exists"
    heat stack-show ${STACK_NAME}
  fi
}

# Configure kubectl.
#
# Assumed vars:
#   STACK_NAME
function configure-kubectl() {

  export KUBE_MASTER_IP=$(nova show "${STACK_NAME}"-master | awk '$3=="network" {print $6}')
  export CONTEXT="heat-docker-kubernetes"
  
  export KUBECONFIG=${KUBECONFIG:-$DEFAULT_KUBECONFIG}


  if [[ ! -e "${KUBECONFIG}" ]]; then
    mkdir -p $(dirname "${KUBECONFIG}")
    touch "${KUBECONFIG}"
  fi
  
  local cluster_args=(
      "--server=${KUBE_SERVER:-http://${KUBE_MASTER_IP}:8080}"
  )

  kubectl config set-cluster "${CONTEXT}" "${cluster_args[@]}"
  kubectl config set-context "${CONTEXT}" --cluster="${CONTEXT}" --user="${CONTEXT}"
  kubectl config use-context "${CONTEXT}"  --cluster="${CONTEXT}"

  echo "Wrote config for ${CONTEXT} to ${KUBECONFIG}"
}
