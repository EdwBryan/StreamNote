# Se aplica UNA vez a mano. Crea lo que el pipeline necesita para entrar a AWS y guardar el estado.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-2"
}

data "aws_caller_identity" "me" {}

locals {
  repo = "EdwBryan/StreamNote"   # solo este repo puede usar el rol
  # GitHub firma el "sub" con los IDs de la cuenta y del repo (formato inmutable):
  # aunque alguien cree otro repo con el mismo nombre, sus IDs no coinciden.
  repo_inmutable = "EdwBryan@268266098/StreamNote@1435819305"
}

# 1) Bucket del estado de Terraform (el número de cuenta lo hace único)
resource "aws_s3_bucket" "tfstate" {
  bucket = "streamnote-tfstate-${data.aws_caller_identity.me.account_id}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"   # si el estado se daña, se recupera una versión anterior
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true   # el estado puede tener secretos: nunca público
}

# 2) AWS confía en los tokens que firma GitHub Actions
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# 3) Rol que asume el pipeline, solo desde nuestro repo
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo_inmutable}:*", "repo:${local.repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "streamnote-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"   # simple para el curso
}

output "role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}
