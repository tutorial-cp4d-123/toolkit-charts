#!/usr/bin/env bash

API_VERSION="2021-04-06"

volume_name() {
  local worker_id="$1"
  local volume_suffix="$2"

  local worker_name=$(echo "${worker_id}" | sed "s/kube-//g")

  if [[ -n "${volume_suffix}" ]]; then
    echo "pwx-${worker_name}-${volume_suffix}" | sed 's/\(.\{63\}\).*/\1/'
  else
    echo "pwx-${worker_name}" | sed 's/\(.\{63\}\).*/\1/'
  fi
}

get_token() {
  local API_KEY="$1"

  TOKEN=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${API_KEY}" | jq -r '.access_token')

  if [[ -z "${TOKEN}" ]]; then
    echo "Error retrieving auth token" >&2
    exit 1
  fi
}

get_volume_id() {
  local REGION="$1"
  local NAME="$2"

  local URL="https://${REGION}.iaas.cloud.ibm.com/v1/volumes?version=${API_VERSION}&generation=2&name=${NAME}"

  echo "Getting volume id: ${URL}"

  VOLUME_ID=$(curl -s -X GET "${URL}" \
    -H "Authorization: Bearer ${TOKEN}" | \
    jq -r --arg NAME "${NAME}" '.volumes?[] | select(.name == $NAME) | .id // empty')
}

create_volume() {
  local REGION="$1"
  local NAME="$2"
  local DATA="$3"

  local URL="https://${REGION}.iaas.cloud.ibm.com/v1/volumes?version=${API_VERSION}&generation=2"

  echo "Creating volume using url: ${URL}"
  echo "  Data: ${DATA}"

  curl -s -X POST "${URL}" \
    -H "Authorization: Bearer $TOKEN" \
    -d "${DATA}"

  get_volume_id "${REGION}" "${NAME}"
}

wait_for_volume() {
  local REGION="$1"
  local VOLUME_ID="$2"

  echo "Waiting for volume to be ready: ${VOLUME_ID}"

  count=0
  STATUS="pending"
  while [[ "${STATUS}" == "pending" ]] || [[ $count -gt 20 ]]; do
    local VOLUME=$(curl -s -X GET "https://${REGION}.iaas.cloud.ibm.com/v1/volumes/${VOLUME_ID}?version=${API_VERSION}&generation=2" \
      -H "Authorization: Bearer ${TOKEN}" | jq -c '.')

    STATUS=$(echo "${VOLUME}" | jq -r '.status')

    if [[ "${STATUS}" == "pending" ]]; then
      echo "Volume is still pending. Sleeping for 30 seconds..."
      count=$((count + 1))
      sleep 30
    fi
  done

  if [[ $count -gt 20 ]]; then
    echo "Timed out waiting for volume: ${VOLUME_ID}" >&2
    exit 1
  fi

  echo "Volume is available: ${VOLUME_ID}"
}
