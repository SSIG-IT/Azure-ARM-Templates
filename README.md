# Azure-ARM-Templates

3CX Azure Deployments

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2FSSIG-IT%2FAzure-ARM-Templates%2Fmain%2F3cx-template.json)


# Locks-Policy-RG


This module deploys a complete automated governance setup for enforcing **CanNotDelete** locks on all Azure Resource Groups.

It includes:

- A **Custom Role** for lock + remediation permissions  
- A **Policy Definition** that deploys CanNotDelete locks  
- A **Policy Assignment** with System-Managed Identity  
- An **initial remediation** across all Resource Groups  
- An **Automation Account**, **Runbook**, and **daily schedule at 22:00 CET**  
- Continuous enforcement of the lock policy

---

## 🚀 Run via Azure CLI

You can run this solution directly from the **Azure Cloud Shell** or any terminal with Azure CLI installed.

### **1. Open Azure Cloud Shell**

### **2. Execute the Installer**

Then execute the following command:

```bash
curl -O https://raw.githubusercontent.com/SSIG-IT/Azure-ARM-Templates/main/policies/locks-policy-vm/rg-lock-policy.sh \
  && chmod +x rg-lock-policy.sh \
  && ./rg-lock-policy.sh