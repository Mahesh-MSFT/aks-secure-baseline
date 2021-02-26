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
az group create --name maksh-pnp-aks-rg --location uksouth

# Get the AKS cluster spoke VNet resource ID
RESOURCEID_VNET_CLUSTERSPOKE=$(az deployment group show -g rg-enterprise-networking-spokes -n spoke-BU0001A0008 --query properties.outputs.clusterVnetResourceId.value -o tsv)

# Deploy the cluster ARM template (Individual Parameters)
az deployment group create -g aks-rg -f ./cluster-stamp.json -p targetVnetResourceId=${RESOURCEID_VNET_CLUSTERSPOKE} \
    location=uksouth \
    clusterAdminAadGroupObjectId=${AADOBJECTID_GROUP_CLUSTERADMIN} k8sControlPlaneAuthorizationTenantId=${TENANTID_K8SRBAC} \
    appGatewayListenerCertificate=${APP_GATEWAY_LISTENER_CERTIFICATE} \
    aksIngressControllerCertificate=${AKS_INGRESS_CONTROLLER_CERTIFICATE_BASE64}

# Deploy the cluster ARM template (Template File)
az deployment group create -g maksh-pnp-aks-rg -f ./cluster-stamp.json -p "@azuredeploy.parameters.prod-maksh.json"

# DEBUGGING ONLY: Delete a specific ARM template Deployment
az deployment group delete --resource-group aks-rg --name cluster-stamp

# Get the cluster name
AKS_CLUSTER_NAME=$(az deployment group show -g maksh-pnp-aks-rg -n cluster-stamp --query properties.outputs.aksClusterName.value -o tsv)

# Get AKS kubectl credentials.
az aks get-credentials -g maksh-pnp-aks-rg -n $AKS_CLUSTER_NAME

# Validate
kubectl get nodes

# Get your ACR cluster name
ACR_NAME=$(az deployment group show -g  maksh-pnp-aks-rg -n cluster-stamp --query properties.outputs.containerRegistryName.value -o tsv)

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

#Obtain the Azure Key Vault details
KEYVAULT_NAME=$(az deployment group show --resource-group maksh-pnp-aks-rg -n cluster-stamp --query properties.outputs.keyVaultName.value -o tsv)

# Give the current user permissions to import certificates.
az keyvault set-policy --certificate-permissions import list get --upn $(az account show --query user.name -o tsv) -n $KEYVAULT_NAME

# Import the AKS Ingress Controller's Wildcard Certificate
cat traefik-ingress-internal-aks-ingress-contoso-com-tls.crt traefik-ingress-internal-aks-ingress-contoso-com-tls.key > traefik-ingress-internal-aks-ingress-contoso-com-tls.pem
az keyvault certificate import -f traefik-ingress-internal-aks-ingress-contoso-com-tls.pem -n traefik-ingress-internal-aks-ingress-contoso-com-tls --vault-name $KEYVAULT_NAME

# Remove Azure Key Vault import certificates permissions for current user
az keyvault delete-policy --upn $(az account show --query user.name -o tsv) -n $KEYVAULT_NAME

# Confirm policies are applied to the AKS cluster
kubectl get constrainttemplate

# Get the AKS Ingress Controller Managed Identity details
export TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID=$(az deployment group show --resource-group maksh-pnp-aks-rg -n cluster-stamp --query properties.outputs.aksIngressControllerPodManagedIdentityResourceId.value -o tsv)
export TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID=$(az deployment group show --resource-group maksh-pnp-aks-rg -n cluster-stamp --query properties.outputs.aksIngressControllerPodManagedIdentityClientId.value -o tsv)

# Ensure Flux has created the following namespace
kubectl get ns a0008 -w

# Create Traefik's Azure Managed Identity binding
cat <<EOF | kubectl create -f -
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentity
metadata:
  name: podmi-ingress-controller-identity
  namespace: a0008
spec:
  type: 0
  resourceID: $TRAEFIK_USER_ASSIGNED_IDENTITY_RESOURCE_ID
  clientID: $TRAEFIK_USER_ASSIGNED_IDENTITY_CLIENT_ID
---
apiVersion: aadpodidentity.k8s.io/v1
kind: AzureIdentityBinding
metadata:
  name: podmi-ingress-controller-binding
  namespace: a0008
spec:
  azureIdentity: podmi-ingress-controller-identity
  selector: podmi-ingress-controller
EOF

# Create the Traefik's Secret Provider Class resource
KEYVAULT_NAME=$(az deployment group show --resource-group maksh-pnp-aks-rg -n cluster-stamp --query properties.outputs.keyVaultName.value -o tsv)

cat <<EOF | kubectl create -f -
apiVersion: secrets-store.csi.x-k8s.io/v1alpha1
kind: SecretProviderClass
metadata:
  name: aks-ingress-contoso-com-tls-secret-csi-akv
  namespace: a0008
spec:
  provider: azure
  parameters:
    usePodIdentity: "true"
    keyvaultName: $KEYVAULT_NAME
    objects:  |
      array:
        - |
          objectName: traefik-ingress-internal-aks-ingress-contoso-com-tls
          objectAlias: tls.crt
          objectType: cert
        - |
          objectName: traefik-ingress-internal-aks-ingress-contoso-com-tls
          objectAlias: tls.key
          objectType: secret
    tenantId: $TENANTID_AZURERBAC
EOF

# Import the Traefik container image to your container registry
az acr import --source docker.io/library/traefik:2.2.1 -n $ACR_NAME

# Install the Traefik Ingress Controller
kubectl create -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/workload/traefik.yaml

# Wait for Traefik to be ready
kubectl wait -n a0008 --for=condition=ready pod --selector=app.kubernetes.io/name=traefik-ingress-ilb --timeout=90s

# Deploy the ASP.NET Core Docker sample web app
kubectl create -f https://raw.githubusercontent.com/mspnp/aks-secure-baseline/main/workload/aspnetapp.yaml

# Wait until is ready to process requests running
kubectl wait -n a0008 --for=condition=ready pod --selector=app.kubernetes.io/name=aspnetapp --timeout=90s

# Check your Ingress resource status
kubectl get ingress aspnetapp-ingress -n a0008

# Give it a try 
kubectl run curl -n a0008 -i --tty --rm --image=mcr.microsoft.com/azure-cli --limits='cpu=200m,memory=128Mi'

# From within the open shell
curl -kI https://bu0001a0008-00.aks-ingress.contoso.com -w '%{remote_ip}\n'
exit

# Get Public IP of Application Gateway
export APPGW_PUBLIC_IP=$(az deployment group show --resource-group rg-enterprise-networking-spokes -n spoke-BU0001A0008 --query properties.outputs.appGwPublicIpAddress.value -o tsv)

# HOSTS File Validation
#52.151.125.208 bicycle.contoso.com