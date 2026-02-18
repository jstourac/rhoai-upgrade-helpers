#!/usr/bin/env bash

set -euo pipefail

# This script is used to patch the GuardrailsOrchestrator deployment when upgrading from RHOAI 2.5 to 3.3

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    echo -e "Usage: $0 ${BOLD}-n|--namespace <namespace>${NC} [${BOLD}--check${NC}|${BOLD}--fix${NC}] [${BOLD}--dry-run${NC}]"
    echo ""
    echo "  -n, --namespace <ns>   Target namespace (required)"
    echo "  --check                Only check: list CRs and deployment status, no patching"
    echo "  --fix                  Apply readinessProbe patch to deployments (default)"
    echo "  --dry-run              With --fix: show what would be patched, do not apply"
    exit 1
}

NAMESPACE=""
MODE="fix"
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace)
            if [ -n "${2:-}" ]; then
                NAMESPACE="$2"
                shift 2
            else
                echo -e "${RED}ERROR: --namespace requires a value${NC}"
                usage
            fi
            ;;
        --check)
            MODE="check"
            shift
            ;;
        --fix)
            MODE="fix"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            # Backward compat: single positional arg = namespace
            if [ -z "${NAMESPACE}" ]; then
                NAMESPACE="$1"
                shift
            else
                echo -e "${RED}ERROR: Unknown argument: $1${NC}"
                usage
            fi
            ;;
    esac
done

if [ -z "${NAMESPACE}" ]; then
    echo -e "${RED}ERROR: Namespace is required${NC}"
    usage
fi

FAILED_DEPLOYMENTS=()
PATCHED_COUNT=0

echo ""
# Check if the user is logged in
if ! oc whoami &>/dev/null; then
    echo -e "${RED}ERROR: You are not logged in to the cluster${NC}"
    exit 1
fi

# Check if the namespace exists
if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
    echo -e "${RED}ERROR: Namespace ${CYAN}${NAMESPACE}${RED} does not exist${NC}"
    exit 1
fi

# Check if GuardrailsOrchestrator CRs exist in namespace
echo -e "Checking for GuardrailsOrchestrator CRs in namespace ${CYAN}${NAMESPACE}${NC}"
GORCH_CR_NAMES=$(oc get guardrailsorchestrator -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
if [ -z "${GORCH_CR_NAMES}" ]; then
    echo -e "${RED}No GuardrailsOrchestrator CRs found in namespace ${CYAN}${NAMESPACE}${NC}"
    exit 1
fi

# Convert space-separated names to array
read -ra GORCH_CR_ARRAY <<< "${GORCH_CR_NAMES}"
echo ""
echo -e "Found ${GREEN}${#GORCH_CR_ARRAY[@]}${NC} GuardrailsOrchestrator CR(s) in namespace ${CYAN}${NAMESPACE}${NC}: ${BLUE}${GORCH_CR_NAMES}${NC}"

# Check if deployment has the expected readinessProbe (port 8034, path /health)
needs_patch() {
    local deployment_name="$1"
    local probe_path
    probe_path=$(oc get deployment -n "${NAMESPACE}" "${deployment_name}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="guardrails-orchestrator")].readinessProbe.httpGet.path}' 2>/dev/null || true)
    local probe_port
    probe_port=$(oc get deployment -n "${NAMESPACE}" "${deployment_name}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="guardrails-orchestrator")].readinessProbe.httpGet.port}' 2>/dev/null || true)
    [ "${probe_path}" != "/health" ] || [ "${probe_port}" != "8034" ]
}

# Function to check a single deployment (--check mode)
check_deployment() {
    local deployment_name="$1"
    echo ""
    if ! oc get deployment -n "${NAMESPACE}" "${deployment_name}" &>/dev/null; then
        echo -e "  ${RED}MISSING${NC}  deployment ${CYAN}${deployment_name}${NC}"
        return 1
    fi
    if needs_patch "${deployment_name}"; then
        echo -e "  ${YELLOW}NEEDS PATCH${NC}  deployment ${CYAN}${deployment_name}${NC}"
        return 0
    else
        echo -e "  ${GREEN}OK${NC}  deployment ${CYAN}${deployment_name}${NC} (readinessProbe already set)"
        return 0
    fi
}

# Function to patch a single deployment
patch_deployment() {
    local deployment_name="$1"

    echo ""
    # Verify deployment exists
    if ! oc get deployment -n "${NAMESPACE}" "${deployment_name}" &>/dev/null; then
        echo -e "${YELLOW}WARNING: Deployment ${CYAN}${deployment_name}${YELLOW} not found in namespace ${CYAN}${NAMESPACE}${YELLOW}, skipping...${NC}"
        return 1
    fi

    if [ "${DRY_RUN}" = true ]; then
        if needs_patch "${deployment_name}"; then
            echo -e "${CYAN}[DRY-RUN]${NC} Would patch deployment ${CYAN}${deployment_name}${NC} in namespace ${CYAN}${NAMESPACE}${NC} (add readinessProbe: port 8034, path /health)"
            ((PATCHED_COUNT++))
        else
            echo -e "${CYAN}[DRY-RUN]${NC} Deployment ${CYAN}${deployment_name}${NC} already has expected readinessProbe, skip"
        fi
        return 0
    fi

    # Patch the deployment to add the readinessProbe (port 8034, path /health, scheme HTTP)
    echo -e "Patching deployment ${CYAN}${deployment_name}${NC} in namespace ${CYAN}${NAMESPACE}${NC}"
    if ! oc patch deployment "${deployment_name}" -n "${NAMESPACE}" --type='strategic' -p='
spec:
  template:
    spec:
      containers:
      - name: guardrails-orchestrator
        readinessProbe:
          httpGet:
            path: /health
            port: 8034
            scheme: HTTP
          initialDelaySeconds: 10
          timeoutSeconds: 10
          periodSeconds: 20
          successThreshold: 1
          failureThreshold: 3
'; then
        echo -e "${RED}ERROR: Failed to patch deployment ${CYAN}${deployment_name}${NC}"
        return 1
    fi

    # Wait for rollout to complete
    echo ""
    echo -e "Waiting for rollout to complete..."
    if ! oc rollout status deployment "${deployment_name}" -n "${NAMESPACE}" --timeout=120s; then
        echo -e "${RED}ERROR: Deployment rollout failed for ${CYAN}${deployment_name}${NC}"
        return 1
    fi

    echo ""
    echo -e "${GREEN}Successfully patched deployment ${CYAN}${deployment_name}${NC}"
    return 0
}

if [ "${MODE}" = "check" ]; then
    echo ""
    echo -e "${BOLD}Check mode: deployment status in namespace ${CYAN}${NAMESPACE}${NC}"
    for CR_NAME in "${GORCH_CR_ARRAY[@]}"; do
        check_deployment "${CR_NAME}" || true
    done
    echo ""
    echo -e "${GREEN}Check complete.${NC}"
    exit 0
fi

# Fix mode: loop through all GuardrailsOrchestrator CRs
if [ "${DRY_RUN}" = true ]; then
    echo -e "${BOLD}[DRY-RUN]${NC} Would patch the following deployments in namespace ${CYAN}${NAMESPACE}${NC}:"
fi
for CR_NAME in "${GORCH_CR_ARRAY[@]}"; do
    if patch_deployment "${CR_NAME}"; then
        if [ "${DRY_RUN}" != true ]; then
            ((PATCHED_COUNT++))
        fi
    else
        FAILED_DEPLOYMENTS+=("${CR_NAME}")
    fi
done

echo ""
echo -e "${BOLD}==========================================${NC}"
echo -e "${BOLD}GuardrailsOrchestrator Deployment Patch Summary${NC}"
echo -e "${BOLD}==========================================${NC}"
echo -e "Total GuardrailsOrchestrator CRs found: ${BLUE}${#GORCH_CR_ARRAY[@]}${NC}"
echo -e "Successfully patched: ${GREEN}${PATCHED_COUNT}${NC}"
echo -e "Failed: ${RED}${#FAILED_DEPLOYMENTS[@]}${NC}"
if [ "${DRY_RUN}" = true ]; then
    echo -e "${CYAN}(DRY-RUN: no changes were made)${NC}"
fi

if [ ${#FAILED_DEPLOYMENTS[@]} -gt 0 ]; then
    echo -e "${RED}Failed deployments: ${CYAN}${FAILED_DEPLOYMENTS[*]}${NC}"
    exit 1
fi

echo -e "${GREEN}All guardrails deployments patched successfully!${NC}"
