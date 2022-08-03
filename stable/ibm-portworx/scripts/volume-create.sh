#!/usr/bin/env bash

SCRIPT_DIR=$(cd $(dirname "$0"); pwd -P)

NODE_NAME="$1"
RESOURCE_GROUP_ID="$2"

if [[ -z "${NODE_NAME}" ]] || [[ -z "${RESOURCE_GROUP_ID}" ]]; then
  echo "usage: create-volume.sh NODE_NAME RESOURCE_GROUP_ID" >&2
  exit 1
fi

if [[ -z "${IBMCLOUD_API_KEY}" ]]; then
  echo "IBMCLOUD_API_KEY must be provided as an environment variable" >&2
  exit 1
fi

if ! command -v curl 1> /dev/null 2> /dev/null; then
  echo "curl command not found" >&2
  exit 1
fi

if ! command -v jq 1> /dev/null 2> /dev/null; then
  echo "jq command not found" >&2
  exit 1
fi

if ! command -v kubectl 1> /dev/null 2> /dev/null; then
  echo "kubectl command not found" >&2
  exit 1
fi

source "${SCRIPT_DIR}/support-functions.sh"

## Lookup zone and resource group from the cluster
NODE_JSON=$(kubectl get node "${NODE_NAME}" -o json)

REGION=$(echo "${NODE_JSON}" | jq -r '.metadata.labels["ibm-cloud.kubernetes.io/region"]')
ZONE=$(echo "${NODE_JSON}" | jq -r '.metadata.labels["ibm-cloud.kubernetes.io/zone"]')
WORKER_ID=$(echo "${NODE_JSON}" | jq -r '.metadata.labels["ibm-cloud.kubernetes.io/worker-id"]')

CLUSTER_ID=$(echo "${NODE_JSON}" | jq -r '.spec.providerID' | sed -E 's~.*/([^/]+)/[^/]+~\1~g')

CLUSTER_ID

echo "Node values: region=${REGION}, zone=${ZONE}, workerId=${WORKER_ID}"

NAME=$(volume_name "${WORKER_ID}" "${VOLUME_SUFFIX}")

if [[ -z "${PROFILE}" ]]; then
  PROFILE="custom"
  echo "PROFILE environment variable not provided. Defaulting to '${PROFILE}'"
fi
if [[ -z "${IOPS}" ]] && [[ "${PROFILE}" == "custom" ]]; then
  IOPS="100"
  echo "IOPS environment variable not provided. Defaulting to '${IOPS}'"
fi
if [[ -n "${IOPS}" ]] && [[ "${PROFILE}" != "custom" ]]; then
  IOPS=""
fi
if [[ -z "${CAPACITY}" ]]; then
  CAPACITY="50"
  echo "CAPACITY environment variable not provided. Defaulting to '${CAPACITY}'"
fi
if [[ -z "${ENCRYPTION_KEY}" ]]; then
  echo "ENCRYPTION_KEY environment variable not provided. The volume won't be encrypted with KMS."
fi

TAGS=$(jq -n \
  --arg CLUSTER_TAG "clusterid:${CLUSTER_ID}" \
  --arg WORKER_TAG "workerid:${WORKER_ID}" \
  '[$CLUSTER_TAG, $WORKER_TAG, "source:portworx"]')

jq -n \
  --arg NAME "${NAME}" \
  --arg ZONE "${ZONE}" \
  --arg RESOURCE_GROUP_ID "${RESOURCE_GROUP_ID}" \
  --argjson CAPACITY "${CAPACITY}" \
  --arg PROFILE "${PROFILE}" \
  --argjson TAGS "${TAGS}" \
  '{"name": $NAME, "capacity": $CAPACITY, "zone": {"name": $ZONE}, "profile": {"name": $PROFILE}, "resource_group": {"id": $RESOURCE_GROUP_ID}, "user_tags": $TAGS}' \
  > /tmp/volume-request.json

if [[ -n "${IOPS}" ]]; then
  cat /tmp/volume-request.json | jq --argjson IOPS "${IOPS}" \
    '. += {"iops": $IOPS}' > /tmp/volume-request.json.bak && \
    cp /tmp/volume-request.json.bak /tmp/volume-request.json && \
    rm /tmp/volume-request.json.bak
fi

if [[ -n "${ENCRYPTION_KEY}" ]]; then
  cat /tmp/volume-request.json | jq --arg ENCRYPTION_KEY "${ENCRYPTION_KEY}" \
    '.encryption_key = {"crn": $ENCRYPTION_KEY}' > /tmp/volume-request.json.bak && \
    cp /tmp/volume-request.json.bak /tmp/volume-request.json && \
    rm /tmp/volume-request.json.bak
fi

echo "Getting auth token"

get_token "${IBMCLOUD_API_KEY}" || exit 1

echo "Looking up existing volume: ${NAME}"

## Check if volume already exists
get_volume_id "${REGION}" "${NAME}"

if [[ -z "${VOLUME_ID}" ]]; then
  echo "Volume not found: ${NAME}"

  echo "Creating volume: "
  jq '.' /tmp/volume-request.json

  create_volume "${REGION}" "${NAME}" "$(jq -c '.' /tmp/volume-request.json)"
else
  echo "Existing volume found: ${NAME}"
fi

echo "Waiting for volume"

wait_for_volume "${REGION}" "${VOLUME_ID}"
