# for debug purposes
set -x

# setup information
SUBSCRIPTION_ID=$(az account show --query id | tr -d '\r"')
LOCATION=$(az ml workspace show --query location | tr -d '\r"')
RESOURCE_GROUP=$(az group show --query name | tr -d '\r"')
WORKSPACE=$(az configure -l | jq -r '.[] | select(.name=="workspace") | .value')

echo -e "Using:\nSUBSCRIPTION_ID=$SUBSCRIPTION_ID\nLOCATION=$LOCATION\nRESOURCE_GROUP=$RESOURCE_GROUP\nWORKSPACE=$WORKSPACE"

# deployment variables
# code
CODE_NAME=score-sklearn
# model
MODEL_NAME=sklearn
MODEL_PATH_IN_DATSTORE=model/sklearn_regression_model.pkl
# environment
ENV_NAME=sklearn-env
CONDA_FILE=$(< model/environment/conda.yml) # read conda file
DOCKER_IMAGE=mcr.microsoft.com/azureml/openmpi3.1.2-ubuntu18.04:20210727.v1
# online endpoint and deployment
export ENDPOINT_NAME=endpoint-`echo $RANDOM`
IDENTITY_TYPE=SystemAssigned
AUTHMODE=AMLToken
DEPLOYMENT_NAME=blue
SCORING_SCRIPT=score.py
ENDPOINT_COMPUTE_TYPE=Managed
SKU_NAME=Standard_F2s_v2
SKU_CAPACITY=1

# access token
TOKEN=$(az account get-access-token --query accessToken -o tsv)

# api version
API_VERSION="2021-10-01"

# storage details
response=$(curl --location --request GET "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/datastores?api-version=$API_VERSION&isDefault=true" \
--header "Authorization: Bearer $TOKEN")
AZUREML_DEFAULT_DATASTORE=$(echo $response | jq -r '.value[0].name')
AZUREML_DEFAULT_CONTAINER=$(echo $response | jq -r '.value[0].properties.containerName')
export AZURE_STORAGE_ACCOUNT=$(echo $response | jq -r '.value[0].properties.accountName')

# upload code asset to storage
az storage blob upload-batch -d $AZUREML_DEFAULT_CONTAINER/score -s model/onlinescoring --account-name $AZURE_STORAGE_ACCOUNT

# register code asset
az deployment group create -g $RESOURCE_GROUP \
--template-file templates/code-version.json \
--parameters \
workspaceName=$WORKSPACE \
codeAssetName=$CODE_NAME \
codeUri=https://$AZURE_STORAGE_ACCOUNT.blob.core.windows.net/$AZUREML_DEFAULT_CONTAINER/score

# upload model asset to storage
az storage blob upload-batch -d $AZUREML_DEFAULT_CONTAINER/model -s model/model --account-name $AZURE_STORAGE_ACCOUNT

# register model asset
az deployment group create -g $RESOURCE_GROUP \
--template-file templates/model-version.json \
--parameters \
workspaceName=$WORKSPACE \
modelName=$MODEL_NAME \
modelUri=azureml://subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/workspaces/$WORKSPACE/datastores/$AZUREML_DEFAULT_DATASTORE/paths/$MODEL_PATH_IN_DATSTORE

# register environment asset
az deployment group create -g $RESOURCE_GROUP \
--template-file templates/environment-version.json \
--parameters \
workspaceName=$WORKSPACE \
environmentName=$ENV_NAME \
condaFile="$CONDA_FILE" \
dockerImage=$DOCKER_IMAGE

# create endpoint
az deployment group create -g $RESOURCE_GROUP \
--template-file templates/online-endpoint.json \
--parameters \
workspaceName=$WORKSPACE \
onlineEndpointName=$ENDPOINT_NAME \
identityType=$IDENTITY_TYPE \
authMode=$AUTHMODE \
location=$LOCATION

# # create deployment
az deployment group create -g $RESOURCE_GROUP \
 --template-file templates/online-endpoint-deployment.json \
 --parameters \
 workspaceName=$WORKSPACE \
 location=$LOCATION \
 onlineEndpointName=$ENDPOINT_NAME \
 onlineDeploymentName=$DEPLOYMENT_NAME \
 codeAssetName=$CODE_NAME \
 scoringScript=$SCORING_SCRIPT \
 environmentAssetName=$ENV_NAME \
 modelAssetName=$MODEL_NAME \
 endpointComputeType=$ENDPOINT_COMPUTE_TYPE \
 skuName=$SKU_NAME \
 skuCapacity=$SKU_CAPACITY \

# #get endpoint
response=$(curl --location --request GET "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/$ENDPOINT_NAME?api-version=$API_VERSION" \
--header "Content-Type: application/json" \
--header "Authorization: Bearer $TOKEN")

# scoring URI
scoringUri=$(echo $response | jq -r '.properties' | jq -r '.scoringUri')

# endpoint access token
response=$(curl -H "Content-Length: 0" --location --request POST "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/$ENDPOINT_NAME/token?api-version=$API_VERSION" \
--header "Authorization: Bearer $TOKEN")
accessToken=$(echo $response | jq -r '.accessToken')

# score endpoint
curl --location --request POST $scoringUri \
--header "Authorization: Bearer $accessToken" \
--header "Content-Type: application/json" \
--data-raw @model/sample-request.json

# <get_deployment_logs>
curl --location --request POST "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/$ENDPOINT_NAME/deployments/$DEPLOYMENT_NAME/getLogs?api-version=$API_VERSION" \
--header "Authorization: Bearer $TOKEN" \
--header "Content-Type: application/json" \
--data-raw "{ \"tail\": 100 }"

# delete endpoint
curl --location --request DELETE "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/onlineEndpoints/$ENDPOINT_NAME?api-version=$API_VERSION" \
--header "Content-Type: application/json" \
--header "Authorization: Bearer $TOKEN" || true
