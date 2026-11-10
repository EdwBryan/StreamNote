# Cómputo: una Lambda por dominio, como en el diagrama. Todas usan el mismo paquete del
# backend; lo que cambia es qué rutas les manda API Gateway, qué cola leen y su rol.

variable "prefix" {
  type = string
}

variable "bundle_dir" {
  description = "Carpeta con dist/lambda/index.mjs (npm run build:lambda en backend/)"
  type        = string
}

variable "environment" {
  description = "Variables de entorno comunes a todas las funciones"
  type        = map(string)
}

variable "queue_arns" {
  type = map(string)
}

variable "event_bus_arn" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "table_arn" {
  type = string
}

variable "db_cluster_arn" {
  type = string
}

variable "db_secret_arn" {
  type = string
}

variable "scheduler_role_arn" {
  type = string
}

variable "web_origins" {
  type = list(string)
}

variable "ffmpeg_layer_arn" {
  description = "Capa de Lambda con ffmpeg/ffprobe en /opt/bin, para media-jobs"
  type        = string
  default     = ""
}

data "archive_file" "bundle" {
  type        = "zip"
  source_dir  = var.bundle_dir
  output_path = "${path.module}/.build/${var.prefix}-lambda.zip"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

locals {
  # Permisos que puede pedir cada dominio (mínimo privilegio: cada uno apunta a un recurso concreto)
  permisos = {
    db = [
      { Effect = "Allow", Action = ["rds-data:ExecuteStatement", "rds-data:BatchExecuteStatement", "rds-data:BeginTransaction", "rds-data:CommitTransaction", "rds-data:RollbackTransaction"], Resource = var.db_cluster_arn },
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = var.db_secret_arn },
    ]
    eventos = [
      { Effect = "Allow", Action = "events:PutEvents", Resource = var.event_bus_arn },
    ]
    cola_notas = [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = var.queue_arns["note-writes"] },
    ]
    cola_eventos = [
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = var.queue_arns["domain-events"] },
    ]
    cola_media = [
      { Effect = "Allow", Action = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"], Resource = var.queue_arns["media-jobs"] },
    ]
    recordatorios = [
      { Effect = "Allow", Action = ["scheduler:CreateSchedule", "scheduler:DeleteSchedule"], Resource = "*" },
      { Effect = "Allow", Action = "iam:PassRole", Resource = var.scheduler_role_arn },
    ]
    notificaciones = [
      { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:UpdateItem"], Resource = var.table_arn },
    ]
    grabaciones = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:PutObjectTagging"], Resource = "${var.bucket_arn}/*" },
    ]
  }

  functions = {
    identidad      = { timeout = 15, memory = 512, permisos = ["db"] }
    comunidades    = { timeout = 15, memory = 512, permisos = ["db", "eventos"] }
    notas          = { timeout = 30, memory = 512, permisos = ["db", "eventos", "cola_notas"] }
    tareas         = { timeout = 15, memory = 512, permisos = ["db", "recordatorios"] }
    notificaciones = { timeout = 20, memory = 512, permisos = ["db", "eventos", "cola_eventos", "recordatorios", "notificaciones"] }
    streaming      = { timeout = 300, memory = 2048, permisos = ["db", "eventos", "cola_media", "recordatorios", "grabaciones"] }
  }

  # Qué cola lee cada dominio
  colas = {
    note-writes   = "notas"
    domain-events = "notificaciones"
    media-jobs    = "streaming"
  }

  # Qué Lambda atiende cada ruta de la API. API Gateway elige la ruta más específica.
  rutas = {
    "ANY /auth/{proxy+}"               = "identidad"
    "ANY /me"                          = "identidad"
    "ANY /communities"                 = "comunidades"
    "ANY /communities/{proxy+}"        = "comunidades"
    "ANY /notes"                       = "notas"
    "ANY /notes/{proxy+}"              = "notas"
    "ANY /files"                       = "notas"
    "ANY /folders"                     = "notas"
    "ANY /folders/{proxy+}"            = "notas"
    "ANY /communities/{id}/notes"      = "notas"
    "ANY /reminders"                   = "tareas"
    "ANY /reminders/{proxy+}"          = "tareas"
    "ANY /notifications"               = "notificaciones"
    "ANY /notifications/{proxy+}"      = "notificaciones"
    "ANY /streams/{proxy+}"            = "streaming"
    "ANY /recordings/{proxy+}"         = "streaming"
    "ANY /communities/{id}/streams"    = "streaming"
    "ANY /communities/{id}/recordings" = "streaming"
    "ANY /internal/{proxy+}"           = "streaming"
  }
}

resource "aws_iam_role" "lambda" {
  for_each           = local.functions
  name               = "${var.prefix}-lambda-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  for_each   = local.functions
  role       = aws_iam_role.lambda[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "app" {
  for_each = local.functions
  role     = aws_iam_role.lambda[each.key].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = flatten([for p in each.value.permisos : local.permisos[p]])
  })
}

resource "aws_lambda_function" "this" {
  for_each         = local.functions
  function_name    = "${var.prefix}-${each.key}"
  role             = aws_iam_role.lambda[each.key].arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  timeout          = each.value.timeout
  memory_size      = each.value.memory
  filename         = data.archive_file.bundle.output_path
  source_code_hash = data.archive_file.bundle.output_base64sha256
  layers           = each.key == "streaming" && var.ffmpeg_layer_arn != "" ? [var.ffmpeg_layer_arn] : []

  environment {
    variables = merge(var.environment, each.key == "streaming" ? { PATH = "/opt/bin:/usr/local/bin:/usr/bin:/bin" } : {})
  }
}

resource "aws_lambda_event_source_mapping" "queues" {
  for_each                = local.colas
  event_source_arn        = var.queue_arns[each.key]
  function_name           = aws_lambda_function.this[each.value].arn
  batch_size              = each.key == "media-jobs" ? 1 : 10
  function_response_types = ["ReportBatchItemFailures"]

  scaling_config {
    maximum_concurrency = each.key == "note-writes" ? 5 : 10 # note-writes: máximo 5 para no saturar Aurora (RNF-18)
  }
}

resource "aws_apigatewayv2_api" "http" {
  name          = "${var.prefix}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = var.web_origins
    allow_methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]
    allow_headers = ["authorization", "content-type"]
  }
}

resource "aws_apigatewayv2_integration" "http" {
  for_each               = local.functions
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  for_each  = local.rutas
  api_id    = aws_apigatewayv2_api.http.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.http[each.value].id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
  default_route_settings {
    throttling_burst_limit = 200
    throttling_rate_limit  = 100
  }
}

resource "aws_lambda_permission" "apigw" {
  for_each      = local.functions
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

output "api_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}
