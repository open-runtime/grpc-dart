# Azure Dev Box Infrastructure

This directory contains ARM templates and parameters for provisioning Azure Dev Box **control plane** resources.

## What This Template Creates

This template creates **only the control plane**—it does **not** create any actual Dev Box VMs. It provisions:

1. **Dev Center** – The parent resource for Dev Box management, with Microsoft-hosted networking and catalog sync enabled.
2. **Project** – A project linked to the Dev Center.
3. **Role Assignment** – Grants the deployer permission to create Dev Boxes in the project.
4. **Pool** – A Dev Box pool (e.g. `dev-boxes-eastus`) with a Windows 11 + VS 2022 image and 16 vCPU / 64 GB compute.

## What You Must Do After Deployment

Developers must **create an actual Dev Box** from the pool (via Azure Portal, CLI, or API) before Cursor or any other remote development tool can connect. The template only sets up the Dev Center, project, role assignment, and pool—it does not provision individual Dev Box instances.

The template's role assignment is granted to `deployer().objectId`. In practice, that means the identity that runs the deployment gets permission to create Dev Boxes in the project. If you deploy the control plane from CI, a service principal, or a shared admin account, individual developers may still be unable to create Dev Boxes until you grant them the appropriate project-level RBAC access.

Operator guidance: after deployment, assign the required Dev Box creation role to the developer users or groups that should use this pool, then verify Dev Box creation with a real developer identity rather than only the deployment identity.

## Usage

1. Copy `parameters.example.json` to `parameters.json` and adjust values as needed.
2. Set the target resource group for your environment:

   ```bash
   RESOURCE_GROUP="<replace-with-your-resource-group>"
   ```

3. Deploy:

   ```bash
   az deployment group create \
     --resource-group "$RESOURCE_GROUP" \
     --template-file infra/devbox/azure-dev-box.template.json \
     --parameters @infra/devbox/parameters.json
   ```

4. Validate before deploying:

   ```bash
   az deployment group validate \
     --resource-group "$RESOURCE_GROUP" \
     --template-file infra/devbox/azure-dev-box.template.json \
     --parameters @infra/devbox/parameters.json
   ```

## Parameters

| Parameter       | Example          | Description                                                                 |
|----------------|------------------|-----------------------------------------------------------------------------|
| `location`     | `eastus`         | Azure region (must be in the template's allowed values).                    |
| `devCenterName`| `global-dev-boxes` | Base name for the Dev Center (a unique suffix is appended automatically). |
| `projectName`  | `dev-boxes`      | Name of the project.                                                        |
| `poolName`     | `dev-boxes`      | Base name for the pool (region is appended, e.g. `dev-boxes-eastus`).       |
