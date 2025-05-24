#!/bin/bash


################################################################################################## Initialize

echo " "
echo "Display ARO Credentials & Endpoints"
echo "==================================="
echo " "

if [ $# -ne 1 ]; then
    echo "Usage: $BASH_SOURCE <name of cluster>"
    exit 1
fi

if [ -z "$(az aro list -o table |grep -i  $1)" ]; then
    echo "$1 doesn't seem to exist. Review the output of 'az aro list'"
    exit 1
fi

clusterName="$(az aro list -o table |grep -i $1 | awk '{print $1}')"
clusterResourceGroup="$(az aro list -o table |grep -i $1 | awk '{print $2}')"

echo "Cluster name: $clusterName"
echo " "

az aro show -n $clusterName -g $clusterResourceGroup -o jsonc --query '[apiserverProfile , consoleProfile , ingressProfiles]'

echo " "

az aro list-credentials -o table -n $clusterName -g $clusterResourceGroup

declare apiServer="$(az aro show -n $clusterName -g $clusterResourceGroup -o tsv --query '[apiserverProfile.url]')"
declare kubePW="$(az aro list-credentials -n $clusterName -g $clusterResourceGroup -o tsv --query '[kubeadminPassword]')"

echo " "
echo "To log in to CLI:"
echo "oc login $apiServer -u kubeadmin -p $kubePW"

echo " "
echo "To delete cluster:"
echo "az aro delete -n $clusterName -g $clusterResourceGroup -y ; az group delete -n $clusterResourceGroup -y"
echo " "
