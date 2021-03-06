#!/usr/bin/env bash

# This script is designed to provision a new vm and start kyma with control-plane. It takes an optional positional parameter using --image flag
# Use this flag to specify the custom image for provisining vms. If no flag is provided, the latest custom image is used.

set -o errexit

readonly SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly TEST_INFRA_SOURCES_DIR="$(cd "${SCRIPT_DIR}/../../" && pwd)"
KYMA_PROJECT_DIR=${KYMA_PROJECT_DIR:-"/home/prow/go/src/github.com/kyma-project"}

# shellcheck source=prow/scripts/lib/gcloud.sh
source "${SCRIPT_DIR}/lib/gcloud.sh"
# shellcheck source=prow/scripts/lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

if [[ "${BUILD_TYPE}" == "pr" ]]; then
    log::info "Execute Job Guard"
    export JOB_NAME_PATTERN="(pre-control-plane-components-.*)|(pre-control-plane-tests-.*)"
    "${TEST_INFRA_SOURCES_DIR}/development/jobguard/scripts/run.sh"
fi

cleanup() {
    ARG=$?
    log::info "Removing instance control-plane-integration-test-${RANDOM_ID}"
    gcloud compute instances delete --zone="${ZONE}" "control-plane-integration-test-${RANDOM_ID}" || true ### Workaround: not failing the job regardless of the vm deletion result
    exit $ARG
}

function testCustomImage() {
    CUSTOM_IMAGE="$1"
    IMAGE_EXISTS=$(gcloud compute images list --filter "name:${CUSTOM_IMAGE}" | tail -n +2 | awk '{print $1}')
    if [[ -z "$IMAGE_EXISTS" ]]; then
        log::error "${CUSTOM_IMAGE} is invalid, it is not available in GCP images list, the script will terminate ..." && exit 1
    fi
}

gcloud::authenticate "${GOOGLE_APPLICATION_CREDENTIALS}"

RANDOM_ID=$(openssl rand -hex 4)

LABELS=""
if [[ -z "${PULL_NUMBER}" ]]; then
    LABELS=(--labels "branch=$PULL_BASE_REF,job-name=control-plane-integration")
else
    LABELS=(--labels "pull-number=$PULL_NUMBER,job-name=control-plane-integration")
fi

POSITIONAL=()
while [[ $# -gt 0 ]]
do

    key="$1"

    case ${key} in
        --image)
            IMAGE="$2"
            testCustomImage "${IMAGE}"
            shift
            shift
            ;;
        --*)
            echo "Unknown flag ${1}"
            exit 1
            ;;
        *)    # unknown option
            POSITIONAL+=("$1") # save it in an array for later
            shift # past argument
            ;;
    esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters


if [[ -z "$IMAGE" ]]; then
    log::info "Provisioning vm using the latest default custom image ..."
    
    IMAGE=$(gcloud compute images list --sort-by "~creationTimestamp" \
         --filter "family:custom images AND labels.default:yes" --limit=1 | tail -n +2 | awk '{print $1}')
    
    if [[ -z "$IMAGE" ]]; then
       log::error "There are no default custom images, the script will exit ..." && exit 1
    fi   
 fi

ZONE_LIMIT=${ZONE_LIMIT:-5}
EU_ZONES=$(gcloud compute zones list --filter="name~europe" --limit="${ZONE_LIMIT}" | tail -n +2 | awk '{print $1}')

for ZONE in ${EU_ZONES}; do
    log::info "Attempting to create a new instance named control-plane-integration-test-${RANDOM_ID} in zone ${ZONE} using image ${IMAGE}"
    gcloud compute instances create "control-plane-integration-test-${RANDOM_ID}" \
        --metadata enable-oslogin=TRUE \
        --image "${IMAGE}" \
        --machine-type n1-standard-4 \
        --zone "${ZONE}" \
        --boot-disk-size 30 "${LABELS[@]}" &&\
    log::info "Created control-plane-integration-test-${RANDOM_ID} in zone ${ZONE}" && break
    log::error "Could not create machine in zone ${ZONE}"
done || exit 1

trap cleanup exit INT

log::info "Copying control-plane to the instance"

for i in $(seq 1 5); do
    [[ ${i} -gt 1 ]] && echo 'Retrying in 15 seconds..' && sleep 15;
    gcloud compute scp --quiet --recurse --zone="${ZONE}" /home/prow/go/src/github.com/kyma-project/control-plane "control-plane-integration-test-${RANDOM_ID}":~/control-plane && break;
    [[ ${i} -ge 5 ]] && echo "Failed after $i attempts." && exit 1
done;

log::info "Download stable Kyma CLI"
curl -Lo kyma https://storage.googleapis.com/kyma-cli-stable/kyma-linux
chmod +x kyma

gcloud compute ssh --quiet --zone="${ZONE}" "control-plane-integration-test-${RANDOM_ID}" -- "mkdir \$HOME/bin"

for i in $(seq 1 5); do
    [[ ${i} -gt 1 ]] && echo 'Retrying in 15 seconds..' && sleep 15;
    gcloud compute scp --quiet --zone="${ZONE}" "kyma" "control-plane-integration-test-${RANDOM_ID}":~/bin/kyma && break;
    [[ ${i} -ge 5 ]] && echo "Failed after $i attempts." && exit 1
done;

gcloud compute ssh --quiet --zone="${ZONE}" "control-plane-integration-test-${RANDOM_ID}" -- "sudo cp \$HOME/bin/kyma /usr/local/bin/kyma"

log::info "Triggering the installation"

gcloud compute ssh --quiet --zone="${ZONE}" "control-plane-integration-test-${RANDOM_ID}" -- "yes | ./control-plane/installation/scripts/prow/deploy-and-test.sh"

log::info "Copying test artifacts from VM"

for i in $(seq 1 5); do
    [[ ${i} -gt 1 ]] && echo 'Retrying in 15 seconds..' && sleep 15;
    gcloud compute scp --recurse --zone="${ZONE}" "control-plane-integration-test-${RANDOM_ID}":/var/log/prow_artifacts "${ARTIFACTS}"  && break;
    # TODO change exit code to 1 later
    [[ ${i} -ge 5 ]] && echo "Failed after $i attempts." && exit 0
done;

