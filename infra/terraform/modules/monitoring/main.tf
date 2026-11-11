# RNF-12: si más del 2 % de las solicitudes a la API fallan durante 5 minutos, llega un correo al equipo.

variable "prefix" {
  type = string
}

variable "api_id" {
  type = string
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
