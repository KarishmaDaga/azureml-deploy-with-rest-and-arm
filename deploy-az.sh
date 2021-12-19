# azure resource group, workspace, and storage
RG=RG_NAME_PLACEHOLDER
WS=WS_NAME_PLACEHOLDER
API_VERSION="2021-10-01"
DEFAULT_CONTAINER=AZUREML_DEFAULT_CONTAINER
## assets
# code
codeVersionTemplate=templates/codeversion.json
codeAssetUri=geospatial_analytics
isAnonymous=false

# code
# upload code assets
az storage blob upload-batch \
  -d $AZUREML_DEFAULT_CONTAINER/score \
  -s endpoints/online/model-1/onlinescoring

# register code version
az deployment group create \
  -g "${RG}" \
  --template-file $codeVersionTemplate \
  --parameters \
  workspaceName="${WS}" \
  codeAssetUri="${codeAssetUri}" \
  isAnonymous="${isAnonymous}"

exit