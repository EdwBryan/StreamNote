# Alarmas que avisan al equipo por correo (SNS).
# RNF-12: si más del 2 % de las solicitudes a la API fallan durante 5 minutos, llega un correo al equipo.

variable "prefix" {
  type = string
}

variable "api_id" {
  type = string
}

variable "dlq_names" {
  description = "Nombre de cada DLQ, por cola"
  type        = map(string)
}

variable "function_names" {
  description = "Nombre de cada Lambda, por dominio"
  type        = map(string)
}

variable "alert_email" {
  description = "Correo del equipo. Viene del secreto ALERT_EMAIL de GitHub; vacío = sin suscripción"
  type        = string
  default     = ""
  sensitive   = true
}

resource "aws_sns_topic" "alertas" {
  #checkov:skip=CKV_AWS_26:Con la llave administrada aws/sns CloudWatch no puede publicar la alarma; haría falta una llave propia (1 USD al mes) para un aviso que no lleva datos de usuarios.
  name = "${var.prefix}-alertas"
}

resource "aws_sns_topic_subscription" "correo" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email" # AWS manda un correo para confirmar la suscripción
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "errores_api" {
  alarm_name          = "${var.prefix}-api-errores"
  alarm_description   = "Más del 2 % de las solicitudes a la API devolvieron 5xx en 5 minutos"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 2
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alertas.arn]

  metric_query {
    id          = "tasa"
    expression  = "IF(solicitudes > 0, 100 * errores / solicitudes, 0)"
    label       = "% de errores 5xx"
    return_data = true
  }

  metric_query {
    id = "errores"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5xx"
      period      = 300
      stat        = "Sum"
      dimensions  = { ApiId = var.api_id }
    }
  }

  metric_query {
    id = "solicitudes"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      period      = 300
      stat        = "Sum"
      dimensions  = { ApiId = var.api_id }
    }
  }
}

# RNF-05 y RNF-10: un mensaje en una DLQ es una operación que falló todos sus reintentos.
# Queda guardado 14 días, pero alguien tiene que revisarlo.
resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each            = var.dlq_names
  alarm_name          = "${var.prefix}-dlq-${each.key}"
  alarm_description   = "Hay mensajes en la DLQ de ${each.key}: fallaron todos sus reintentos"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}

# RNF-10: una Lambda que falla (excepción o tiempo agotado) avisa al equipo.
resource "aws_cloudwatch_metric_alarm" "lambda_errores" {
  for_each            = var.function_names
  alarm_name          = "${var.prefix}-lambda-${each.key}-errores"
  alarm_description   = "La Lambda ${each.key} falló en los últimos 5 minutos"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}

# RNF-09: si ya corren todas las Lambdas que la cuenta permite a la vez, las nuevas se rechazan (throttle).
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each            = var.function_names
  alarm_name          = "${var.prefix}-lambda-${each.key}-throttles"
  alarm_description   = "La Lambda ${each.key} rechazó solicitudes por falta de capacidad"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}
