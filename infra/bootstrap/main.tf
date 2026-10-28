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
  region  = "us-east-2"
  account = data.aws_caller_identity.me.account_id
  # GitHub firma el "sub" con los IDs de la cuenta y del repo (formato inmutable):
  # aunque alguien cree otro repo con el mismo nombre, sus IDs no coinciden.
  # Solo los jobs con "environment: dev" de este repo pueden asumir el rol.
  github_sub = "repo:EdwBryan@268266098/StreamNote@1435819305:environment:dev"
  # Recursos del stack de dev: todos se llaman streamnote-dev-*
  prefix = "streamnote-dev"
  # Estado del laboratorio (bucket creado a mano en us-east-2)
  state_bucket = "streamnote-tfstate-ohio-666791"
  state_key    = "lab09/dev/terraform.tfstate"
}

# 1) Bucket del estado original (us-east-1). Ya existe con estado real: se fija su región para
#    que el provider en us-east-2 no lo reemplace, y prevent_destroy impide borrarlo por error.
resource "aws_s3_bucket" "tfstate" {
  region = "us-east-1"
  bucket = "streamnote-tfstate-${data.aws_caller_identity.me.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  region = "us-east-1"
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # si el estado se daña, se recupera una versión anterior
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  region                  = "us-east-1"
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true # el estado puede tener secretos: nunca público
}

# 2) AWS confía en los tokens que firma GitHub Actions
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# 3) Rol que asume el pipeline, solo desde el environment dev de nuestro repo (sin comodines)
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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "lab09-github-actions-dev"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# 4) Mínimo privilegio: solo lo que el stack de dev crea, acotado por ARN donde la API lo permite.
#    Va en dos políticas porque una administrada admite como máximo 6144 caracteres.
data "aws_iam_policy_document" "deploy_app" {
  # --- Estado de Terraform: solo la llave del laboratorio y su lock ---
  statement {
    sid       = "StateList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${local.state_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["lab09/dev/*"]
    }
  }
  statement {
    sid       = "StateObject"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/${local.state_key}"]
  }
  statement {
    sid       = "StateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${local.state_bucket}/${local.state_key}.tflock"]
  }

  # --- IAM: roles de ejecución del stack ---
  statement {
    sid       = "PassLambdaRole"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account}:role/${local.prefix}-lambda"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
  statement {
    sid = "StackRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags",
      "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${local.account}:role/${local.prefix}-*"]
  }
  # Solo se puede adjuntar la política de logs de Lambda: nunca una política amplia
  statement {
    sid       = "StackRolesAttach"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account}:role/${local.prefix}-*"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values   = ["arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"]
    }
  }
  statement {
    sid       = "RdsServiceLinkedRole"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account}:role/aws-service-role/rds.amazonaws.com/*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["rds.amazonaws.com"]
    }
  }

  # --- Lambda ---
  statement {
    sid = "LambdaFunctions"
    actions = [
      "lambda:CreateFunction", "lambda:DeleteFunction", "lambda:GetFunction", "lambda:GetFunctionConfiguration",
      "lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:ListVersionsByFunction",
      "lambda:GetFunctionCodeSigningConfig", "lambda:GetPolicy", "lambda:AddPermission", "lambda:RemovePermission",
      "lambda:TagResource", "lambda:UntagResource", "lambda:ListTags",
    ]
    resources = ["arn:aws:lambda:${local.region}:${local.account}:function:${local.prefix}-*"]
  }
  # Crear/cambiar/borrar colas → Lambda solo hacia funciones del stack
  statement {
    sid       = "LambdaEventSourceMappings"
    actions   = ["lambda:CreateEventSourceMapping", "lambda:UpdateEventSourceMapping", "lambda:DeleteEventSourceMapping"]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "lambda:FunctionArn"
      values   = ["arn:aws:lambda:${local.region}:${local.account}:function:${local.prefix}-*"]
    }
  }
  statement {
    sid       = "LambdaEventSourceMappingsRead"
    actions   = ["lambda:GetEventSourceMapping", "lambda:ListTags", "lambda:TagResource", "lambda:UntagResource"]
    resources = ["arn:aws:lambda:${local.region}:${local.account}:event-source-mapping:*"]
  }

  # --- CloudWatch Logs: grupos que crea Lambda para las funciones del stack ---
  statement {
    sid       = "LogsDescribe"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${local.region}:${local.account}:log-group:*"]
  }
  statement {
    sid = "LogsStack"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy",
      "logs:TagResource", "logs:UntagResource", "logs:ListTagsForResource",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account}:log-group:/aws/lambda/${local.prefix}-*"]
  }

  # --- API Gateway HTTP API (los ARN usan IDs aleatorios: se acota a la región) ---
  statement {
    sid = "ApiGateway"
    actions = [
      "apigateway:GET", "apigateway:POST", "apigateway:PUT", "apigateway:PATCH", "apigateway:DELETE",
      "apigateway:TagResource", "apigateway:UntagResource",
    ]
    resources = [
      "arn:aws:apigateway:${local.region}::/apis",
      "arn:aws:apigateway:${local.region}::/apis/*",
      "arn:aws:apigateway:${local.region}::/tags/*",
    ]
  }

  # --- Cognito ---
  statement {
    sid       = "CognitoCreatePool"
    actions   = ["cognito-idp:CreateUserPool"]
    resources = ["*"] # la API no admite ARN al crear
  }
  statement {
    sid = "CognitoPools"
    actions = [
      "cognito-idp:DescribeUserPool", "cognito-idp:UpdateUserPool", "cognito-idp:DeleteUserPool",
      "cognito-idp:GetUserPoolMfaConfig", "cognito-idp:SetUserPoolMfaConfig",
      "cognito-idp:CreateUserPoolClient", "cognito-idp:DescribeUserPoolClient",
      "cognito-idp:UpdateUserPoolClient", "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:TagResource", "cognito-idp:UntagResource", "cognito-idp:ListTagsForResource",
    ]
    resources = ["arn:aws:cognito-idp:${local.region}:${local.account}:userpool/*"]
  }
}

data "aws_iam_policy_document" "deploy_datos" {
  # --- Aurora (RDS), su secreto y la Data API de las migraciones ---
  statement {
    sid = "Rds"
    actions = [
      "rds:CreateDBCluster", "rds:ModifyDBCluster", "rds:DeleteDBCluster", "rds:DescribeDBClusters",
      "rds:CreateDBInstance", "rds:ModifyDBInstance", "rds:DeleteDBInstance", "rds:DescribeDBInstances",
      "rds:CreateDBSubnetGroup", "rds:ModifyDBSubnetGroup", "rds:DeleteDBSubnetGroup", "rds:DescribeDBSubnetGroups",
      "rds:AddTagsToResource", "rds:RemoveTagsFromResource", "rds:ListTagsForResource",
      "rds:EnableHttpEndpoint", "rds:DisableHttpEndpoint",
    ]
    resources = [
      "arn:aws:rds:${local.region}:${local.account}:cluster:${local.prefix}-db",
      "arn:aws:rds:${local.region}:${local.account}:db:${local.prefix}-db-*",
      "arn:aws:rds:${local.region}:${local.account}:subgrp:${local.prefix}-db",
      # grupos de parámetros y opciones por defecto que RDS asocia al crear
      "arn:aws:rds:${local.region}:${local.account}:cluster-pg:default.*",
      "arn:aws:rds:${local.region}:${local.account}:pg:default.*",
      "arn:aws:rds:${local.region}:${local.account}:og:default:*",
    ]
  }
  statement {
    sid = "RdsData"
    actions = [
      "rds-data:ExecuteStatement", "rds-data:BatchExecuteStatement",
      "rds-data:BeginTransaction", "rds-data:CommitTransaction", "rds-data:RollbackTransaction",
    ]
    resources = ["arn:aws:rds:${local.region}:${local.account}:cluster:${local.prefix}-db"]
  }
  # RDS crea y rota el secreto de la contraseña maestra (manage_master_user_password) con los permisos de quien despliega
  statement {
    sid = "RdsSecret"
    actions = [
      "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue", "secretsmanager:RotateSecret", "secretsmanager:TagResource",
    ]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account}:secret:rds!*"]
  }
  # Llaves administradas por AWS (aws/rds, aws/secretsmanager): solo a través de esos servicios
  statement {
    sid       = "KmsViaRds"
    actions   = ["kms:DescribeKey", "kms:CreateGrant", "kms:Decrypt", "kms:GenerateDataKey"]
    resources = ["arn:aws:kms:${local.region}:${local.account}:key/*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["rds.${local.region}.amazonaws.com", "secretsmanager.${local.region}.amazonaws.com"]
    }
  }

  # --- Red de Aurora (VPC, subredes, SG). Las lecturas de EC2 no admiten ARN ---
  statement {
    sid = "Ec2Describe"
    actions = [
      "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups",
      "ec2:DescribeSecurityGroupRules", "ec2:DescribeAvailabilityZones", "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags", "ec2:DescribeAccountAttributes",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "Ec2Create"
    actions   = ["ec2:CreateVpc", "ec2:CreateSubnet", "ec2:CreateSecurityGroup"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [local.region]
    }
  }
  statement {
    sid       = "Ec2TagOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateVpc", "CreateSubnet", "CreateSecurityGroup"]
    }
  }
  # Cambiar o borrar solo lo que tiene los tags por defecto del stack de dev
  statement {
    sid = "Ec2StackResources"
    actions = [
      "ec2:ModifyVpcAttribute", "ec2:DeleteVpc", "ec2:ModifySubnetAttribute", "ec2:DeleteSubnet",
      "ec2:DeleteSecurityGroup", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/proyecto"
      values   = ["streamnote"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/entorno"
      values   = ["dev"]
    }
  }

  # --- SQS ---
  statement {
    sid = "Sqs"
    actions = [
      "sqs:CreateQueue", "sqs:DeleteQueue", "sqs:GetQueueAttributes", "sqs:SetQueueAttributes", "sqs:GetQueueUrl",
      "sqs:ListQueueTags", "sqs:TagQueue", "sqs:UntagQueue", "sqs:ListDeadLetterSourceQueues",
    ]
    resources = ["arn:aws:sqs:${local.region}:${local.account}:${local.prefix}-*"]
  }

  # --- EventBridge ---
  statement {
    sid = "EventBridge"
    actions = [
      "events:CreateEventBus", "events:DeleteEventBus", "events:DescribeEventBus", "events:UpdateEventBus",
      "events:PutRule", "events:DeleteRule", "events:DescribeRule", "events:EnableRule", "events:DisableRule",
      "events:PutTargets", "events:RemoveTargets", "events:ListTargetsByRule",
      "events:TagResource", "events:UntagResource", "events:ListTagsForResource",
    ]
    resources = [
      "arn:aws:events:${local.region}:${local.account}:event-bus/${local.prefix}-*",
      "arn:aws:events:${local.region}:${local.account}:rule/${local.prefix}-*/${local.prefix}-*",
    ]
  }

  # --- DynamoDB ---
  statement {
    sid = "DynamoDb"
    actions = [
      "dynamodb:CreateTable", "dynamodb:DeleteTable", "dynamodb:DescribeTable", "dynamodb:UpdateTable",
      "dynamodb:DescribeContinuousBackups", "dynamodb:UpdateContinuousBackups",
      "dynamodb:DescribeTimeToLive", "dynamodb:UpdateTimeToLive",
      "dynamodb:ListTagsOfResource", "dynamodb:TagResource", "dynamodb:UntagResource",
    ]
    resources = ["arn:aws:dynamodb:${local.region}:${local.account}:table/${local.prefix}-*"]
  }

  # --- S3 de la app (web y grabaciones: streamnote-dev-<cuenta>-*) ---
  statement {
    sid = "AppBuckets"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket", "s3:ListBucketVersions",
      "s3:GetBucket*", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketTagging", "s3:GetAccelerateConfiguration", "s3:GetLifecycleConfiguration",
      "s3:PutLifecycleConfiguration", "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration",
    ]
    resources = ["arn:aws:s3:::${local.prefix}-*"]
  }
  # aws s3 sync --delete publica la web; force_destroy vacía los buckets en dev
  statement {
    sid       = "AppObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["arn:aws:s3:::${local.prefix}-*/*"]
  }

  # --- CloudFront (global; los ARN usan IDs aleatorios: se acota a la cuenta) ---
  statement {
    sid = "CloudFront"
    actions = [
      "cloudfront:CreateDistribution", "cloudfront:GetDistribution", "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution",
      "cloudfront:TagResource", "cloudfront:UntagResource", "cloudfront:ListTagsForResource",
      "cloudfront:CreateInvalidation", "cloudfront:GetInvalidation",
    ]
    resources = ["arn:aws:cloudfront::${local.account}:distribution/*"]
  }
  statement {
    sid = "CloudFrontOac"
    actions = [
      "cloudfront:CreateOriginAccessControl", "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl",
    ]
    resources = ["arn:aws:cloudfront::${local.account}:origin-access-control/*"]
  }
}

resource "aws_iam_policy" "deploy" {
  for_each = {
    app   = data.aws_iam_policy_document.deploy_app.json   # estado, IAM, Lambda, logs, API Gateway, Cognito
    datos = data.aws_iam_policy_document.deploy_datos.json # Aurora, red, colas, eventos, DynamoDB, S3, CloudFront
  }
  name        = "lab09-github-actions-dev-${each.key}"
  description = "Permisos mínimos del pipeline para desplegar el stack de dev de StreamNote (${each.key})"
  policy      = each.value
}

resource "aws_iam_role_policy_attachment" "deploy" {
  for_each   = aws_iam_policy.deploy
  role       = aws_iam_role.github_deploy.name
  policy_arn = each.value.arn
}

output "role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "state_bucket" {
  value = local.state_bucket
}
