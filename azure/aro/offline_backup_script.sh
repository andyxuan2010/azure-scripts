#!/bin/bash

export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
export OCP_PASSWORD=XXXXXXXXXXXXXXXXXXXXXXXXXX
export OCP_USERNAME=kubeadmin
export OCP_URL=https://api.example.com:6443
export SERVER_ARGUMENTS="--server=${OCP_URL}"
export LOGIN_ARGUMENTS="--username=${OCP_USERNAME} --password=${OCP_PASSWORD}"

export PROJECT_CPD_INST_OPERANDS="cpd-operands"
export PROJECT_CPD_INST_OPERATORS="cpd-operators"
export PROJECT_OADP_OPERATOR="oadp-operator"

export SMTP=smtp.example.com
export MAIL_ID_LIST="user@example.com"
export CURRENT_DATE=$(date +"%Y%m%d%H%M")
export BACKUP_DIR_PATH=/tmp/oadp
export LOG_FILE="/tmp/oadp/backup_log_$(date +%Y%m%d%H%M%S).txt"
export CPD_CLI_DIR=/tmp/cp4d-install/cpd-cli-linux-EE-13.1.0-79
export OC_PATH=/tmp/cp4d-install

cluster_login() {
    log_message "Trying to login to OCP." "INFO"
    oc_login=`${OC_PATH}/oc login ${OCP_URL} ${LOGIN_ARGUMENTS}`
    local failed_login="Login failed"
    if [[ $oc_login =~ $failed_login ]]; then
        log_message "$oc_login" "ERROR"
        log_message "Failed to login to OCP. Exiting..." "ERROR"
	send_mail_notification "Backup failed: Failed to login to OCP."
        exit 1
    else 
        log_message "$oc_login" "INFO"
        log_message "Successfully logged on to OCP." "INFO"
    fi

    log_message "Trying to login to cpd-cli." "INFO"
    cpd_cli_login=`${CPD_CLI_DIR}/cpd-cli manage login-to-ocp ${SERVER_ARGUMENTS} ${LOGIN_ARGUMENTS}`
    if [[ $cpd_cli_login =~ $failed_login ]]; then
        log_message "$cpd_cli_login" "ERROR"
        log_message "Failed to login to cpd-cli. Exiting..." "ERROR"
	send_mail_notification "Backup failed: Failed to login to cpd-cli."
        exit 1
    else
        log_message "$cpd_cli_login" "INFO"
        log_message "Successfully logged on to cpd-cli." "INFO"
    fi

}

log_message() {
    local log_message="$1"
    local log_level="$2"

    echo "$(date) ${log_level}: ${log_message}"
    sleep 1
}

send_mail_notification() {
    /usr/bin/tar -czf "${LOG_FILE}.tar.gz" "${LOG_FILE}"
    echo "Check attached log file for more details" | mailx -v -S smtp=smtp.example.com -s "$1" -r "no-reply-nonprod-cpdadmin@example.com" -a "${LOG_FILE}.tar.gz" "user@example.com"
}


get_cr_status() {
#	${CPD_CLI_DIR}/cpd-cli manage get-cr-status --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
	all_completed=true
        ${CPD_CLI_DIR}/cpd-cli manage get-cr-status --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} | sed -n '/\[INFO\] Output the result in the JSON format:/,/^\[/{:a;n;p;ba}' | sed '2!d' > /tmp/oadp/output.json	
    	jq -r '.[] | .[] | "\(.["CR-name"]) \(.Status)"' /tmp/oadp/output.json | while read -r line; do

    # Extract the CR-name and Status from the line
    CR_NAME=$(echo "$line" | cut -d ' ' -f1)
    STATUS=$(echo "$line" | cut -d ' ' -f2-)   
	# Check if the status is not Completed
    	   if [[ ! "$STATUS" == "Completed" && ! "$STATUS" == "Succeeded" ]]; then
               log_message "$CR_NAME  is not completed, current status: $STATUS" "INFO"
               all_completed=false
	   else
	      log_message "$CR_NAME  is  completed, current status: $STATUS" "INFO"
	      
           fi
	done

	# Check the overall status after going through all components
	if [ "$all_completed" = true ]; then
    	    log_message "All components are in Completed state." "INFO"
	    return 0
	else
    	    log_message "Some components are not in Completed state." "WARNING"
	    return 1
	fi
}

get_pod_status() {
    
    output=$(${OC_PATH}/oc get pod -A -o wide --no-headers | grep -Ev '([[:digit:]])/\1.*R' | grep -Ev 'Completed|env-spec-sync-job')
    if [ -z "$output" ]; then
        log_message "All pods are running fine." "INFO"
	return 0
    else
	sleep 300
	output=$(${OC_PATH}/oc get pod -A -o wide --no-headers | grep -Ev '([[:digit:]])/\1.*R' | grep -Ev 'Completed|env-spec-sync-job')
        if [ -z "$output" ]; then
            log_message "All pods are running fine." "INFO"
	    return 0
        else  
	    log_message "$output" "ERROR"
	    return 1
	 fi
    fi
}


get_cluster_status() {
   # Check status of the installed components
   get_cr_status
   cr_status=$?
   if [ $cr_status -eq 1 ]; then
       #Sleep for 5 min and try to check status again if status is not in completed
       sleep 300
       get_cr_status
       cr_status=$?
   fi
   # Check the status of the pods
   get_pod_status
   pod_status=$?
   if [ "$1" = "Pre-backup" ]; then
	if  [ $cr_status -eq 1 ] || [ $pod_status -eq 1 ]; then
	    log_message "Cluster health doesn't look good. Verify before proceeding" "ERROR"
	    send_mail_notification "Cluster health doesn't look good. Verify before proceeding"
	    exit 1
   	else
	    log_message "Cluster health is good. Proceeding with backup" "INFO"
	fi
    elif [ "$1" = "Post-backup" ]; then
        if  [ $cr_status -eq 1 ] || [ $pod_status -eq 1 ]; then
	  log_message "Cluster health doesn't look good post backup please verify" "ERROR"
	  send_mail_notification "Backup Completed: Backup completed but cluster health not good"
  	  exit 1
	else
 	   log_message "Cluster health is good post backup" "INFO"
           send_mail_notification "Backup Completed: Backup completed and cluster health is good"
           exit 1
        fi
    fi
}


pod_sts_deploy_backup() {
    log_message "Backing PODS, STS, DEPLOYMENT, PVC and CRONJOB of ${PROJECT_CPD_INST_OPERANDS} ${PROJECT_CPD_INST_OPERATORS}" "INFO"
    backup_dir="$BACKUP_DIR_PATH/offline-backup-$(date +%Y%m%d)"
    mkdir -p "$backup_dir"
    log_message "Backup directory created: $backup_dir" "INFO"
    ${OC_PATH}/oc get sts,deploy -n "${PROJECT_CPD_INST_OPERANDS}" > "$backup_dir/sts_deploy.cpd.$(date +%Y%m%d%H%M%S).out"
    ${OC_PATH}/oc get sts,deploy,cj -n "${PROJECT_CPD_INST_OPERATORS}" > "$backup_dir/sts_deploy.ics.$(date +%Y%m%d%H%M%S).out"
    ${OC_PATH}/oc get cj -n "${PROJECT_CPD_INST_OPERANDS}" > "$backup_dir/cj.cpd.$(date +%Y%m%d%H%M%S).out"
    ${OC_PATH}/oc get po -n "${PROJECT_CPD_INST_OPERANDS}" > "$backup_dir/po.cpd.$(date +%Y%m%d%H%M%S).out"
    ${OC_PATH}/oc get pvc -n "${PROJECT_CPD_INST_OPERANDS}" > "$backup_dir/pvc.cpd.$(date +%Y%m%d%H%M%S).out"
    log_message "Backing STS, DEPLOYMENT, PVC to $backup_dir completed" "INFO"
}

zen_metastore_edb_status() {
    log_message "Checking zen-metastore-edb cluster state" "INFO"
    cluster_status=$(${OC_PATH}/oc  cnp status zen-metastore-edb -n ${PROJECT_CPD_INST_OPERANDS} --verbose)

    if [[ "$cluster_status" == *"Cluster in healthy state"* ]]; then
        log_message "Cluster zen-metastore-edb is healthy" "INFO"
        primary_pod=$(${OC_PATH}/oc cnp status zen-metastore-edb -n ${PROJECT_CPD_INST_OPERANDS} | tail -n 2 | awk '{print $1}' | head -1)
        secondary_pod=$(${OC_PATH}/oc cnp status zen-metastore-edb -n ${PROJECT_CPD_INST_OPERANDS}| tail -n 2 | awk '{print $1}' | tail -1)
        log_message "Primary pod: $primary_pod" "INFO"
        log_message "Secondary pod: $secondary_pod" "INFO"
    else
        log_message "Cluster zen-metastore-edb is unhealthy. Exiting..." "ERROR"
	send_mail_notification "Backup Failed: zen-metastore-edb is unhealthy."
        exit 1
    fi
}

data_refinery_jobs() {
    log_message "Stopping data refinery jobs" "INFO"
    ${OC_PATH}/oc -n "${PROJECT_CPD_INST_OPERANDS}" delete "$(${OC_PATH}/oc -n ${PROJECT_CPD_INST_OPERANDS} get deployment -l type=shaper -o name)"
    ${OC_PATH}/oc -n "${PROJECT_CPD_INST_OPERANDS}" delete "$(${OC_PATH}/oc -n ${PROJECT_CPD_INST_OPERANDS} get svc -l type=shaper -o name)"
    ${OC_PATH}/oc -n "${PROJECT_CPD_INST_OPERANDS}" delete "$(${OC_PATH}/oc -n ${PROJECT_CPD_INST_OPERANDS} get job -l type=shaper -o name)"
    ${OC_PATH}/oc -n "${PROJECT_CPD_INST_OPERANDS}" delete "$(${OC_PATH}/oc -n ${PROJECT_CPD_INST_OPERANDS} get secrets -l type=shaper -o name)"
    ${OC_PATH}/oc -n "${PROJECT_CPD_INST_OPERANDS}" delete "$(${OC_PATH}/oc -n ${PROJECT_CPD_INST_OPERANDS} get cronjobs -l type=shaper -o name)"
    ${OC_PATH}/oc -n "${PROJECT_CPD_INST_OPERANDS}" scale --replicas=0 deploy wdp-shaper wdp-dataprep
}


backup_cpd_operators_configmap() {
    log_message "Generating the cpd-operators configmap" "INFO"
    /tmp/oadp/cpd-operators.sh backup --foundation-namespace "${PROJECT_CPD_INST_OPERATORS}" --operators-namespace "${PROJECT_CPD_INST_OPERATORS}" --backup-iam-data
    echo $?
    if [ $? -ne 0 ]; then
	 log_message "CPD Operators Configmap Generation Failed. Exiting..." "ERROR"
	 send_mail_notification "Backup Failed: CPD Operators Configmap Generation Failed."
        exit 1
    else
	log_message "CPD Operators Configmap Generation Succedded" "INFO"
    fi
}

backup_cpd_operators_edb_postgres() {
    log_message "Creating backup of CPD operators and EDB Postgres cluster resources" "INFO"
    local backup_name=offline-backupname1-"${CURRENT_DATE}"
    ${CPD_CLI_DIR}/cpd-cli oadp backup create $backup_name --tenant-operator-namespace "${PROJECT_CPD_INST_OPERATORS}" --include-resources='namespaces,operatorgroups,roles,rolebindings,serviceaccounts,customresourcedefinitions.apiextensions.k8s.io,securitycontextconstraints.security.openshift.io,configmaps,namespacescopes,commonservices,clusters.postgresql.k8s.enterprisedb.io' --skip-hooks --log-level=debug --verbose
   if [ $? -ne 0 ]; then
        log_message "CPD Operators and EDB Postgres Backup Failed. Exiting..." "ERROR"
	send_mail_notification "Backup Failed: CPD Operators and EDB Postgres Backup Failed."
	exit 1
    else
	status=$(${CPD_CLI_DIR}/cpd-cli oadp backup list | grep $backup_name | awk '{print $2}')
	if [ "$status" = "Completed" ]; then
  	    log_message "CPD Operators and EDB Postgres Backup Succeded." "INFO"
	else
  	    log_message "CPD Operators and EDB Postgres Backup Failed. Exiting..." "ERROR"
	    send_mail_notification "Backup Failed: CPD Operators and EDB Postgres Backup failed."
            exit 1
	fi
    fi 
}

run_prehook() {
    log_message "Starting Prehook" "INFO"
    ${CPD_CLI_DIR}/cpd-cli oadp backup prehooks --tenant-operator-namespace ${PROJECT_CPD_INST_OPERATORS} --log-level=debug --verbose
    if [ $? -ne 0 ]; then
        log_message "Prehook Failed. Retrying...." "ERROR"
        ${CPD_CLI_DIR}/cpd-cli oadp backup prehooks --tenant-operator-namespace ${PROJECT_CPD_INST_OPERATORS} --log-level=debug --verbose
        if [ $? -ne 0 ]; then
            log_message "Prehook Failed on retry as well. Exiting..." "ERROR"
            send_mail_notification "Backup Failed: Prehook failed. "
            return 1
        fi
        log_message "Prehook Succeded" "INFO"
        return 0
    fi
}

backup_kubernetes_resources() {
    log_message "Starting backup of Kubernetes resources and volume data" "INFO"
    backup_name=offline-backupname2-"${CURRENT_DATE}"
    ${CPD_CLI_DIR}/cpd-cli oadp backup create offline-backupname2-"${CURRENT_DATE}" --tenant-operator-namespace "${PROJECT_CPD_INST_OPERATORS}" --exclude-tenant-operator-namespace=true --exclude-resources='event,event.events.k8s.io,imagetags.openshift.io,operatorgroups,roles,rolebindings,serviceaccounts,customresourcedefinitions.apiextensions.k8s.io,securitycontextconstraints.security.openshift.io,catalogsources.operators.coreos.com,subscriptions.operators.coreos.com,clusterserviceversions.operators.coreos.com,installplans.operators.coreos.com,operandconfig,operandregistry,operandrequest,clients.oidc.security.ibm.com,authentication.operator.ibm.com,namespacescopes,commonservices,clusters.postgresql.k8s.enterprisedb.io,certificaterequests.cert-manager.io,orders.acme.cert-manager.io,challenges.acme.cert-manager.io' --default-volumes-to-restic --snapshot-volumes=false --skip-hooks --cleanup-completed-resources --vol-mnt-pod-mem-request=1Gi --vol-mnt-pod-mem-limit=4Gi --wait-timeout=15m --log-level=debug --verbose

    if [ $? -ne 0 ]; then
        log_message "Offline Restic Backup Failed." "ERROR"
        log_message "Proceeding with Posthook" "INFO"
	send_mail_notification "Backup Failed: Offline Restic Backup Failed. Running Posthook..."
     else
	status=$(${CPD_CLI_DIR}/cpd-cli oadp backup list | grep $backup_name | awk '{print $2}')
        if [ "$status" = "Completed" ]; then
            log_message "Offline Restic Backup Succeded." "INFO"
        else
            log_message "Offline Restic Backup Failed. Running Posthook..." "ERROR"
            send_mail_notification "Backup Failed: Offline Restic Backup failed. Running Posthook..."
        fi
    fi
}

run_posthook() {
    log_message "Starting Posthook" "INFO"
    ${CPD_CLI_DIR}/cpd-cli oadp backup posthooks --tenant-operator-namespace ${PROJECT_CPD_INST_OPERATORS} --log-level=debug --verbose
    if [ $? -ne 0 ]; then
        send_mail_notification "Posthook Failed: Posthook failed to scale all the pods"
        exit 1
    else
	log_message "Posthook succeded." "INFO"
    fi

}

main() {

    # Redirect stdout and stderr to log file
    exec >"${LOG_FILE}" 2>&1
    log_message "Starting CPD Offline Backup Execution $(date)" "INFO"

    # Login to cluster
    cluster_login
    #Check cluster health before doing backup
    get_cluster_status "Pre-backup"

    # Backup Steps
    # Take backup of Statefulsets and deployments to cross verify if needed
    pod_sts_deploy_backup
   
    # Check zen_metastore_edb pods are in sync
    zen_metastore_edb_status
    # Scale down data refinery
    data_refinery_jobs
    # Create operators configmap
    backup_cpd_operators_configmap
  
    # Create CPD operators and edb_postgres backup
    backup_cpd_operators_edb_postgres
    # Run prehook to bring down the cluster
    run_prehook
    # Take restic backup only if prehook are successful 
    if [ $? -eq 0 ]; then
        log_message "Backup Prehook Completed Successfully $(date)" "INFO"
        backup_kubernetes_resources
    fi
    # Get the cluster back up after the backup
    run_posthook
    
    #Sleep for 10 min before checking cluster status
    sleep 600
    # Scale up data refinary to before backup state
    oc -n "${PROJECT_CPD_INST_OPERANDS}" scale --replicas=1 deploy wdp-shaper wdp-dataprep
    # Check cluster health after the backup is finished
    get_cluster_status "Post-backup"


    log_message "CPD Offline Backup Execution Completed $(date)" "INFO"
}

# Run main function
main