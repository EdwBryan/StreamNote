# Hosting de la web (React + Vite compilado): S3 privado detrás de CloudFront.
# El bucket no es público: solo CloudFront puede leerlo (Origin Access Control).

variable "prefix" {
  type = string
}

variable "force_destroy" {
  description = "true en dev/qa: permite borrar el bucket aunque tenga archivos"
  type        = bool
  default     = false
}

resource "aws_s3_bucket" "web" {
  bucket        = "${var.prefix}-web"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "web" {
  bucket                  = aws_s3_bucket.web.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "web" {
  name                              = "${var.prefix}-web"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# RNF-06: si una IP manda más de 300 solicitudes en 5 minutos, se bloquea
resource "aws_wafv2_web_acl" "web" {
  name  = "${var.prefix}-web"
  scope = "CLOUDFRONT" # el WAF de CloudFront siempre vive en us-east-1

  default_action {
    allow {}
  }

  rule {
    name     = "limite-por-ip"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = 300
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "limite-por-ip"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.prefix}-web"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_distribution" "web" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # puntos de presencia más baratos (Norteamérica y Europa); Perú se atiende desde EE. UU.
  web_acl_id          = aws_wafv2_web_acl.web.arn
  comment             = "${var.prefix} web"

  origin {
    domain_name              = aws_s3_bucket.web.bucket_regional_domain_name
    origin_id                = "s3-web"
    origin_access_control_id = aws_cloudfront_origin_access_control.web.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-web"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # política administrada CachingOptimized
  }

  # La app es una SPA: cualquier ruta (/notas, /comunidades/...) debe devolver index.html
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

    restrictions {
    # Los usuarios son estudiantes en Perú
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["PE"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Solo esta distribución de CloudFront puede leer el bucket
data "aws_iam_policy_document" "web" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.web.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.web.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web.json
}

output "bucket_name" {
  value = aws_s3_bucket.web.bucket
}

output "distribution_id" {
  value = aws_cloudfront_distribution.web.id
}

output "url" {
  value = "https://${aws_cloudfront_distribution.web.domain_name}"
}
