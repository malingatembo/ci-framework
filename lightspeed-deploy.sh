#!/bin/bash
# lightspeed-deploy.sh - OpenStack Lightspeed CI Framework Deployment
# Automated deployment with workaround for SSH key bug
# Bug reference: https://github.com/openstack-k8s-operators/ci-framework/issues/TBD

set -e  # Exit on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOG_FILE="$HOME/lightspeed-deploy.log"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

log "Starting CI Framework deployment for Lightspeed..."
log "Log file: $LOG_FILE"

# Step 1: Clean environment
log "Step 1: Cleaning environment with deepscrub..."
cd "$SCRIPT_DIR" && ansible-playbook -i custom/inventory.yml reproducer-clean.yml --tags deepscrub >> "$LOG_FILE" 2>&1
if [ $? -eq 0 ]; then
    log "✅ Environment cleaned successfully"
else
    error "Deepscrub failed"
    exit 1
fi

# Step 2: Prepare pull secret
log "Step 2: Preparing pull secret..."
mkdir -p ~/ci-framework-data
if [ -f ~/pull-secret.txt ]; then
    cp ~/pull-secret.txt ~/ci-framework-data/pull-secret.txt
    log "✅ Pull secret copied"
else
    error "Pull secret not found at ~/pull-secret.txt"
    exit 1
fi

# Step 3: Run deployment (expected to fail at 99%)
log "Step 3: Running CI Framework deployment (this takes ~40 minutes)..."
log "Deployment started at $(date)"

cd "$SCRIPT_DIR" && ansible-playbook -i custom/inventory.yml \
  -e @scenarios/reproducers/networking-definition.yml \
  -e @custom/crc-with-hook.yml \
  reproducer.yml >> "$LOG_FILE" 2>&1 || DEPLOY_RESULT=$?

log "Deployment completed at $(date) with exit code: ${DEPLOY_RESULT:-0}"

# Step 4: Check if it's the known SSH key bug
if grep -q "chown failed: failed to look up user cloud-user" ~/ansible.log; then
    warn "Known SSH key bug detected (CI Framework issue)"
    log "Step 4: Applying workaround..."

    # Wait a moment for VMs to be fully accessible
    sleep 5

    # Apply workaround
    if ssh controller-0.utility "sudo chown zuul:zuul /home/zuul/.ssh/id_cifw" >> "$LOG_FILE" 2>&1; then
        log "✅ SSH key ownership fixed"
    else
        error "Failed to fix SSH key ownership"
        exit 1
    fi

    # Step 5: Execute post_deploy hooks manually
    log "Step 5: Executing post_deploy hooks..."
    if ansible-playbook ~/team-deployments/hooks/test-webhook.yml >> "$LOG_FILE" 2>&1; then
        log "✅ post_deploy hooks executed successfully"
    else
        error "Hook execution failed"
        exit 1
    fi

    # Step 6: Verify hook execution
    log "Step 6: Verifying deployment..."
    if [ -f ~/team-deployments/logs/webhook-executed.txt ]; then
        log "✅ Hook marker file found"
        log "Hook execution details:"
        cat ~/team-deployments/logs/webhook-executed.txt | tee -a "$LOG_FILE"
    else
        warn "Hook marker file not found"
    fi

    # Verify VMs are running
    log "Verifying VMs..."
    VM_COUNT=$(virsh -c qemu:///system list --state-running | grep cifmw | wc -l)
    if [ "$VM_COUNT" -eq 3 ]; then
        log "✅ All 3 VMs running (CRC, compute-0, controller-0)"
    else
        warn "Expected 3 VMs, found $VM_COUNT"
    fi

    # Verify OpenShift health
    log "Verifying OpenShift health..."
    if ssh crc-0.utility "curl -k -s https://192.168.126.11:6443/healthz" | grep -q "ok"; then
        log "✅ OpenShift cluster is healthy"
    else
        warn "OpenShift health check failed"
    fi

    log ""
    log "=========================================="
    log "✅ DEPLOYMENT COMPLETE WITH WORKAROUND"
    log "=========================================="
    log "OpenStack + Lightspeed environment ready"
    log "Total deployment time: Check timestamps above"
    log "Full log: $LOG_FILE"
    log ""
    exit 0

elif [ "${DEPLOY_RESULT:-0}" -ne 0 ]; then
    error "Deployment failed with unknown error"
    error "Check logs:"
    error "  - $LOG_FILE"
    error "  - ~/ansible.log"
    tail -50 ~/ansible.log | tee -a "$LOG_FILE"
    exit 1
else
    log "=========================================="
    log "✅ DEPLOYMENT SUCCESSFUL (100%)"
    log "=========================================="
    log "No workaround needed - bug may be fixed!"
    log "Full log: $LOG_FILE"
    exit 0
fi
