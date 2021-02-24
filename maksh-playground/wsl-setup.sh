# Create the certificate for Azure Application Gateway
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out appgw.crt -keyout appgw.key -subj "/CN=bicycle.contoso.com/O=Contoso Bicycle"
openssl pkcs12 -export -out appgw.pfx -in appgw.crt -inkey appgw.key -passout pass:

export APP_GATEWAY_LISTENER_CERTIFICATE=$(cat appgw.pfx | base64 | tr -d '\n')

# Generate certificate for the AKS Ingress Controller
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -out traefik-ingress-internal-aks-ingress-contoso-com-tls.crt -keyout traefik-ingress-internal-aks-ingress-contoso-com-tls.key -subj "/CN=*.aks-ingress.contoso.com/O=Contoso Aks Ingress"

export AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64=$(cat traefik-ingress-internal-aks-ingress-contoso-com-tls.crt | base64 | tr -d '\n')

# Login to Azure and set right Azure subscription (USE CREDS THAT HAVE RIGHTS TO CREATE AZURE AD GROUP)
az login
az account set -s "FTE - Visual Studio Enterprise Subscription"

# Query and save Azure subscription's tenant id.
TENANTID_AZURERBAC=$(az account show --query tenantId -o tsv)

# Link Azure tenant and Kubernetes Cluster API authorization endpoint
TENANTID_K8SRBAC=$(az account show --query tenantId -o tsv)

# Create the Azure AD security group to be mapped to the Kubernetes Cluster Admin role cluster-admin
export AADOBJECTNAME_GROUP_CLUSTERADMIN=aks-cluster-admins
export AADOBJECTID_GROUP_CLUSTERADMIN=$(az ad group create --display-name $AADOBJECTNAME_GROUP_CLUSTERADMIN --mail-nickname $AADOBJECTNAME_GROUP_CLUSTERADMIN --description "Principals in this group are AKS cluster admins." --query objectId -o tsv)

# Create a "Break Glass" User Account to be added in Azure AD Group
export TENANTDOMAIN_K8SRBAC=$(az ad signed-in-user show --query 'userPrincipalName' -o tsv | cut -d '@' -f 2 | sed 's/\"//')
export AADOBJECTNAME_USER_CLUSTERADMIN=aks-cluster-admin-breakglass-user
export AADOBJECTID_USER_CLUSTERADMIN=$(az ad user create --display-name=${AADOBJECTNAME_USER_CLUSTERADMIN} --user-principal-name ${AADOBJECTNAME_USER_CLUSTERADMIN}@${TENANTDOMAIN_K8SRBAC} --force-change-password-next-login --password ChangeMebu0001a0008AdminChangeMe --query objectId -o tsv)

# Add the cluster admin user(s) to the cluster admin security group. This UserID will create AKS cluster
az ad group member add -g $AADOBJECTID_GROUP_CLUSTERADMIN --member-id $AADOBJECTID_USER_CLUSTERADMIN

# Navigate to cluster-rbac.yaml and identify palceholder to update AAD group ID

# Start Deploying Hub and Spoke Network Topology
az login -t $TENANTID_AZURERBAC
az account set -s "FTE - Visual Studio Enterprise Subscription"

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

# Create the AKS cluster resource group.
az group create --name aks-rg --location uksouth

# Get the AKS cluster spoke VNet resource ID
RESOURCEID_VNET_CLUSTERSPOKE=$(az deployment group show -g rg-enterprise-networking-spokes -n spoke-BU0001A0008 --query properties.outputs.clusterVnetResourceId.value -o tsv)

# Deploy the cluster ARM template
az deployment group create -g aks-rg -f ./cluster-stamp.json -p targetVnetResourceId=${RESOURCEID_VNET_CLUSTERSPOKE} clusterAdminAadGroupObjectId=${AADOBJECTID_GROUP_CLUSTERADMIN} k8sControlPlaneAuthorizationTenantId=${TENANTID_K8SRBAC} appGatewayListenerCertificate=${APP_GATEWAY_LISTENER_CERTIFICATE} aksIngressControllerCertificate=${AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64}