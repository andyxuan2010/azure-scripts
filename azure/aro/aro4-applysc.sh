#!/bin/bash

# Apply additional storage classes for other types of Azure disks

oc apply -f managed-std-hdd.yaml
oc apply -f managed-std-ssd.yaml
oc apply -f managed-ultra-ssd.yaml
oc get sc