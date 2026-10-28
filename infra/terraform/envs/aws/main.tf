# Entorno AWS (us-east-2). Un solo código para dev, qa y prod: cambia el archivo .tfvars
# y la llave del estado. Reutiliza los módulos del entorno local y agrega lo que en local
# se emula: red para Aurora, Aurora, Lambda + API Gateway, Cognito, Scheduler y la web.
#
#   terraform init -backend-config="bucket=<bucket-de-estado>" -backend-config="key=dev/terraform.tfstate"
#   terraform plan -var-file=dev.tfvars
#
# Lo aplica el pipeline (.github/workflows/deploy.yml) según la rama:
#   develop -> dev   |   qa -> qa   |   main -> prod
# Pendiente: adaptador de Amazon IVS (MEDIA_PROVIDER=ivs), IVS Chat, Web Push, WAF, monitoreo.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # El bucket y la llave se pasan en "terraform init" (-backend-config), así el mismo
  # código sirve para los tres ambientes sin pisar el estado de otro.
  backend "s3" {
    region       = "us-east-1"
    use_lockfile = true # bloqueo nativo: dos despliegues a la vez no pueden romper el estado
  }
}

provider "aws" {
  region = "us-east-2"
  default_tags {
    tags = { proyecto = "streamnote", entorno = var.stage }
  }
}

variable "stage" {
  description = "dev, qa o prod"
  type        = string
}

variable "auth_mode" {
  description = "cognito (qa/prod) o local (solo dev, mientras el login con Cognito no esté en la web)"
  type        = string
  default     = "cognito"
  validation {
    condition     = contains(["cognito", "local"], var.auth_mode)
    error_message = "auth_mode debe ser cognito o local."
  }
}

variable "is_prod" {
  description = "Activa protecciones de producción (no borrar la base, conservar buckets)"
  type        = bool
  default     = false
}

variable "db_with_reader" {
  description = "Lector de Aurora en otra zona (RNF-04)"
  type        = bool
  default     = true
}

variable "ffmpeg_layer_arn" {
  type    = string
  default = ""
}

data "aws_caller_identity" "me" {}

locals {
  prefix = "streamnote-${var.stage}"
  # Los nombres de bucket son únicos en todo el mundo: se les agrega el número de cuenta
  bucket_prefix = "streamnote-${var.stage}-${data.aws_caller_identity.me.account_id}"
}

module "network" {
  source = "../../modules/network"
  prefix = local.prefix
}

module "web" {
  source        = "../../modules/web"
  prefix        = local.bucket_prefix
  force_destroy = !var.is_prod
}

module "messaging" {
  source = "../../modules/messaging"
  prefix = local.prefix
}

module "storage" {
  source        = "../../modules/storage"
  prefix        = local.bucket_prefix
  force_destroy = !var.is_prod
}

module "notifications" {
  source = "../../modules/notifications"
  prefix = local.prefix
}

module "database" {
  source              = "../../modules/database"
  prefix              = local.prefix
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.private_subnet_ids
  with_reader         = var.db_with_reader
  deletion_protection = var.is_prod
}

# Firma de los tokens del login de desarrollo (solo se usa con auth_mode = local).
# Terraform la genera y la guarda en el estado: nunca está escrita en el repo.
resource "random_password" "jwt" {
  length  = 48
  special = false
}

# ---------- Cognito (inicio de sesión; el proveedor de Google se agrega con sus credenciales) ----------
resource "aws_cognito_user_pool" "this" {
  name                     = "${local.prefix}-users"
  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]
}

resource "aws_cognito_user_pool_client" "web" {
  name                                 = "${local.prefix}-web"
  user_pool_id                         = aws_cognito_user_pool.this.id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"] # agregar "Google" al configurar el IdP
  callback_urls                        = [module.web.url]
  logout_urls                          = [module.web.url]
}

# ---------- EventBridge Scheduler: deja los recordatorios en la cola de eventos ----------
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sqs:SendMessage", Resource = module.messaging.queue_arns["domain-events"] }]
  })
}

module "api" {
  source             = "../../modules/api"
  prefix             = local.prefix
  bundle_dir         = "${path.root}/../../../../backend/dist/lambda"
  queue_arns         = module.messaging.queue_arns
  event_bus_arn      = module.messaging.event_bus_arn
  bucket_arn         = module.storage.bucket_arn
  table_arn          = module.notifications.table_arn
  db_cluster_arn     = module.database.cluster_arn
  db_secret_arn      = module.database.secret_arn
  scheduler_role_arn = aws_iam_role.scheduler.arn
  web_origins        = [module.web.url]
  ffmpeg_layer_arn   = var.ffmpeg_layer_arn

  environment = {
    STAGE                   = var.stage
    AUTH_MODE               = var.auth_mode
    COGNITO_ISSUER          = "https://cognito-idp.us-east-1.amazonaws.com/${aws_cognito_user_pool.this.id}"
    COGNITO_CLIENT_ID       = aws_cognito_user_pool_client.web.id
    JWT_SECRET              = random_password.jwt.result
    DB_DRIVER               = "data-api"
    DB_CLUSTER_ARN          = module.database.cluster_arn
    DB_SECRET_ARN           = module.database.secret_arn
    NOTE_WRITES_QUEUE_URL   = module.messaging.queue_urls["note-writes"]
    DOMAIN_EVENTS_QUEUE_URL = module.messaging.queue_urls["domain-events"]
    MEDIA_JOBS_QUEUE_URL    = module.messaging.queue_urls["media-jobs"]
    EVENT_BUS_NAME          = module.messaging.event_bus_name
    RECORDINGS_BUCKET       = module.storage.bucket_name
    NOTIFICATIONS_TABLE     = module.notifications.table_name
    SCHEDULER_MODE          = "eventbridge"
    SCHEDULER_TARGET_ARN    = module.messaging.queue_arns["domain-events"]
    SCHEDULER_ROLE_ARN      = aws_iam_role.scheduler.arn
    MEDIA_PROVIDER          = "ivs"
    REALTIME_MODE           = "none"
    EMULATE_S3_LIFECYCLE    = "false"
    WEB_ORIGIN              = module.web.url
  }
}

# ---------- Salidas que usa el pipeline ----------
output "api_url" {
  value = module.api.api_url
}

output "web_url" {
  value = module.web.url
}

output "web_bucket" {
  value = module.web.bucket_name
}

output "cloudfront_id" {
  value = module.web.distribution_id
}

output "db_cluster_arn" {
  value = module.database.cluster_arn
}

output "db_secret_arn" {
  value = module.database.secret_arn
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "auth_mode" {
  value = var.auth_mode
}
