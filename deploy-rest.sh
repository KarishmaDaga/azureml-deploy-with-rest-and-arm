set -x

# <create_variables>
SUBSCRIPTION_ID=$(az account show --query id | tr -d '\r"')
LOCATION=$(az ml workspace show --query location | tr -d '\r"')
RESOURCE_GROUP=$(az group show --query name | tr -d '\r"')
WORKSPACE=$(az configure -l | jq -r '.[] | select(.name=="workspace") | .value')

echo -e "Using:\nSUBSCRIPTION_ID=$SUBSCRIPTION_ID\nLOCATION=$LOCATION\nRESOURCE_GROUP=$RESOURCE_GROUP\nWORKSPACE=$WORKSPACE"

CODE_NAME=score-sklearn
MODEL_NAME=sklearn
MODEL_PATH_IN_DATASTORE=model/sklearn_regression_model.pkl
ENV_NAME=sklearn-env
DOCKER_IMAGE=mcr.microsoft.com/azureml/openmpi3.1.2-ubuntu18.04:20210727.v1
DEPLOYMENT_NAME=blue
SCORING_SCRIPT=score.py
ENDPOINT_COMPUTE_TYPE=Managed
SKU_NAME=Standard_F2s_v2
SKU_CAPACITY=1
#</create_variables>

# <read_condafile>
CONDA_FILE=$(< model/environment/conda.yml)
# <read_condafile>

#<get_access_token>
TOKEN=$(az account get-access-token --query accessToken -o tsv)
#</get_access_token>

# <set_endpoint_name>
export ENDPOINT_NAME=endpt-`echo $RANDOM`
# </set_endpoint_name>

#<api_version>
API_VERSION="2021-10-01"
#</api_version>

# define how to wait  
wait_for_completion () {
    operation_id=$1
    status="unknown"

    if [[ $operation_id == "" || -z $operation_id  || $operation_id == "null" ]]; then
        echo "operation id cannot be empty"
        exit 1
    fi

    while [[ $status != "Succeeded" && $status != "Failed" ]]
    do
        echo "Getting operation status from: $operation_id"
        operation_result=$(curl --location --request GET $operation_id --header "Authorization: Bearer $TOKEN")
        # TODO error handling here
        status=$(echo $operation_result | jq -r '.status')
        echo "Current operation status: $status"
        sleep 5
    done

    if [[ $status == "Failed" ]]
    then
        error=$(echo $operation_result | jq -r '.error')
        echo "Error: $error"
    fi
}

# <get_storage_details>
# Get values for storage account
response=$(curl --location --request GET "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.MachineLearningServices/workspaces/$WORKSPACE/datastores?api-version=$API_VERSION&isDefault=true" \
--header "Authorization: Bearer $TOKEN")
AZUREML_DEFAULT_DATASTORE=$(echo $response | jq -r '.value[0].name')
AZUREML_DEFAULT_CONTAINER=$(echo $response | jq -r '.value[0].properties.containerName')
export AZURE_STORAGE_ACCOUNT=$(echo $response | jq -r '.value[0].properties.accountName')
# </get_storage_details>

# <upload_code>
az storage blob upload-batch -d $AZUREML_DEFAULT_CONTAINER/score -s model/onlinescoring --account-name $AZURE_STORAGE_ACCOUNT
# </upload_code>

# <create_code>
curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Resources/deployments/$CODE_NAME?api-version=2020-10-01" \
-H "Authorization: Bearer $TOKEN" \
-H 'Content-Type: application/json' \
--data-raw "{
    \"properties\": {
      \"mode\": \"Incremental\",
      \"templateLink\": {
        \"uri\": \"https://raw.githubusercontent.com/KarishmaDaga/azureml-deploy-with-rest-and-arm/main/rest-templates/code-version.json\"
      },
      \"parameters\": {
        \"workspaceName\": {
          \"value\": \"$WORKSPACE\"
        },
        \"codeAssetName\": {
          \"value\": \"$CODE_NAME\"
        },
        \"codeAssetVersion\": {
          \"value\": \"1\"
        },
        \"codeUri\": {
          \"value\": \"https://$AZURE_STORAGE_ACCOUNT.blob.core.windows.net/$AZUREML_DEFAULT_CONTAINER/score\"
        }
      }
    }
}"
# <\create_code>

# <upload_model>
az storage blob upload-batch -d $AZUREML_DEFAULT_CONTAINER/model -s model/model --account-name $AZURE_STORAGE_ACCOUNT
# <\upload_model>

# <create_model>
curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Resources/deployments/$MODEL_NAME?api-version=2020-10-01" \
-H "Authorization: Bearer $TOKEN" \
-H 'Content-Type: application/json' \
--data-raw "{
    \"properties\": {
      \"mode\": \"Incremental\",
      \"templateLink\": {
        \"uri\": \"https://raw.githubusercontent.com/KarishmaDaga/azureml-deploy-with-rest-and-arm/main/rest-templates/model-version.json\"
      },
      \"parameters\": {
        \"workspaceName\": {
          \"value\": \"$WORKSPACE\"
        },
        \"modelVersion\": {
          \"value\": \"1\"
        },
        \"modelName\": {
          \"value\": \"$MODEL_NAME\"
        },
        \"modelUri\": {
          \"value\": \"azureml://subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/workspaces/$WORKSPACE/datastores/$AZUREML_DEFAULT_DATASTORE/paths/$MODEL_PATH_IN_DATASTORE\"
        }
      }
    }
  }"
# <\create_model>

# <create_environment>
curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Resources/deployments/$ENV_NAME?api-version=2020-10-01" \
-H "Authorization: Bearer $TOKEN" \
-H 'Content-Type: application/json' \
--data-raw "{
    \"properties\": {
      \"mode\": \"Incremental\",
      \"templateLink\": {
        \"uri\": \"https://raw.githubusercontent.com/KarishmaDaga/azureml-deploy-with-rest-and-arm/main/rest-templates/environment-version.json\"
      },
      \"parameters\": {
        \"workspaceName\": {
          \"value\": \"$WORKSPACE\"
        },
        \"environmentName\": {
          \"value\": \"$ENV_NAME\"
        },
        \"environmentVersion\": {
          \"value\": \"1\"
        },
        \"condaFile\": {
          \"value\": \"$CONDA_FILE\"
        },
        \"dockerImage\": {
            \"value\": \"$DOCKER_IMAGE\"
        }
      }
    }
  }"
# <\create_environment>

# <create_endpoint>
response=$(curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Resources/deployments/$ENDPOINT_NAME?api-version=2020-10-01" \
-H "Authorization: Bearer $TOKEN" \
-H 'Content-Type: application/json' \
--data-raw "{
  \"properties\": {
    \"mode\": \"Incremental\",
    \"templateLink\": {
      \"uri\": \"https://raw.githubusercontent.com/KarishmaDaga/azureml-deploy-with-rest-and-arm/main/rest-templates/online-endpoint.json\"
    },
    \"parameters\": {
      \"workspaceName\": {
        \"value\": \"$WORKSPACE\"
      },
      \"location\": {
        \"value\": \"$LOCATION\"
      },
      \"identityType\": {
        \"value\": \"SystemAssigned\"
      },
      \"authMode\": {
        \"value\": \"AMLToken\"
      },
      \"onlineEndpointName\": {
        \"value\": \"$ENDPOINT_NAME\"
      }
    }
  }
}")
# <\create_endpoint>

echo "Endpoint response: $response"
operation_id=$(echo $response | jq -r '.properties' | jq -r '.correlationId')
wait_for_completion $operation_id

# <create_deployment>
response=$(curl --location --request PUT "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Resources/deployments/$DEPLOYMENT_NAME?api-version=2020-10-01" \
-H "Authorization: Bearer $TOKEN" \
-H 'Content-Type: application/json' \
--data-raw "{
    \"properties\": {
      \"mode\": \"Incremental\",
      \"templateLink\": {
        \"uri\": \"https://raw.githubusercontent.com/KarishmaDaga/azureml-deploy-with-rest-and-arm/main/rest-templates/online-endpoint-deployment.json\"
      },
      \"parameters\": {
        \"workspaceName\": {
          \"value\": \"$WORKSPACE\"
        },
        \"location\": {
          \"value\": \"$LOCATION\"
        },
        \"onlineEndpointName\": {
          \"value\": \"$ENDPOINT_NAME\"
        },
        \"onlineDeploymentName\": {
            \"value\": \"$DEPLOYMENT_NAME\"
        },
        \"codeAssetName\": {
            \"value\": \"$CODE_NAME\"
        },
        \"scoringScript\": {
            \"value\": \"$SCORING_SCRIPT\"
        },
        \"environmentAssetName\": {
            \"value\": \"$ENV_NAME\"
        },
        \"modelAssetName\": {
            \"value\": \"$MODEL_NAME\"
        },
        \"endpointComputeType\": {
            \"value\": \"$ENDPOINT_COMPUTE_TYPE\"
        },
        \"skuName\": {
            \"value\": \"$SKU_NAME\"
        },
        \"skuCapacity\": {
            \"value\": $SKU_CAPACITY
        }
      }
    }
}")
# <\create_deployment>

echo "Endpoint response: $response"
operation_id=$(echo $response | jq -r '.properties' | jq -r '.correlationId')
wait_for_completion $operation_id

# get endpoint
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