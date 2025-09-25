terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket         = "my-innovatemart-terraform-state"
    key            = "eks/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-lock"
  }
}

provider "aws" {
  region = "eu-west-1"
}

module "eks" {
  source = "./modules/eks"

  cluster_name    = "bedrock-eks"
  cluster_version = "1.29"
  vpc_id          = "vpc-06d9f330c756a127c"
  subnet_ids      = ["subnet-0d18d4189a1c03bfd", "subnet-0b29e3b56d8e77446"]
  eks_role_arn    = "arn:aws:iam::073186739637:role/AmazonEKSClusterRole"
  node_role_arn   = "arn:aws:iam::073186739637:role/AmazonEKSAutoClusterRole"
}