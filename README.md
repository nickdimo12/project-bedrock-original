# Project Bedrock Infrastructure

This repository contains the infrastructure-as-code (IaC) and CI/CD configuration for deploying the retail-store-sample-app to an Amazon EKS cluster (`bedrock-eks`) in the `eu-west-1` region, as part of InnovateMart's "Project Bedrock." The setup uses Terraform to provision the EKS cluster and GitHub Actions to automate deployment of Kubernetes manifests to the `retail` namespace, ensuring compatibility with AWS free-tier constraints.

## Table of Contents
- [Overview](#overview)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Setup Instructions](#setup-instructions)
  - [1. Configure AWS Resources](#1-configure-aws-resources)
  - [2. Set Up Local Environment](#2-set-up-local-environment)
  - [3. Populate the Repository](#3-populate-the-repository)
  - [4. Configure GitHub Secrets](#4-configure-github-secrets)
  - [5. Run the CI/CD Pipeline](#5-run-the-cicd-pipeline)
- [Usage](#usage)
- [Troubleshooting](#troubleshooting)
- [Cost Management](#cost-management)
- [Contributing](#contributing)
- [License](#license)

## Overview
The project provisions an EKS cluster (`bedrock-eks`) using Terraform and deploys a retail store UI application with a MySQL backend to the `retail` namespace. The CI/CD pipeline includes:
- **Terraform Plan**: Runs on pushes to `feature/*` branches to plan infrastructure changes.
- **Terraform Apply**: Manually triggered to apply the Terraform plan and create the EKS cluster.
- **Deploy**: Deploys Kubernetes manifests (`ui`, MySQL, Ingress) to the cluster.

The setup uses the `github-eks-ci` IAM user for AWS access and ensures minimal costs by using `t3.micro` instances for EKS nodes.

## Repository Structure
```
project-bedrock-infra/
├── infra/                     # Terraform configurations for EKS
│   ├── main.tf
│   ├── output.tf
│   ├── variables.tf
│   └── modules/
│       └── eks/
│           ├── main.tf
│           └── variables.tf
├── k8s/                       # Kubernetes manifests
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── namespace-retail.yaml
│   ├── mysql-deployment.yaml
│   ├── mysql-service.yaml
│   ├── mysql-secret.yaml
│   ├── ui-ingress.yaml
│   └── aws-lb-controller.yaml
├── .github/
│   └── workflows/             # GitHub Actions workflows
│       ├── terraform-plan.yaml
│       ├── terraform-apply.yaml
│       └── deploy.yaml
├── iam-policy.json            # IAM policy for github-eks-ci (not committed)
└── .gitignore
```

## Prerequisites
- **AWS Account**: Free-tier eligible, with access to `eu-west-1`.
- **GitHub Account**: Access to `https://github.com/nickdimo12/project-bedrock-original
- **Local Tools**:
  - Git
  - Terraform (v1.7.5)
  - AWS CLI (v2)
  - `kubectl`
  - Docker (if building custom UI image)
- **AWS Resources**:
  - S3 bucket: `my-innovatemart-terraform-state`
  - DynamoDB table: `terraform-lock` (partition key: `LockID`)
  - IAM user: `github-eks-ci` with access keys
  - IAM roles: `AmazonEKSClusterRole`, `AmazonEKSAutoClusterRole`, `AmazonEKSLoadBalancerControllerRole`
- **VPC and Subnets**: A VPC and at least two subnets in `eu-west-1`.

## Setup Instructions

### 1. Configure AWS Resources
1. **Create S3 Bucket**:
   ```bash
   aws s3 mb s3://my-innovatemart-terraform-state --region eu-west-1
   aws s3api put-bucket-versioning --bucket my-innovatemart-terraform-state --versioning-configuration Status=Enabled
   ```
2. **Create DynamoDB Table**:
   ```bash
   aws dynamodb create-table --table-name terraform-lock --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST --region eu-west-1
   ```
3. **Create IAM User and Roles**:
   - Create `github-eks-ci`:
     ```bash
     aws iam create-user --user-name github-eks-ci
     aws iam create-access-key --user-name github-eks-ci
     ```
     - Save `AccessKeyId` and `SecretAccessKey`.
   - Apply `iam-policy.json`:
     ```bash
     aws iam put-user-policy --user-name github-eks-ci --policy-name GithubEksCiPolicy --policy-document file://iam-policy.json
     ```
   - Create `AmazonEKSClusterRole`:
     ```bash
     aws iam create-role --role-name AmazonEKSClusterRole --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"eks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
     aws iam attach-role-policy --role-name AmazonEKSClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
     ```
   - Create `AmazonEKSAutoClusterRole`:
     ```bash
     aws iam create-role --role-name AmazonEKSAutoClusterRole --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
     aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
     aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
     aws iam attach-role-policy --role-name AmazonEKSAutoClusterRole --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
     ```
   - Create `AmazonEKSLoadBalancerControllerRole`:
     - Get EKS OIDC provider ID after cluster creation:
       ```bash
       aws eks describe-cluster --name bedrock-eks --query cluster.identity.oidc.issuer
       ```
     - Create role (replace `EXAMPLED5390C6A8C08EABCD` with OIDC ID):
       ```bash
       aws iam create-role --role-name AmazonEKSLoadBalancerControllerRole --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Federated":"arn:aws:iam::073186739637:oidc-provider/oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED5390C6A8C08EABCD"},"Action":"sts:AssumeRoleWithWebIdentity","Condition":{"StringEquals":{"oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED5390C6A8C08EABCD:aud":"sts.amazonaws.com","oidc.eks.eu-west-1.amazonaws.com/id/EXAMPLED5390C6A8C08EABCD:sub":"system:serviceaccount:kube-system:aws-load-balancer-controller"}}}]}'
       ```
     - Attach policy:
       ```bash
       curl -o lb-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
       aws iam put-role-policy --role-name AmazonEKSLoadBalancerControllerRole --policy-name AWSELBPolicy --policy-document file://lb-policy.json
       ```

### 2. Set Up Local Environment
1. Install tools:
   ```bash
   # Terraform
   wget https://releases.hashicorp.com/terraform/1.7.5/terraform_1.7.5_linux_amd64.zip
   unzip terraform_1.7.5_linux_amd64.zip
   sudo mv terraform /usr/local/bin/
   terraform version  # Should show v1.7.5

   # AWS CLI
   curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
   unzip awscliv2.zip
   sudo ./aws/install

   # kubectl
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   chmod +x kubectl
   sudo mv kubectl /usr/local/bin/
   kubectl version --client

   # Git
   sudo apt update
   sudo apt install git
   ```
2. Configure AWS CLI:
   ```bash
   aws configure
   # Enter Access Key ID, Secret Access Key, region (eu-west-1), output format (json)
   ```

### 3. Populate the Repository
1. Clone or initialize the repository:
   ```bash
   git clone https://github.com/nickdimo12/project-bedrock-infra.git
   cd project-bedrock-infra
   # OR
   mkdir project-bedrock-infra
   cd project-bedrock-infra
   git init
   ```
2. Create the file structure:
   ```bash
   mkdir -p infra/modules/eks k8s .github/workflows
   ```
3. Add files from the provided configurations (Terraform, Kubernetes, workflows) to their respective directories.
4. Update `infra/main.tf` with your VPC and subnet IDs:
   ```bash
   aws ec2 describe-vpcs --region eu-west-1
   aws ec2 describe-subnets --region eu-west-1
   ```
5. Update `k8s/mysql-secret.yaml` with base64-encoded MySQL credentials:
   ```bash
   echo -n 'retail_user' | base64  # e.g., cmV0YWlsX3VzZXI=
   echo -n 'MySecurePass123!' | base64  # e.g., TXlTZWN1cmVQYXNzMTIzIQ==
   ```
6. Update `k8s/deployment.yaml` with your UI image (e.g., `073186739637.dkr.ecr.eu-west-1.amazonaws.com/retail-store-ui:latest` or `nginx:latest`).
7. Commit and push:
   ```bash
   git add .
   git commit -m "Initial commit: Add Terraform, Kubernetes, and CI/CD files"
   git branch -M main
   git remote add origin https://github.com/nickdimo12/project-bedrock-infra.git
   git push -u origin main
   ```

### 4. Configure GitHub Secrets
1. Go to GitHub > Repository > Settings > Secrets and variables > Actions > New repository secret.
2. Add:
   - `AWS_ACCESS_KEY_ID`: From `github-eks-ci`.
   - `AWS_SECRET_ACCESS_KEY`: From `github-eks-ci`.

### 5. Run the CI/CD Pipeline
1. Push to a feature branch to trigger `terraform-plan.yaml`:
   ```bash
   git checkout -b feature/setup
   git push origin feature/setup
   ```
2. Manually run `terraform-apply.yaml` (GitHub > Actions > Terraform Apply > Run workflow).
3. Run `deploy.yaml` manually or after `Terraform Apply`.
4. Verify deployment:
   ```bash
   aws eks update-kubeconfig --region eu-west-1 --name bedrock-eks
   kubectl get pods -n retail
   kubectl get svc -n retail
   kubectl get ingress -n retail
   ```

## Usage
- **Access the UI**: Get the Ingress URL:
  ```bash
  kubectl get ingress -n retail -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
  ```
- **Monitor Pods**:
  ```bash
  kubectl logs -n retail -l app=ui
  kubectl logs -n retail -l app=mysql
  ```
- **Update UI Image**: If using a custom UI image, build and push to ECR:
  ```bash
  aws ecr create-repository --repository-name retail-store-ui --region eu-west-1
  aws ecr get-login-password --region eu-west-1 | docker login --username AWS --password-stdin 073186739637.dkr.ecr.eu-west-1.amazonaws.com
  docker build -t retail-store-ui:latest .
  docker tag retail-store-ui:latest 073186739637.dkr.ecr.eu-west-1.amazonaws.com/retail-store-ui:latest
  docker push 073186739637.dkr.ecr.eu-west-1.amazonaws.com/retail-store-ui:latest
  ```

## Troubleshooting
- **File Not Found**: Check `deploy.yaml` logs for `Verify k8s directory` errors. Ensure all `k8s/` files are committed.
- **IAM Errors**: Verify `github-eks-ci` permissions and secrets. Ensure IAM roles exist.
- **Terraform Errors**: Confirm S3 bucket and DynamoDB table exist. Clear locks:
  ```bash
  terraform force-unlock <LOCK_ID>
  ```
- **Ingress Issues**: Ensure the AWS Load Balancer Controller is running:
  ```bash
  kubectl get pods -n kube-system -l app=aws-load-balancer-controller
  ```
- **MySQL Connection**: Check `ui` pod logs:
  ```bash
  kubectl logs -n retail -l app=ui
  ```

## Cost Management
- Use `t3.micro` nodes to stay within AWS free-tier limits.
- Delete resources after testing:
  ```bash
  cd infra
  terraform destroy -auto-approve
  aws ecr delete-repository --repository-name retail-store-ui --region eu-west-1
  ```

## Contributing
Contributions are welcome! Please submit a pull request or open an issue for suggestions or bug reports.

## License
This project is licensed under the MIT License.
