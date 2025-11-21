#!/bin/bash
set -e

#############################################
# 🔰 GLOBAL VARIABLES
#############################################

SUB_ID=$(az account show --query id -o tsv)
LOCATION="germanywestcentral"

AA_RG="rg-automation"
AA_NAME="aa-lock-remediation"
RUNBOOK_NAME="Run-Remediate-RGLocks"

ROLE_NAME="RG-Lock-Contributor"
POLICY_NAME="Deploy-RG-Lock"
ASSIGNMENT_NAME="assign-rg-lock"

echo "🔎 Subscription: $SUB_ID"
echo "🔎 Custom Role: $ROLE_NAME"
echo "🔎 Policy:      $POLICY_NAME"
echo ""


#############################################
# 1️⃣ Custom Role erstellen / prüfen
#############################################

echo "🔍 Prüfe ob Custom Role $ROLE_NAME existiert..."
ROLE_EXISTS=$(az role definition list --name "$ROLE_NAME" --query "[].name" -o tsv)

if [[ -z "$ROLE_EXISTS" ]]; then
  echo "➡ Rolle nicht vorhanden, erstelle sie..."

  cat <<EOF > rg-lock-role.json
{
  "Name": "RG-Lock-Contributor",
  "IsCustom": true,
  "Description": "Allows modifying resource group locks and starting policy remediations.",
  "Actions": [
    "Microsoft.Authorization/locks/read",
    "Microsoft.Authorization/locks/write",
    "Microsoft.Authorization/locks/delete",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Resources/subscriptions/resourceGroups/write",
    "Microsoft.Resources/deployments/read",
    "Microsoft.Resources/deployments/write",
    "Microsoft.Resources/deployments/delete",
    "Microsoft.Resources/deployments/cancel/action",
    "Microsoft.Resources/deployments/validate/action",
    "Microsoft.Resources/deployments/whatIf/action",
    "Microsoft.Resources/deployments/operations/read",
    "Microsoft.Resources/deployments/operationstatuses/read",
    "Microsoft.Resources/tags/read",
    "Microsoft.Resources/tags/write",
    "Microsoft.Resources/tags/delete",
    "Microsoft.PolicyInsights/remediations/read",
    "Microsoft.PolicyInsights/remediations/write",
    "Microsoft.PolicyInsights/remediations/delete"
  ],
  "NotActions": [],
  "AssignableScopes": [
    "/subscriptions/$SUB_ID"
  ]
}
EOF

  az role definition create --role-definition rg-lock-role.json
else
  echo "✔ Custom Role existiert bereits."
fi

ROLE_OBJECT_ID=$(az role definition list --name "$ROLE_NAME" --query "[].id" -o tsv)
echo "➡ Role ID: $ROLE_OBJECT_ID"
echo ""


#############################################
# 2️⃣ Policy Definition erstellen
#############################################

echo "🔍 Erstelle Policy Rule JSON..."
cat <<EOF > rg-lock-policy-rule.json
{
  "if": {
    "field": "type",
    "equals": "Microsoft.Resources/subscriptions/resourceGroups"
  },
  "then": {
    "effect": "deployIfNotExists",
    "details": {
      "type": "Microsoft.Authorization/locks",
      "name": "CanNotDeleteLock",
      "roleDefinitionIds": [
        "$ROLE_OBJECT_ID"
      ],
      "existenceCondition": {
        "field": "Microsoft.Authorization/locks/level",
        "equals": "CanNotDelete"
      },
      "deployment": {
        "properties": {
          "mode": "incremental",
          "template": {
            "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
            "contentVersion": "1.0.0.0",
            "parameters": {},
            "resources": [
              {
                "type": "Microsoft.Authorization/locks",
                "apiVersion": "2016-09-01",
                "name": "CanNotDeleteLock",
                "properties": {
                  "level": "CanNotDelete",
                  "notes": "Auto-applied by policy"
                }
              }
            ]
          }
        }
      }
    }
  }
}
EOF

echo "🔍 Prüfe ob Policy Definition $POLICY_NAME existiert..."
if ! az policy definition show --name "$POLICY_NAME" &>/dev/null; then
  echo "➡ Policy wird erstellt..."
  az policy definition create \
    --name "$POLICY_NAME" \
    --display-name "Deploy RG CanNotDelete Lock" \
    --description "Applies a CanNotDelete lock to all Resource Groups." \
    --rules rg-lock-policy-rule.json \
    --mode All
else
  echo "✔ Policy existiert bereits."
fi
echo ""


#############################################
# 3️⃣ Policy Assignment mit System Identity
#############################################

echo "🔍 Prüfe Policy Assignment $ASSIGNMENT_NAME..."
if ! az policy assignment show --name "$ASSIGNMENT_NAME" &>/dev/null; then
  echo "➡ Erstelle Policy Assignment (mit Managed Identity)..."
  az policy assignment create \
    --name "$ASSIGNMENT_NAME" \
    --display-name "Assign RG Lock" \
    --policy "$POLICY_NAME" \
    --location "$LOCATION" \
    --assign-identity
else
  echo "✔ Policy Assignment existiert schon."
fi

MI_PRINCIPAL_ID=$(az policy assignment show \
  --name "$ASSIGNMENT_NAME" \
  --query "identity.principalId" -o tsv)

echo "➡ Managed Identity Principal ID: $MI_PRINCIPAL_ID"
echo ""


#############################################
# 4️⃣ Custom Role der Managed Identity zuweisen (mit Retry)
#############################################

echo "⏳ Warte bis Managed Identity im Entra ID Graph registriert ist..."

for i in {1..20}; do
  if az ad sp show --id "$MI_PRINCIPAL_ID" &>/dev/null; then
    echo "✔ Managed Identity ist bereit."
    break
  else
    echo "… noch nicht verfügbar, warte 3 Sekunden ($i/20)"
    sleep 3
  fi
done

if ! az ad sp show --id "$MI_PRINCIPAL_ID" &>/dev/null; then
  echo "❌ Fehler: Managed Identity ist nach 60s nicht bereit."
  exit 1
fi

echo "➡ Weise Rolle $ROLE_NAME zu…"

az role assignment create \
  --role "$ROLE_NAME" \
  --assignee "$MI_PRINCIPAL_ID" \
  --scope "/subscriptions/$SUB_ID"

echo ""


#############################################
# 5️⃣ Remediation einmalig starten
#############################################

echo "🔍 Starte initiale Remediation für alle bestehenden RGs..."
az policy remediation create \
  --name remediate-rg-lock-initial \
  --policy-assignment "$ASSIGNMENT_NAME" \
  --resource-discovery-mode ReEvaluateCompliance

echo "⏳ Remediation gestartet. Locks erscheinen in 2–5 Minuten."
echo ""


###########################################################
# 🔁 AB HIER: 2. SCRIPT – AUTOMATION ACCOUNT & RUNBOOK
###########################################################

#############################################
# 6️⃣ Resource Group für Automation
#############################################

echo "🔍 Prüfe Resource Group $AA_RG..."
if ! az group show --name $AA_RG &>/dev/null; then
  echo "➡ Erstelle Resource Group $AA_RG..."
  az group create --name $AA_RG --location $LOCATION --output none
else
  echo "✔ Resource Group existiert bereits."
fi
echo ""


#############################################
# 7️⃣ Automation Account erstellen
#############################################

echo "🔧 Erstelle / prüfe Automation Account..."

if ! az automation account show --resource-group $AA_RG --name $AA_NAME &>/dev/null; then
  az automation account create \
    --resource-group $AA_RG \
    --name $AA_NAME \
    --location $LOCATION \
    --sku Free \
    --output none
  echo "✔ Automation Account erstellt."
else
  echo "✔ Automation Account existiert bereits."
fi
echo ""


#############################################
# 8️⃣ Automation Managed Identity aktivieren
#############################################

echo "🔐 Aktiviere Managed Identity für Automation Account..."

az resource update \
  --resource-group $AA_RG \
  --name $AA_NAME \
  --resource-type "Microsoft.Automation/automationAccounts" \
  --set identity.type=SystemAssigned \
  --output none

AA_MI=$(az resource show \
  --resource-group $AA_RG \
  --name $AA_NAME \
  --resource-type Microsoft.Automation/automationAccounts \
  --query identity.principalId -o tsv)

echo "➡ Automation MI PrincipalId: $AA_MI"


echo "⏳ Warte auf Automation Managed Identity Registrierung..."

for i in {1..20}; do
  if az ad sp show --id "$AA_MI" &>/dev/null; then
    echo "✔ Automation Managed Identity im Graph sichtbar."
    break
  fi
  echo "   … warte 3 Sekunden ($i/20)"
  sleep 3
done

if ! az ad sp show --id "$AA_MI" &>/dev/null; then
  echo "❌ ERROR: Automation MI ist nach 60s nicht sichtbar!"
  exit 1
fi


#############################################
# 9️⃣ Rolle für Automation MI zuweisen
#############################################

echo "🔍 Weise Custom Role der Automation MI zu..."

az role assignment create \
  --assignee $AA_MI \
  --role "$ROLE_NAME" \
  --scope "/subscriptions/$SUB_ID" \
  --output none

echo "✔ Rolle erfolgreich zugewiesen."
echo ""


#############################################
# 🔟 Runbook erstellen
#############################################

echo "📝 Erstelle Runbook Datei remediate.ps1..."

cat <<'EOF' > remediate.ps1
param()

Write-Output "🔐 Starting remediation..."

# Login mit der System-Managed-Identity
Connect-AzAccount -Identity

# Subscription automatisch auslesen
$SubscriptionId = (Get-AzContext).Subscription.Id

# Policy Assignment Id dynamisch generieren
$PolicyAssignmentId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments/assign-rg-lock"

Write-Output "➡ Verwende PolicyAssignmentId: $PolicyAssignmentId"

# Remediation starten
Start-AzPolicyRemediation `
    -Name "remediate-rg-locks" `
    -PolicyAssignmentId $PolicyAssignmentId `
    -ResourceDiscoveryMode ReEvaluateCompliance

Write-Output "✔ Remediation gestartet."
EOF

echo "📤 Importiere Runbook…"

if ! az automation runbook show --automation-account-name $AA_NAME --resource-group $AA_RG --name $RUNBOOK_NAME &>/dev/null; then
  az automation runbook create \
    --automation-account-name $AA_NAME \
    --resource-group $AA_RG \
    --name $RUNBOOK_NAME \
    --type PowerShell \
    --location $LOCATION
fi

az automation runbook replace-content \
  --automation-account-name $AA_NAME \
  --resource-group $AA_RG \
  --name $RUNBOOK_NAME \
  --content @remediate.ps1

echo "📦 Veröffentliche Runbook…"

az automation runbook publish \
  --automation-account-name $AA_NAME \
  --resource-group $AA_RG \
  --name $RUNBOOK_NAME

echo ""


#############################################
# 1️⃣1️⃣ Schedule erstellen & verknüpfen
#############################################

echo "📝 Erstelle PowerShell Datei für Schedule…"

cat << 'EOF' > create_schedule.ps1
$rg = "rg-automation"
$aa = "aa-lock-remediation"

Write-Output "⏱ Erstelle neuen Schedule Daily-21h…"

New-AzAutomationSchedule `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -Name "Daily-22h" `
    -StartTime (Get-Date "21:00" -Format "yyyy-MM-ddTHH:mm:ss") `
    -DayInterval 1 `
    -TimeZone "Europe/Berlin"

Write-Output "🔗 Verknüpfe Schedule mit Runbook…"

Register-AzAutomationScheduledRunbook `
    -ResourceGroupName $rg `
    -AutomationAccountName $aa `
    -RunbookName "Run-Remediate-RGLocks" `
    -ScheduleName "Daily-22h"

Write-Output "✔ Schedule erfolgreich erstellt und verknüpft."
EOF

echo "🚀 Starte PowerShell zur Schedule-Erstellung…"
pwsh -File ./create_schedule.ps1



#############################################
# 🎉 FERTIG
#############################################

echo ""
echo "🎉 ALLES FERTIG!"
echo "➡ Policy & Locks aktiv"
echo "➡ Automation Account & Runbook eingerichtet"
echo "➡ Remediation läuft nun alle 6 Stunden automatisch."
