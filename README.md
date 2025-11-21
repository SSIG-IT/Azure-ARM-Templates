# Azure-ARM-Templates

3CX Azure Deployments

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FSSIG-IT%2FAzure-ARM-Templates%2Fmain%2F3cx-template.json)


# Locks-Policy-RG

## Run via Azure CLI

To deploy the Resource Group Lock Policy, Automation Account, Runbook, and daily remediation schedule, simply open the **Azure Cloud Shell** or any terminal with the Azure CLI installed.

Then execute the following command:

```bash
curl -O https://raw.githubusercontent.com/SSIG-IT/Azure-ARM-Templates/main/policies/locks-policy-vm/rg-lock-policy.sh \
  && chmod +x rg-lock-policy.sh \
  && ./rg-lock-policy.sh