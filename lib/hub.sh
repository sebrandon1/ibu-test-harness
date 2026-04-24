#!/usr/bin/env bash
# Hub cluster operations

argocd_refresh() {
    local app="$1"
    log_info "Triggering ArgoCD refresh for $app"
    hub_oc annotate application.argoproj.io -n openshift-gitops "$app" \
        argocd.argoproj.io/refresh=normal --overwrite
}

argocd_set_branch() {
    local app="$1" branch="$2"
    log_info "Setting ArgoCD app $app to branch $branch"
    hub_oc patch application.argoproj.io "$app" -n openshift-gitops \
        --type=merge -p "{\"spec\":{\"source\":{\"targetRevision\":\"$branch\"}}}"
}

argocd_enable_autosync() {
    local app="$1"
    log_info "Enabling auto-sync on $app"
    hub_oc patch application.argoproj.io "$app" -n openshift-gitops \
        --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
}

wait_for_policy_compliant() {
    local ns="$1" policy="$2" timeout="${3:-300}"
    log_info "Waiting for policy $policy in $ns to become Compliant"
    wait_for "$timeout" 15 "policy $policy Compliant" \
        bash -c "hub_oc get policy -n '$ns' '$policy' -o jsonpath='{.status.compliant}' 2>/dev/null | grep -q Compliant"
}
