# Create the certificate for Azure Application Gateway
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out appgw.crt -keyout appgw.key -subj "/CN=bicycle.contoso.com/O=Contoso Bicycle"
openssl pkcs12 -export -out appgw.pfx -in appgw.crt -inkey appgw.key -passout pass:

export APP_GATEWAY_LISTENER_CERTIFICATE=$(cat appgw.pfx | base64 | tr -d '\n')

# Generate certificate for the AKS Ingress Controller
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out traefik-ingress-internal-aks-ingress-contoso-com-tls.crt -keyout traefik-ingress-internal-aks-ingress-contoso-com-tls.key -subj "/CN=*.aks-ingress.contoso.com/O=Contoso Aks Ingress"

export AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64=$(cat traefik-ingress-internal-aks-ingress-contoso-com-tls.crt | base64 | tr -d '\n')

# Login to Azure and set right Azure subscription (USE CREDS THAT HAVE RIGHTS TO CREATE AZURE AD GROUP)
az login
#az account set -s "FTE - Visual Studio Enterprise Subscription"
az account set -s "Maksh's Azure"

# Query and save Azure subscription's tenant id.
TENANTID_AZURERBAC=$(az account show --query tenantId -o tsv)

# Link Azure tenant and Kubernetes Cluster API authorization endpoint
TENANTID_K8SRBAC=$(az account show --query tenantId -o tsv)

# Create the Azure AD security group to be mapped to the Kubernetes Cluster Admin role cluster-admin
export AADOBJECTNAME_GROUP_CLUSTERADMIN=maksh-aks-cluster-admins
#export AADOBJECTID_GROUP_CLUSTERADMIN=$(az ad group create --display-name $AADOBJECTNAME_GROUP_CLUSTERADMIN --mail-nickname $AADOBJECTNAME_GROUP_CLUSTERADMIN --description "Principals in this group are AKS cluster admins." --query objectId -o tsv)
export AADOBJECTID_GROUP_CLUSTERADMIN=d6ffaa4e-d30c-4041-8499-4c8ae2c8c9a2

# TOBE USed for Subsequent Executions
export AADOBJECTID_GROUP_CLUSTERADMIN=$(az ad group show -g $AADOBJECTNAME_GROUP_CLUSTERADMIN --query objectId -o tsv)

# Create a "Break Glass" User Account to be added in Azure AD Group
export TENANTDOMAIN_K8SRBAC=$(az ad signed-in-user show --query 'userPrincipalName' -o tsv | cut -d '@' -f 2 | sed 's/\"//')
export AADOBJECTNAME_USER_CLUSTERADMIN=aks-cluster-admin-breakglass-user
export AADOBJECTID_USER_CLUSTERADMIN=$(az ad user create --display-name=${AADOBJECTNAME_USER_CLUSTERADMIN} --user-principal-name ${AADOBJECTNAME_USER_CLUSTERADMIN}@${TENANTDOMAIN_K8SRBAC} --force-change-password-next-login --password ChangeMebu0001a0008AdminChangeMe --query objectId -o tsv)

# Add the cluster admin user(s) to the cluster admin security group. This UserID will create AKS cluster
# az ad group member add -g $AADOBJECTID_GROUP_CLUSTERADMIN --member-id $AADOBJECTID_USER_CLUSTERADMIN
az ad group member add -g $AADOBJECTID_GROUP_CLUSTERADMIN --member-id aa610942-4935-4bc0-81ee-99cfa96ce7a1

# Navigate to cluster-rbac.yaml and identify palceholder to update AAD group ID

# Start Deploying Hub and Spoke Network Topology
az login -t $TENANTID_AZURERBAC
az account set -s "Maksh's Azure"

# Create RG for Hub
az group create -n rg-enterprise-networking-hubs -l uksouth

# Create the networking spokes resource group.
az group create -n rg-enterprise-networking-spokes -l uksouth

# Create the regional network hub
az deployment group create -g rg-enterprise-networking-hubs -f ./networking/hub-default.json -p location=uksouth

# Capture the Hub VNet ID
RESOURCEID_VNET_HUB=$(az deployment group show -g rg-enterprise-networking-hubs -n hub-default --query properties.outputs.hubVnetId.value -o tsv)

# Deploy the Spoke VNet
az deployment group create -g rg-enterprise-networking-spokes -f ./networking/spoke-BU0001A0008.json -p location=uksouth hubVnetResourceId="${RESOURCEID_VNET_HUB}"

# Update the shared, regional hub deployment 
RESOURCEID_SUBNET_NODEPOOLS=$(az deployment group show -g rg-enterprise-networking-spokes -n spoke-BU0001A0008 --query properties.outputs.nodepoolSubnetResourceIds.value -o tsv)
az deployment group create -g rg-enterprise-networking-hubs -f networking/hub-regionA.json -p location=uksouth nodepoolSubnetResourceIds="['${RESOURCEID_SUBNET_NODEPOOLS}']"

# Create the AKS cluster resource group.
az group create --name maksh-bc2-aks-rg --location uksouth
az group create --name maksh-bc3-aks-rg --location uksouth

# Get the AKS cluster spoke VNet resource ID
RESOURCEID_VNET_CLUSTERSPOKE=$(az deployment group show -g rg-enterprise-networking-spokes -n spoke-BU0001A0008 --query properties.outputs.clusterVnetResourceId.value -o tsv)

# Deploy the cluster ARM template (Individual Parameters)
az deployment group create -g aks-rg -f ./cluster-stamp.json -p targetVnetResourceId=${RESOURCEID_VNET_CLUSTERSPOKE} \
    location=uksouth \
    clusterAdminAadGroupObjectId=${AADOBJECTID_GROUP_CLUSTERADMIN} k8sControlPlaneAuthorizationTenantId=${TENANTID_K8SRBAC} \
    appGatewayListenerCertificate=${APP_GATEWAY_LISTENER_CERTIFICATE} \
    aksIngressControllerCertificate=${AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64}

# Deploy the cluster ARM template (Template File)
az deployment group create -g maksh-bc3-aks-rg -f ./cluster-stamp.json -p "@azuredeploy.parameters.prod-maksh.json"

# DEBUGGING ONLY: Delete a specific ARM template Deployment
az deployment group delete --resource-group aks-rg --name cluster-stamp

# Get the cluster name
AKS_CLUSTER_NAME=$(az deployment group show -g maksh-bc2-aks-rg -n cluster-stamp --query properties.outputs.aksClusterName.value -o tsv)

# Get AKS kubectl credentials.
az aks get-credentials -g maksh-bc2-aks-rg -n $AKS_CLUSTER_NAME

# Validate
kubectl get nodes

# Get your ACR cluster name
ACR_NAME=$(az deployment group show -g  maksh-bc2-aks-rg -n cluster-stamp --query properties.outputs.containerRegistryName.value -o tsv)

# Import cluster management images hosted in public container registries
az acr import --source docker.io/library/memcached:1.5.20 -n $ACR_NAME
az acr import --source docker.io/fluxcd/flux:1.21.1 -n $ACR_NAME
az acr import --source docker.io/weaveworks/kured:1.6.1 -n $ACR_NAME

# Create the cluster baseline settings namespace as a logical division of the cluster bootstrap configuration from workload configuration
kubectl create namespace cluster-baseline-settings

# Deploy Flux
kubectl create -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/cluster-manifests/cluster-baseline-settings/flux.yaml

# Wait for Flux to be ready
kubectl wait -n cluster-baseline-settings --for=condition=ready pod --selector=app.kubernetes.io/name=flux --timeout=90s
