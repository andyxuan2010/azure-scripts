#!/bin/bash
# Azure Red Hat OpenShift cluster deletion script.
# Customize three following lines to choose your Azure region, resource group name and ARO cluster name

LOCATION=eastus                 # the location of your cluster
RESOURCEGROUP=aro-rg            # the name of the resource group where you want to delete your cluster from
CLUSTER=arotest                 # the name of your cluster

az aro delete --resource-group $RESOURCEGROUP --name $CLUSTER
