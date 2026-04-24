# shellcheck shell=bash
# Spoke provisioning and deprovisioning

deprovision_spoke() {
    local name="${1:-$SPOKE_NAME}" ns="${2:-$SPOKE_NAMESPACE}"
    log_info "Deprovisioning spoke $name"

    # Delete ClusterDeployment (cascades to BMH, ACI, Agent)
    hub_oc delete clusterdeployment -n "$ns" "$name" --wait=false 2>/dev/null || true
    wait_for 120 5 "ClusterDeployment deleted" \
        bash -c "! hub_oc get clusterdeployment -n '$ns' '$name' --no-headers 2>/dev/null"

    # Remove ClusterInstance finalizer and delete
    hub_oc patch clusterinstance -n "$ns" "$name" \
        --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]' 2>/dev/null || true
    hub_oc delete clusterinstance -n "$ns" "$name" --wait=false 2>/dev/null || true

    # Delete ManagedCluster
    hub_oc delete managedcluster "$name" --wait=false 2>/dev/null || true

    # Clean up stale resources that block namespace deletion
    for resource in bmh agent agentclusterinstall infraenv; do
        hub_oc delete "$resource" -n "$ns" --all --ignore-not-found 2>/dev/null || true
    done

    # Wait for namespace deletion (may be kept alive by ArgoCD, that's OK)
    log_info "Waiting for namespace $ns to terminate (up to 10 min)"
    wait_for 600 10 "namespace $ns deleted" \
        bash -c "! hub_oc get ns '$ns' --no-headers 2>/dev/null" || true

    log_info "Deprovision of $name complete"
}

provision_spoke() {
    local name="${1:-$SPOKE_NAME}" ns="${2:-$SPOKE_NAMESPACE}"
    log_info "Provisioning spoke $name"

    # Create namespace if needed
    hub_oc get ns "$ns" &>/dev/null || hub_oc create ns "$ns"

    # Ensure pull-secret exists
    if ! hub_oc get secret pull-secret -n "$ns" &>/dev/null; then
        hub_oc get secret pull-secret -n "$SEED_NAMESPACE" -o json 2>/dev/null \
            | jq ".metadata = {\"name\":\"pull-secret\",\"namespace\":\"$ns\"}" \
            | hub_oc apply -f -
    fi

    # Ensure BMH secret exists
    if ! hub_oc get secret "${name}-bmh-secret" -n "$ns" &>/dev/null; then
        hub_oc create secret generic "${name}-bmh-secret" -n "$ns" \
            --from-literal=username="$BMC_USER" --from-literal=password="$BMC_PASS"
    fi

    # Ensure extra-manifests-cm exists (container storage partition)
    if ! hub_oc get configmap extra-manifests-cm -n "$ns" &>/dev/null; then
        if [[ -n "${EXTRA_MANIFESTS_SOURCE_NS:-}" ]]; then
            hub_oc get configmap extra-manifests-cm -n "$EXTRA_MANIFESTS_SOURCE_NS" -o json \
                | jq ".metadata = {\"name\":\"extra-manifests-cm\",\"namespace\":\"$ns\"}" \
                | hub_oc apply -f -
        else
            create_container_storage_configmap "$ns"
        fi
    fi

    # Apply ClusterInstance
    hub_oc apply -f "$CLUSTER_INSTANCE_PATH"
    log_info "ClusterInstance applied, waiting for provisioning"

    wait_for_provisioning "$name" "$ns"
}

create_container_storage_configmap() {
    local ns="$1"
    local disk="${DISK_DEVICE:-/dev/disk/by-path/pci-0000:05:00.0-nvme-1}"
    log_info "Creating container storage partition ConfigMap in $ns (disk: $disk)"

    cat <<OUTER | hub_oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: extra-manifests-cm
  namespace: $ns
data:
  98-var-lib-containers-partitioned.yaml: |
    apiVersion: machineconfiguration.openshift.io/v1
    kind: MachineConfig
    metadata:
      labels:
        machineconfiguration.openshift.io/role: master
      name: 98-var-lib-containers-partitioned
    spec:
      config:
        ignition:
          version: 3.2.0
        storage:
          disks:
            - device: $disk
              partitions:
                - label: varlibcontainers
                  startMiB: 250000
                  sizeMiB: 0
          filesystems:
            - device: /dev/disk/by-partlabel/varlibcontainers
              format: xfs
              mountOptions:
                - defaults
                - prjquota
              path: /var/lib/containers
              wipeFilesystem: true
        systemd:
          units:
            - contents: |-
                [Unit]
                Before=local-fs.target
                Requires=systemd-fsck@dev-disk-by\x2dpartlabel-varlibcontainers.service
                After=systemd-fsck@dev-disk-by\x2dpartlabel-varlibcontainers.service

                [Mount]
                Where=/var/lib/containers
                What=/dev/disk/by-partlabel/varlibcontainers
                Type=xfs
                Options=defaults,prjquota

                [Install]
                RequiredBy=local-fs.target
              enabled: true
              name: var-lib-containers.mount
OUTER
}

wait_for_provisioning() {
    local name="$1" ns="$2" timeout="${3:-5400}"
    log_info "Monitoring provisioning of $name (timeout: ${timeout}s)"

    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        local bmh_state aci_status agent_status
        bmh_state=$(hub_oc get bmh -n "$ns" --no-headers 2>/dev/null | awk '{print $2}')
        agent_status=$(hub_oc get agent -n "$ns" --no-headers 2>/dev/null | awk '{print $4, $5}')
        aci_status=$(hub_oc get agentclusterinstall -n "$ns" \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Completed")].reason}' 2>/dev/null)

        log_info "BMH: ${bmh_state:-pending} | Agent: ${agent_status:-none} | ACI: ${aci_status:-pending}"

        if [[ "$aci_status" == "InstallationCompleted" ]]; then
            log_info "Provisioning of $name completed"
            return 0
        fi
        if [[ "$aci_status" == "InstallationFailed" ]]; then
            log_error "Provisioning of $name FAILED"
            return 1
        fi
        sleep 60
    done

    log_error "Provisioning of $name timed out after ${timeout}s"
    return 1
}
